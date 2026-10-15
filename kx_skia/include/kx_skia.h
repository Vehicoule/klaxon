// kx_skia.h — Klaxon's C ABI over Skia. No C++ type crosses this boundary:
// Zig sees only opaque handles and C functions.
//
// Conventions:
//   - Colors are 0xRRGGBBAA (R in the high byte, alpha in the low byte).
//   - Coordinates are in pixels, origin top-left, y down.
//   - All functions are thread-confined to the caller's thread (no internal
//     locking). Exception: the font manager is process-global (lazily
//     initialized once) because text metrics are needed before/without a ctx.
//
// Version history:
//   0.1.0 — Phase 0: raster, clear, text, rect, rrect, readback.
//   0.2.0 — Phase 1b: + kx_draw_text_styled (bold-aware text), + kx_measure_text
//           (text metrics for widget layout), + image registry (create once,
//           draw many — no per-frame allocation). Purely additive: the 0.1.0
//           entry points keep their signatures (ADR-0009: breaking changes
//           bump the major version; additive changes bump the minor).
//   0.3.0 — Phase 1e: + canvas state (kx_save/kx_restore), transforms
//           (kx_translate/kx_scale) for paint-time animated offsets/scales,
//           + clipping (kx_clip_rect/kx_clip_reset) for dirty-rect repaints.
//   0.4.0 — Phase 2a: + kx_layer_alpha (saveLayer with alpha) for fade
//           transitions. Restored with kx_restore, like kx_save.
//   0.6.0 — Phase 2d.2: + kx_stroke_rrect (outlined M3E button borders).
//   0.7.0 — Phase 2d.2 PR C2: + kx_fill_rrect_corners (per-corner radii —
//           the M3E filled text field's top-only rounded corners).
//   0.8.0 — Phase 2d.3 PR D3: + kx_stroke_rrect_corners (per-corner radii
//           stroke — the M3E segmented/split buttons' 1dp borders on
//           start/end/middle shapes).
//   0.9.0 — Phase 2d.4 PR #32: + kx_fill_polygon (a closed polygon fill —
//           the M3E loading indicator's morphing shapes; no path type
//           crosses this boundary, like kx_stroke_polyline).
//   0.10.0 — Phase 2d.4 PR #34: + kx_fill_rrect_gradient (a 2..8-stop linear
//           gradient fill clipped to a rounded rect — the color picker's SV
//           square overlays + hue slider; no shader type crosses this
//           boundary).
//   0.11.0 — Phase 4e.1: + kx_gpu_warmup (compile the framework's op set
//           into a small offscreen GPU surface and submit, so the first real
//           frames do not pay one-time program compilation — retail frame
//           p99 was dominated by first-frames shader-compile jank). Purely
//           additive: no existing entry point changed.
//   0.12.0 — Phase 4e.2: + kx_rotate (the last rigid transform the canvas
//           lacked), + kx_clip_path (arbitrary polygon clip — star masks,
//           avatar cutouts; no path type crosses the boundary), +
//           kx_offscreen_begin/kx_offscreen_end_image (render-to-image: a
//           vector asset rasterized once, then drawn like any registered
//           image — the retained-cache idiom). Purely additive.
//   0.13.0 — + kx_image_is_opaque (skip the destination clear under a
//           full-coverage opaque blit), + kx_draw_pixels (zero-copy borrowed
//           pixel draw — the video texture-upload idiom), + aa flag on
//           kx_clip_path. Purely additive except the kx_clip_path signature.
//   0.14.0 — + kx_frame_draw_ops (real submitted-op count per frame).
//   0.15.0 — real text: kx_draw_text/_styled/measure_text now shape through
//            SkParagraph (HarfBuzz + ICU bidi + fallback); + kx_text_layout
//            multi-style span API.
//   0.16.0 — real primitives: kx_layer_blur (content blur via image filter),
//            kx_backdrop_blur (backdrop filter saveLayer), kx_shadow_rrect
//            (SkShadowUtils ambient+spot elevation shadows), kx_fill_path/
//            kx_stroke_path (verb-encoded cubic paths).
//   0.17.0 — variable fonts: kx_text_style gains variation axes (OpenType
//            variation design coordinates — SkFontArguments::VariationPosition
//            via TextStyle::setFontArguments). Struct-append only; existing
//            zero-initialized callers behave identically (count 0).
#ifndef KX_SKIA_H
#define KX_SKIA_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum kx_backend {
    KX_BACKEND_RASTER = 0,           // CPU raster — always available, headless-capable
    KX_BACKEND_GRAPHITE_METAL = 1,   // macOS / iOS
    KX_BACKEND_GRAPHITE_VULKAN = 2,  // Linux / Android (API >= 33)
    KX_BACKEND_GANESH_GLES = 3,      // Android fallback (API < 33)
    KX_BACKEND_GANESH_GL = 4,        // Linux / Windows fallback
    KX_BACKEND_GRAPHITE_DAWN = 5,    // Windows (D3D12) / iOS (Dawn Metal)
    KX_BACKEND_GRAPHITE_WEBGPU = 6,  // Web
    KX_BACKEND_GANESH_WEBGL2 = 7,    // Web fallback
    KX_BACKEND_GANESH_METAL = 8,     // macOS / iOS fallback (Ganesh Metal)
    KX_BACKEND_AUTO = 9,             // walk the platform chain: graphite → ganesh → raster
} kx_backend;

