// kx_skia_common.cpp — backend-independent implementation of the kx_skia ABI:
// raster surfaces, drawing helpers, readback. GPU backends plug in through
// kx_skia_platform.h.
#include "kx_skia.h"
#include "kx_skia_platform.h"
#include <cmath>

#include "include/core/SkCanvas.h"
#include "include/core/SkColor.h"
#include "include/core/SkData.h"
#include "include/core/SkFont.h"
#include "include/core/SkFontMgr.h"
#include "include/core/SkFontMetrics.h"
#include "include/core/SkFontStyle.h"
#include "include/core/SkImage.h"
#include "include/core/SkImageInfo.h"
#include "include/core/SkPaint.h"
#include "include/core/SkPathBuilder.h"
#include "include/core/SkRect.h"
#include "include/core/SkSamplingOptions.h"
#include "include/core/SkSurface.h"
#include "include/core/SkTextBlob.h"
#include "include/core/SkTypeface.h"
#include "include/effects/SkGradient.h"
#include "src/core/SkStroke.h"
#include "src/core/SkUTF.h"

#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <string>
#include <unordered_map>
#include <vector>
#if defined(__ARM_NEON) || defined(__ARM_NEON__)
#include <arm_neon.h>
#elif defined(__SSE2__)
#include <emmintrin.h>
#endif

struct KxRecLayer;

// One op recorded inside an alpha layer (0.12.0). The flat union keeps every
// argument needed to replay the draw later; only the variants in use carry
// data (xs/ys for polylines/polygons/clip paths, cols for gradient stops,
// text for string draws, child for nested layers).
struct KxRecOp {
    enum class K : uint8_t {
        Save, Restore, Translate, Scale, Rotate, ClipRect, ClipPath,
        Clear, FillRect, FillRRect, FillRRectCorners, StrokeRRect,
        StrokeRRectCorners, StrokePolyline, FillPolygon, FillRRectGradient,
        Text, ImageDraw, Group,
    } k;
    float f[8] = {};
    uint32_t color = 0;
    uint64_t image = 0;
    int count = 0;
    bool flag = false;
    float size = 0;
    std::string text;
    std::vector<float> xs, ys;
    std::vector<uint32_t> cols;
    std::unique_ptr<KxRecLayer> child;
    // The draw's extent in the coordinate space CURRENT when it was recorded
    // (pre-transform ops in this layer have not been applied to it yet —
    // the layer's `rel` matrix maps it into push space).
    SkRect local_bounds = SkRect::MakeEmpty();
};

// An alpha layer being recorded: the ops between kx_layer_alpha and its
// matching kx_restore, plus enough bookkeeping to decide the emission at
// close (see kx_layer_close).
struct KxRecLayer {
    float alpha = 1.0f;
    int depth = 0;            // save/clip opens still unmatched inside
    bool unbounded = false;   // a kx_clear was recorded — bounds unknown
    SkMatrix rel = SkMatrix::I(); // current-local -> push-space transform
    SkRect bounds = SkRect::MakeEmpty();
    bool bounds_valid = false;
    std::vector<KxRecOp> ops;

    void acc(const SkRect& local) {
        if (local.isEmpty()) return;
        SkRect mapped;
        rel.mapRect(&mapped, local);
        bounds.join(mapped);
        bounds_valid = true;
    }
};

struct kx_ctx {
    int width = 0;
    int height = 0;
    kx_backend backend = KX_BACKEND_RASTER;
    sk_sp<SkSurface> raster;     // raster backend
    kx::GpuState* gpu = nullptr; // GPU backends
    SkCanvas* canvas = nullptr;  // current frame
    // Image registry (per-ctx; images are plain pixel data, shared by all draws).
    struct KxImg {
        sk_sp<SkImage> img;
        // True when EVERY pixel's alpha is 0xFF — scanned once at register
        // time (SkImage::isOpaque only reflects the declared alpha type,
        // which premul rasters never satisfy). Opaque blits take the Src
        // path (write-only, no dst read).
        bool opaque = false;
    };
    std::unordered_map<uint64_t, KxImg> images;
    uint64_t next_image_id = 1;
    // Alpha-layer recorder (0.12.0): non-empty while a kx_layer_alpha region
    // is open — draw/state calls append to the top layer instead of issuing.
    std::vector<std::unique_ptr<KxRecLayer>> layers;
    // Offscreen render-to-image pass (0.12.0): kx_offscreen_begin swaps the
    // draw target; layer recording is paused inside (an offscreen pass is a
    // raster target of its own, not layer content).
    SkCanvas* offscreen_prev_canvas = nullptr;
    sk_sp<SkSurface> offscreen;
    int offscreen_w = 0;
    int offscreen_h = 0;
    // Ephemeral images registered by kx_draw_pixels inside an alpha layer —
    // destroyed right after the top-level layer's replay (they exist only
    // so the recorded ImageDraw op resolves at replay time).
    std::vector<uint64_t> owned_images;
    // Persistent backing store for the raster surface: SkSurfaces::Raster
    // mallocs fresh pages per kx_resize (each pixel's first write page-faults
    // — resize workloads pay a full-surface fault storm every frame). A
    // grow-only WrapPixels buffer allocates once and re-wraps in place.
    std::unique_ptr<uint8_t[]> raster_pixels;
    size_t raster_capacity = 0;
    // Point-array → SkPath memoization (0.12.0): clipPath/strokePolyline/
    // fillPolygon rebuild the same shapes every frame (star masks, chart
    // polylines). SkPathBuilder + the convexity pass is the per-call cost —
    // cache on a hash of the coords (verify by memcmp, bounded LRU).
    struct KxPathEntry {
        std::vector<float> xs, ys;
        bool closed = false;
        SkPath path;
        uint64_t tick = 0;
    };
    std::unordered_map<uint64_t, KxPathEntry> path_cache;
    uint64_t path_tick = 0;
    // Stroke-geometry memoization: a repeated stroke re-tessellates the same
    // outline every call — getFillPath produces the stroked fill path once
    // (the rasterizer's own path — identical pixels), then draws are fills.
    struct KxStrokeEntry {
        std::vector<float> xs, ys;
        float w = 0;
        bool cap = false;
        SkPath path;
        uint64_t tick = 0;
    };
    std::unordered_map<uint64_t, KxStrokeEntry> stroke_cache;
};

// Font manager is process-global: text metrics are needed at layout time,
// before/without a kx_ctx. Initialized once (thread-confined afterwards).
static sk_sp<SkFontMgr>& kx_fonts() {
    static sk_sp<SkFontMgr> mgr = kx::platform_font_mgr();
    return mgr;
}

static bool kx_typeface_covers(SkTypeface* tf, const char* utf8) {
    if (!tf) return false;
    const char* p = utf8;
    const char* const end = utf8 + std::strlen(utf8);
    while (p < end) {
        const SkUnichar u = SkUTF::NextUTF8(&p, end);
        if (u < 0) break;
        if (tf->unicharToGlyph(u) == 0) return false;
    }
    return true;
}

// legacyMakeTypeface goes through the platform font manager (CoreText on
// darwin) on every miss — ~4-6us for a resolved family name that never
// changes. The bench's list scenes shape ~13 fresh strings per operation;
// memoize (family, bold) -> typeface in a tiny fixed table.
struct KxFaceEntry {
    std::string family;
    bool bold = false;
    sk_sp<SkTypeface> tf;
};
static KxFaceEntry kx_face_cache[8];
static size_t kx_face_cache_n = 0;

static sk_sp<SkTypeface> kx_resolve_typeface(const char* family, bool bold) {
    // nullptr family = "platform default typeface" (darwin) — a valid,
    // cacheable key stored as the empty string.
    for (size_t i = 0; i < kx_face_cache_n; ++i) {
        KxFaceEntry& e = kx_face_cache[i];
        const bool same = family ? e.family == family : e.family.empty();
        if (e.bold == bold && same) return e.tf;
    }
    sk_sp<SkTypeface> tf = kx_fonts()->legacyMakeTypeface(
        family, bold ? SkFontStyle::Bold() : SkFontStyle::Normal());
    if (tf && kx_face_cache_n < std::size(kx_face_cache)) {
        KxFaceEntry& e = kx_face_cache[kx_face_cache_n++];
        e.family = family ? family : "";
        e.bold = bold;
        e.tf = tf;
    }
    return tf;
}

static SkFont kx_make_font(const char* text, float size, bool bold) {
    SkFont font;
    if (kx_fonts()) {
        sk_sp<SkTypeface> tf = kx_resolve_typeface(kx::platform_font_family(), bold);
        const char* fallback = kx::platform_fallback_font_family();
        if (tf && fallback && text && !kx_typeface_covers(tf.get(), text)) {
            if (sk_sp<SkTypeface> fbtf = kx_resolve_typeface(fallback, bold)) {
                if (kx_typeface_covers(fbtf.get(), text)) tf = std::move(fbtf);
            }
        }
        font.setTypeface(std::move(tf));
    }
    font.setSize(size);
    return font;
}

