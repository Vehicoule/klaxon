// kx.cpp — Qt6 port of the Klaxon UI core exercised by the conformance suite.
//
// Line-for-line port of src/ui/{node,layout,input,semantics,state,anim,scroll,
// gestures,i18n,navigator}.zig and src/ui/paint.zig semantics onto Qt types.
// See kx.h for the mapping rationale: Qt supplies rasterisation (QPainter on
// QImage), font metrics (QFontMetricsF) and the offscreen event boundary;
// every DSL contract runs through this engine.

#include "kx.h"

#include <QtCore/QJsonArray>
#include <QtCore/QVariant>
#include <QtGui/QPaintEvent>
#include <charconv>
#include <cstring>

namespace kx {

// ===========================================================================
// Geometry + constraints (src/ui/node.zig + src/ui/layout.zig)
// ===========================================================================

Rect rectUnion(const Rect &a, const Rect &b) {
    const float x = std::min(a.x, b.x);
    const float y = std::min(a.y, b.y);
    const float r = std::max(a.x + a.w, b.x + b.w);
    const float bot = std::max(a.y + a.h, b.y + b.h);
    return {x, y, r - x, bot - y};
}

Rect rectIntersect(const Rect &a, const Rect &b) {
    const float x = std::max(a.x, b.x);
    const float y = std::max(a.y, b.y);
    const float r = std::min(a.x + a.w, b.x + b.w);
    const float bot = std::min(a.y + a.h, b.y + b.h);
    if (r <= x || bot <= y) return {x, y, 0, 0};
    return {x, y, r - x, bot - y};
}

bool rectOverlaps(const Rect &a, const Rect &b) {
    return a.x < b.x + b.w && a.x + a.w > b.x && a.y < b.y + b.h && a.y + a.h > b.y;
}

Rect rectNormalize(const Rect &r) {
    float x = r.x, y = r.y, w = r.w, h = r.h;
    if (w < 0) { x += w; w = -w; }
    if (h < 0) { y += h; h = -h; }
    return {x, y, w, h};
}

EdgeInsets EdgeInsetsDirectional::resolve(Direction dir) const {
    if (dir == Direction::rtl) return {end, top, start, bottom};
    return {start, top, end, bottom};
}

Size Constraints::constrain(Size s) const {
    return {std::clamp(s.w, min_w, max_w), std::clamp(s.h, min_h, max_h)};
}

Constraints Constraints::deflate(float amount) const {
    return deflateEdge(EdgeInsets::all(amount));
}

Constraints Constraints::deflateEdge(const EdgeInsets &e) const {
    auto dec = [](float v, float a) { return v > a ? v - a : 0.0f; };
    return {
        dec(min_w, e.hSum()),
        dec(max_w, e.hSum()),
        dec(min_h, e.vSum()),
        dec(max_h, e.vSum()),
    };
}

Constraints Constraints::enforcedBy(const Constraints &add) const {
    return {
        std::clamp(min_w, add.min_w, add.max_w),
        std::clamp(max_w, add.min_w, add.max_w),
        std::clamp(min_h, add.min_h, add.max_h),
        std::clamp(max_h, add.min_h, add.max_h),
    };
}

Constraints Constraints::loosenMain(Axis a) const {
    if (a == Axis::horizontal) return {0, max_w, min_h, max_h};
    return {min_w, max_w, 0, max_h};
}

TextAlign resolveAlign(TextAlign a, Direction dir) {
    switch (a) {
        case TextAlign::start: return dir == Direction::ltr ? TextAlign::left : TextAlign::right;
        case TextAlign::end:   return dir == Direction::ltr ? TextAlign::right : TextAlign::left;
        default: return a;
    }
}

Rect Alignment::position(const Rect &b, Size s) const {
    return {
        b.x + (b.w - s.w) * (x + 1.0f) / 2.0f,
        b.y + (b.h - s.h) * (y + 1.0f) / 2.0f,
        s.w, s.h,
    };
}

// direction() is defined below I18n (it reads the live current locale, like
// i18n.zig's process-global direction() — not a cached copy).

// --- flex measure/layout (ui/layout.zig flexMeasure / flexLayout) ---

Size flexMeasure(KxNode *n, const Constraints &c, Axis axis, float gap, float padding) {
    const Constraints inner = c.deflate(padding * 2);
    const float gaps = n->children.size() > 1
                           ? gap * static_cast<float>(n->children.size() - 1) : 0.0f;
    float main_total = 0, cross_max = 0;
    quint32 flex_total = 0;
    float non_flex_main = 0;
    for (KxNode *child : n->children) {
        if (child->flex > 0) { flex_total += child->flex; continue; }
        const Size s = child->measure(inner.loosenMain(axis));
        non_flex_main += s.main(axis);
        cross_max = std::max(cross_max, s.cross(axis));
    }
    // Flex children (Expanded) share the remaining main space, tight, by
    // weight. On an unbounded main axis they keep their natural size.
    const float inner_main_max = axis == Axis::horizontal ? inner.max_w : inner.max_h;
    if (flex_total > 0 && std::isfinite(inner_main_max)) {
        const float remaining = std::max(0.0f, inner_main_max - non_flex_main - gaps);
        for (KxNode *child : n->children) {
            if (child->flex == 0) continue;
            const float alloc = remaining * static_cast<float>(child->flex) /
                                static_cast<float>(flex_total);
            Constraints cc;
            if (axis == Axis::horizontal) cc = {alloc, alloc, 0, inner.max_h};
            else cc = {0, inner.max_w, alloc, alloc};
            const Size s = child->measure(cc);
            main_total += alloc;
            cross_max = std::max(cross_max, s.cross(axis));
        }
    } else {
        for (KxNode *child : n->children) {
            if (child->flex == 0) continue;
            const Size s = child->measure(inner.loosenMain(axis));
            main_total += s.main(axis);
            cross_max = std::max(cross_max, s.cross(axis));
        }
    }
    main_total += non_flex_main + gaps;
    return c.constrain(Size::fromMainCross(axis, main_total + padding * 2,
                                           cross_max + padding * 2));
}

void flexLayout(KxNode *n, const Rect &bounds, Axis axis, float gap, float padding,
                MainAlign main_align, CrossAlign cross_align) {
    const size_t count = n->children.size();
    if (count == 0) return;
    std::vector<Size> sizes(count);

    const float inner_main = std::max(0.0f, bounds.main(axis) - padding * 2);
    const float cross_avail = std::max(0.0f, bounds.cross(axis) - padding * 2);

    // Pass 1: measure every child. Non-flex children get the full inner main
    // axis; flex children (Expanded) share the REMAINING main space, tight,
    // by weight (natural size on an unbounded main axis).
    float natural_main = padding * 2;
    quint32 flex_total = 0;
    float non_flex_main = 0;
    const float gaps_total = count > 1 ? gap * static_cast<float>(count - 1) : 0.0f;
    for (size_t i = 0; i < count; ++i) {
        KxNode *child = n->children[i];
        if (child->flex > 0) { flex_total += child->flex; continue; }
        Constraints cc;
        if (axis == Axis::horizontal) cc = {0, inner_main, 0, cross_avail};
        else cc = {0, cross_avail, 0, inner_main};
        sizes[i] = child->measure(cc);
        non_flex_main += sizes[i].main(axis);
    }
    const float remaining = std::max(0.0f, inner_main - non_flex_main - gaps_total);
    for (size_t i = 0; i < count; ++i) {
        KxNode *child = n->children[i];
        if (child->flex == 0) continue;
        if (flex_total > 0 && std::isfinite(inner_main)) {
            const float alloc = remaining * static_cast<float>(child->flex) /
                                static_cast<float>(flex_total);
            Constraints cc;
            if (axis == Axis::horizontal) cc = {alloc, alloc, 0, cross_avail};
            else cc = {0, cross_avail, alloc, alloc};
            sizes[i] = child->measure(cc);
        } else {
            Constraints cc;
            if (axis == Axis::horizontal) cc = {0, inner_main, 0, cross_avail};
            else cc = {0, cross_avail, 0, inner_main};
            sizes[i] = child->measure(cc);
        }
    }
    for (const auto &s : sizes) natural_main += s.main(axis);
    natural_main += gaps_total;

    // Free space distribution along the main axis.
    const float free_sp = std::max(0.0f, bounds.main(axis) - natural_main);
    float start = padding;
    float extra_gap = 0;
    switch (main_align) {
        case MainAlign::start: break;
        case MainAlign::center: start += free_sp / 2; break;
        case MainAlign::end: start += free_sp; break;
        case MainAlign::space_between:
            if (count > 1) extra_gap = free_sp / static_cast<float>(count - 1);
            break;
        case MainAlign::space_around: {
            const float nf = static_cast<float>(count);
            start += free_sp / (2 * nf);
            extra_gap = free_sp / nf;
            break;
        }
        case MainAlign::space_evenly: {
            const float nf = static_cast<float>(count + 1);
            start += free_sp / nf;
            extra_gap = free_sp / nf;
            break;
        }
    }

    // Pass 2: place children.
    const bool rtl = axis == Axis::horizontal && direction() == Direction::rtl;
    float cursor = start;
    for (size_t i = 0; i < count; ++i) {
        KxNode *child = n->children[i];
        const Size &s = sizes[i];
        float cross_pos;
        switch (cross_align) {
            case CrossAlign::start:
            case CrossAlign::stretch: cross_pos = padding; break;
            case CrossAlign::center: cross_pos = padding + (cross_avail - s.cross(axis)) / 2; break;
            case CrossAlign::end: cross_pos = padding + (cross_avail - s.cross(axis)); break;
        }
        const float cross_size = cross_align == CrossAlign::stretch
                                     ? cross_avail
                                     : std::min(s.cross(axis), cross_avail);
        // RTL mirrors the horizontal main axis: the logical order runs
        // right → left (the cursor math is direction-agnostic).
        const float main_pos = rtl ? bounds.w - cursor - s.w : cursor;
        Rect cb;
        if (axis == Axis::horizontal)
            cb = {bounds.x + main_pos, bounds.y + cross_pos, s.w, cross_size};
        else
            cb = {bounds.x + cross_pos, bounds.y + cursor, cross_size, s.h};
        child->layout(cb);
        cursor += s.main(axis) + gap + extra_gap;
    }
}

// ===========================================================================
// Paint (src/ui/paint.zig via QPainter)
// ===========================================================================

QColor toQColor_(Color c) { return toQColor(c); }

static QFont makeFont(float size, bool bold) {
    QFont f;
    f.setPointSizeF(size);
    f.setBold(bold);
    return f;
}

TextMetrics measureText(const QString &str, float size, bool bold) {
    TextMetrics m;
    if (str.isEmpty()) {
        QFontMetricsF fm(makeFont(size, bold));
        m.ascent = fm.ascent();
        m.height = fm.ascent() + fm.descent();
        return m;
    }
    QFontMetricsF fm(makeFont(size, bold));
    m.width = fm.horizontalAdvance(str);
    m.ascent = fm.ascent();
    m.height = fm.ascent() + fm.descent();
    return m;
}

void drawText(QPainter &p, const QString &str, float x, float baseline_y,
              float size, bool bold, Color color) {
    p.save();
    p.setFont(makeFont(size, bold));
    p.setPen(toQColor(color));
    p.drawText(QPointF(x, baseline_y), str);
    p.restore();
}

void fillRect(QPainter &p, float x, float y, float w, float h, Color color) {
    p.fillRect(QRectF(x, y, w, h), toQColor(color));
}

void fillRRect(QPainter &p, float x, float y, float w, float h, float radius, Color color) {
    p.save();
    p.setPen(Qt::NoPen);
    p.setBrush(toQColor(color));
    if (radius > 0) p.drawRoundedRect(QRectF(x, y, w, h), radius, radius);
    else p.drawRect(QRectF(x, y, w, h));
    p.restore();
}

void clipRect(QPainter &p, float x, float y, float w, float h) {
    p.save();
    p.setClipRect(QRectF(x, y, w, h), Qt::IntersectClip);
}

void clipReset(QPainter &p) { p.restore(); }

int channelDiff(Color a, Color b, int shift) {
    return std::abs(static_cast<int>((a >> shift) & 0xFF) - static_cast<int>((b >> shift) & 0xFF));
}

// ===========================================================================
// Frame (src/golden.zig Frame)
// ===========================================================================

Frame::Frame(const QImage &img) {
    img_ = img.convertToFormat(QImage::Format_RGBA8888);
    w = img_.width();
    h = img_.height();
}

Color Frame::pixelAt(int x, int y) const {
    if (x < 0 || y < 0 || x >= w || y >= h) return 0;
    const uchar *px = img_.constScanLine(y) + x * 4;
    return (static_cast<Color>(px[0]) << 24) | (static_cast<Color>(px[1]) << 16) |
           (static_cast<Color>(px[2]) << 8) | static_cast<Color>(px[3]);
}

Rect Frame::clipToFrame(Rect r) const {
    return rectIntersect(r, {0, 0, static_cast<float>(w), static_cast<float>(h)});
}

static bool colorApprox(Color a, Color b) {
    return channelDiff(a, b, 24) <= 2 && channelDiff(a, b, 16) <= 2 &&
           channelDiff(a, b, 8) <= 2 && channelDiff(a, b, 0) <= 2;
}

quint64 Frame::countColor(Color color) const { return countColorIn({0, 0, (float)w, (float)h}, color); }
quint64 Frame::countNot(Color color) const { return countNotIn({0, 0, (float)w, (float)h}, color); }

quint64 Frame::countColorIn(Rect rect, Color color) const {
    const Rect r = clipToFrame(rectNormalize(rect));
    quint64 n = 0;
    for (int y = (int)r.y; y < (int)(r.y + r.h); ++y)
        for (int x = (int)r.x; x < (int)(r.x + r.w); ++x)
            if (pixelAt(x, y) == color) ++n;
    return n;
}

quint64 Frame::countNotIn(Rect rect, Color color) const {
    const Rect r = clipToFrame(rectNormalize(rect));
    quint64 n = 0;
    for (int y = (int)r.y; y < (int)(r.y + r.h); ++y)
        for (int x = (int)r.x; x < (int)(r.x + r.w); ++x)
            if (pixelAt(x, y) != color) ++n;
    return n;
}

quint64 Frame::countColorApproxIn(Rect rect, Color color) const {
    const Rect r = clipToFrame(rectNormalize(rect));
    quint64 n = 0;
    for (int y = (int)r.y; y < (int)(r.y + r.h); ++y)
        for (int x = (int)r.x; x < (int)(r.x + r.w); ++x)
            if (colorApprox(pixelAt(x, y), color)) ++n;
    return n;
}

// ===========================================================================
// KxNode (src/ui/node.zig)
// ===========================================================================

// Deferred-destruction traversal freeze (node.zig).
static int g_traversal_depth = 0;
static std::vector<KxNode *> g_zombie_list;
static std::vector<KxNode *> g_pending_free;

void traversalBegin() { g_traversal_depth += 1; }
bool traversalActive() { return g_traversal_depth > 0; }

void traversalEnd() {
    g_traversal_depth -= 1;
    if (g_traversal_depth != 0) return;
    // Sweeping runs callbacks (deinits can touch the tree): hold a freeze so
    // nested deinits queue onto the list we drain below.
    g_traversal_depth = 1;
    while (!g_zombie_list.empty() || !g_pending_free.empty()) {
        std::vector<KxNode *> batch;
        batch.swap(g_zombie_list);
        for (KxNode *z : batch) {
            if (z->torn_down) continue; // consumed eagerly by a parent's teardown
            z->torn_down = true;
            // Detach from the parent first — the node stayed listed so far.
            if (z->parent) {
                KxNode *p = z->parent;
                z->parent = nullptr;
                p->remove(z);
            }
            z->deinitBody();
            g_pending_free.push_back(z);
        }
        for (KxNode *z : g_pending_free) delete z;
        g_pending_free.clear();
    }
    g_traversal_depth = 0;
}

void KxNode::add(KxNode *child) {
    children.push_back(child);
    child->parent = this;
    markLayoutDirty();
    markDirty();
}

void KxNode::insert(size_t index, KxNode *child) {
    if (index > children.size()) index = children.size();
    children.insert(children.begin() + index, child);
    child->parent = this;
    markLayoutDirty();
    markDirty();
}

bool KxNode::remove(KxNode *child) {
    for (size_t i = 0; i < children.size(); ++i) {
        if (children[i] == child) {
            children.erase(children.begin() + i);
            child->parent = nullptr;
            markLayoutDirty();
            markDirty();
            return true;
        }
    }
    return false;
}

void KxNode::deinit() {
    if (zombie) return;
    if (traversalActive()) {
        zombie = true;
        g_zombie_list.push_back(this);
        return;
    }
    traversalBegin();
    zombie = true;
    g_zombie_list.push_back(this);
    traversalEnd();
}

void KxNode::deinitBody() {
    releaseNodeGlobal(this);
    focusNodeDestroyed(this);
    for (KxNode *child : children) {
        child->parent = nullptr;
        if (!child->torn_down) {
            child->torn_down = true;
            child->deinitBody();
            g_pending_free.push_back(child);
        }
    }
    children.clear();
    delete semantics;
    semantics = nullptr;
    teardown();
}

void KxNode::layout(const Rect &b) {
    bounds = b;
    layout_dirty = false;
    onLayout(b);
}

static void markDirtyUp(KxNode *n) {
    while (true) {
        n->dirty = true;
        KxNode *p = n->parent;
        if (!p) return;
        n = p;
    }
}

static void unionDamage(KxNode *root, Rect rect) {
    if (rect.w <= 0 || rect.h <= 0) return;
    root->damage = root->damage_valid ? rectUnion(root->damage, rect) : rect;
    root->damage_valid = true;
}

static void damageRectUp(KxNode *n, Rect rect) {
    Rect r = rect;
    while (n->parent) {
        n->parent->mapPaintRect(&r);
        n = n->parent;
    }
    unionDamage(n, r);
}

void KxNode::markDirty() {
    markDirtyUp(this);
    damageRectUp(this, paintRect());
}

void KxNode::markDirtyRect(const Rect &rect) {
    markDirtyUp(this);
    damageRectUp(this, rect);
}

void KxNode::markLayoutDirty() {
    KxNode *n = this;
    while (true) {
        n->layout_dirty = true;
        KxNode *p = n->parent;
        if (!p) return;
        n = p;
    }
}

void KxNode::clearDamage() {
    damage = {};
    damage_valid = false;
    for (KxNode *child : children) child->clearDamage();
}

Rect KxNode::paintRect() const {
    Rect r;
    if (paintBounds(&r)) return r;
    const EdgeInsets &o = damage_overflow;
    return {bounds.x - o.left, bounds.y - o.top,
            bounds.w + o.left + o.right, bounds.h + o.top + o.bottom};
}

void KxNode::paint(QPainter &ctx, const Rect &vis) {
    if (!visible || zombie) return;
    Rect child_region = vis;
    Rect cc;
    if (childClip(&cc)) child_region = rectIntersect(vis, mapRectToRoot(cc));
    const bool own_hit = rectOverlaps(mapRectToRoot(paintRect()), vis);
    const bool children_hit = child_region.w > 0 && child_region.h > 0;
    if (!own_hit && !children_hit) return;
    dirty = false;
    if (own_hit) onPaint(ctx);
    if (children_hit) {
        preChildrenPaint(ctx);
        for (KxNode *child : children) {
            if (child->defer_paint || child->zombie) continue;
            child->paint(ctx, child_region);
        }
        postChildrenPaint(ctx);
    }
}

KxNode *KxNode::hitTest(float px, float py) {
    if (!visible || zombie) return nullptr;
    Rect hb;
    const Rect *bp = &bounds;
    if (hitBounds(&hb)) bp = &hb;
    if (!bp->contains(px, py)) return nullptr;
    float cx = px, cy = py;
    preChildrenHit(px, py, &cx, &cy);
    for (auto it = children.rbegin(); it != children.rend(); ++it) {
        if ((*it)->zombie) continue;
        if (KxNode *hit = (*it)->hitTest(cx, cy)) return hit;
    }
    return this;
}

std::optional<KxNode::MappedHit> KxNode::hitTestMapped(float px, float py) {
    if (!visible || zombie) return std::nullopt;
    Rect hb;
    const Rect *bp = &bounds;
    if (hitBounds(&hb)) bp = &hb;
    if (!bp->contains(px, py)) return std::nullopt;
    float cx = px, cy = py;
    preChildrenHit(px, py, &cx, &cy);
    for (auto it = children.rbegin(); it != children.rend(); ++it) {
        if ((*it)->zombie) continue;
        if (auto m = (*it)->hitTestMapped(cx, cy)) return m;
    }
    return MappedHit{this, px, py};
}

HitPoint KxNode::mapPointToParentSpace(float px, float py) const {
    std::vector<const KxNode *> chain;
    for (const KxNode *n = parent; n; n = n->parent) chain.push_back(n);
    float x = px, y = py;
    for (auto it = chain.rbegin(); it != chain.rend(); ++it) {
        float ox = x, oy = y;
        if ((*it)->preChildrenHit(x, y, &ox, &oy)) { x = ox; y = oy; }
    }
    return {x, y};
}

Rect KxNode::mapRectToRoot(Rect r) const {
    const KxNode *n = this;
    while (n->parent) {
        if (n->parent->mapPaintRect(&r)) r = rectNormalize(r);
        n = n->parent;
    }
    return r;
}

bool KxNode::scrollInfo(ScrollInfo *) const { return false; }
bool KxNode::preChildrenHit(float, float, float *, float *) const { return false; }

// ===========================================================================
// Input router (src/ui/input.zig)
// ===========================================================================

static InputRouter *g_router = nullptr;
void setCurrentRouter(InputRouter *r) { g_router = r; }
InputRouter *currentRouter() { return g_router; }

void requestFocus(KxNode *n) {
    if (g_router) g_router->focus(n);
    routerFocusChanged(n);
}

bool isFocused(KxNode *n) { return g_router && g_router->focused == n; }
void setOpenPopup(KxNode *n) { if (g_router) g_router->open_popup = n; }
void releaseNodeGlobal(KxNode *n) { if (g_router) g_router->releaseNode(n); }

// send* helpers are file-static (input.zig private fns).

/// sendPointer, skipping `except` (capture handover). Hover phases are
/// notifications: they keep bubbling past handlers that report handled.
static bool sendPointerExcept(KxNode *node, const PointerEvent &ev, KxNode *except) {
    const bool notify = ev.phase == PointerPhase::enter || ev.phase == PointerPhase::leave ||
                        ev.phase == PointerPhase::hover_move;
    bool handled = false;
    for (KxNode *cur = node; cur; cur = cur->parent) {
        if (cur == except || cur->zombie) continue;
        if (cur->onPointer(ev)) {
            handled = true;
            if (!notify) return true;
        }
    }
    return handled;
}

static bool sendPointer(KxNode *node, const PointerEvent &ev) {
    return sendPointerExcept(node, ev, nullptr);
}

static bool sendKey(KxNode *node, const KeyEvent &ev) {
    for (KxNode *cur = node; cur; cur = cur->parent) {
        if (cur->zombie) continue;
        if (cur->onKey(ev)) return true;
    }
    return false;
}

static bool sendScroll(KxNode *node, const ScrollEvent &ev) {
    for (KxNode *cur = node; cur; cur = cur->parent) {
        if (cur->zombie) continue;
        if (cur->onScroll(ev)) return true;
    }
    return false;
}

static bool isDescendant(KxNode *node, KxNode *ancestor) {
    for (KxNode *cur = node; cur; cur = cur->parent)
        if (cur == ancestor) return true;
    return false;
}

int InputRouter::captureSlot(quint64 pointer) const {
    return static_cast<int>(pointer % MAX_POINTERS);
}

void InputRouter::captureSet(quint64 pointer, KxNode *node) {
    captured[captureSlot(pointer)] = Capture{pointer, node};
}

void InputRouter::captureClear(quint64 pointer) {
    auto &slot = captured[captureSlot(pointer)];
    if (slot && slot->pointer == pointer) slot = std::nullopt;
}

KxNode *InputRouter::capturedNode(quint64 pointer) const {
    const auto &slot = captured[captureSlot(pointer)];
    if (slot && slot->pointer == pointer) return slot->node;
    return nullptr;
}

/// Deepest visible descendant of `node` containing the point — unlike
/// KxNode::hitTest, intermediate bounds are not required to contain the point
/// (popup children paint and hit outside their parent's bounds).
static KxNode *hitTestSubtree(KxNode *node, float px, float py) {
    if (!node->visible) return nullptr;
    float cx = px, cy = py;
    node->preChildrenHit(px, py, &cx, &cy);
    for (auto it = node->children.rbegin(); it != node->children.rend(); ++it) {
        if (KxNode *hit = hitTestSubtree(*it, cx, cy)) return hit;
    }
    Rect hb;
    const Rect *bp = &node->bounds;
    if (node->hitBounds(&hb)) bp = &hb;
    if (bp->contains(px, py)) return node;
    return nullptr;
}

/// Hit-test a point that may land on an open popup's overflow content.
static std::optional<KxNode::MappedHit> hitPopupOrRoot(KxNode *root, KxNode *popup,
                                                     float x, float y) {
    const HitPoint p = popup->mapPointToParentSpace(x, y);
    if (KxNode *h = hitTestSubtree(popup, p.x, p.y)) {
        const HitPoint lp = h->mapPointToParentSpace(x, y);
        return KxNode::MappedHit{h, lp.x, lp.y};
    }
    return root->hitTestMapped(x, y);
}

void InputRouter::captureNode(const PointerEvent &ev, KxNode *node, KxNode *except) {
    traversalBegin();
    const int i = captureSlot(ev.pointer);
    if (captured[i] && captured[i]->pointer == ev.pointer) {
        KxNode *prev = captured[i]->node;
        captured[i] = Capture{ev.pointer, node};
        if (prev != node) {
            PointerEvent od;
            od.phase = PointerPhase::outside_down;
            od.x = ev.x; od.y = ev.y;
            od.raw_x = ev.raw_x; od.raw_y = ev.raw_y;
            od.button = ev.button; od.pointer = ev.pointer; od.time_ms = ev.time_ms;
            sendPointerExcept(prev, od, except);
        }
    } else {
        captureSet(ev.pointer, node);
    }
    traversalEnd();
}

void InputRouter::dispatchPointer(KxNode *root, const PointerEvent &ev_in) {
    traversalBegin();
    PointerEvent ev = ev_in;
    ev.raw_x = ev_in.x;
    ev.raw_y = ev_in.y;
    if (ev.pointer == 0) {
        last_x = ev.x;
        last_y = ev.y;
        has_last = true;
    }
    switch (ev.phase) {
        case PointerPhase::down: {
            // A click outside an open popup closes it and is consumed
            // (barrier semantics — the next click reaches the tree).
            if (open_popup) {
                auto hit = hitPopupOrRoot(root, open_popup, ev.x, ev.y);
                const bool inside = hit && isDescendant(hit->node, open_popup);
                if (!inside) {
                    KxNode *popup = open_popup;
                    open_popup = nullptr;
                    PointerEvent od;
                    od.phase = PointerPhase::outside_down;
                    od.x = ev.x; od.y = ev.y;
                    od.raw_x = ev.raw_x; od.raw_y = ev.raw_y;
                    od.pointer = ev.pointer; od.time_ms = ev.time_ms;
                    sendPointer(popup, od);
                    traversalEnd();
                    return;
                }
                captureSet(ev.pointer, hit->node);
                PointerEvent local = ev;
                local.x = hit->x; local.y = hit->y;
                sendPointer(hit->node, local);
                traversalEnd();
                return;
            }
            if (auto hit = root->hitTestMapped(ev.x, ev.y)) {
                captureSet(ev.pointer, hit->node);
                PointerEvent local = ev;
                local.x = hit->x; local.y = hit->y;
                sendPointer(hit->node, local);
            }
            break;
        }
        case PointerPhase::move: {
            if (KxNode *c = capturedNode(ev.pointer)) {
                const HitPoint local = c->mapPointToParentSpace(ev.x, ev.y);
                PointerEvent le = ev;
                le.x = local.x; le.y = local.y;
                sendPointer(c, le);
            } else if (ev.pointer == 0) {
                updateHover(root, ev.x, ev.y, true);
            }
            break;
        }
        case PointerPhase::up: {
            if (KxNode *c = capturedNode(ev.pointer)) {
                captureClear(ev.pointer);
                const HitPoint local = c->mapPointToParentSpace(ev.x, ev.y);
                PointerEvent le = ev;
                le.x = local.x; le.y = local.y;
                sendPointer(c, le);
                if (ev.pointer == 0) refreshHover(root);
            } else if (auto hit = root->hitTestMapped(ev.x, ev.y)) {
                PointerEvent le = ev;
                le.x = hit->x; le.y = hit->y;
                sendPointer(hit->node, le);
            }
            break;
        }
        // enter/leave/outside_down/hover_move are synthesized by the router.
        case PointerPhase::enter:
        case PointerPhase::leave:
        case PointerPhase::outside_down:
        case PointerPhase::hover_move:
            break;
    }
    traversalEnd();
}

bool InputRouter::dispatchKey(const KeyEvent &ev) {
    traversalBegin();
    bool r = false;
    if (focused) r = sendKey(focused, ev);
    traversalEnd();
    return r;
}

void InputRouter::dispatchScroll(KxNode *root, const ScrollEvent &ev) {
    traversalBegin();
    if (ev.pointer == 0) {
        last_x = ev.x;
        last_y = ev.y;
        has_last = true;
    }
    KxNode *hit = root->hitTest(ev.x, ev.y);
    if (hit) sendScroll(hit, ev);
    traversalEnd();
}

/// Hardware back / Escape: the focused chain gets `.escape` first; then the
/// topmost modal back handler; then the registered back handler.
bool InputRouter::dispatchBack() {
    traversalBegin();
    if (focused) {
        KeyEvent esc;
        esc.kind = KeyEvent::Kind::key_down;
        esc.key = Key::escape;
        if (sendKey(focused, esc)) { traversalEnd(); return true; }
    }
    if (back_stack_len > 0) {
        auto &h = back_stack[back_stack_len - 1];
        bool r = h.fn && h.fn();
        traversalEnd();
        return r;
    }
    bool r = back_handler && back_handler();
    traversalEnd();
    return r;
}

void InputRouter::updateHover(KxNode *root, float x, float y, bool send_move) {
    traversalBegin();
    auto hit = open_popup ? hitPopupOrRoot(root, open_popup, x, y)
                          : root->hitTestMapped(x, y);
    KxNode *hov = hit ? hit->node : nullptr;
    if (hov != hovered) {
        if (hovered) {
            PointerEvent lev;
            lev.phase = PointerPhase::leave;
            lev.x = x; lev.y = y;
            lev.raw_x = x; lev.raw_y = y;
            sendPointer(hovered, lev);
        }
        hovered = hov;
        if (hit) {
            PointerEvent ent;
            ent.phase = PointerPhase::enter;
            ent.x = hit->x; ent.y = hit->y;
            ent.raw_x = x; ent.raw_y = y;
            sendPointer(hit->node, ent);
        }
    } else if (send_move && hit) {
        PointerEvent mv;
        mv.phase = PointerPhase::hover_move;
        mv.x = hit->x; mv.y = hit->y;
        mv.raw_x = x; mv.raw_y = y;
        sendPointer(hit->node, mv);
    }
    traversalEnd();
}

void InputRouter::refreshHover(KxNode *root) {
    if (!has_last) return;
    updateHover(root, last_x, last_y, false);
}

void InputRouter::clearHover() {
    traversalBegin();
    if (hovered) {
        PointerEvent lev;
        lev.phase = PointerPhase::leave;
        lev.x = last_x; lev.y = last_y;
        lev.raw_x = last_x; lev.raw_y = last_y;
        sendPointer(hovered, lev);
    }
    hovered = nullptr;
    traversalEnd();
}

/// Release every reference to a node being destroyed (no GC: dangling
/// pointers are fatal). Exact matches only — children deinit separately.
void InputRouter::releaseNode(KxNode *node) {
    for (auto &slot : captured) {
        if (slot && slot->node == node) slot = std::nullopt;
    }
    if (hovered == node) hovered = nullptr;
    if (focused == node) focused = nullptr;
    if (open_popup == node) open_popup = nullptr;
}

void InputRouter::focus(KxNode *node) {
    // The previously focused node's focus styling must repaint.
    if (focused && focused != node) focused->markDirty();
    focused = node;
}

bool InputRouter::pushBackHandler(std::function<bool()> h, void *key) {
    if (back_stack_len >= 8) return false;
    back_stack[back_stack_len++] = BackEntry{std::move(h), key};
    return true;
}

void InputRouter::popBackHandler(void *key) {
    for (int i = back_stack_len - 1; i >= 0; --i) {
        if (back_stack[i].key == key) {
            for (int j = i; j < back_stack_len - 1; ++j) back_stack[j] = back_stack[j + 1];
            back_stack_len -= 1;
            return;
        }
    }
}

// ===========================================================================
// Reactive state (src/ui/state.zig)
// ===========================================================================

Subscriber Subscriber::forEffect(Effect *e) {
    Subscriber s; s.kind = Kind::effect; s.effect = e; return s;
}
Subscriber Subscriber::forNode(KxNode *n) {
    Subscriber s; s.kind = Kind::node; s.node = n; return s;
}
Subscriber Subscriber::forCallback(std::function<void()> f, void *key) {
    Subscriber s; s.kind = Kind::callback; s.fn = std::move(f); s.key = key; return s;
}
bool Subscriber::same(const Subscriber &o) const {
    if (kind != o.kind) return false;
    switch (kind) {
        case Kind::effect: return effect == o.effect;
        case Kind::node: return node == o.node;
        case Kind::callback: return key == o.key && key != nullptr;
    }
    return false;
}

void SignalBase::unsubscribe(const Subscriber &s) {
    for (size_t i = 0; i < subscribers.size(); ++i) {
        if (subscribers[i].same(s)) {
            subscribers.erase(subscribers.begin() + i);
            return;
        }
    }
}

void SignalBase::notify() {
    version += 1;
    auto snapshot = subscribers; // copy: callbacks may resubscribe
    for (const auto &s : snapshot) {
        // revalidate: still subscribed?
        bool live = false;
        for (const auto &cur : subscribers) if (cur.same(s)) { live = true; break; }
        if (!live) continue;
        switch (s.kind) {
            case Subscriber::Kind::effect:
                if (s.effect) s.effect->run();
                break;
            case Subscriber::Kind::node:
                if (s.node) s.node->markDirty();
                break;
            case Subscriber::Kind::callback:
                if (s.fn) s.fn();
                break;
        }
    }
}

static Effect *g_current_effect = nullptr;
Effect *currentEffect() { return g_current_effect; }
void setCurrentEffect(Effect *e) { g_current_effect = e; }

void trackDep(SignalBase *base) {
    if (auto *e = g_current_effect) e->track(base);
}

void Effect::track(SignalBase *base) {
    for (auto *d : deps_) if (d == base) return;
    deps_.push_back(base);
    base->subscribe(Subscriber::forEffect(this));
}

void Effect::run() {
    for (auto *d : deps_) d->unsubscribe(Subscriber::forEffect(this));
    deps_.clear();
    Effect *prev = g_current_effect;
    g_current_effect = this;
    if (fn_) fn_();
    g_current_effect = prev;
}

void Effect::deinit() {
    for (auto *d : deps_) d->unsubscribe(Subscriber::forEffect(this));
    deps_.clear();
}

Memo::Memo(std::function<qint64()> compute) : compute_(std::move(compute)) {
    effect_ = new Effect([this] {
        cache_ = compute_ ? compute_() : 0;
        base.notify();
    });
    effect_->run();
}

Memo::~Memo() { deinit(); }

void Memo::deinit() {
    if (effect_) { delete effect_; effect_ = nullptr; }
}

qint64 Memo::get() {
    if (auto *e = currentEffect()) e->track(&base);
    return cache_;
}

void bindNode(KxNode *node, SignalBase &sig) {
    sig.subscribe(Subscriber::forNode(node));
}

// ===========================================================================
// Timeline (src/ui/anim.zig — tickers only; the corpus has no animations)
// ===========================================================================

quint64 Timeline::addTicker(std::function<void(quint64)> fn, std::function<bool()> has_pending) {
    Ticker t;
    t.id = next_id_++;
    t.fn = std::move(fn);
    t.has_pending = std::move(has_pending);
    tickers_.push_back(std::move(t));
    return tickers_.back().id;
}

void Timeline::removeTicker(quint64 id) {
    for (auto &t : tickers_) if (t.id == id) t.active = false;
}

bool Timeline::hasTimedWork() const {
    for (const auto &t : tickers_)
        if (t.active && t.has_pending && t.has_pending()) return true;
    return false;
}

void Timeline::tick(quint64 now_ms) {
    last_now_ms = now_ms;
    traversalBegin();
    // Ticker callbacks run widget code — a callback that destroys a node
    // defers via the traversal freeze. Re-read the list every step.
    for (size_t i = 0; i < tickers_.size(); ++i) {
        Ticker t = tickers_[i]; // copy: callbacks may append/remove
        if (t.active && t.fn) t.fn(now_ms);
    }
    // Compact inactive tickers after the pass.
    std::vector<Ticker> kept;
    kept.reserve(tickers_.size());
    for (auto &t : tickers_) if (t.active) kept.push_back(std::move(t));
    tickers_ = std::move(kept);
    traversalEnd();
}

static Timeline *g_timeline = nullptr;
void setCurrentTimeline(Timeline *tl) { g_timeline = tl; }
Timeline *currentTimeline() { return g_timeline; }

// ===========================================================================
// Scroll state + virtualization (src/ui/scroll.zig + widgets/scroll_util.zig)
// ===========================================================================

bool ScrollState::setOffset(float value) {
    const float clamped = std::clamp(value, 0.0f, maxOffset());
    if (clamped == offset) return false;
    offset = clamped;
    return true;
}

Range visibleRange(size_t item_count, float stride, float viewport, float offset, size_t margin) {
    // ui/scroll.zig: empty when any input is degenerate; half-open
    // [first, last) = intersecting items ± margin, clamped to the count.
    if (item_count == 0 || viewport <= 0 || stride <= 0) return {0, 0};
    const float margin_f = static_cast<float>(margin);
    const float count_f = static_cast<float>(item_count);
    const float first_f = std::max(0.0f, std::floor(offset / stride) - margin_f);
    const float last_f = std::min(count_f, std::ceil((offset + viewport) / stride) + margin_f);
    const size_t first = static_cast<size_t>(std::max(0.0f, first_f));
    const size_t last = static_cast<size_t>(std::max(static_cast<float>(first), last_f));
    return {first, last};
}

static ScrollInput::Track *trackFor(ScrollInput &inp, quint64 pointer) {
    for (auto &t : inp.tracks)
        if (t.active && t.pointer == pointer) return &t;
    for (auto &t : inp.tracks)
        if (!t.active) return &t;
    return &inp.tracks[0]; // full: reuse slot 0 (P0)
}

static void releaseTrack(ScrollInput &inp, quint64 pointer) {
    for (auto &t : inp.tracks)
        if (t.active && t.pointer == pointer) t.active = false;
}

/// Drag: a move only scrolls while the router has a capture for the pointer
/// (a real drag — hover moves never scroll). Tracks live in window space
/// (raw_y) so content scrolling under a held finger doesn't cancel the drag.
bool ScrollInput::onPointer(const PointerEvent &ev, ScrollState &scroll,
                            const SetOffset &set_offset, KxNode *n) {
    switch (ev.phase) {
        case PointerPhase::down: {
            Track *t = trackFor(*this, ev.pointer);
            *t = Track{ev.pointer, ev.raw_y, true};
            return false; // items handle taps
        }
        case PointerPhase::up:
        case PointerPhase::outside_down:
            releaseTrack(*this, ev.pointer);
            return false;
        case PointerPhase::move:
            break;
        default:
            return false;
    }
    InputRouter *router = currentRouter();
    if (!router) return false;
    const bool dragging = router->capturedNode(ev.pointer) != nullptr;
    Track *t = trackFor(*this, ev.pointer);
    const float last = (t->active && t->pointer == ev.pointer) ? t->y : ev.raw_y;
    *t = Track{ev.pointer, ev.raw_y, true};
    if (!dragging) return false; // hover move: no scroll
    const float dy = ev.raw_y - last;
    if (dy == 0) return false;
    // The finger drags the content: moving up (dy < 0) increases the offset.
    return set_offset(n, scroll.offset - dy);
}

/// Wheel: positive delta_y = scroll up = offset decreases.
bool ScrollInput::onScroll(const ScrollEvent &ev, ScrollState &scroll, float wheel_speed,
                           const SetOffset &set_offset, KxNode *n) {
    if (!scroll.info().canScroll()) return false;
    return set_offset(n, scroll.offset - ev.delta_y * wheel_speed);
}

// syncItemWindow — the virtualization diff (scroll_util.zig): children[0]
// is item `first`; the window is [range.first, range.last).
void syncItemWindow(KxNode *n, size_t *first, const ItemFactory &factory,
                    Range range, const LayoutItem &layout_item) {
    auto &kids = n->children;
    // Non-overlapping windows (or an empty window): drop everything and
    // re-anchor — a large jump must NOT materialize the intervening items.
    const size_t old_last = *first + kids.size();
    const bool overlaps = *first < range.last && range.first < old_last;
    if (!overlaps) {
        while (!kids.empty()) {
            KxNode *child = kids.back();
            n->remove(child); // detach then deinit — never the reverse
            child->deinit();
        }
        *first = range.first;
    }
    // Trim items that left the window (front): destroy the child and
    // advance `first` — advancing continues past an empty window.
    while (*first < range.first) {
        if (!kids.empty()) {
            KxNode *child = kids.front();
            n->remove(child);
            child->deinit();
        }
        *first += 1;
    }
    // Trim items that left the window (back).
    while (*first + kids.size() > range.last && !kids.empty()) {
        KxNode *child = kids.back();
        n->remove(child);
        child->deinit();
    }
    // Items entering at the front (scrolled up): prepend. scroll_util.zig
    // inserts into the children list + sets the parent directly — no
    // markDirty/markLayoutDirty (the list marks once per scroll).
    while (*first > range.first) {
        *first -= 1;
        KxNode *child = factory(*first);
        n->children.insert(n->children.begin(), child);
        child->parent = n;
        layout_item(n, child, *first);
    }
    // Items entering at the back (scrolled down): append.
    while (*first + kids.size() < range.last) {
        const size_t index = *first + kids.size();
        KxNode *child = factory(index);
        n->add(child);
        layout_item(n, child, index);
    }
}

// ===========================================================================
// Gestures (src/ui/gestures.zig)
// ===========================================================================

QString swipeDirectionName(SwipeDirection d) {
    switch (d) {
        case SwipeDirection::left: return "left";
        case SwipeDirection::right: return "right";
        case SwipeDirection::up: return "up";
        case SwipeDirection::down: return "down";
    }
    return "left";
}

using Rec = GestureArena::Recognizer;
using Fire = GestureArena::Fire;

void Rec::reset() {
    state = State::idle;
    tracking = std::nullopt;
    ptr_a = std::nullopt;
    ptr_b = std::nullopt;
    long_press_fired = false;
    sample_len = 0;
    // double-tap memory is not gesture state: it survives cancels.
}

static float dist(float x1, float y1, float x2, float y2) {
    const float dx = x2 - x1, dy = y2 - y1;
    return std::sqrt(dx * dx + dy * dy);
}

static bool follows(Rec &rec, const PointerEvent &ev) {
    if (rec.tracking) return ev.pointer == *rec.tracking;
    return ev.phase == PointerPhase::down;
}

static void beginDown(Rec &rec, const PointerEvent &ev) {
    rec.state = Rec::State::possible;
    rec.tracking = ev.pointer;
    rec.start_x = ev.x; rec.start_y = ev.y;
    rec.start_time = ev.time_ms;
    rec.last_x = ev.x; rec.last_y = ev.y;
}

static void addSample(Rec &rec, const PointerEvent &ev) {
    if (rec.sample_len == 8) {
        for (int i = 0; i < 7; ++i) rec.samples[i] = rec.samples[i + 1];
        rec.samples[7] = {ev.x, ev.y, ev.time_ms};
    } else {
        rec.samples[rec.sample_len++] = {ev.x, ev.y, ev.time_ms};
    }
}

static void trackDown(Rec &rec, const PointerEvent &ev) {
    if (!rec.ptr_a) {
        rec.ptr_a = Rec::Tracked{ev.pointer, ev.x, ev.y};
    } else if (!rec.ptr_b && ev.pointer != rec.ptr_a->id) {
        rec.ptr_b = Rec::Tracked{ev.pointer, ev.x, ev.y};
    }
    if (rec.ptr_a && rec.ptr_b) {
        const auto a = *rec.ptr_a, b = *rec.ptr_b;
        rec.initial_distance = dist(a.x, a.y, b.x, b.y);
        rec.initial_angle = std::atan2(b.y - a.y, b.x - a.x);
        rec.last_angle = rec.initial_angle;
        rec.state = Rec::State::accepted;
    }
}

static bool trackUp(Rec &rec, const PointerEvent &ev) {
    bool lifted = false;
    if (rec.ptr_a && rec.ptr_a->id == ev.pointer) { rec.ptr_a = std::nullopt; lifted = true; }
    if (rec.ptr_b && rec.ptr_b->id == ev.pointer) { rec.ptr_b = std::nullopt; lifted = true; }
    if (lifted) rec.state = Rec::State::idle;
    return lifted;
}

static float wrapAngle(float d) {
    float r = d;
    const float two_pi = 2 * static_cast<float>(M_PI);
    while (r > static_cast<float>(M_PI)) r -= two_pi;
    while (r < -static_cast<float>(M_PI)) r += two_pi;
    return r;
}

static bool trackMove(Rec &rec, const PointerEvent &ev) {
    if (rec.ptr_a && rec.ptr_a->id == ev.pointer) {
        rec.ptr_a->x = ev.x; rec.ptr_a->y = ev.y;
        return true;
    }
    if (rec.ptr_b && rec.ptr_b->id == ev.pointer) {
        rec.ptr_b->x = ev.x; rec.ptr_b->y = ev.y;
        return true;
    }
    return false;
}

static void velocity(Rec &rec, quint64 now, float *vx, float *vy) {
    *vx = 0; *vy = 0;
    if (rec.sample_len == 0) return;
    auto first = rec.samples[rec.sample_len - 1];
    for (int i = 0; i < rec.sample_len; ++i) {
        if (now - rec.samples[i].t <= VELOCITY_WINDOW_MS) { first = rec.samples[i]; break; }
    }
    const auto last = rec.samples[rec.sample_len - 1];
    const quint64 dt_ms = last.t - first.t;
    if (dt_ms == 0) return;
    const float dt = static_cast<float>(dt_ms) / 1000.0f;
    *vx = (last.x - first.x) / dt;
    *vy = (last.y - first.y) / dt;
}

Fire feedTap(Rec &rec, const PointerEvent &ev) {
    if (!follows(rec, ev)) return {};
    switch (ev.phase) {
        case PointerPhase::down: beginDown(rec, ev); return {};
        case PointerPhase::move:
            if (rec.state == Rec::State::possible &&
                dist(ev.x, ev.y, rec.start_x, rec.start_y) > GESTURE_SLOP)
                rec.state = Rec::State::rejected;
            rec.last_x = ev.x; rec.last_y = ev.y;
            return {};
        case PointerPhase::up: {
            const bool ok = rec.state == Rec::State::possible &&
                            dist(ev.x, ev.y, rec.start_x, rec.start_y) <= GESTURE_SLOP &&
                            ev.time_ms - rec.start_time < TAP_TIMEOUT_MS;
            rec.state = Rec::State::idle;
            rec.tracking = std::nullopt;
            if (ok) { Fire f; f.k = Fire::K::tap; return f; }
            return {};
        }
        default: rec.reset(); return {};
    }
}

Fire feedDoubleTap(Rec &rec, const PointerEvent &ev) {
    if (!follows(rec, ev)) return {};
    switch (ev.phase) {
        case PointerPhase::down: beginDown(rec, ev); return {};
        case PointerPhase::move:
            if (rec.state == Rec::State::possible &&
                dist(ev.x, ev.y, rec.start_x, rec.start_y) > GESTURE_SLOP)
                rec.state = Rec::State::rejected;
            return {};
        case PointerPhase::up: {
            const bool is_tap = rec.state == Rec::State::possible &&
                                dist(ev.x, ev.y, rec.start_x, rec.start_y) <= GESTURE_SLOP &&
                                ev.time_ms - rec.start_time < TAP_TIMEOUT_MS;
            rec.state = Rec::State::idle;
            rec.tracking = std::nullopt;
            if (!is_tap) { rec.has_last_tap = false; return {}; }
            if (rec.has_last_tap &&
                ev.time_ms - rec.last_tap_time < DOUBLE_TAP_MS &&
                dist(ev.x, ev.y, rec.last_tap_x, rec.last_tap_y) <= GESTURE_SLOP) {
                rec.has_last_tap = false;
                Fire f; f.k = Fire::K::double_tap; return f;
            }
            rec.last_tap_time = ev.time_ms;
            rec.last_tap_x = ev.x; rec.last_tap_y = ev.y;
            rec.has_last_tap = true;
            return {};
        }
        default: rec.reset(); return {};
    }
}

Fire feedLongPress(Rec &rec, const PointerEvent &ev) {
    if (!follows(rec, ev)) return {};
    switch (ev.phase) {
        case PointerPhase::down:
            beginDown(rec, ev);
            rec.long_press_fired = false;
            return {};
        case PointerPhase::move:
            if (rec.state != Rec::State::possible) return {};
            if (dist(ev.x, ev.y, rec.start_x, rec.start_y) > GESTURE_SLOP) {
                rec.state = Rec::State::rejected;
                return {};
            }
            if (!rec.long_press_fired && ev.time_ms - rec.start_time >= LONG_PRESS_MS) {
                rec.long_press_fired = true;
                rec.state = Rec::State::idle;
                rec.tracking = std::nullopt;
                Fire f; f.k = Fire::K::long_press; return f;
            }
            return {};
        case PointerPhase::up: {
            const bool ok = rec.state == Rec::State::possible && !rec.long_press_fired &&
                            dist(ev.x, ev.y, rec.start_x, rec.start_y) <= GESTURE_SLOP &&
                            ev.time_ms - rec.start_time >= LONG_PRESS_MS;
            rec.state = Rec::State::idle;
            rec.tracking = std::nullopt;
            if (ok) { Fire f; f.k = Fire::K::long_press; return f; }
            return {};
        }
        default: rec.reset(); return {};
    }
}

Fire feedPan(Rec &rec, const PointerEvent &ev) {
    if (!follows(rec, ev)) return {};
    switch (ev.phase) {
        case PointerPhase::down:
            beginDown(rec, ev);
            rec.sample_len = 0;
            addSample(rec, ev);
            return {};
        case PointerPhase::move:
            if (rec.state == Rec::State::possible) {
                if (dist(ev.x, ev.y, rec.start_x, rec.start_y) > GESTURE_SLOP) {
                    rec.state = Rec::State::accepted;
                    rec.last_x = ev.x;
                    rec.last_y = ev.y;
                    addSample(rec, ev);
                    Fire f; f.k = Fire::K::pan_start;
                    f.a = ev.x - rec.start_x; f.b = ev.y - rec.start_y;
                    return f;
                }
                return {};
            }
            if (rec.state == Rec::State::accepted) {
                const float dx = ev.x - rec.last_x;
                const float dy = ev.y - rec.last_y;
                rec.last_x = ev.x; rec.last_y = ev.y;
                addSample(rec, ev);
                Fire f; f.k = Fire::K::pan_update; f.a = dx; f.b = dy;
                return f;
            }
            return {};
        case PointerPhase::up: {
            if (rec.state != Rec::State::accepted) {
                rec.state = Rec::State::idle;
                rec.tracking = std::nullopt;
                return {};
            }
            rec.state = Rec::State::idle;
            rec.tracking = std::nullopt;
            addSample(rec, ev);
            float vx, vy;
            velocity(rec, ev.time_ms, &vx, &vy);
            const float dx = ev.x - rec.last_x;
            const float dy = ev.y - rec.last_y;
            if (rec.kind == GestureArena::Kind::swipe &&
                std::max(std::abs(vx), std::abs(vy)) > SWIPE_VELOCITY) {
                Fire f; f.k = Fire::K::swipe;
                if (std::abs(vx) >= std::abs(vy))
                    f.dir = vx > 0 ? SwipeDirection::right : SwipeDirection::left;
                else
                    f.dir = vy > 0 ? SwipeDirection::down : SwipeDirection::up;
                f.a = vx; f.b = vy;
                return f;
            }
            Fire f; f.k = Fire::K::pan_end;
            f.a = vx; f.b = vy; f.c = dx; f.d = dy;
            return f;
        }
        default: rec.reset(); return {};
    }
}

Fire feedPinch(Rec &rec, const PointerEvent &ev) {
    switch (ev.phase) {
        case PointerPhase::down: trackDown(rec, ev); return {};
        case PointerPhase::move: {
            if (rec.state != Rec::State::accepted || !trackMove(rec, ev)) return {};
            const auto a = *rec.ptr_a, b = *rec.ptr_b;
            if (rec.initial_distance <= 0) return {};
            Fire f; f.k = Fire::K::pinch;
            f.a = dist(a.x, a.y, b.x, b.y) / rec.initial_distance;
            return f;
        }
        case PointerPhase::up: trackUp(rec, ev); return {};
        default: rec.reset(); return {};
    }
}

Fire feedRotate(Rec &rec, const PointerEvent &ev) {
    switch (ev.phase) {
        case PointerPhase::down: trackDown(rec, ev); return {};
        case PointerPhase::move: {
            if (rec.state != Rec::State::accepted || !trackMove(rec, ev)) return {};
            const auto a = *rec.ptr_a, b = *rec.ptr_b;
            const float angle = std::atan2(b.y - a.y, b.x - a.x);
            const float delta = wrapAngle(angle - rec.last_angle);
            rec.last_angle = angle;
            Fire f; f.k = Fire::K::rotate; f.a = delta;
            return f;
        }
        case PointerPhase::up: trackUp(rec, ev); return {};
        default: rec.reset(); return {};
    }
}

Fire GestureArena::feedRec(Recognizer &rec, const PointerEvent &ev) {
    switch (rec.kind) {
        case Kind::tap: return feedTap(rec, ev);
        case Kind::double_tap: return feedDoubleTap(rec, ev);
        case Kind::long_press: return feedLongPress(rec, ev);
        case Kind::pan:
        case Kind::swipe: return feedPan(rec, ev);
        case Kind::pinch: return feedPinch(rec, ev);
        case Kind::rotate: return feedRotate(rec, ev);
    }
    return {};
}

Fire GestureArena::tickRec(Recognizer &rec, quint64 now_ms) {
    if (rec.kind != Kind::long_press) return {};
    if (rec.state != Recognizer::State::possible || rec.long_press_fired) return {};
    if (now_ms - rec.start_time < LONG_PRESS_MS) return {};
    rec.long_press_fired = true;
    rec.state = Recognizer::State::idle;
    rec.tracking = std::nullopt;
    Fire f; f.k = Fire::K::long_press;
    return f;
}

void GestureArena::invoke(const Fire &f) {
    switch (f.k) {
        case Fire::K::tap: if (cbs_.on_tap) cbs_.on_tap(); break;
        case Fire::K::double_tap: if (cbs_.on_double_tap) cbs_.on_double_tap(); break;
        case Fire::K::long_press: if (cbs_.on_long_press) cbs_.on_long_press(); break;
        case Fire::K::pan_start: if (cbs_.on_pan_start) cbs_.on_pan_start(f.a, f.b); break;
        case Fire::K::pan_update: if (cbs_.on_pan_update) cbs_.on_pan_update(f.a, f.b); break;
        case Fire::K::pan_end: if (cbs_.on_pan_end) cbs_.on_pan_end(f.a, f.b, f.c, f.d); break;
        case Fire::K::swipe: if (cbs_.on_swipe) cbs_.on_swipe(f.dir, f.a, f.b); break;
        case Fire::K::pinch: if (cbs_.on_pinch) cbs_.on_pinch(f.a); break;
        case Fire::K::rotate: if (cbs_.on_rotate) cbs_.on_rotate(f.a); break;
        default: break;
    }
}

GestureArena::GestureArena(const GestureCallbacks &cbs) : cbs_(cbs) {
    auto push = [this](Kind kind, bool enabled) {
        if (enabled && recognizers_.size() < 8) {
            Recognizer r; r.kind = kind;
            recognizers_.push_back(r);
        }
    };
    push(Kind::tap, cbs.on_tap != nullptr);
    push(Kind::double_tap, cbs.on_double_tap != nullptr);
    push(Kind::long_press, cbs.on_long_press != nullptr);
    push(Kind::pan, cbs.on_pan_start != nullptr ||
                                cbs.on_pan_update != nullptr || cbs.on_pan_end != nullptr);
    push(Kind::swipe, cbs.on_swipe != nullptr);
    push(Kind::pinch, cbs.on_pinch != nullptr);
    push(Kind::rotate, cbs.on_rotate != nullptr);
}

void GestureArena::feed(const PointerEvent &ev) {
    if (ev.phase == PointerPhase::enter || ev.phase == PointerPhase::leave ||
        ev.phase == PointerPhase::outside_down) {
        cancel();
        return;
    }
    // Two-pointer gestures first.
    bool two_finger_active = false;
    for (auto &r : recognizers_) {
        if (r.kind != Kind::pinch && r.kind != Kind::rotate) continue;
        Fire f = feedRec(r, ev);
        if (f.k == Fire::K::pinch || f.k == Fire::K::rotate) invoke(f);
        if (r.state == Recognizer::State::accepted) {
            two_finger_active = true;
            for (auto &o : recognizers_) {
                if (o.kind == Kind::pinch || o.kind == Kind::rotate) continue;
                o.reset();
            }
        }
    }
    if (two_finger_active) return;
    // Single-pointer recognizers.
    bool tap_fire = false, double_tap_fire = false;
    std::optional<Fire> terminal;
    for (auto &r : recognizers_) {
        if (r.kind == Kind::pinch || r.kind == Kind::rotate) continue;
        Fire f = feedRec(r, ev);
        switch (f.k) {
            case Fire::K::tap: tap_fire = true; break;
            case Fire::K::double_tap: double_tap_fire = true; break;
            case Fire::K::pan_start:
            case Fire::K::pan_update:
                invoke(f); break;
            case Fire::K::long_press:
            case Fire::K::pan_end:
            case Fire::K::swipe:
                if (!terminal) terminal = f;
                break;
            default: break;
        }
    }
    // Resolution: double-tap suppresses the same-event tap.
    if (double_tap_fire) {
        if (cbs_.on_double_tap) cbs_.on_double_tap();
    } else if (tap_fire) {
        if (cbs_.on_tap) cbs_.on_tap();
    } else if (terminal) {
        invoke(*terminal);
    }
}

void GestureArena::cancel() {
    for (auto &r : recognizers_) r.reset();
}

void GestureArena::tick(quint64 now_ms) {
    for (auto &r : recognizers_) {
        Fire f = tickRec(r, now_ms);
        if (f.k == Fire::K::long_press) {
            if (cbs_.on_long_press) cbs_.on_long_press();
        }
    }
}

bool GestureArena::hasPendingTimeWork() const {
    for (const auto &r : recognizers_)
        if (r.kind == Kind::long_press &&
            r.state == Recognizer::State::possible && !r.long_press_fired) return true;
    return false;
}

// ===========================================================================
// i18n (src/ui/i18n.zig)
// ===========================================================================

/// Zig `{d}` float formatting: the shortest decimal that round-trips,
/// in positional notation (no exponent). std::to_chars general mode yields
/// the same digits; a scientific result is expanded back to positional so
/// the integer/fraction split below sees the same string Zig produced.
static QString zigFloatDigits(double v) {
    char buf[64];
    const auto r = std::to_chars(buf, buf + sizeof(buf), v);
    QString s = QString::fromLatin1(buf, static_cast<int>(r.ptr - buf));
    const int epos = s.indexOf('e');
    if (epos < 0) return s;
    // Expand "d.dddde±X" into positional form.
    QString mant = s.left(epos);
    int exp10 = s.mid(epos + 1).toInt();
    const bool neg = mant.startsWith('-');
    if (neg) mant = mant.mid(1);
    const int dot = mant.indexOf('.');
    QString digits = (dot < 0) ? mant : mant.left(dot) + mant.mid(dot + 1);
    int point = (dot < 0) ? digits.size() : dot;
    point += exp10;
    QString out;
    if (neg) out += '-';
    if (point <= 0) {
        out += "0.";
        out += QString(-point, '0');
        out += digits;
    } else if (point >= digits.size()) {
        out += digits;
        out += QString(point - digits.size(), '0');
    } else {
        out += digits.left(point);
        out += '.';
        out += digits.mid(point);
    }
    return out;
}

QString KxLocale::formatNumber(double value, const NumberOptions &opts) const {
    QString buf;
    double v = value;
    if (v < 0) { buf += '-'; v = -v; }
    if (opts.percent) v *= 100.0;
    // Shortest round-trip digits, then split integer/fraction.
    const QString all = zigFloatDigits(v);
    const int dot = all.indexOf('.');
    const QString int_part = dot < 0 ? all : all.left(dot);
    const QString frac_part = dot < 0 ? QString() : all.mid(dot + 1);
    // Group the integer part (groups of 3, from the right).
    if (opts.grouping && int_part.size() > 3) {
        const int len = int_part.size();
        const int rem = len % 3;
        const int first_n = rem == 0 ? 3 : rem;
        buf += int_part.left(first_n);
        for (int pos = first_n; pos < len; pos += 3) {
            buf += group_sep;
            buf += int_part.mid(pos, 3);
        }
    } else {
        buf += int_part;
    }
    if (opts.decimals) {
        const int d = *opts.decimals;
        if (d > 0) {
            buf += decimal_sep;
            for (int i = 0; i < d; ++i)
                buf += i < frac_part.size() ? frac_part[i] : QLatin1Char('0');
        }
    } else if (!frac_part.isEmpty()) {
        buf += decimal_sep;
        buf += frac_part;
    }
    if (opts.percent) buf += '%';
    return buf;
}

QString KxLocale::formatDate(const Date &d, DateKind kind) const {
    const QString fmt = kind == DateKind::short_ ? date_short
                        : kind == DateKind::medium ? date_medium : date_long;
    // Minimal formatter for the corpus patterns: M/d/yy, MMM d, y, MMMM d, y,
    // d MMM y, d MMMM y, yy/M/d, d/M/yy.
    QString out;
    for (int i = 0; i < fmt.size();) {
        if (fmt[i] == 'M') {
            int n = 0;
            while (i < fmt.size() && fmt[i] == 'M') { ++n; ++i; }
            if (n >= 4) out += month_long[d.month - 1];
            else if (n == 3) out += month_short[d.month - 1];
            else if (n == 2) out += QString("%1").arg(d.month, 2, 10, QLatin1Char('0'));
            else out += QString::number(d.month);
        } else if (fmt[i] == 'd') {
            int n = 0;
            while (i < fmt.size() && fmt[i] == 'd') { ++n; ++i; }
            if (n == 2) out += QString("%1").arg(d.day, 2, 10, QLatin1Char('0'));
            else out += QString::number(d.day);
        } else if (fmt[i] == 'y') {
            int n = 0;
            while (i < fmt.size() && fmt[i] == 'y') { ++n; ++i; }
            if (n == 2) out += QString("%1").arg(d.year % 100, 2, 10, QLatin1Char('0'));
            else out += QString::number(d.year);
        } else {
            out += fmt[i];
            ++i;
        }
    }
    return out;
}

void applyFormatData(KxLocale &loc) {
    // Base tag only (i18n.zig splits on '-').
    const QString t = loc.tag.section('-', 0, 0);
    auto setMonths = [&loc](const char *const long_[12], const char *const short_[12]) {
        for (int i = 0; i < 12; ++i) {
            loc.month_long[i] = QString::fromUtf8(long_[i]);
            loc.month_short[i] = QString::fromUtf8(short_[i]);
        }
    };
    if (t == "fr") {
        loc.decimal_sep = ",";
        loc.group_sep = " "; // i18n.zig table: a plain space (not CLDR's NNBSP)
        loc.date_short = "dd/MM/y";
        loc.date_medium = "d MMM y";
        loc.date_long = "d MMMM y";
        static const char *const l[12] = {
            "janvier", "février", "mars", "avril", "mai", "juin",
            "juillet", "août", "septembre", "octobre", "novembre", "décembre"};
        static const char *const s[12] = {
            "janv.", "févr.", "mars", "avr.", "mai", "juin",
            "juil.", "août", "sept.", "oct.", "nov.", "déc."};
        setMonths(l, s);
    } else if (t == "ja") {
        loc.date_short = "y/MM/dd";
        loc.date_medium = "y/MM/dd";
        loc.date_long = "y年M月d日";
        static const char *const l[12] = {
            "1月", "2月", "3月", "4月", "5月", "6月",
            "7月", "8月", "9月", "10月", "11月", "12月"};
        setMonths(l, l);
    } else if (t == "ar") {
        loc.direction = Direction::rtl;
        loc.date_short = "d/M/y";
        loc.date_medium = "d MMM y";
        loc.date_long = "d MMMM y";
        static const char *const l[12] = {
            "يناير", "فبراير", "مارس", "أبريل", "مايو", "يونيو",
            "يوليو", "أغسطس", "سبتمبر", "أكتوبر", "نوفمبر", "ديسمبر"};
        static const char *const s[12] = {
            "يناير", "فبراير", "مارس", "أبريل", "مايو", "يونيو",
            "يوليو", "أغسطس", "سبتمبر", "أكتوبر", "نوفمبر", "ديسمبر"};
        setMonths(l, s);
    }
    // en + unknown tags: defaults already set.
}

PluralCategory pluralCategory(const QString &tag, qint64 n) {
    const QString base = tag.section('-', 0, 0);
    if (base == "fr") {
        // fr: one covers 0 and 1
        return (n >= 0 && n < 2) ? PluralCategory::one : PluralCategory::other;
    }
    if (base == "ja") return PluralCategory::other;
    if (base == "ar") {
        if (n == 0) return PluralCategory::zero;
        if (n == 1) return PluralCategory::one;
        if (n == 2) return PluralCategory::two;
        if (n > 0) {
            const qint64 m100 = ((n % 100) + 100) % 100;
            if (m100 >= 3 && m100 <= 10) return PluralCategory::few;
            if (m100 >= 11 && m100 <= 99) return PluralCategory::many;
        }
        return PluralCategory::other;
    }
    // en + default: one is exactly 1
    return n == 1 ? PluralCategory::one : PluralCategory::other;
}

/// Parse an ARB plural block: `{count, plural, =0 {...} one {...} other
/// {...}}` (i18n.zig parsePlural — the block opens at the '{' before the
/// count name; `, plural,` is the marker). Returns nullopt when the message
/// is not a plural block.
std::optional<PluralMsg> parsePlural(const QString &msg) {
    const int p = msg.indexOf(QStringLiteral(", plural,"));
    if (p < 0) return std::nullopt;
    const int open = msg.lastIndexOf('{', p - 1);
    if (open < 0) return std::nullopt;
    PluralMsg out;
    out.prefix = msg.left(open);
    int i = p + static_cast<int>(QStringLiteral(", plural,").size());
    static const QHash<QString, PluralCategory> cats{
        {"zero", PluralCategory::zero}, {"one", PluralCategory::one},
        {"two", PluralCategory::two}, {"few", PluralCategory::few},
        {"many", PluralCategory::many}, {"other", PluralCategory::other},
    };
    while (i < msg.size()) {
        while (i < msg.size() && msg[i] == ' ') ++i; // skip whitespace
        if (i >= msg.size()) return std::nullopt;
        if (msg[i] == '}') {
            out.suffix = msg.mid(i + 1);
            return out.len > 0 ? std::optional<PluralMsg>(out) : std::nullopt;
        }
        PluralBranch br;
        if (msg[i] == '=') {
            // exact selector: =N (optional sign)
            ++i;
            bool neg = false;
            if (i < msg.size() && msg[i] == '-') { neg = true; ++i; }
            qint64 num = 0;
            while (i < msg.size() && msg[i].isDigit()) {
                num = num * 10 + (msg[i].unicode() - '0');
                ++i;
            }
            br.exact = neg ? -num : num;
        } else {
            const int start = i;
            while (i < msg.size() && msg[i] != ' ' && msg[i] != '{') ++i;
            const QString kw = msg.mid(start, i - start);
            auto it = cats.find(kw);
            br.category = it == cats.end() ? std::optional<PluralCategory>() : *it;
        }
        while (i < msg.size() && msg[i] == ' ') ++i;
        if (i >= msg.size() || msg[i] != '{') return std::nullopt;
        ++i;
        const int text_start = i;
        int depth = 1;
        while (i < msg.size() && depth > 0) {
            if (msg[i] == '{') ++depth;
            else if (msg[i] == '}') --depth;
            ++i;
        }
        if (depth != 0) return std::nullopt;
        br.text = msg.mid(text_start, i - 1 - text_start);
        if (out.len >= 16) return std::nullopt; // too many branches — reject
        out.branches[out.len++] = br;
    }
    return out.len > 0 ? std::optional<PluralMsg>(out) : std::nullopt;
}

std::optional<QString> selectPlural(const PluralMsg &msg, const QString &tag, qint64 count) {
    // exact branches first
    for (quint32 i = 0; i < msg.len; ++i)
        if (msg.branches[i].exact && *msg.branches[i].exact == count)
            return msg.branches[i].text;
    const PluralCategory cat = pluralCategory(tag, count);
    for (quint32 i = 0; i < msg.len; ++i)
        if (msg.branches[i].category && *msg.branches[i].category == cat)
            return msg.branches[i].text;
    // fall back to "other"
    for (quint32 i = 0; i < msg.len; ++i)
        if (msg.branches[i].category && *msg.branches[i].category == PluralCategory::other)
            return msg.branches[i].text;
    return std::nullopt;
}

QString interpolate(const QString &msg, const QHash<QString, QString> &args) {
    QString out;
    for (int i = 0; i < msg.size();) {
        if (msg[i] == '{') {
            const int close = msg.indexOf('}', i);
            if (close > i + 1) {
                const QString name = msg.mid(i + 1, close - i - 1);
                auto it = args.find(name);
                if (it != args.end()) {
                    out += *it;
                    i = close + 1;
                    continue;
                }
            }
        }
        out += msg[i];
        ++i;
    }
    return out;
}

/// Interpolate a plural branch: `#` and `{count}` expand to the count,
/// other `{name}` placeholders come from the args map (i18n.zig).
static QString interpolatePlural(const QString &branch, qint64 count,
                                 const QHash<QString, QString> &args) {
    QString out;
    const QString count_str = QString::number(count);
    for (int i = 0; i < branch.size();) {
        if (branch[i] == '#') {
            out += count_str;
            ++i;
            continue;
        }
        if (branch[i] == '{') {
            const int close = branch.indexOf('}', i);
            if (close > i + 1) {
                const QString name = branch.mid(i + 1, close - i - 1);
                if (name == "count") {
                    out += count_str;
                    i = close + 1;
                    continue;
                }
                auto it = args.find(name);
                if (it != args.end()) {
                    out += *it;
                    i = close + 1;
                    continue;
                }
            }
        }
        out += branch[i];
        ++i;
    }
    return out;
}

// --- I18n ---

I18n::I18n(const QString &fallback_tag) : fallback_(fallback_tag) {}
I18n::~I18n() {
    qDeleteAll(locales_);
}

/// Register a locale from an ARB object: fresh KxLocale (re-registering
/// replaces the whole catalog — stale keys never survive a reload), then
/// the addLocale swap protocol from i18n.zig: replacing the current locale
/// force-notifies (same tag suppresses Signal::set) + fires the direction
/// callback on a flip; replacing the fallback catalog also invalidates.
bool I18n::addArb(const QString &tag, const QJsonObject &msgs, Direction dir, QString *err) {
    auto *loc = new KxLocale;
    loc->tag = tag;
    loc->direction = dir;
    for (auto it = msgs.begin(); it != msgs.end(); ++it) {
        if (it.key().startsWith('@')) continue;
        if (it.value().isString()) loc->messages.insert(it.key(), it.value().toString());
    }
    // addLocale(loc): applyFormatData may re-set the direction (ar → rtl).
    Direction replaced_dir;
    bool had_replaced = false;
    if (KxLocale *old = locales_.value(tag, nullptr)) {
        locales_.remove(tag);
        if (current_ == old) {
            had_replaced = true;
            replaced_dir = old->direction;
            current_ = loc;
        }
        delete old;
    }
    locales_.insert(tag, loc);
    applyFormatData(*loc);
    if (!current_) current_ = loc;
    if (had_replaced) {
        locale_sig.forceNotify();
        if (loc->direction != replaced_dir && on_direction_changed) on_direction_changed();
    } else if (loc->tag == fallback_) {
        locale_sig.forceNotify();
    }
    if (err) err->clear();
    return true;
}

bool I18n::setLocale(const QString &tag, QString *err) {
    KxLocale *loc = locales_.value(tag, nullptr);
    if (!loc) {
        if (err) *err = "UnknownLocale";
        return false;
    }
    const Direction old_dir = dir();
    current_ = loc;
    locale_sig.set(loc->tag); // notifies → widgets re-render (same tag: no-op, like Zig)
    if (dir() != old_dir && on_direction_changed) on_direction_changed();
    if (err) err->clear();
    return true;
}

Direction I18n::dir() const {
    return current_ ? current_->direction : Direction::ltr;
}

QString I18n::tr(const QString &key) const {
    if (current_) {
        auto it = current_->messages.find(key);
        if (it != current_->messages.end()) return *it;
    }
    KxLocale *fb = locales_.value(fallback_, nullptr);
    if (fb) {
        auto it = fb->messages.find(key);
        if (it != fb->messages.end()) return *it;
    }
    return key;
}

QString I18n::trArgs(const QString &key, const QHash<QString, QString> &args) const {
    return interpolate(tr(key), args);
}

/// Resolve a message and the tag of the locale that provided it (plural
/// rules follow the message's locale, not the active one — i18n.zig).
QString I18n::trPlural(const QString &key, qint64 count,
                       const QHash<QString, QString> &args) const {
    QString msg = key, tag = current_ ? current_->tag : QString();
    if (current_) {
        auto it = current_->messages.find(key);
        if (it != current_->messages.end()) { msg = *it; tag = current_->tag; }
        else if (KxLocale *fb = locales_.value(fallback_, nullptr)) {
            auto fit = fb->messages.find(key);
            if (fit != fb->messages.end()) { msg = *fit; tag = fb->tag; }
        }
    } else if (KxLocale *fb = locales_.value(fallback_, nullptr)) {
        auto fit = fb->messages.find(key);
        if (fit != fb->messages.end()) { msg = *fit; tag = fb->tag; }
    }
    auto pm = parsePlural(msg);
    if (!pm) return interpolate(msg, args);
    auto branch = selectPlural(*pm, tag, count);
    if (!branch) return msg; // Zig returns the raw message (no interpolation)
    if (pm->prefix.isEmpty() && pm->suffix.isEmpty())
        return interpolatePlural(*branch, count, args);
    return interpolate(pm->prefix, args) + interpolatePlural(*branch, count, args) +
           interpolate(pm->suffix, args);
}

static I18n *g_i18n = nullptr;
void setCurrentI18n(I18n *i) { g_i18n = i; }
I18n *currentI18n() { return g_i18n; }

/// The current text direction (ltr when no i18n is installed) — i18n.zig
/// direction() reads the live locale every call so setLocale flips mirror
/// layout/text-align immediately.
Direction direction() { return g_i18n ? g_i18n->dir() : Direction::ltr; }

// ===========================================================================
// Navigator (src/ui/navigator.zig)
// ===========================================================================

QString changeKindName(ChangeKind k) {
    switch (k) {
        case ChangeKind::push: return "push";
        case ChangeKind::pop: return "pop";
        case ChangeKind::replace: return "replace";
        case ChangeKind::reset: return "reset";
    }
    return "push";
}

QString Params::get(const QString &key) const {
    for (quint32 i = 0; i < len; ++i)
        if (items[i].key == key) return items[i].value;
    return QString();
}

bool Params::add(const QString &key, const QString &value) {
    if (len >= MAX_PARAMS) return false;
    items[len++] = Param{key, value};
    return true;
}

/// splitScalar('/') keeps empty segments — "a//b" has arity 3 (navigator.zig).
static QStringList splitPath(const QString &s) {
    return s.split('/', Qt::KeepEmptyParts);
}

/// Build the concrete path from a pattern + params ("anime/{id}" + id=42).
/// `params` is the caller's (unbounded) list like navigator.zig — capacity
/// is checked later in buildPage, so MissingParam wins over TooManyParams.
/// Returns "" + sets *err = "MissingParam" when a placeholder has no value.
static QString buildPath(const QString &pattern, const std::vector<Param> &params, QString *err) {
    QString out;
    bool first = true;
    for (const QString &seg : splitPath(pattern)) {
        if (!first) out += '/';
        first = false;
        if (seg.size() >= 2 && seg.startsWith('{') && seg.endsWith('}')) {
            const QString key = seg.mid(1, seg.size() - 2);
            bool found = false;
            for (const auto &p : params) {
                if (p.key == key) {
                    out += p.value;
                    found = true;
                    break;
                }
            }
            if (!found) {
                if (err) *err = "MissingParam";
                return QString();
            }
        } else {
            out += seg;
        }
    }
    if (err) err->clear();
    return out;
}

bool matchPattern(const QString &pattern, const QString &path, Params *params) {
    params->len = 0; // resets first (navigator.zig)
    const QStringList pp = splitPath(pattern);
    const QStringList sp = splitPath(path);
    if (pp.size() != sp.size()) return false;
    for (int i = 0; i < pp.size(); ++i) {
        if (pp[i].size() >= 2 && pp[i].startsWith('{') && pp[i].endsWith('}')) {
            const QString key = pp[i].mid(1, pp[i].size() - 2);
            if (!params->add(key, sp[i])) return false;
        } else if (pp[i] != sp[i]) {
            return false;
        }
    }
    return true;
}

/// Parse "scheme://path?query" (the scheme is optional): strip the scheme,
/// split at '?', strip trailing slashes, null when there is no path.
std::optional<ParsedUri> parseUri(const QString &uri) {
    QString rest = uri;
    const int s = rest.indexOf(QStringLiteral("://"));
    if (s >= 0) rest = rest.mid(s + 3);
    QString path = rest, query;
    const int q = rest.indexOf('?');
    if (q >= 0) {
        path = rest.left(q);
        query = rest.mid(q + 1);
    }
    while (path.size() > 1 && path.endsWith('/')) path.chop(1);
    if (path.isEmpty()) return std::nullopt;
    return ParsedUri{path, query};
}

const Navigator::RouteDef *Navigator::findDef(const QString &pattern) const {
    for (const auto &d : routes_) if (d.pattern == pattern) return &d;
    return nullptr;
}

QString Navigator::define(const QString &pattern, std::function<KxNode *(const Route &)> builder,
                          Transition transition) {
    RouteDef d;
    d.pattern = pattern;
    d.builder = std::move(builder);
    d.transition = transition;
    routes_.push_back(std::move(d));
    return QString();
}

QString Navigator::buildPage(const RouteDef &def, const QString &path,
                             const std::vector<Param> &params, Page *out) {
    // buildPageFromSlice: capacity is checked inside the copy loop, before
    // the page is built (an over-cap list never produces a page).
    Params owned;
    for (const auto &p : params) {
        if (owned.len >= MAX_PARAMS) return "TooManyParams";
        owned.add(p.key, p.value);
    }
    Route r;
    r.pattern = def.pattern;
    r.path = path;
    r.params = owned;
    r.transition = def.transition;
    KxNode *node = def.builder ? def.builder(r) : nullptr;
    out->id = next_id_++;
    out->route = r;
    out->node = node;
    return QString();
}

QString Navigator::pushDef(const RouteDef &def, const QString &path,
                           const std::vector<Param> &params) {
    Page p;
    QString e = buildPage(def, path, params, &p);
    if (!e.isEmpty()) return e;
    pages_.push_back(p);
    notify(ChangeKind::push);
    return QString();
}

QString Navigator::push(const QString &pattern, const std::vector<Param> &params) {
    const RouteDef *def = findDef(pattern);
    if (!def) return "UnknownRoute";
    QString err;
    const QString path = buildPath(pattern, params, &err);
    if (!err.isEmpty()) return err;
    return pushDef(*def, path, params);
}

QString Navigator::pushPath(const QString &path, const std::vector<Param> &params) {
    for (const auto &def : routes_) {
        Params matched;
        if (matchPattern(def.pattern, path, &matched)) {
            // merge the explicit params after the path captures (the cap
            // check is inside the merge, like navigator.zig — an unmatched
            // path is UnknownRoute even with an over-cap param list)
            for (const auto &p : params)
                if (!matched.add(p.key, p.value)) return "TooManyParams";
            std::vector<Param> merged(matched.begin(), matched.end());
            return pushDef(def, path, merged);
        }
    }
    return "UnknownRoute";
}

QString Navigator::navigateTo(const QString &uri) {
    const auto pu = parseUri(uri);
    if (!pu) return "InvalidUri";
    Params params;
    const RouteDef *def = nullptr;
    for (const auto &d : routes_) {
        if (matchPattern(d.pattern, pu->path, &params)) { def = &d; break; }
    }
    if (!def) return "UnknownRoute";
    // query params ("tab=2&lang=fr")
    if (!pu->query.isEmpty()) {
        for (const QString &pair : pu->query.split('&')) {
            const int eq = pair.indexOf('=');
            if (eq < 0) return "InvalidUri";
            if (!params.add(pair.left(eq), pair.mid(eq + 1))) return "TooManyParams";
        }
    }
    // No-op when the top page is the same concrete path.
    if (const Page *top = current())
        if (top->route.path == pu->path) return QString();
    std::vector<Param> merged(params.begin(), params.end());
    return pushDef(*def, pu->path, merged);
}

QString Navigator::replace(const QString &pattern, const std::vector<Param> &params) {
    // On an empty stack this is a push (navigator.zig).
    if (pages_.empty()) return push(pattern, params);
    const RouteDef *def = findDef(pattern);
    if (!def) return "UnknownRoute";
    QString err;
    const QString path = buildPath(pattern, params, &err);
    if (!err.isEmpty()) return err;
    // Build the replacement FIRST — on error the old page stays live.
    Page p;
    QString e = buildPage(*def, path, params, &p);
    if (!e.isEmpty()) return e;
    pages_.back() = p;
    notify(ChangeKind::replace);
    return QString();
}

bool Navigator::pop() {
    if (!canPop()) return false;
    pages_.pop_back();
    notify(ChangeKind::pop);
    return true;
}

void Navigator::popToRoot() {
    if (pages_.size() <= 1) return;
    pages_.resize(1);
    notify(ChangeKind::reset);
}

void Navigator::deinit() {
    // Page nodes are tree-owned: the harness tracks/deinits them. The
    // navigator only clears its stack.
    pages_.clear();
    routes_.clear();
}

// ===========================================================================
// Semantics (src/ui/semantics.zig)
// ===========================================================================

QString roleName(Role r) {
    switch (r) {
        case Role::none: return "none";
        case Role::text: return "text";
        case Role::heading: return "heading";
        case Role::button: return "button";
        case Role::link: return "link";
        case Role::image: return "image";
        case Role::text_field: return "text_field";
        case Role::toggle: return "toggle";
        case Role::checkbox: return "checkbox";
        case Role::radio: return "radio";
        case Role::slider: return "slider";
        case Role::progress: return "progress";
        case Role::scrollbar: return "scrollbar";
        case Role::list: return "list";
        case Role::list_item: return "list_item";
        case Role::dialog: return "dialog";
        case Role::alert: return "alert";
        case Role::menu: return "menu";
        case Role::menu_item: return "menu_item";
        case Role::tab: return "tab";
        case Role::tab_panel: return "tab_panel";
        case Role::separator: return "separator";
        case Role::group: return "group";
    }
    return "none";
}

Role roleFromName(const QString &s, bool *ok) {
    static const QHash<QString, Role> m{
        {"none", Role::none}, {"text", Role::text}, {"heading", Role::heading},
        {"button", Role::button}, {"link", Role::link}, {"image", Role::image},
        {"text_field", Role::text_field}, {"toggle", Role::toggle},
        {"checkbox", Role::checkbox}, {"radio", Role::radio}, {"slider", Role::slider},
        {"progress", Role::progress}, {"scrollbar", Role::scrollbar},
        {"list", Role::list}, {"list_item", Role::list_item}, {"dialog", Role::dialog},
        {"alert", Role::alert}, {"menu", Role::menu}, {"menu_item", Role::menu_item},
        {"tab", Role::tab}, {"tab_panel", Role::tab_panel},
        {"separator", Role::separator}, {"group", Role::group},
    };
    auto it = m.find(s);
    if (ok) *ok = it != m.end();
    return it != m.end() ? *it : Role::none;
}

Action actionFromName(const QString &s, bool *ok) {
    static const QHash<QString, Action> m{
        {"activate", Action::activate}, {"increment", Action::increment},
        {"decrement", Action::decrement}, {"delete", Action::delete_},
    };
    auto it = m.find(s);
    if (ok) *ok = it != m.end();
    return it != m.end() ? *it : Action::activate;
}

void attach(KxNode *n, const Semantics &sem) {
    delete n->semantics;
    n->semantics = new Semantics(sem);
}

// --- bridge ---

QString bridgeKindName(BridgeEvent::Kind k) {
    switch (k) {
        case BridgeEvent::Kind::tree_dirty: return "tree_dirty";
        case BridgeEvent::Kind::focus_changed: return "focus_changed";
        case BridgeEvent::Kind::announce: return "announce";
        case BridgeEvent::Kind::control_changed: return "control_changed";
    }
    return "tree_dirty";
}

static BridgeFn g_bridge;
void setBridge(BridgeFn fn) { g_bridge = std::move(fn); }

// `emit` is a Qt keyword macro — name the helper emitBridge instead.
static void emitBridge(const BridgeEvent &ev) { if (g_bridge) g_bridge(ev); }

void notifyTreeDirty() {
    BridgeEvent ev; ev.kind = BridgeEvent::Kind::tree_dirty;
    emitBridge(ev);
}

void announce(const QString &text, LiveRegion region) {
    BridgeEvent ev; ev.kind = BridgeEvent::Kind::announce;
    ev.text = text; ev.region = region;
    emitBridge(ev);
}

void notifyControlChanged(KxNode *n) {
    BridgeEvent ev; ev.kind = BridgeEvent::Kind::control_changed;
    ev.node = n;
    emitBridge(ev);
}

BridgeFn LogBridge::bridge() {
    return [this](const BridgeEvent &ev) {
        LoggedEvent le;
        le.kind = ev.kind;
        le.node_id = 0;
        le.text = ev.text;
        le.region = ev.region;
        events.append(le);
    };
}

// --- semantic tree flattening ---

/// First descendant (depth-first) with a non-empty label — the fallback for
/// container-ish roles (a Button's label is its Text child).
static QString firstDescendantLabel(KxNode *n) {
    for (KxNode *c : n->children) {
        if (c->exclude_semantics || !c->visible) continue;
        if (c->semantics && !c->semantics->label.isEmpty()) return c->semantics->label;
        const QString l = firstDescendantLabel(c);
        if (!l.isEmpty()) return l;
    }
    return QString();
}

static void flattenInto(KxNode *n, std::vector<std::unique_ptr<SemanticNode>> *out) {
    if (n->exclude_semantics || !n->visible || n->zombie) return;
    // A subtree that cannot be hit-tested is not interactive — skip it.
    Rect hb;
    if (n->hitBounds(&hb) && (hb.w <= 0 || hb.h <= 0)) return;
    if (n->semantics) {
        auto sn = std::make_unique<SemanticNode>();
        sn->node = n;
        sn->role = n->semantics->role;
        // Label fallback: an empty own label borrows the first descendant's
        // (a Button announces its text child).
        sn->label = !n->semantics->label.isEmpty() ? n->semantics->label
                                                 : firstDescendantLabel(n);
        sn->hint = n->semantics->hint;
        sn->value = n->semantics->value;
        sn->checked = n->semantics->checked;
        sn->disabled = n->semantics->disabled;
        sn->focusable = n->semantics->focusable;
        sn->actions = n->semantics->actions;
        sn->live = n->semantics->live;
        SemanticNode *keep = sn.get();
        for (KxNode *c : n->children) flattenInto(c, &keep->children);
        out->push_back(std::move(sn));
        return;
    }
    // Transparent container: lift the children into the current list.
    for (KxNode *c : n->children) flattenInto(c, out);
}

std::unique_ptr<SemanticNode> buildSemanticTree(KxNode *root) {
    std::vector<std::unique_ptr<SemanticNode>> tops;
    flattenInto(root, &tops);
    if (tops.size() == 1) return std::move(tops[0]);
    // Wrap multiple top-level nodes in a synthetic group (semantics.zig).
    auto g = std::make_unique<SemanticNode>();
    g->node = root;
    g->role = Role::group;
    g->children = std::move(tops);
    return g;
}

// --- FocusManager ---

static FocusManager *g_focus = nullptr;
void setCurrentFocus(FocusManager *fm) { g_focus = fm; }
FocusManager *currentFocus() { return g_focus; }

void focusNodeDestroyed(KxNode *n) {
    if (g_focus && g_focus->focused == n) g_focus->focusNode(nullptr);
}

void routerFocusChanged(KxNode *n) {
    if (g_focus) g_focus->onRouterFocusChanged(n);
}

FocusManager::FocusManager() {
    focused_sig = new Signal<KxNode *>(nullptr);
}

FocusManager::~FocusManager() {
    delete focused_sig;
}

static void collectFocusable(SemanticNode *sn, QVector<KxNode *> *out) {
    if (sn->focusable && !sn->disabled && sn->node) out->append(sn->node);
    for (auto &c : sn->children) collectFocusable(c.get(), out);
}

QVector<KxNode *> FocusManager::focusOrder() const {
    QVector<KxNode *> out;
    if (!root) return out;
    auto tree = buildSemanticTree(root);
    collectFocusable(tree.get(), &out);
    return out;
}

/// The focus ring rect: bounds expanded by `margin`, mapped to root space
/// (semantics.zig ringRect — the ring's damage region).
static Rect ringRect(KxNode *n, float margin) {
    const Rect r = n->mapRectToRoot(n->bounds);
    return {r.x - margin, r.y - margin, r.w + 2 * margin, r.h + 2 * margin};
}

void FocusManager::setFocused(KxNode *node) {
    if (focused == node) return;
    // Damage the old + new ring regions so the repaint covers exactly what
    // the ring vacated/occupies; the nodes themselves are marked dirty too.
    if (root) {
        if (focused) {
            focused->markDirty();
            root->markDirtyRect(ringRect(focused, ring_offset));
        }
        if (node) root->markDirtyRect(ringRect(node, ring_offset));
    }
    focused = node;
    focused_sig->set(node);
    if (node) node->markDirty();
    BridgeEvent ev; ev.kind = BridgeEvent::Kind::focus_changed; ev.node = node;
    emitBridge(ev);
}

void FocusManager::focusNode(KxNode *n) {
    setFocused(n);
    requestFocus(n); // the router delivers keys to the focused node
}

void FocusManager::onRouterFocusChanged(KxNode *n) {
    setFocused(n);
}

void FocusManager::focusNext() {
    const auto order = focusOrder();
    if (order.isEmpty()) return;
    int idx = -1;
    for (int i = 0; i < order.size(); ++i)
        if (order[i] == focused) { idx = i; break; }
    const int next = idx < 0 ? 0 : (idx + 1) % order.size();
    focusNode(order[next]);
}

void FocusManager::focusPrev() {
    const auto order = focusOrder();
    if (order.isEmpty()) return;
    int idx = -1;
    for (int i = 0; i < order.size(); ++i)
        if (order[i] == focused) { idx = i; break; }
    const int prev = idx < 0 ? static_cast<int>(order.size()) - 1
                             : (idx - 1 + order.size()) % order.size();
    focusNode(order[prev]);
}

/// Activate a node = synthesize down+up at its center through the router
/// (each phase re-hit-tests — a .down handler that tears down its own
/// subtree can't make the .up dereference freed nodes). Headless fallback:
/// deliver straight to the nearest pointer-handling ancestor.
static void activateNode(KxNode *node, KxNode *root) {
    if (root && g_router) {
        const Rect r = node->mapRectToRoot(node->bounds);
        PointerEvent down;
        down.phase = PointerPhase::down;
        down.x = r.x + r.w / 2.0f; down.y = r.y + r.h / 2.0f;
        down.raw_x = down.x; down.raw_y = down.y;
        PointerEvent up = down;
        up.phase = PointerPhase::up;
        g_router->dispatchPointer(root, down);
        g_router->dispatchPointer(root, up);
        return;
    }
    for (KxNode *cur = node; cur; cur = cur->parent) {
        // First ancestor that consumes the synthesized down gets the up.
        PointerEvent down;
        down.phase = PointerPhase::down;
        down.x = cur->bounds.x + cur->bounds.w / 2.0f;
        down.y = cur->bounds.y + cur->bounds.h / 2.0f;
        down.raw_x = down.x; down.raw_y = down.y;
        PointerEvent up = down;
        up.phase = PointerPhase::up;
        if (cur->onPointer(down)) {
            cur->onPointer(up);
            return;
        }
    }
}

bool FocusManager::handleKey(const KeyEvent &ev) {
    if (ev.kind != KeyEvent::Kind::key_down) return false;
    switch (ev.key) {
        case Key::tab:
            if (ev.shift) focusPrev(); else focusNext();
            return true;
        case Key::enter:
        case Key::space: {
            // Only nodes advertising the activate action are activated: a
            // slider has increment/decrement — a center click would reset
            // its value to 50%.
            if (!focused || !focused->semantics) return false;
            if (!(focused->semantics->actions & actionBit(Action::activate)))
                return false;
            activateNode(focused, root);
            return true;
        }
        default:
            return false;
    }
}

// ===========================================================================
// KxSurface — the QWidget host
// ===========================================================================

QImage KxSurface::renderFrame(int w_, int h_, Color bg) {
    QImage img(w_, h_, QImage::Format_RGBA8888);
    img.fill(toQColor(bg));
    {
        QPainter p(&img);
        p.setRenderHint(QPainter::Antialiasing, true);
        p.setRenderHint(QPainter::TextAntialiasing, true);
        if (root_) {
            const Rect surface{0, 0, (float)w_, (float)h_};
            root_->paint(p, surface);
        }
    }
    return img;
}

void KxSurface::paintTree(QPainter &p, const Rect &visible_r) {
    if (root_) root_->paint(p, visible_r);
}

void KxSurface::paintEvent(QPaintEvent *ev) {
    QPainter p(this);
    p.setRenderHint(QPainter::Antialiasing, true);
    const QRectF r = ev->rect();
    paintTree(p, {(float)r.x(), (float)r.y(), (float)r.width(), (float)r.height()});
}

} // namespace kx