typedef struct kx_ctx kx_ctx;

// Create a rendering context.
//   sdl_window — SDL_Window* (opaque). Required for GPU backends (the shim attaches
//                an onscreen surface to it). May be NULL for KX_BACKEND_RASTER.
//   width/height — target size in pixels.
// Returns NULL on failure (e.g. GPU backend unavailable).
kx_ctx* kx_create(void* sdl_window, int width, int height, kx_backend backend);
void kx_destroy(kx_ctx* ctx);
void kx_resize(kx_ctx* ctx, int width, int height);

// Frame lifecycle.
void kx_begin_frame(kx_ctx* ctx);
void kx_end_frame(kx_ctx* ctx); // GPU backends: submit + present. Raster: flush.

// Drawing (current frame canvas; call between begin/end_frame).
void kx_clear(kx_ctx* ctx, uint32_t rgba);
// Fully-shaped text, y = first-line baseline (SkParagraph — HarfBuzz
// shaping, ICU bidi + line breaking, script-aware fallback since 0.15.0).
void kx_draw_text(kx_ctx* ctx, const char* text, float x, float y, float size, uint32_t rgba);
// Bold-aware text variant (added in 0.2.0; kx_draw_text is unchanged for ABI
// stability — it delegates with bold=false).
void kx_draw_text_styled(kx_ctx* ctx, const char* text, float x, float y, float size, bool bold, uint32_t rgba);

// Multi-style shaped text (0.15.0): a paragraph built from styled spans —
// real rich text (weight 100..900, italic, letter-spacing, per-span color)
// with full shaping/bidi/fallback. The handle builds + lays out lazily on
// the first metric or paint call; spans added afterwards are ignored.
// kx_text_paint_layout's (x,y) is the first-line BASELINE — same
// convention as kx_draw_text.
typedef struct kx_text_layout kx_text_layout;
typedef struct kx_text_style {
    float size;           // px
    int32_t weight;       // 100..900 (400 = normal, 700 = bold)
    int32_t slant;        // 0 = upright, 1 = italic
    float letter_spacing; // px added between glyphs (0 = font default)
    uint32_t color;       // 0xRRGGBBAA — baked per span
    // Variable-font axes (0.17.0): up to 8 OpenType variation design
    // coordinates — axis is the 4-char tag packed big-endian ('wght' ==
    // 0x77676874), value in the font's declared axis range. A 'wght'
    // coordinate overrides `weight` on variable fonts; axes absent from the
    // resolved font are ignored (fontStyle weight still selects among
    // static instances). Zero-init count = today's behaviour.
    uint32_t variation_count;
    uint32_t variation_axes[8];
    float    variation_values[8];
    // Font family override (0.17.0): family or PostScript name resolved
    // through the platform font manager ("SF Compact", "New York", ...);
    // NULL/empty keeps the platform default. Consumed synchronously by
    // kx_text_layout_span (the name is copied into the span style) — the
    // pointer need only outlive that call. This is what makes the
    // variation axes above actually reachable: a 'wght' coordinate only
    // moves glyphs when the resolved face is variable.
    const char* family;
} kx_text_style;
kx_text_layout* kx_text_layout_begin(float max_width); // <=0 = unconstrained
void kx_text_layout_span(kx_text_layout* layout, const char* text, const kx_text_style* style);
float kx_text_layout_width(kx_text_layout* layout);   // longest laid-out line
float kx_text_layout_height(kx_text_layout* layout);
float kx_text_layout_baseline(kx_text_layout* layout); // first line, alphabetic
void kx_text_paint_layout(kx_ctx* ctx, const kx_text_layout* layout, float x, float y);
void kx_text_layout_destroy(kx_text_layout* layout);