// --- Text shape/metrics cache ------------------------------------------
// kx_draw_text_styled and kx_measure_text each used to pay, on EVERY call:
// a font-mgr typeface lookup, a per-codepoint coverage scan
// (kx_typeface_covers), a UTF-8 decode + textToGlyphs, and glyph-run
// construction. A retained tree repaints the same strings every frame —
// the bench's gallery scene issued ~400 such font ops per frame before
// paint culling, and still pays it for every on-screen label.
//
// The shaped result depends only on (text bytes, size, bold), so it is
// cached: the resolved SkFont, an SkTextBlob (glyph ids + positions — the
// same conversion drawSimpleText performs, paid once), and the measured
// metrics. A hit is hash + probe + memcmp — no allocation, no font work.
// Direction is deliberately NOT in the key: drawSimpleText does no bidi —
// (text,size,bold) fully determines the glyphs (alignment/RTL resolution
// happens widget-side, in textX).
//
// Fixed-capacity open addressing (linear probing) with tombstones + LRU
// eviction: bounded memory, ZERO allocations on the hit path — key copies
// and blob construction happen only on a miss. Threading: the ABI's
// existing contract — thread-confined (no locking), process-global like
// the font manager (kx_measure_text takes no ctx, so the cache can't be
// per-ctx).
//
// The cached font/blob bake in the resolved typeface. The font manager is
// fixed at process start today; if a runtime font-registration API is
// added it MUST call kx_text_cache_reset() or stale glyphs would render.
namespace {

constexpr int kTextCacheCap = 2048;     // power of two — probe mask
constexpr int kTextCacheMaxUsed = 1536; // ~73% load keeps probes short

enum class KxTextSlotState : uint8_t { kEmpty, kOccupied, kTombstone };

struct KxTextSlot {
    std::string text;       // owned key bytes — allocated on insert only
    uint64_t hash = 0;
    float size = 0.0f;
    bool bold = false;
    KxTextSlotState state = KxTextSlotState::kEmpty;
    uint64_t last_used = 0; // LRU tick
    SkFont font;            // resolved typeface + size (fallback applied)
    sk_sp<SkTextBlob> blob; // null when the text can't form a blob
    kx_text_metrics metrics = {0, 0, 0, 0};
};

KxTextSlot kx_text_cache[kTextCacheCap];
int kx_text_cache_used = 0;
uint64_t kx_text_cache_tick = 0;

uint64_t kx_text_key_hash(const char* text, size_t len, float size, bool bold) {
    uint64_t h = 14695981039346656037ull; // FNV-1a over the UTF-8 bytes
    for (size_t i = 0; i < len; i++) {
        h ^= static_cast<uint8_t>(text[i]);
        h *= 1099511628211ull;
    }
    uint32_t size_bits;
    std::memcpy(&size_bits, &size, sizeof(size_bits));
    h ^= size_bits;
    h *= 1099511628211ull;
    h ^= bold ? 0xFFu : 0x33u;
    h *= 1099511628211ull;
    return h;
}

// Drop every entry — today only a future runtime font-registration API
// would need this (the font manager is fixed at process start).
[[maybe_unused]] void kx_text_cache_reset() {
    for (auto& s : kx_text_cache) s = KxTextSlot{}; // releases key + blob + typeface
    kx_text_cache_used = 0;
}

// Free one slot for a new key. A tombstone (not kEmpty) is left behind so
// probe chains that pass through this slot still terminate correctly.
void kx_text_cache_evict_lru() {
    int oldest = -1;
    for (int i = 0; i < kTextCacheCap; i++) {
        if (kx_text_cache[i].state == KxTextSlotState::kOccupied &&
            (oldest < 0 || kx_text_cache[i].last_used < kx_text_cache[oldest].last_used)) {
            oldest = i;
        }
    }
    if (oldest < 0) return;
    kx_text_cache[oldest] = KxTextSlot{};
    kx_text_cache[oldest].state = KxTextSlotState::kTombstone;
    --kx_text_cache_used;
}

// First tombstone-or-empty slot on key h's probe path (the key is known to
// be absent). Call only when such a slot is known to exist — the probe is
// unbounded.
int kx_text_cache_victim(uint64_t h) {
    const size_t mask = kTextCacheCap - 1;
    for (size_t i = h & mask;; i = (i + 1) & mask) {
        if (kx_text_cache[i].state != KxTextSlotState::kOccupied) return static_cast<int>(i);
    }
}

// The slot for (text,size,bold) — the shared entry for kx_measure_text and
// kx_draw_text_styled. On a miss the full font path runs ONCE (typeface
// resolution + coverage fallback + shaping + metrics) and the result is
// inserted; hits only refresh the LRU tick.
KxTextSlot* kx_text_entry(const char* text, size_t len, float size, bool bold) {
    const uint64_t h = kx_text_key_hash(text, len, size, bold);
    const uint64_t tick = ++kx_text_cache_tick;
    const size_t mask = kTextCacheCap - 1;
    size_t i = h & mask;
    int insert_at = -1;   // first reusable tombstone on the probe path
    bool hit_empty = false;
    for (int scanned = 0; scanned < kTextCacheCap; ++scanned) {
        KxTextSlot& s = kx_text_cache[i];
        if (s.state == KxTextSlotState::kEmpty) { hit_empty = true; break; }
        if (s.state == KxTextSlotState::kTombstone) {
            if (insert_at < 0) insert_at = static_cast<int>(i);
        } else if (s.hash == h && s.size == size && s.bold == bold &&
                   s.text.size() == len && std::memcmp(s.text.data(), text, len) == 0) {
            s.last_used = tick;
            return &s;
        }
        i = (i + 1) & mask;
    }
    // Miss — the key is absent (the probe hit a virgin slot, or scanned the
    // whole ring past only occupied/tombstone slots). Bound the live set:
    // evict the LRU entry once occupancy reaches kTextCacheMaxUsed; the
    // evicted slot becomes a tombstone, so a pathological all-non-empty ring
    // still yields an insert slot below.
    if (kx_text_cache_used >= kTextCacheMaxUsed) kx_text_cache_evict_lru();
    if (insert_at < 0) {
        insert_at = hit_empty ? static_cast<int>(i) : kx_text_cache_victim(h);
    }
    KxTextSlot& s = kx_text_cache[insert_at];
    s.text.assign(text, len); // owned key copy — the only per-entry alloc
    s.hash = h;
    s.size = size;
    s.bold = bold;
    s.last_used = tick;
    s.font = kx_make_font(text, size, bold);
    // One shaping pass feeds both consumers: textToGlyphs once, then
    // getWidthsBounds gives the advances (the metric width MakeFromText +
    // measureText used to compute through a second decode+map pass) and
    // allocRunPosH stores the same glyphs+positions in the blob directly.
    // The blob draws identically to a MakeFromText TextH run — the simple
    // glyph path applies no GPOS shaping either way.
    const size_t nglyphs =
        s.font.getTypeface() ? s.font.countText(text, len, SkTextEncoding::kUTF8) : 0;
    if (nglyphs > 0) {
        std::vector<SkGlyphID> glyphs(nglyphs);
        s.font.textToGlyphs(text, len, SkTextEncoding::kUTF8,
                            SkSpan<SkGlyphID>(glyphs.data(), nglyphs));
        std::vector<SkScalar> advances(nglyphs);
        s.font.getWidthsBounds(SkSpan<const SkGlyphID>(glyphs.data(), nglyphs),
                               SkSpan<SkScalar>(advances.data(), nglyphs), {}, nullptr);
        std::vector<SkScalar> xs(nglyphs);
        SkScalar x = 0;
        for (size_t i = 0; i < nglyphs; ++i) {
            xs[i] = x;
            x += advances[i];
        }
        s.metrics.width = x;
        SkTextBlobBuilder builder;
        const SkTextBlobBuilder::RunBuffer& run =
            builder.allocRunPosH(s.font, int(nglyphs), /*constY=*/0);
        std::memcpy(run.glyphs, glyphs.data(), nglyphs * sizeof(SkGlyphID));
        std::memcpy(run.pos, xs.data(), nglyphs * sizeof(SkScalar));
        s.blob = builder.make();
    } else {
        s.blob = nullptr;
        s.metrics.width = 0;
    }
    SkFontMetrics fm;
    s.font.getMetrics(&fm);
    s.metrics.ascent = -fm.fAscent; // fAscent is negative (above the baseline)
    s.metrics.descent = fm.fDescent;
    s.metrics.height = s.metrics.ascent + s.metrics.descent;
    s.state = KxTextSlotState::kOccupied;
    ++kx_text_cache_used;
    return &s;
}

} // namespace

// kx color: 0xRRGGBBAA → SkColor: 0xAARRGGBB
static SkColor kx_to_skcolor(uint32_t rgba) {
    const uint32_t r = (rgba >> 24) & 0xFF;
    const uint32_t g = (rgba >> 16) & 0xFF;
    const uint32_t b = (rgba >> 8) & 0xFF;
    const uint32_t a = rgba & 0xFF;
    return SkColorSetARGB(a, r, g, b);
}

// --- Alpha-layer recorder (0.12.0) ----------------------------------------
// kx_layer_alpha used to push saveLayerAlphaf(nullptr, a): a fresh offscreen
// raster the size of the CURRENT CLIP (usually the whole surface) for every
// layer — a 300x110 glass card paid a full-screen composite and the bench's
// overdraw_stack paid 24 of them per frame.
//
// The layer now RECORDS the ops drawn until its kx_restore and resolves at
// close:
//   - empty                                 -> emit nothing;
//   - one provably non-self-overlapping draw (solid fills, image draws —
//     primitives whose pixels can't overlap inside the layer): a single
//     draw composited at alpha A produces the exact same pixels as the
//     draw with its alpha multiplied by A, so the alpha folds into the
//     paint and NO offscreen pass exists at all;
//   - anything else                         -> ONE saveLayer bounded to the
//     union of the recorded ops' mapped bounds (a card-sized layer costs
//     card-sized raster, not window-sized), with the ops replayed inside.
//
// Nested layers record recursively: a closing child lands in its parent as
// a folded draw or a Group op — its own elision already ran. Replay goes
// through the public kx_* entry points, so nested groups re-record and
// re-resolve (fold/bound) on their own close.
namespace {

bool kx_recording(const kx_ctx* ctx) {
    // The offscreen pass is a raster target of its own: draws inside it are
    // not part of an open alpha layer's content.
    return !ctx->layers.empty() && !ctx->offscreen_prev_canvas;
}

// Fold a 0..1 alpha multiplier into a kx color's alpha channel.
uint32_t kx_fold_color(uint32_t rgba, float a) {
    const float base = (rgba & 0xFF) / 255.0f;
    uint32_t na = static_cast<uint32_t>(base * a * 255.0f + 0.5f);
    if (na > 255) na = 255;
    return (rgba & 0xFFFFFF00u) | na;
}

// Ops that provably cannot self-overlap inside a layer: a convex fill or a
// destination-rect image blit. Strokes/paths/text can (AA joins, glyph
// overlap) — folding those would change group-alpha semantics, so they
// always take the real saveLayer path.
bool kx_op_foldable(const KxRecOp& op) {
    switch (op.k) {
        case KxRecOp::K::FillRect:
        case KxRecOp::K::FillRRect:
        case KxRecOp::K::FillRRectCorners:
        case KxRecOp::K::FillRRectGradient:
        case KxRecOp::K::ImageDraw:
            return true;
        default:
            return false;
    }
}

SkRect kx_xywh(float x, float y, float w, float h, float pad) {
    return SkRect::MakeLTRB(x - pad, y - pad, x + w + pad, y + h + pad);
}

SkRect kx_pts_bounds(const float* xs, const float* ys, int n, float pad) {
    float l = xs[0], t = ys[0], r = xs[0], b = ys[0];
    for (int i = 1; i < n; i++) {
        l = std::min(l, xs[i]); r = std::max(r, xs[i]);
        t = std::min(t, ys[i]); b = std::max(b, ys[i]);
    }
    return SkRect::MakeLTRB(l - pad, t - pad, r + pad, b + pad);
}

void kx_rec_op(kx_ctx* ctx, KxRecOp op) {
    KxRecLayer* L = ctx->layers.back().get();
    L->acc(op.local_bounds);
    L->ops.push_back(std::move(op));
}

void kx_replay_ops(kx_ctx* ctx, const std::vector<KxRecOp>& ops);

// Emit a folded draw directly on the canvas: `op` is the layer's only op.
void kx_emit_folded(kx_ctx* ctx, const KxRecOp& op, float alpha) {
    SkCanvas* c = ctx->canvas;
    SkPaint paint;
    paint.setAntiAlias(true);
    switch (op.k) {
        case KxRecOp::K::FillRect:
            paint.setColor(kx_to_skcolor(kx_fold_color(op.color, alpha)));
            c->drawRect(SkRect::MakeXYWH(op.f[0], op.f[1], op.f[2], op.f[3]), paint);
            break;
        case KxRecOp::K::FillRRect:
            paint.setColor(kx_to_skcolor(kx_fold_color(op.color, alpha)));
            c->drawRoundRect(SkRect::MakeXYWH(op.f[0], op.f[1], op.f[2], op.f[3]),
                             op.f[4], op.f[4], paint);
            break;
        case KxRecOp::K::FillRRectCorners: {
            paint.setColor(kx_to_skcolor(kx_fold_color(op.color, alpha)));
            SkRRect rrect;
            const SkVector radii[4] = {{op.f[4], op.f[4]}, {op.f[5], op.f[5]},
                                       {op.f[6], op.f[6]}, {op.f[7], op.f[7]}};
            rrect.setRectRadii(SkRect::MakeXYWH(op.f[0], op.f[1], op.f[2], op.f[3]), radii);
            c->drawRRect(rrect, paint);
            break;
        }
        case KxRecOp::K::FillRRectGradient: {
            SkColor4f stops[8];
            for (int i = 0; i < op.count; i++) {
                const uint32_t rgba = kx_fold_color(op.cols[i], alpha);
                stops[i] = {((rgba >> 24) & 0xFF) / 255.0f, ((rgba >> 16) & 0xFF) / 255.0f,
                            ((rgba >> 8) & 0xFF) / 255.0f, (rgba & 0xFF) / 255.0f};
            }
            SkGradient::Interpolation interp;
            interp.fInPremul = SkGradient::Interpolation::InPremul::kYes;
            const SkGradient grad(SkGradient::Colors(
                SkSpan<const SkColor4f>(stops, op.count), SkTileMode::kClamp), interp);
            const SkPoint pts[2] = {{op.xs[0], op.ys[0]}, {op.xs[1], op.ys[1]}};
            paint.setShader(SkShaders::LinearGradient(pts, grad));
            c->drawRoundRect(SkRect::MakeXYWH(op.f[0], op.f[1], op.f[2], op.f[3]),
                             op.f[4], op.f[4], paint);
            break;
        }
        case KxRecOp::K::ImageDraw: {
            auto it = ctx->images.find(op.image);
            if (it == ctx->images.end()) break;
            paint.setAlphaf(alpha);
            const SkImage* img = it->second.img.get();
            c->drawImageRect(img, SkRect::MakeIWH(img->width(), img->height()),
                             SkRect::MakeXYWH(op.f[0], op.f[1], op.f[2], op.f[3]),
                             SkSamplingOptions(), &paint,
                             SkCanvas::kStrict_SrcRectConstraint);
            break;
        }
        default:
            break;
    }
}

// Close the top recorded layer: emit onto the canvas when it is the
// outermost one, otherwise fold/group it into the parent layer's op list.
void kx_layer_close(kx_ctx* ctx) {
    std::unique_ptr<KxRecLayer> L = std::move(ctx->layers.back());
    ctx->layers.pop_back();
    KxRecLayer* parent = ctx->layers.empty() ? nullptr : ctx->layers.back().get();

    if (L->ops.empty()) return; // an alpha layer with no content is a no-op

    if (L->ops.size() == 1 && kx_op_foldable(L->ops.front())) {
        KxRecOp op = std::move(L->ops.front());
        if (parent) {
            // The folded draw joins the parent's content: its alpha is
            // baked in now (color folds into the paint, image draws carry
            // it in `size`), its bounds accumulate like any other op.
            switch (op.k) {
                case KxRecOp::K::FillRRectGradient:
                    for (auto& c : op.cols) c = kx_fold_color(c, L->alpha);
                    break;
                case KxRecOp::K::ImageDraw:
                    op.size = L->alpha; // folded alpha rides in `size`
                    op.flag = true;     // marks the fold (alpha can be 0)
                    break;
                default:
                    op.color = kx_fold_color(op.color, L->alpha);
                    break;
            }
            kx_rec_op(ctx, std::move(op));
        } else {
            kx_emit_folded(ctx, op, L->alpha);
            // The folded op drew now — ephemeral uploads can go too.
            for (uint64_t id : ctx->owned_images) ctx->images.erase(id);
            ctx->owned_images.clear();
        }
        return;
    }

    if (parent) {
        // A nested layer lands as one Group op in the parent; its bounds
        // are already in the parent's coordinate space (the child pushed
        // there), and the parent's rel maps them into the union.
        KxRecOp g{KxRecOp::K::Group};
        g.local_bounds = L->bounds;
        g.child = std::move(L);
        kx_rec_op(ctx, std::move(g));
        return;
    }

    // Top level: ONE bounded saveLayer, ops replayed through the public
    // entry points (nested Group ops re-record and re-resolve on close).
    SkRect b = L->bounds;
    b.outset(1.0f, 1.0f); // AA fringe allowance — never clip content edges
    ctx->canvas->saveLayerAlphaf(L->bounds_valid && !L->unbounded ? &b : nullptr,
                                 L->alpha);
    kx_replay_ops(ctx, L->ops);
    ctx->canvas->restore();
    // Ephemeral kx_draw_pixels uploads live only until their layer replays.
    for (uint64_t id : ctx->owned_images) ctx->images.erase(id);
    ctx->owned_images.clear();
}

void kx_replay_ops(kx_ctx* ctx, const std::vector<KxRecOp>& ops) {
    for (const KxRecOp& op : ops) {
        switch (op.k) {
            case KxRecOp::K::Save: kx_save(ctx); break;
            case KxRecOp::K::Restore: kx_restore(ctx); break;
            case KxRecOp::K::Translate: kx_translate(ctx, op.f[0], op.f[1]); break;
            case KxRecOp::K::Scale: kx_scale(ctx, op.f[0], op.f[1]); break;
            case KxRecOp::K::Rotate: kx_rotate(ctx, op.f[0]); break;
            case KxRecOp::K::ClipRect:
                kx_clip_rect(ctx, op.f[0], op.f[1], op.f[2], op.f[3]);
                break;
            case KxRecOp::K::ClipPath:
                kx_clip_path(ctx, op.xs.data(), op.ys.data(), op.count, op.f[0] != 0.0f ? 1 : 0);
                break;
            case KxRecOp::K::Clear: kx_clear(ctx, op.color); break;
            case KxRecOp::K::FillRect:
                kx_fill_rect(ctx, op.f[0], op.f[1], op.f[2], op.f[3], op.color);
                break;
            case KxRecOp::K::FillRRect:
                kx_fill_rrect(ctx, op.f[0], op.f[1], op.f[2], op.f[3], op.f[4], op.color);
                break;
            case KxRecOp::K::FillRRectCorners:
                kx_fill_rrect_corners(ctx, op.f[0], op.f[1], op.f[2], op.f[3],
                                      op.f[4], op.f[5], op.f[6], op.f[7], op.color);
                break;
            case KxRecOp::K::StrokeRRect:
                kx_stroke_rrect(ctx, op.f[0], op.f[1], op.f[2], op.f[3],
                                op.f[4], op.f[5], op.color);
                break;
            case KxRecOp::K::StrokeRRectCorners:
                kx_stroke_rrect_corners(ctx, op.f[0], op.f[1], op.f[2], op.f[3],
                                        op.f[4], op.f[5], op.f[6], op.f[7],
                                        op.size, op.color);
                break;
            case KxRecOp::K::StrokePolyline:
                kx_stroke_polyline(ctx, op.xs.data(), op.ys.data(), op.count,
                                   op.size, op.flag, op.color);
                break;
            case KxRecOp::K::FillPolygon:
                kx_fill_polygon(ctx, op.xs.data(), op.ys.data(), op.count, op.color);
                break;
            case KxRecOp::K::FillRRectGradient:
                kx_fill_rrect_gradient(ctx, op.f[0], op.f[1], op.f[2], op.f[3],
                                       op.f[4], op.xs[0], op.ys[0], op.xs[1],
                                       op.ys[1], op.cols.data(), op.count);
                break;
            case KxRecOp::K::Text:
                kx_draw_text_styled(ctx, op.text.c_str(), op.f[0], op.f[1],
                                    op.size, op.flag, op.color);
                break;
            case KxRecOp::K::ImageDraw: {
                // `flag` marks a folded op: `size` then carries the layer
                // alpha and the draw replays with an alpha paint.
                if (!op.flag) {
                    kx_draw_image(ctx, op.image, op.f[0], op.f[1], op.f[2], op.f[3]);
                } else {
                    auto it = ctx->images.find(op.image);
                    if (it != ctx->images.end()) {
                        SkPaint paint;
                        paint.setAlphaf(op.size);
                        const SkImage* img = it->second.img.get();
                        ctx->canvas->drawImageRect(
                            img, SkRect::MakeIWH(img->width(), img->height()),
                            SkRect::MakeXYWH(op.f[0], op.f[1], op.f[2], op.f[3]),
                            SkSamplingOptions(), &paint,
                            SkCanvas::kStrict_SrcRectConstraint);
                    }
                }
                break;
            }
            case KxRecOp::K::Group:
                // A nested layer replays through the recorder too: its ops
                // re-record and its close resolves fold-vs-real on its own.
                kx_layer_alpha(ctx, op.child->alpha);
                kx_replay_ops(ctx, op.child->ops);
                kx_restore(ctx);
                break;
        }
    }
}

} // namespace