// Real rendering primitives (0.16.0).
// Push a content-blur layer: ops until the matching kx_restore rasterize
// once and composite through a Gaussian image filter — glass blur, not an
// alpha stand-in. sigma <= 0 degenerates to a pass-through layer.
void kx_layer_blur(kx_ctx* ctx, float sigma);
// Backdrop blur: blurs what is ALREADY painted within the rect (the
// backdrop filter path — a saveLayer whose init pixels are the filtered
// backdrop). Subsequent draws composite over the blur.
void kx_backdrop_blur(kx_ctx* ctx, float x, float y, float w, float h, float sigma);
// Material elevation shadow (SkShadowUtils ambient+spot, M3 key light):
// elevation in dp scales z-offset and penumbra. transparent_occluder for
// glass/translucent fills (shadow shows through the shape).
void kx_shadow_rrect(kx_ctx* ctx, float x, float y, float w, float h, float radius,
                     float elevation, uint32_t ambient_rgba, uint32_t spot_rgba,
                     int transparent_occluder);
// Verb-encoded paths (0.16.0): `verbs` consumes `pts` sequentially —
// 0 = moveTo(2 floats), 1 = lineTo(2), 2 = quadTo(4), 3 = cubicTo(6),
// 4 = close(0). fill_rule: 0 = winding, 1 = even-odd. Covers arbitrary
// Bézier fills/strokes (shape morphing emits verb 0 + N×3 + 4).
void kx_fill_path(kx_ctx* ctx, const float* pts, const int* verbs, int n_verbs,
                  uint32_t rgba, int fill_rule);
void kx_stroke_path(kx_ctx* ctx, const float* pts, const int* verbs, int n_verbs,
                  float stroke_w, uint32_t rgba, int fill_rule);
// Fill an axis-aligned rectangle with a solid color.
void kx_fill_rect(kx_ctx* ctx, float x, float y, float w, float h, uint32_t rgba);
// Fill a rounded rectangle with a solid color.
void kx_fill_rrect(kx_ctx* ctx, float x, float y, float w, float h, float radius, uint32_t rgba);
// Fill a rounded rectangle with PER-CORNER radii (added in 0.7.0), in
// SkRRect order: top-left, top-right, bottom-right, bottom-left. The M3E
// filled text field rounds only its top corners (bottom = 0).
void kx_fill_rrect_corners(kx_ctx* ctx, float x, float y, float w, float h, float tl, float tr, float br, float bl, uint32_t rgba);
// Stroke a rounded rectangle's outline (added in 0.6.0): the stroke is
// centered on the edge, like Skia's drawRoundRect with a stroke paint.
void kx_stroke_rrect(kx_ctx* ctx, float x, float y, float w, float h, float radius, float stroke_w, uint32_t rgba);
// Stroke a rounded rectangle's outline with PER-CORNER radii (added in
// 0.8.0), in SkRRect order: top-left, top-right, bottom-right, bottom-left.
// The M3E segmented/split buttons stroke 1dp borders on start/end/middle
// shapes (a pill's start half, a square, a pill's end half).
void kx_stroke_rrect_corners(kx_ctx* ctx, float x, float y, float w, float h, float tl, float tr, float br, float bl, float stroke_w, uint32_t rgba);