// Backend fallback chain — the contract in docs/ARCHITECTURE.md: primary is
// Graphite on the native API, fallback is the Ganesh GL family, raster is the
// always-available last resort. KX_BACKEND_AUTO walks the whole chain; an
// explicit backend tries itself then raster (the app survives a missing
// driver, never silently switches APIs).
static const kx_backend* kx_platform_chain(size_t* count) {
#if defined(__EMSCRIPTEN__)
    static const kx_backend chain[] = { KX_BACKEND_GANESH_WEBGL2 };
#elif defined(__ANDROID__)
    static const kx_backend chain[] = { KX_BACKEND_GRAPHITE_VULKAN, KX_BACKEND_GANESH_GLES };
#elif defined(__APPLE__)
    // iOS and macOS share the chain: Metal everywhere, raster if it fails.
    static const kx_backend chain[] = { KX_BACKEND_GRAPHITE_METAL };
#elif defined(_WIN32)
    static const kx_backend chain[] = { KX_BACKEND_GRAPHITE_DAWN, KX_BACKEND_GANESH_GL };
#elif defined(__linux__)
    static const kx_backend chain[] = { KX_BACKEND_GRAPHITE_VULKAN, KX_BACKEND_GANESH_GL };
#else
    static const kx_backend chain[] = { KX_BACKEND_RASTER };
#endif
    *count = sizeof(chain) / sizeof(chain[0]);
    return chain;
}

// (Re)wrap the ctx's raster surface over the persistent grow-only pixel
// buffer — resize recreates the SkSurface view but never re-allocates
// pages it already owns (fresh SkSurfaces::Raster mallocs a full buffer
// whose first writes page-fault per pixel).
static bool kx_make_raster(kx_ctx* ctx, int width, int height) {
    const size_t need = static_cast<size_t>(width) * static_cast<size_t>(height) * 4;
    if (ctx->raster_capacity < need) {
        const size_t cap = std::max(need, ctx->raster_capacity * 2);
        ctx->raster_pixels = std::make_unique<uint8_t[]>(cap);
        ctx->raster_capacity = cap;
    }
    ctx->raster = SkSurfaces::WrapPixels(
        SkImageInfo::MakeN32Premul(width, height),
        ctx->raster_pixels.get(), static_cast<size_t>(width) * 4);
    return ctx->raster != nullptr;
}

kx_ctx* kx_create(void* sdl_window, int width, int height, kx_backend backend) {
    if (width <= 0 || height <= 0) return nullptr;

    // Resolve the backend: AUTO walks the platform chain, an explicit request
    // tries just that backend; both end on raster (which cannot fail on
    // supported platforms) rather than returning NULL.
    size_t chain_len = 0;
    const kx_backend* chain = kx_platform_chain(&chain_len);
    // Try list: [requested] for an explicit backend, the full platform chain
    // for AUTO — raster appended at the end in both cases.
    const kx_backend* try_list = &backend;
    size_t try_len = 1;
    if (backend == KX_BACKEND_AUTO) {
        try_list = chain;
        try_len = chain_len;
    }

    for (size_t i = 0; i <= try_len; i++) {
        const kx_backend attempt = (i < try_len) ? try_list[i] : KX_BACKEND_RASTER;
        if (attempt == KX_BACKEND_AUTO) continue; // chain never lists AUTO

        auto* ctx = new kx_ctx();
        ctx->width = width;
        ctx->height = height;
        ctx->backend = attempt;

        bool ok = false;
        if (attempt == KX_BACKEND_RASTER) {
            ok = kx_make_raster(ctx, width, height);
        } else {
            ok = kx::gpu_init(&ctx->gpu, sdl_window, width, height, attempt);
        }
        if (ok) return ctx;
        delete ctx;
    }
    return nullptr;
}

void kx_destroy(kx_ctx* ctx) {
    if (!ctx) return;
    if (ctx->gpu) kx::gpu_shutdown(ctx->gpu);
    delete ctx;
}

void kx_resize(kx_ctx* ctx, int width, int height) {
    if (!ctx || width <= 0 || height <= 0) return;
    // A frame in flight holds the surface being replaced. Closing it out
    // at the old size lets gpu_end_frame present valid pixels AND release
    // its drawable/recorder — just clearing ctx->canvas left that frame
    // active, so the next kx_end_frame would present stale pixels. Resize
    // is still meant to happen between frames; this keeps a stray
    // mid-frame call well-defined.
    if (ctx->canvas) kx_end_frame(ctx);
    ctx->width = width;
    ctx->height = height;
    if (ctx->raster) {
        kx_make_raster(ctx, width, height);
    } else if (ctx->gpu) {
        kx::gpu_resize(ctx->gpu, width, height);
    }
}

void kx_begin_frame(kx_ctx* ctx) {
    if (!ctx) return;
    // Unbalanced layer records from a previous frame die with it.
    ctx->layers.clear();
    if (ctx->raster) {
        ctx->canvas = ctx->raster->getCanvas();
    } else if (ctx->gpu) {
        ctx->canvas = kx::gpu_begin_frame(ctx->gpu);
    }
}

void kx_end_frame(kx_ctx* ctx) {
    if (!ctx) return;
    // Defensive: an unclosed layer still emits its content at frame end so
    // a broken caller loses compositing quality, never pixels.
    while (ctx->canvas && !ctx->layers.empty()) kx_layer_close(ctx);
    if (ctx->gpu) {
        kx::gpu_end_frame(ctx->gpu);
    }
    // Raster is synchronous — drawing lands in the pixel buffer immediately,
    // nothing to flush (SkSurface::flush no longer exists at this pin).
    ctx->canvas = nullptr;
}

void kx_clear(kx_ctx* ctx, uint32_t rgba) {
    if (!ctx || !ctx->canvas) return;
    if (kx_recording(ctx)) {
        KxRecOp op{KxRecOp::K::Clear};
        op.color = rgba;
        ctx->layers.back()->unbounded = true; // a clear fills the whole layer
        ctx->layers.back()->ops.push_back(std::move(op));
        return;
    }
    ctx->canvas->clear(kx_to_skcolor(rgba));
}

void kx_draw_text(kx_ctx* ctx, const char* text, float x, float y, float size, uint32_t rgba) {
    kx_draw_text_styled(ctx, text, x, y, size, false, rgba);
}

void kx_draw_text_styled(kx_ctx* ctx, const char* text, float x, float y, float size, bool bold, uint32_t rgba) {
    if (!ctx || !ctx->canvas || !text) return;
    const size_t len = std::strlen(text);
    if (kx_recording(ctx)) {
        KxRecOp op{KxRecOp::K::Text};
        op.f[0] = x; op.f[1] = y;
        op.size = size; op.flag = bold; op.color = rgba;
        op.text.assign(text, len);
        if (size > 0.0f) {
            const KxTextSlot* e = kx_text_entry(text, len, size, bold);
            op.local_bounds = SkRect::MakeLTRB(x - 1, y - e->metrics.ascent - 1,
                                               x + e->metrics.width + 2,
                                               y + e->metrics.descent + 1);
        }
        kx_rec_op(ctx, std::move(op));
        return;
    }
    // Degenerate keys bypass the cache: NaN never matches itself (it would
    // re-insert forever), and non-positive sizes draw nothing anyway.
    if (!(size > 0.0f)) {
        SkFont font = kx_make_font(text, size, bold);
        SkPaint paint;
        paint.setColor(kx_to_skcolor(rgba));
        paint.setAntiAlias(true);
        ctx->canvas->drawSimpleText(text, len, SkTextEncoding::kUTF8, x, y, font, paint);
        return;
    }
    const KxTextSlot* e = kx_text_entry(text, len, size, bold);
    SkPaint paint;
    paint.setColor(kx_to_skcolor(rgba));
    paint.setAntiAlias(true);
    if (e->blob) {
        // The cached glyph run replays at any origin — drawTextBlob(blob,x,y)
        // is what drawSimpleText computes per call (UTF-8 decode → glyphs →
        // advances from the origin) — identical output, no re-shaping.
        ctx->canvas->drawTextBlob(e->blob.get(), x, y, paint);
    } else {
        // Unshapeable input (e.g. empty string or no resolvable glyphs):
        // draw through the stored font — identical to the uncached path.
        ctx->canvas->drawSimpleText(text, len, SkTextEncoding::kUTF8, x, y, e->font, paint);
    }
}

kx_text_metrics kx_measure_text(const char* text, float size, bool bold) {
    kx_text_metrics m = {0, 0, 0, 0};
    if (!text) return m;
    if (!(size > 0.0f)) {
        // Degenerate key (NaN/<=0 bypasses the cache — see kx_draw_text_styled):
        // run the uncached path so the returned metrics are unchanged.
        const SkFont font = kx_make_font(text, size, bold);
        SkFontMetrics fm;
        font.getMetrics(&fm);
        m.ascent = -fm.fAscent;
        m.descent = fm.fDescent;
        m.height = m.ascent + m.descent;
        if (font.getTypeface()) {
            m.width = font.measureText(text, std::strlen(text), SkTextEncoding::kUTF8);
        }
        return m;
    }
    return kx_text_entry(text, std::strlen(text), size, bold)->metrics;
}

// True when every 4-byte pixel's alpha byte (offset 3 for all our 8888
// formats — N32 BGRA and RGBA alike) is 0xFF. Scanned once at register time
// because SkImage::isOpaque only reflects the DECLARED alpha type.
static bool kx_pixels_opaque(const uint8_t* p, size_t bytes) {
    for (size_t i = 3; i < bytes; i += 4)
        if (p[i] != 0xFF) return false;
    return true;
}

static bool kx_image_content_opaque(const SkImage* img) {
    SkPixmap pm;
    if (!img || !img->peekPixels(&pm)) return false;
    if (pm.info().bytesPerPixel() != 4) return false;
    const uint8_t* row = static_cast<const uint8_t*>(pm.addr());
    const size_t row_bytes = static_cast<size_t>(pm.width()) * 4;
    for (int y = 0; y < pm.height(); ++y, row += pm.rowBytes())
        if (!kx_pixels_opaque(row, row_bytes)) return false;
    return true;
}

uint64_t kx_image_create(kx_ctx* ctx, const uint8_t* rgba, int32_t w, int32_t h) {
    if (!ctx || !rgba || w <= 0 || h <= 0) return 0;
    const size_t bytes = static_cast<size_t>(w) * static_cast<size_t>(h) * 4;
    sk_sp<SkData> data = SkData::MakeWithCopy(rgba, bytes);
    if (!data) return 0;
    sk_sp<SkImage> img = SkImages::RasterFromData(
        SkImageInfo::Make(w, h, kRGBA_8888_SkColorType, kUnpremul_SkAlphaType),
        std::move(data), static_cast<size_t>(w) * 4);
    if (!img) return 0;
    // GPU ctx: upload now if a recorder is live (mid-frame creates); else the
    // lazy upgrade in kx_draw_image converts at first draw.
    if (ctx->gpu) img = kx::gpu_image_upload(ctx->gpu, std::move(img));
    const uint64_t id = ctx->next_image_id++;
    ctx->images.emplace(id, kx_ctx::KxImg{std::move(img), kx_pixels_opaque(rgba, bytes)});
    return id;
}

void kx_image_destroy(kx_ctx* ctx, uint64_t image) {
    if (ctx && image) ctx->images.erase(image);
}

uint8_t kx_image_is_opaque(kx_ctx* ctx, uint64_t image) {
    if (!ctx || !image) return 0;
    auto it = ctx->images.find(image);
    return (it != ctx->images.end() && it->second.opaque) ? 1 : 0;
}

void kx_draw_image(kx_ctx* ctx, uint64_t image, float x, float y, float w, float h) {
    if (!ctx || !ctx->canvas || !image || w <= 0 || h <= 0) return;
    if (kx_recording(ctx)) {
        KxRecOp op{KxRecOp::K::ImageDraw};
        op.f[0] = x; op.f[1] = y; op.f[2] = w; op.f[3] = h;
        op.image = image;
        op.local_bounds = kx_xywh(x, y, w, h, 0.5f);
        kx_rec_op(ctx, std::move(op));
        return;
    }
    auto it = ctx->images.find(image);
    if (it == ctx->images.end()) return;
    // Lazy GPU upgrade: images created before the first frame had no recorder
    // to upload through — convert at first draw (TextureFromImage no-ops on
    // already GPU-backed images).
    if (ctx->gpu && !it->second.img->isTextureBacked())
        it->second.img = kx::gpu_image_upload(ctx->gpu, it->second.img);
    const SkImage* img = it->second.img.get();
    if (w == img->width() && h == img->height()) {
        // Opaque same-format blit under an integer translation: peek both
        // buffers and copy the visible rows in 16-byte vectors — the cheapest
        // honest path (a kSrc paint avoids the dst read but falls off Skia's
        // sprite blitter into a slow pipeline, measured ~5x slower than
        // SrcOver; and this TU's plain memcpy binds to a naive byte loop).
        if (it->second.opaque) {
            const SkMatrix& ctm = ctx->canvas->getTotalMatrix();
            if (ctm.getType() <= SkMatrix::kTranslate_Mask) {
                SkPixmap src, dst;
                const bool sp = img->peekPixels(&src), dp = ctx->canvas->peekPixels(&dst);
                if (sp && dp &&
                    src.info().colorType() == dst.info().colorType() &&
                    src.info().bytesPerPixel() == 4) {
                    const int dx = (int)std::lround(x + ctm.getTranslateX());
                    const int dy = (int)std::lround(y + ctm.getTranslateY());
                    const SkIRect drect = SkIRect::MakeXYWH(dx, dy, src.width(), src.height());
                    SkIRect vis;
                    if (vis.intersect(drect, ctx->canvas->getDeviceClipBounds()) && !vis.isEmpty()) {
                        const size_t bytes = static_cast<size_t>(vis.width()) * 4;
                        const uint8_t* srow = static_cast<const uint8_t*>(src.addr()) +
                            static_cast<size_t>(vis.y() - dy) * src.rowBytes() +
                            static_cast<size_t>(vis.x() - dx) * 4;
                        uint8_t* drow = static_cast<uint8_t*>(dst.writable_addr()) +
                            static_cast<size_t>(vis.y()) * dst.rowBytes() +
                            static_cast<size_t>(vis.x()) * 4;
                        // Row copy in explicit 16-byte vectors: this TU's
                        // plain memcpy binds to a naive byte loop (~4 GB/s)
                        // — NEON/SSE moves at hardware speed.
                        const size_t vec = bytes / 16;
                        for (int yy = 0; yy < vis.height(); ++yy) {
                            const uint8_t* s = srow;
                            uint8_t* d = drow;
#if defined(__ARM_NEON) || defined(__ARM_NEON__)
                            for (size_t k = 0; k < vec; ++k, s += 16, d += 16)
                                vst1q_u8(d, vld1q_u8(s));
#elif defined(__SSE2__)
                            for (size_t k = 0; k < vec; ++k, s += 16, d += 16)
                                _mm_storeu_si128((__m128i*)d, _mm_loadu_si128((const __m128i*)s));
#else
                            for (size_t k = 0; k < bytes / 8; ++k)
                                ((uint64_t*)d)[k] = ((const uint64_t*)s)[k];
#endif
                            const size_t tail = bytes % 16;
                            if (tail) memcpy(d, s, tail);
                            srow += src.rowBytes();
                            drow += dst.rowBytes();
                        }
                    }
                    return;
                }
            }
        }
        ctx->canvas->drawImage(img, x, y, SkSamplingOptions(), nullptr);
        return;
    }
    ctx->canvas->drawImageRect(img, SkRect::MakeIWH(img->width(), img->height()),
                               SkRect::MakeXYWH(x, y, w, h),
                               SkSamplingOptions(), nullptr,
                               SkCanvas::kFast_SrcRectConstraint);
}