// Canvas state + transforms (added in 0.3.0). save/restore must be balanced
// within a frame; a wrapper widget wraps its children's paint in a pair.
void kx_save(kx_ctx* ctx);
void kx_restore(kx_ctx* ctx);
void kx_translate(kx_ctx* ctx, float dx, float dy);
void kx_scale(kx_ctx* ctx, float sx, float sy);
// Rotate the canvas clockwise by `degrees` around the current origin
// (added in 0.12.0). Pair with kx_translate to rotate about a point.
void kx_rotate(kx_ctx* ctx, float degrees);
// Clip the current frame to a rect (intersect with the existing clip).
// kx_clip_rect saves the canvas state; kx_clip_reset restores it. The surface
// is retained between frames: repainting the tree clipped to the damaged
// region is the dirty-rect path (Phase 1e).
void kx_clip_rect(kx_ctx* ctx, float x, float y, float w, float h);
void kx_clip_reset(kx_ctx* ctx);
// Clip the current frame to the CLOSED polygon through (xs, ys) (added in
// 0.12.0): anti-aliased intersect clip, balanced by kx_clip_reset like
// kx_clip_rect. Star masks and avatar cutouts are polygons generated in
// Zig — no path type crosses this boundary.
void kx_clip_path(kx_ctx* ctx, const float* xs, const float* ys, int count, int aa);
// Push an alpha layer: everything drawn until the matching kx_restore
// composites at `alpha` opacity (fade transitions, Phase 2a). Alpha is
// clamped to [0,1]. The implementation records the layer's ops and elides
// or bounds the layer automatically (0.12.0): a layer holding a single
// non-self-overlapping draw folds the alpha into the draw — identical
// pixels, no offscreen pass; multi-op layers get a saveLayer bounded to
// their content instead of the whole clip.
void kx_layer_alpha(kx_ctx* ctx, float alpha);
// Stroke a polyline (added in 0.5.0): moveTo/lineTo through the `count`
// points with a solid color. round_cap selects round line caps (progress
// indicators). Arcs and wavy indicators are polylines generated in Zig —
// no path type crosses this boundary.
void kx_stroke_polyline(kx_ctx* ctx, const float* xs, const float* ys, int count, float stroke_w, bool round_cap, uint32_t rgba);
// Fill a closed polygon through (xs, ys) (added in 0.9.0): moveTo/lineTo
// through the `count` points, closed, with a solid color — the M3E loading
// indicator's shapes are polygons generated in Zig (rounded corners are a
// follow-up: Skia fills the polygon as given).
void kx_fill_polygon(kx_ctx* ctx, const float* xs, const float* ys, int count, uint32_t rgba);
// Fill an rrect with a linear gradient (added in 0.10.0): 2..8 evenly-spaced
// color stops running from (x0,y0) to (x1,y1), clipped to the rounded rect.
// Colors are 0xRRGGBBAA; the gradient interpolates in premul (correct alpha
// fades). The color picker's gradients are generated in Zig — no shader type
// crosses this boundary.
void kx_fill_rrect_gradient(kx_ctx* ctx, float x, float y, float w, float h, float radius,
                            float x0, float y0, float x1, float y1,
                            const uint32_t* colors, int count);

// Text metrics for widget layout. Ctx-independent: fonts are process-global.
//   width   — advance width in pixels
//   height  — ascent + descent
//   ascent  — line top → baseline (positive)
//   descent — baseline → line bottom (positive)
typedef struct kx_text_metrics {
    float width;
    float height;
    float ascent;
    float descent;
} kx_text_metrics;
kx_text_metrics kx_measure_text(const char* text, float size, bool bold);

// Images (per-ctx registry). Create once from RGBA pixels (memory order
// R,G,B,A, unpremultiplied), draw many times — no per-frame allocation.
// Returns 0 on failure. Destroy when the owner is done.
uint64_t kx_image_create(kx_ctx* ctx, const uint8_t* rgba, int32_t width, int32_t height);
void kx_image_destroy(kx_ctx* ctx, uint64_t image);
// Draw an image stretched into the destination rect (nearest sampling).
void kx_draw_image(kx_ctx* ctx, uint64_t image, float x, float y, float w, float h);
// 1 when every pixel of the image is fully opaque — lets callers skip the
// destination clear under a full-coverage Src blit.
uint8_t kx_image_is_opaque(kx_ctx* ctx, uint64_t image);
// Batched sprite draw (added in 0.18.0): ONE draw submission for `count`
// sprites of the SAME image — SkCanvas::drawAtlas underneath, the sprite-
// batch idiom scene graphs use internally (QSG batches quads the same way).
// Each sprite's similarity transform maps the source rect into place:
//   dst = src * [[scos, -ssin], [ssin, scos]] + (tx, ty)
// i.e. rotate+scale then translate; for a plain (x, y, w, h) blit use
// scos=w/iw, ssin=0, tx=x, ty=y. tex_xywh = optional per-sprite source
// rects (4 floats each); NULL samples the full image.
typedef struct { float scos, ssin, tx, ty; } kx_sprite_xform;
void kx_draw_image_atlas(kx_ctx* ctx, uint64_t image,
                         const kx_sprite_xform* xforms, const float* tex_xywh,
                         int32_t count);