void kx_draw_pixels(kx_ctx* ctx, const uint8_t* rgba, int32_t w, int32_t h,
                    float x, float y, float dw, float dh) {
    if (!ctx || !ctx->canvas || !rgba || w <= 0 || h <= 0 || dw <= 0 || dh <= 0) return;
    if (kx_recording(ctx)) {
        // A layer replays after the call — the borrowed pixels can't outlive
        // it, so this path registers like kx_image_create (one copy, only on
        // the rare pixels-in-layer pattern) and self-cleans at layer close.
        const uint64_t id = kx_image_create(ctx, rgba, w, h);
        if (!id) return;
        ctx->owned_images.push_back(id);
        KxRecOp op{KxRecOp::K::ImageDraw};
        op.f[0] = x; op.f[1] = y; op.f[2] = dw; op.f[3] = dh;
        op.image = id;
        op.local_bounds = kx_xywh(x, y, dw, dh, 0.5f);
        kx_rec_op(ctx, std::move(op));
        return;
    }
    const SkImageInfo info = SkImageInfo::Make(w, h, kRGBA_8888_SkColorType, kUnpremul_SkAlphaType);
    if (ctx->gpu) {
        // GPU path: own the pixels — the backend upload may defer its read
        // past this call, so the borrowed buffer can't be relied on.
        sk_sp<SkData> data = SkData::MakeWithCopy(rgba, static_cast<size_t>(w) * h * 4);
        sk_sp<SkImage> img = SkImages::RasterFromData(info, std::move(data), static_cast<size_t>(w) * 4);
        img = kx::gpu_image_upload(ctx->gpu, std::move(img));
        ctx->canvas->drawImageRect(img.get(), SkRect::MakeIWH(w, h), SkRect::MakeXYWH(x, y, dw, dh),
                                   SkSamplingOptions(), nullptr,
                                   SkCanvas::kFast_SrcRectConstraint);
        return;
    }
    // Borrowed-pixels draw: RasterFromPixmap wraps the buffer with no copy —
    // a raster canvas consumes it synchronously, so the borrow is safe.
    SkPixmap pixmap(info, rgba, static_cast<size_t>(w) * 4);
    ctx->canvas->drawImageRect(SkImages::RasterFromPixmap(pixmap, {}, nullptr).get(),
                               SkRect::MakeIWH(w, h), SkRect::MakeXYWH(x, y, dw, dh),
                               SkSamplingOptions(), nullptr,
                               SkCanvas::kFast_SrcRectConstraint);
}

void kx_fill_rect(kx_ctx* ctx, float x, float y, float w, float h, uint32_t rgba) {
    if (!ctx || !ctx->canvas) return;
    if (kx_recording(ctx)) {
        KxRecOp op{KxRecOp::K::FillRect};
        op.f[0] = x; op.f[1] = y; op.f[2] = w; op.f[3] = h;
        op.color = rgba;
        op.local_bounds = kx_xywh(x, y, w, h, 0.5f);
        kx_rec_op(ctx, std::move(op));
        return;
    }
    SkPaint paint;
    paint.setColor(kx_to_skcolor(rgba));
    paint.setAntiAlias(true);
    ctx->canvas->drawRect(SkRect::MakeXYWH(x, y, w, h), paint);
}

void kx_fill_rrect(kx_ctx* ctx, float x, float y, float w, float h, float radius, uint32_t rgba) {
    if (!ctx || !ctx->canvas) return;
    if (kx_recording(ctx)) {
        KxRecOp op{KxRecOp::K::FillRRect};
        op.f[0] = x; op.f[1] = y; op.f[2] = w; op.f[3] = h; op.f[4] = radius;
        op.color = rgba;
        op.local_bounds = kx_xywh(x, y, w, h, 0.5f);
        kx_rec_op(ctx, std::move(op));
        return;
    }
    SkPaint paint;
    paint.setColor(kx_to_skcolor(rgba));
    paint.setAntiAlias(true);
    ctx->canvas->drawRoundRect(SkRect::MakeXYWH(x, y, w, h), radius, radius, paint);
}

void kx_fill_rrect_corners(kx_ctx* ctx, float x, float y, float w, float h, float tl, float tr, float br, float bl, uint32_t rgba) {
    if (!ctx || !ctx->canvas) return;
    if (kx_recording(ctx)) {
        KxRecOp op{KxRecOp::K::FillRRectCorners};
        op.f[0] = x; op.f[1] = y; op.f[2] = w; op.f[3] = h;
        op.f[4] = tl; op.f[5] = tr; op.f[6] = br; op.f[7] = bl;
        op.color = rgba;
        op.local_bounds = kx_xywh(x, y, w, h, 0.5f);
        kx_rec_op(ctx, std::move(op));
        return;
    }
    SkPaint paint;
    paint.setColor(kx_to_skcolor(rgba));
    paint.setAntiAlias(true);
    SkRRect rrect;
    const SkVector radii[4] = {{tl, tl}, {tr, tr}, {br, br}, {bl, bl}};
    rrect.setRectRadii(SkRect::MakeXYWH(x, y, w, h), radii);
    ctx->canvas->drawRRect(rrect, paint);
}

void kx_stroke_rrect(kx_ctx* ctx, float x, float y, float w, float h, float radius, float stroke_w, uint32_t rgba) {
    if (!ctx || !ctx->canvas || stroke_w <= 0) return;
    if (kx_recording(ctx)) {
        KxRecOp op{KxRecOp::K::StrokeRRect};
        op.f[0] = x; op.f[1] = y; op.f[2] = w; op.f[3] = h;
        op.f[4] = radius; op.f[5] = stroke_w;
        op.color = rgba;
        op.local_bounds = kx_xywh(x, y, w, h, stroke_w / 2 + 1.5f);
        kx_rec_op(ctx, std::move(op));
        return;
    }
    SkPaint paint;
    paint.setColor(kx_to_skcolor(rgba));
    paint.setAntiAlias(true);
    paint.setStyle(SkPaint::kStroke_Style);
    paint.setStrokeWidth(stroke_w);
    ctx->canvas->drawRoundRect(SkRect::MakeXYWH(x, y, w, h), radius, radius, paint);
}

void kx_stroke_rrect_corners(kx_ctx* ctx, float x, float y, float w, float h, float tl, float tr, float br, float bl, float stroke_w, uint32_t rgba) {
    if (!ctx || !ctx->canvas || stroke_w <= 0) return;
    if (kx_recording(ctx)) {
        KxRecOp op{KxRecOp::K::StrokeRRectCorners};
        op.f[0] = x; op.f[1] = y; op.f[2] = w; op.f[3] = h;
        op.f[4] = tl; op.f[5] = tr; op.f[6] = br; op.f[7] = bl;
        op.size = stroke_w; op.color = rgba;
        op.local_bounds = kx_xywh(x, y, w, h, stroke_w / 2 + 1.5f);
        kx_rec_op(ctx, std::move(op));
        return;
    }
    SkPaint paint;
    paint.setColor(kx_to_skcolor(rgba));
    paint.setAntiAlias(true);
    paint.setStyle(SkPaint::kStroke_Style);
    paint.setStrokeWidth(stroke_w);
    SkRRect rrect;
    const SkVector radii[4] = {{tl, tl}, {tr, tr}, {br, br}, {bl, bl}};
    rrect.setRectRadii(SkRect::MakeXYWH(x, y, w, h), radii);
    ctx->canvas->drawRRect(rrect, paint);
}

/// Point-array → SkPath memoization (see kx_ctx::path_cache): hash the
/// coords, verify by memcmp, build on miss, evict stale entries past 256.
static const SkPath& kx_cached_path(kx_ctx* ctx, const float* xs, const float* ys, int count, bool closed) {
    uint64_t h = 1469598103934665603ull; // FNV-1a
    for (int i = 0; i < count * 4; i++) {
        h ^= reinterpret_cast<const uint8_t*>(xs)[i]; h *= 1099511628211ull;
        h ^= reinterpret_cast<const uint8_t*>(ys)[i]; h *= 1099511628211ull;
    }
    h ^= (uint64_t)count * 0x9E3779B97F4A7C15ull + (closed ? 1 : 0);
    auto& ent = ctx->path_cache[h];
    ent.tick = ++ctx->path_tick;
    if (ent.xs.size() == (size_t)count && ent.ys.size() == (size_t)count &&
        ent.closed == closed && !ent.xs.empty() &&
        std::memcmp(ent.xs.data(), xs, count * 4) == 0 &&
        std::memcmp(ent.ys.data(), ys, count * 4) == 0) {
        return ent.path;
    }
    SkPathBuilder builder;
    builder.moveTo(xs[0], ys[0]);
    for (int i = 1; i < count; i++) builder.lineTo(xs[i], ys[i]);
    if (closed) builder.close();
    ent.path = builder.snapshot();
    ent.xs.assign(xs, xs + count);
    ent.ys.assign(ys, ys + count);
    ent.closed = closed;
    if (ctx->path_cache.size() > 256) {
        for (auto it = ctx->path_cache.begin(); it != ctx->path_cache.end();) {
            if (it->first != h && ctx->path_tick - it->second.tick > 200)
                it = ctx->path_cache.erase(it);
            else ++it;
        }
    }
    return ent.path;
}

/// Stroke params → stroked-fill SkPath (see kx_ctx::stroke_cache). The
/// stroker runs once per (pts,width,cap); subsequent draws are plain fills
/// of the identical outline — same pixels, no per-frame tessellation.
static const SkPath& kx_cached_stroke(kx_ctx* ctx, const float* xs, const float* ys,
                                      int count, float stroke_w, bool round_cap) {
    uint64_t h = 1469598103934665603ull;
    for (int i = 0; i < count * 4; i++) {
        h ^= reinterpret_cast<const uint8_t*>(xs)[i]; h *= 1099511628211ull;
        h ^= reinterpret_cast<const uint8_t*>(ys)[i]; h *= 1099511628211ull;
    }
    h ^= (uint64_t)count * 0x9E3779B97F4A7C15ull;
    uint32_t wbits;
    std::memcpy(&wbits, &stroke_w, 4);
    h ^= (uint64_t)wbits * 0xBF58476D1CE4E5B9ull + (round_cap ? 1 : 0);
    auto& ent = ctx->stroke_cache[h];
    ent.tick = ++ctx->path_tick;
    if (ent.xs.size() == (size_t)count && ent.ys.size() == (size_t)count &&
        ent.w == stroke_w && ent.cap == round_cap && !ent.xs.empty() &&
        std::memcmp(ent.xs.data(), xs, count * 4) == 0 &&
        std::memcmp(ent.ys.data(), ys, count * 4) == 0) {
        return ent.path;
    }
    SkPathBuilder builder;
    builder.moveTo(xs[0], ys[0]);
    for (int i = 1; i < count; i++) builder.lineTo(xs[i], ys[i]);
    SkStroke stroke;
    stroke.setWidth(stroke_w);
    stroke.setCap(round_cap ? SkPaint::kRound_Cap : SkPaint::kButt_Cap);
    SkPathBuilder out;
    stroke.strokePath(builder.snapshot(), &out);
    ent.path = out.snapshot();
    ent.xs.assign(xs, xs + count);
    ent.ys.assign(ys, ys + count);
    ent.w = stroke_w;
    ent.cap = round_cap;
    if (ctx->stroke_cache.size() > 256) {
        for (auto it = ctx->stroke_cache.begin(); it != ctx->stroke_cache.end();) {
            if (it->first != h && ctx->path_tick - it->second.tick > 200)
                it = ctx->stroke_cache.erase(it);
            else ++it;
        }
    }
    return ent.path;
}

void kx_stroke_polyline(kx_ctx* ctx, const float* xs, const float* ys, int count, float stroke_w, bool round_cap, uint32_t rgba) {
    if (!ctx || !ctx->canvas || !xs || !ys || count < 2 || stroke_w <= 0) return;
    if (kx_recording(ctx)) {
        KxRecOp op{KxRecOp::K::StrokePolyline};
        op.xs.assign(xs, xs + count);
        op.ys.assign(ys, ys + count);
        op.count = count; op.size = stroke_w; op.flag = round_cap; op.color = rgba;
        op.local_bounds = kx_pts_bounds(xs, ys, count, stroke_w + 1.5f);
        kx_rec_op(ctx, std::move(op));
        return;
    }
    SkPaint paint;
    paint.setColor(kx_to_skcolor(rgba));
    paint.setAntiAlias(true);
    // Fill the cached stroked outline — the stroker's own output, identical
    // pixels to a live stroke but tessellated once per (pts,w,cap).
    ctx->canvas->drawPath(kx_cached_stroke(ctx, xs, ys, count, stroke_w, round_cap), paint);
}

void kx_fill_polygon(kx_ctx* ctx, const float* xs, const float* ys, int count, uint32_t rgba) {
    if (!ctx || !ctx->canvas || !xs || !ys || count < 3) return;
    if (kx_recording(ctx)) {
        KxRecOp op{KxRecOp::K::FillPolygon};
        op.xs.assign(xs, xs + count);
        op.ys.assign(ys, ys + count);
        op.count = count; op.color = rgba;
        op.local_bounds = kx_pts_bounds(xs, ys, count, 0.5f);
        kx_rec_op(ctx, std::move(op));
        return;
    }
    SkPaint paint;
    paint.setColor(kx_to_skcolor(rgba));
    paint.setAntiAlias(true);
    paint.setStyle(SkPaint::kFill_Style);
    ctx->canvas->drawPath(kx_cached_path(ctx, xs, ys, count, /*closed=*/true), paint);
}

// kx color: 0xRRGGBBAA → SkColor4f (unpremul floats 0..1)
static SkColor4f kx_to_skcolor4f(uint32_t rgba) {
    return {
        ((rgba >> 24) & 0xFF) / 255.0f,
        ((rgba >> 16) & 0xFF) / 255.0f,
        ((rgba >> 8) & 0xFF) / 255.0f,
        (rgba & 0xFF) / 255.0f,
    };
}

void kx_fill_rrect_gradient(kx_ctx* ctx, float x, float y, float w, float h, float radius,
                            float x0, float y0, float x1, float y1,
                            const uint32_t* colors, int count) {
    if (!ctx || !ctx->canvas || !colors || count < 2 || count > 8) return;
    if (kx_recording(ctx)) {
        KxRecOp op{KxRecOp::K::FillRRectGradient};
        op.f[0] = x; op.f[1] = y; op.f[2] = w; op.f[3] = h; op.f[4] = radius;
        op.xs.push_back(x0); op.xs.push_back(x1);
        op.ys.push_back(y0); op.ys.push_back(y1);
        op.cols.assign(colors, colors + count);
        op.count = count;
        op.local_bounds = kx_xywh(x, y, w, h, 0.5f);
        kx_rec_op(ctx, std::move(op));
        return;
    }
    SkColor4f stops[8];
    for (int i = 0; i < count; i++) stops[i] = kx_to_skcolor4f(colors[i]);
    // Premul interpolation: alpha fades (white→transparent over the hue) stay
    // correct instead of darkening through transparent black.
    SkGradient::Interpolation interp;
    interp.fInPremul = SkGradient::Interpolation::InPremul::kYes;
    const SkGradient grad(SkGradient::Colors(SkSpan<const SkColor4f>(stops, count), SkTileMode::kClamp), interp);
    const SkPoint pts[2] = {{x0, y0}, {x1, y1}};
    SkPaint paint;
    paint.setAntiAlias(true);
    paint.setShader(SkShaders::LinearGradient(pts, grad));
    if (!paint.getShader()) return;
    ctx->canvas->drawRoundRect(SkRect::MakeXYWH(x, y, w, h), radius, radius, paint);
}

void kx_save(kx_ctx* ctx) {
    if (!ctx || !ctx->canvas) return;
    if (kx_recording(ctx)) {
        KxRecLayer* L = ctx->layers.back().get();
        L->depth++;
        L->ops.push_back(KxRecOp{KxRecOp::K::Save});
        return;
    }
    ctx->canvas->save();
}

void kx_restore(kx_ctx* ctx) {
    if (!ctx || !ctx->canvas) return;
    if (!ctx->layers.empty() && !ctx->offscreen_prev_canvas) {
        KxRecLayer* L = ctx->layers.back().get();
        if (L->depth > 0) {
            // Balances a save/clip recorded inside the layer.
            L->depth--;
            L->ops.push_back(KxRecOp{KxRecOp::K::Restore});
            return;
        }
        kx_layer_close(ctx);
        return;
    }
    ctx->canvas->restore();
}

void kx_translate(kx_ctx* ctx, float dx, float dy) {
    if (!ctx || !ctx->canvas) return;
    if (kx_recording(ctx)) {
        KxRecLayer* L = ctx->layers.back().get();
        SkMatrix m;
        m.setTranslate(dx, dy);
        L->rel.postConcat(m);
        KxRecOp op{KxRecOp::K::Translate};
        op.f[0] = dx; op.f[1] = dy;
        L->ops.push_back(std::move(op));
        return;
    }
    ctx->canvas->translate(dx, dy);
}

void kx_scale(kx_ctx* ctx, float sx, float sy) {
    if (!ctx || !ctx->canvas) return;
    if (kx_recording(ctx)) {
        KxRecLayer* L = ctx->layers.back().get();
        SkMatrix m;
        m.setScale(sx, sy);
        L->rel.postConcat(m);
        KxRecOp op{KxRecOp::K::Scale};
        op.f[0] = sx; op.f[1] = sy;
        L->ops.push_back(std::move(op));
        return;
    }
    ctx->canvas->scale(sx, sy);
}

void kx_rotate(kx_ctx* ctx, float degrees) {
    if (!ctx || !ctx->canvas) return;
    if (kx_recording(ctx)) {
        KxRecLayer* L = ctx->layers.back().get();
        SkMatrix m;
        m.setRotate(degrees);
        L->rel.postConcat(m);
        KxRecOp op{KxRecOp::K::Rotate};
        op.f[0] = degrees;
        L->ops.push_back(std::move(op));
        return;
    }
    ctx->canvas->rotate(degrees);
}