// Batched distinct-image draw (same batch): SkCanvas::DrawEdgeAAImageSet —
// one submission for N quads that may sample DIFFERENT registered images
// (the retained-row scroll idiom). dst rects only (axis-aligned, no rotate).
typedef struct {
    uint64_t image;
    float sx, sy, sw, sh; // source rect in the image (sw/sh <= 0 = full)
    float dx, dy, dw, dh; // destination rect in device space
} kx_image_quad;
void kx_draw_image_set(kx_ctx* ctx, const kx_image_quad* quads, int32_t count);
// Row atlas (added in 0.18.0): a persistent grow-only surface shared by all
// retained subtrees — a row rasterizes STRAIGHT into its slot (no texture
// alloc, no upload task per row — the dominant scroll cost on Graphite)
// and re-blits by sampling its rect of the one atlas texture. Slots are
// shelves; gen bumps whenever the atlas regrows and every slot resets.
uint32_t kx_atlas_gen(kx_ctx* ctx);
// Begin a paint pass into a fresh slot of at least w×h; on success the ctx
// canvas targets the atlas region and *out_slot receives {x,y,w,h} — paint
// in LOCAL space as usual, then kx_atlas_end returns the atlas image id to
// blit with kx_draw_image_region. Returns false when nested/full.
bool kx_atlas_begin(kx_ctx* ctx, int32_t w, int32_t h, float* out_slot);
void kx_atlas_end(kx_ctx* ctx);
uint64_t kx_atlas_image(kx_ctx* ctx); // 0 until the first pass ends
// Return a slot's pixels to its shelf (evicted retained rows); pass the
// exact {x,y,w,h} the begin call returned.
void kx_atlas_free(kx_ctx* ctx, float sx, float sy, float sw, float sh);
// Blit an image sub-rect to a dst rect (atlas slots and plain images alike).
void kx_draw_image_region(kx_ctx* ctx, uint64_t image,
                          float sx, float sy, float sw, float sh,
                          float dx, float dy, float dw, float dh);
// Sprite batch (added in 0.18.0): while open, draws of ATLAS-region images
// accumulate as device-space sprites and flush as ONE drawVertices when the
// batch closes or any other op intervenes (ordering preserved). Lists wrap
// their children pass in it: N retained-row blits become a single draw.
void kx_sprite_batch_begin(kx_ctx* ctx);
void kx_sprite_batch_end(kx_ctx* ctx);
// Zero-copy draw (added in 0.12.0): draw raw RGBA pixels stretched into the
// rect WITHOUT the registry round-trip — the pixel buffer is borrowed for
// the synchronous raster draw (no memcpy, no image object). The video
// texture-upload idiom: a decoded frame is drawn, not retained. `rgba` must
// stay valid only for the call's duration — raster draws consume it
// immediately (GPU backends must still copy to upload — same semantics).
void kx_draw_pixels(kx_ctx* ctx, const uint8_t* rgba, int32_t w, int32_t h,
                    float x, float y, float dw, float dh);

// Render-to-image (added in 0.12.0): kx_offscreen_begin switches the ctx's
// draw target to a fresh w×h transparent raster surface; everything drawn
// until kx_offscreen_end_image lands there, the canvas is restored, and the
// result is registered like a kx_image_create image (returns the id, 0 on
// failure). Rasterizes a vector asset once so it can be drawn many times —
// the retained-cache idiom (Compose's graphicsLayer / QML layer.enabled).
// Call between begin/end_frame; may NOT nest inside kx_layer_alpha regions
// or other offscreen passes.
bool kx_offscreen_begin(kx_ctx* ctx, int width, int height);
uint64_t kx_offscreen_end_image(kx_ctx* ctx);

// Readback — raster backend only. Copies the frame as RGBA (memory order R,G,B,A)
// into dst. dst_size must be >= width*height*4. Returns false on GPU backends
// (async readback lands in Phase 1) or on failure.
bool kx_readback_rgba(kx_ctx* ctx, void* dst, size_t dst_size, int* out_width, int* out_height);

// GPU warmup (added in 0.11.0, Phase 4e.1): draw the framework's full op set
// (fills, rrects, gradients, text, images, layers, clips) into a small
// offscreen GPU surface and submit — the one-time shader/pipeline program
// compilation for those ops then lands HERE, not inside the first real
// frames (retail frame p99 on GLES was dominated by first-frames compile
// jank). No-op returning true on raster (nothing to pre-compile). Call
// OUTSIDE begin/end_frame — the host calls it right after the first present,
// so TTFF is unaffected. Returns false when the backend cannot warm up
// (surface creation failure, or a platform without an offscreen path yet).
bool kx_gpu_warmup(kx_ctx* ctx);

// Introspection.
kx_backend kx_backend_of(const kx_ctx* ctx);
const char* kx_backend_name(kx_backend backend);
// Draw ops submitted to the canvas by the last completed frame (0.14.0):
// counted on the emit path — a layer-recorded op counts once, at replay.
uint64_t kx_frame_draw_ops(kx_ctx* ctx);
// ABI version (semver). Breaking changes bump the major version. (ADR-0009)
const char* kx_abi_version(void);

#ifdef __cplusplus
}
#endif

#endif // KX_SKIA_H