void kx_layer_alpha(kx_ctx* ctx, float alpha) {
    if (!ctx || !ctx->canvas) return;
    float a = alpha;
    if (a < 0.0f) a = 0.0f;
    if (a > 1.0f) a = 1.0f;
    if (ctx->offscreen_prev_canvas) {
        // The offscreen raster is a plain canvas: layers inside it keep the
        // real saveLayer behaviour (recording is suspended there).
        ctx->canvas->saveLayerAlphaf(nullptr, a);
        return;
    }
    // Record: ops accumulate until the matching kx_restore, then resolve —
    // empty layers vanish, single non-overlapping draws fold the alpha into
    // their paint, everything else gets one bounded saveLayer.
    auto L = std::make_unique<KxRecLayer>();
    L->alpha = a;
    ctx->layers.push_back(std::move(L));
}

void kx_clip_rect(kx_ctx* ctx, float x, float y, float w, float h) {
    if (!ctx || !ctx->canvas) return;
    if (kx_recording(ctx)) {
        KxRecLayer* L = ctx->layers.back().get();
        L->depth++;
        KxRecOp op{KxRecOp::K::ClipRect};
        op.f[0] = x; op.f[1] = y; op.f[2] = w; op.f[3] = h;
        op.local_bounds = kx_xywh(x, y, w, h, 1.0f);
        // A clip can only shrink output: keep it out of the union so a
        // clip bigger than the content doesn't inflate the layer bounds.
        L->ops.push_back(std::move(op));
        return;
    }
    ctx->canvas->save();
    ctx->canvas->clipRect(SkRect::MakeXYWH(x, y, w, h), SkClipOp::kIntersect, true);
}

void kx_clip_path(kx_ctx* ctx, const float* xs, const float* ys, int count, int aa) {
    if (!ctx || !ctx->canvas || !xs || !ys || count < 3) return;
    if (kx_recording(ctx)) {
        KxRecLayer* L = ctx->layers.back().get();
        L->depth++;
        KxRecOp op{KxRecOp::K::ClipPath};
        op.xs.assign(xs, xs + count);
        op.ys.assign(ys, ys + count);
        op.count = count;
        op.f[0] = aa ? 1.0f : 0.0f;
        L->ops.push_back(std::move(op));
        return;
    }
    const SkPath& path = kx_cached_path(ctx, xs, ys, count, /*closed=*/true);
    ctx->canvas->save();
    ctx->canvas->clipPath(path, SkClipOp::kIntersect, aa != 0);
}

void kx_clip_reset(kx_ctx* ctx) {
    kx_restore(ctx);
}

// --- Offscreen render-to-image (0.12.0) ------------------------------------
// Rasterizes arbitrary drawing into a reusable SkImage. The pass swaps the
// ctx draw target onto a private raster surface; the image registry stores
// the snapshot so kx_draw_image/kx_image_destroy work on the returned id.
bool kx_offscreen_begin(kx_ctx* ctx, int w, int h) {
    if (!ctx || !ctx->canvas || w <= 0 || h <= 0 || ctx->offscreen_prev_canvas) return false;
    // GPU ctx: a backend render target so the snapshot draws GPU→GPU
    // (Graphite drops raster images entirely). Falls back to raster.
    ctx->offscreen = ctx->gpu ? kx::gpu_offscreen_surface(ctx->gpu, w, h) : nullptr;
    if (!ctx->offscreen) ctx->offscreen = SkSurfaces::Raster(SkImageInfo::MakeN32Premul(w, h));
    if (!ctx->offscreen) return false;
    ctx->offscreen_w = w;
    ctx->offscreen_h = h;
    ctx->offscreen_prev_canvas = ctx->canvas;
    ctx->canvas = ctx->offscreen->getCanvas();
    ctx->canvas->clear(SK_ColorTRANSPARENT);
    return true;
}

uint64_t kx_offscreen_end_image(kx_ctx* ctx) {
    if (!ctx || !ctx->offscreen_prev_canvas) return 0;
    sk_sp<SkImage> img = ctx->offscreen->makeImageSnapshot();
    ctx->canvas = ctx->offscreen_prev_canvas;
    ctx->offscreen_prev_canvas = nullptr;
    ctx->offscreen.reset();
    ctx->offscreen_w = 0;
    ctx->offscreen_h = 0;
    if (!img) return 0;
    const bool opaque = kx_image_content_opaque(img.get());
    const uint64_t id = ctx->next_image_id++;
    ctx->images.emplace(id, kx_ctx::KxImg{std::move(img), opaque});
    return id;
}

bool kx_readback_rgba(kx_ctx* ctx, void* dst, size_t dst_size, int* out_width, int* out_height) {
    if (!ctx || !ctx->raster || !dst) return false;
    if (out_width) *out_width = ctx->width;
    if (out_height) *out_height = ctx->height;
    const size_t needed = static_cast<size_t>(ctx->width) * static_cast<size_t>(ctx->height) * 4;
    if (dst_size < needed) return false;
    const SkImageInfo dst_info = SkImageInfo::Make(ctx->width, ctx->height,
                                                  kRGBA_8888_SkColorType, kUnpremul_SkAlphaType);
    return ctx->raster->readPixels(dst_info, dst, static_cast<size_t>(ctx->width) * 4, 0, 0);
}

bool kx_gpu_warmup(kx_ctx* ctx) {
    if (!ctx) return false;
    if (!ctx->gpu) return true; // raster: nothing to pre-compile
    SkCanvas* canvas = kx::gpu_begin_offscreen(ctx->gpu, 64, 64);
    if (!canvas) return false;
    // Draw the framework's full op set through the public entry points —
    // the exact paint code paths real frames take, so the programs compiled
    // here are the programs the first real frames would otherwise compile
    // on the fly (Ganesh compiles lazily per draw op on first use).
    ctx->canvas = canvas;
    kx_clear(ctx, 0x000000FF);
    kx_fill_rect(ctx, 2, 2, 20, 20, 0x3366CCFF);
    kx_fill_rrect(ctx, 4, 4, 40, 40, 8, 0x663399FF);
    kx_fill_rrect_corners(ctx, 0, 0, 60, 60, 12, 0, 0, 0, 0x00CC88FF);
    kx_stroke_rrect(ctx, 6, 6, 50, 50, 10, 2, 0xCC3366FF);
    kx_stroke_rrect_corners(ctx, 2, 2, 58, 58, 0, 8, 0, 8, 1.5f, 0x9933CCFF);
    const float xs[4] = {0, 64, 64, 0};
    const float ys[4] = {0, 0, 64, 64};
    kx_fill_polygon(ctx, xs, ys, 4, 0x33AA66FF);
    kx_stroke_polyline(ctx, xs, ys, 4, 1.0f, true, 0xAA3366FF);
    const uint32_t grad[2] = {0xFF0000FF, 0x0000FFFF};
    kx_fill_rrect_gradient(ctx, 8, 8, 48, 48, 10, 0, 0, 64, 64, grad, 2);
    const uint8_t pixel[4] = {255, 128, 64, 255};
    const uint64_t img = kx_image_create(ctx, pixel, 1, 1);
    if (img) {
        kx_draw_image(ctx, img, 32, 32, 16, 16);
        kx_image_destroy(ctx, img);
    }
    // Clip path (scroll viewports clip their content on every backend).
    kx_clip_rect(ctx, 0, 0, 32, 32);
    kx_fill_rect(ctx, 8, 8, 20, 20, 0xFFFFFF80);
    kx_clip_reset(ctx);
    // Alpha layer (fade transitions): composite + text under a layer.
    kx_layer_alpha(ctx, 0.5f);
    kx_draw_text_styled(ctx, "warmup", 4, 40, 12, true, 0xFFFFFFFF);
    kx_draw_text(ctx, "warmup", 4, 56, 12, 0xCCCCCCCC);
    kx_restore(ctx); // pops the saveLayer pushed by kx_layer_alpha
    ctx->canvas = nullptr;
    return kx::gpu_end_offscreen(ctx->gpu);
}

kx_backend kx_backend_of(const kx_ctx* ctx) {
    return ctx ? ctx->backend : KX_BACKEND_RASTER;
}

const char* kx_abi_version(void) {
    return "0.13.0";
}

const char* kx_backend_name(kx_backend backend) {
    switch (backend) {
        case KX_BACKEND_RASTER: return "raster";
        case KX_BACKEND_GRAPHITE_METAL: return "graphite-metal";
        case KX_BACKEND_GRAPHITE_VULKAN: return "graphite-vulkan";
        case KX_BACKEND_GANESH_GLES: return "ganesh-gles";
        case KX_BACKEND_GANESH_GL: return "ganesh-gl";
        case KX_BACKEND_GRAPHITE_DAWN: return "graphite-dawn";
        case KX_BACKEND_GRAPHITE_WEBGPU: return "graphite-webgpu";
        case KX_BACKEND_GANESH_WEBGL2: return "ganesh-webgl2";
        case KX_BACKEND_GANESH_METAL: return "ganesh-metal";
        case KX_BACKEND_AUTO: return "auto";
    }
    return "unknown";
}
