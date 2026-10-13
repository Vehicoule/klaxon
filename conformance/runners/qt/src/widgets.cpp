// widgets.cpp — Qt6 port of the DSL widget layer exercised by the
// conformance suite (src/widgets/{layout,container,text,input,gestures,
// scroll_view,list_view,i18n}.zig + scroll_util.zig).
//
// Zig's vtable + state-pointer pairs become KxNode subclasses: the widget
// state lives inline (no allocator), vtable.deinit → teardown(). The
// algorithms are line-for-line ports — the vectors measure Klaxon
// semantics, not Qt widget defaults (no QWidget controls are used).

#include "kx.h"

namespace kx {

// ===========================================================================
// Layout widgets (src/widgets/layout.zig)
// ===========================================================================

namespace {

// --- Flex (Row / Column) ---

class FlexNode final : public KxNode {
public:
    Axis axis; FlexOptions opts;
    FlexNode(Axis a, const FlexOptions &o) : axis(a), opts(o) {}
    Size onMeasure(const Constraints &c) override {
        return flexMeasure(this, c, axis, opts.gap, opts.padding);
    }
    void onLayout(const Rect &b) override {
        flexLayout(this, b, axis, opts.gap, opts.padding, opts.main_align, opts.cross_align);
    }
};

// --- Stack ---

class StackNode final : public KxNode {
public:
    StackOptions opts;
    explicit StackNode(const StackOptions &o) : opts(o) {}
    Size onMeasure(const Constraints &c) override {
        // expand: take the biggest allowed size; loose: shrink-wrap the
        // largest child. An unbounded parent shrink-wraps.
        const bool expand = opts.fit == StackFit::expand;
        const Constraints child_c = expand ? c : c.loosen();
        Size size;
        for (KxNode *child : children) {
            const Size cs = child->measure(child_c);
            size.w = std::max(size.w, cs.w);
            size.h = std::max(size.h, cs.h);
        }
        if (expand) {
            if (std::isfinite(c.max_w)) size.w = c.max_w;
            if (std::isfinite(c.max_h)) size.h = c.max_h;
        }
        return c.constrain(size);
    }
    void onLayout(const Rect &b) override {
        const Constraints child_c = opts.fit == StackFit::expand
            ? Constraints{b.w, b.w, b.h, b.h}
            : Constraints{0, b.w, 0, b.h};
        for (KxNode *child : children) {
            const Size cs = child->measure(child_c);
            // RTL mirrors the horizontal alignment.
            child->layout(opts.alignment.mirrored(direction()).position(b, cs));
        }
    }
};

// --- Grid (equal tracks; children fill their cell) ---

class GridNode final : public KxNode {
public:
    GridOptions opts;
    explicit GridNode(const GridOptions &o) : opts(o) {}
    Size onMeasure(const Constraints &c) override {
        const size_t cols = std::max<size_t>(1, opts.columns);
        const size_t count = children.size();
        if (count == 0) return c.constrain({});
        const size_t rows = (count + cols - 1) / cols;
        const float pad2 = opts.padding * 2;
        const float gaps_w = opts.gap * static_cast<float>(cols - 1);
        const float track_w = std::isfinite(c.max_w)
            ? std::max(0.0f, (c.max_w - pad2 - gaps_w) / static_cast<float>(cols))
            : 0.0f; // unbounded: resolved from the widest child below

        std::vector<Size> sizes(count);
        float max_child_w = 0;
        for (size_t i = 0; i < count; ++i) {
            const Constraints child_c = std::isfinite(c.max_w)
                ? Constraints{track_w, track_w, 0, std::numeric_limits<float>::infinity()}
                : Constraints{};
            sizes[i] = children[i]->measure(child_c);
            max_child_w = std::max(max_child_w, sizes[i].w);
        }
        const float tw = std::isfinite(c.max_w) ? track_w : max_child_w;

        std::vector<float> row_h(rows, 0);
        for (size_t i = 0; i < count; ++i)
            row_h[i / cols] = std::max(row_h[i / cols], sizes[i].h);

        float total_h = pad2;
        for (size_t ri = 0; ri < rows; ++ri) {
            total_h += row_h[ri];
            if (ri + 1 < rows) total_h += opts.gap;
        }
        const float w = tw * static_cast<float>(cols) + gaps_w + pad2;
        return c.constrain({w, total_h});
    }
    void onLayout(const Rect &b) override {
        const size_t cols = std::max<size_t>(1, opts.columns);
        const size_t count = children.size();
        if (count == 0) return;
        const size_t rows = (count + cols - 1) / cols;
        const float pad2 = opts.padding * 2;
        const float gaps_w = opts.gap * static_cast<float>(cols - 1);
        const float track_w = std::max(0.0f, (b.w - pad2 - gaps_w) / static_cast<float>(cols));

        std::vector<Size> sizes(count);
        for (size_t i = 0; i < count; ++i)
            sizes[i] = children[i]->measure({track_w, track_w, 0, std::numeric_limits<float>::infinity()});

        std::vector<float> row_h(rows, 0);
        for (size_t i = 0; i < count; ++i)
            row_h[i / cols] = std::max(row_h[i / cols], sizes[i].h);

        // Children fill their cell (tight track width x row height).
        float y = opts.padding;
        size_t cur_row = 0;
        for (size_t i = 0; i < count; ++i) {
            const size_t row_idx = i / cols;
            const size_t col_idx = i % cols;
            if (row_idx != cur_row) {
                y += row_h[cur_row] + opts.gap;
                cur_row = row_idx;
            }
            const float x = opts.padding + static_cast<float>(col_idx) * (track_w + opts.gap);
            children[i]->layout({b.x + x, b.y + y, track_w, row_h[row_idx]});
        }
    }
};

// --- Padding (fill container) ---

class PaddingNode final : public KxNode {
public:
    EdgeInsets insets;
    explicit PaddingNode(const EdgeInsets &i) : insets(i) {}
    Size onMeasure(const Constraints &c) override {
        const Constraints inner = c.deflateEdge(insets);
        Size size;
        if (!children.empty()) {
            const Size cs = children[0]->measure(inner);
            size = {cs.w + insets.hSum(), cs.h + insets.vSum()};
        }
        return c.constrain(size);
    }
    void onLayout(const Rect &b) override {
        if (children.empty()) return;
        // Fill semantics: the child's bounds are the inner rect.
        children[0]->layout({
            b.x + insets.left, b.y + insets.top,
            std::max(0.0f, b.w - insets.hSum()),
            std::max(0.0f, b.h - insets.vSum()),
        });
    }
};

// --- PaddingDirectional (start/end resolve against the text direction) ---

class PaddingDirNode final : public KxNode {
public:
    EdgeInsetsDirectional insets;
    explicit PaddingDirNode(const EdgeInsetsDirectional &i) : insets(i) {}
    Size onMeasure(const Constraints &c) override {
        const EdgeInsets r = insets.resolve(direction());
        const Constraints inner = c.deflateEdge(r);
        Size size;
        if (!children.empty()) {
            const Size cs = children[0]->measure(inner);
            size = {cs.w + r.hSum(), cs.h + r.vSum()};
        }
        return c.constrain(size);
    }
    void onLayout(const Rect &b) override {
        if (children.empty()) return;
        const EdgeInsets r = insets.resolve(direction());
        children[0]->layout({
            b.x + r.left, b.y + r.top,
            std::max(0.0f, b.w - r.hSum()),
            std::max(0.0f, b.h - r.vSum()),
        });
    }
};

// --- Align / Center (positioning container) ---

class AlignNode final : public KxNode {
public:
    Alignment alignment;
    explicit AlignNode(const Alignment &a) : alignment(a) {}
    Size onMeasure(const Constraints &c) override {
        Size size;
        if (!children.empty()) {
            const Size cs = children[0]->measure(c.loosen());
            size = {std::isfinite(c.max_w) ? c.max_w : cs.w,
                    std::isfinite(c.max_h) ? c.max_h : cs.h};
        }
        return c.constrain(size);
    }
    void onLayout(const Rect &b) override {
        if (children.empty()) return;
        KxNode *child = children[0];
        const Size cs = child->measure({0, b.w, 0, b.h});
        // RTL mirrors the horizontal alignment.
        child->layout(alignment.mirrored(direction()).position(b, cs));
    }
};

// --- ConstrainedBox (fill container with additional constraints) ---

class ConstrainedBoxNode final : public KxNode {
public:
    ConstrainedBoxOptions opts;
    explicit ConstrainedBoxNode(const ConstrainedBoxOptions &o) : opts(o) {}
    Size onMeasure(const Constraints &c) override {
        const Constraints add{opts.min_w, opts.max_w, opts.min_h, opts.max_h};
        const Constraints child_c = c.enforcedBy(add);
        Size size;
        if (!children.empty()) {
            size = children[0]->measure(child_c);
        } else {
            // Empty box: still honors its own minimums (fixed-size spacer).
            size = {child_c.min_w, child_c.min_h};
        }
        return c.constrain(size);
    }
    void onLayout(const Rect &b) override {
        if (children.empty()) return;
        children[0]->layout(b); // fill semantics
    }
};

// --- Expanded (flex weight on the main axis) ---

class ExpandedNode final : public KxNode {
public:
    Size onMeasure(const Constraints &c) override {
        Size size;
        if (!children.empty()) size = children[0]->measure(c);
        return c.constrain(size);
    }
    void onLayout(const Rect &b) override {
        if (children.empty()) return;
        children[0]->layout(b); // fill semantics
    }
};

} // namespace

KxNode *makeFlex(Axis axis, const FlexOptions &opts) { return new FlexNode(axis, opts); }
KxNode *makeStack(const StackOptions &opts) { return new StackNode(opts); }
KxNode *makeGrid(const GridOptions &opts) { return new GridNode(opts); }
KxNode *makePadding(const EdgeInsets &insets) { return new PaddingNode(insets); }
KxNode *makePaddingDir(const EdgeInsetsDirectional &insets) { return new PaddingDirNode(insets); }
KxNode *makeAlign(const Alignment &a) { return new AlignNode(a); }
KxNode *makeCenter() { return new AlignNode(Alignment::center()); }
KxNode *makeConstrainedBox(const ConstrainedBoxOptions &opts) { return new ConstrainedBoxNode(opts); }
KxNode *makeExpanded(quint32 weight) {
    auto *n = new ExpandedNode;
    n->flex = std::max(1u, weight);
    return n;
}

// ===========================================================================
// Container (src/widgets/container.zig)
// ===========================================================================

namespace {

class ContainerNode final : public KxNode {
public:
    ContainerOptions opts;
    explicit ContainerNode(const ContainerOptions &o) : opts(o) {}
    Size onMeasure(const Constraints &c) override {
        const Constraints inner = c.deflateEdge(opts.padding);
        Size size;
        if (!children.empty()) {
            const Size cs = children[0]->measure(inner);
            size = {cs.w + opts.padding.hSum(), cs.h + opts.padding.vSum()};
        }
        return c.constrain(size);
    }
    void onLayout(const Rect &b) override {
        if (children.empty()) return;
        children[0]->layout({
            b.x + opts.padding.left, b.y + opts.padding.top,
            std::max(0.0f, b.w - opts.padding.hSum()),
            std::max(0.0f, b.h - opts.padding.vSum()),
        });
    }
    void onPaint(QPainter &ctx) override {
        const Rect &b = bounds;
        const float bw = opts.border_width;
        if (opts.border_color) {
            const Color border = *opts.border_color;
            // Border = outer shape in the border color; the fill covers inside.
            if (opts.radius > 0) fillRRect(ctx, b.x, b.y, b.w, b.h, opts.radius, border);
            else fillRect(ctx, b.x, b.y, b.w, b.h, border);
            if (opts.color) {
                const Rect inner{b.x + bw, b.y + bw,
                                 std::max(0.0f, b.w - bw * 2), std::max(0.0f, b.h - bw * 2)};
                if (opts.radius > 0) fillRRect(ctx, inner.x, inner.y, inner.w, inner.h,
                                               std::max(0.0f, opts.radius - bw), *opts.color);
                else fillRect(ctx, inner.x, inner.y, inner.w, inner.h, *opts.color);
            }
        } else if (opts.color) {
            if (opts.radius > 0) fillRRect(ctx, b.x, b.y, b.w, b.h, opts.radius, *opts.color);
            else fillRect(ctx, b.x, b.y, b.w, b.h, *opts.color);
        }
    }
};

} // namespace

KxNode *makeContainer(const ContainerOptions &opts) { return new ContainerNode(opts); }

// ===========================================================================
// Text (src/widgets/text.zig — the plain immutable text leaf)
// ===========================================================================

namespace {

class TextNode : public KxNode {
public:
    QString str;
    TextOptions opts;
    TextMetrics m;

    TextNode(const QString &s, const TextOptions &o) : str(s), opts(o) {
        m = measureText(str, opts.size, opts.bold);
    }
    Size onMeasure(const Constraints &c) override {
        return c.constrain({m.width, m.height});
    }
    void onLayout(const Rect &) override {}

    /// The text's x for an alignment (start/end resolve against the current
    /// text direction).
    float textX() const {
        const TextAlign r = resolveAlign(opts.text_align, direction());
        switch (r) {
            case TextAlign::left: return bounds.x;
            case TextAlign::center: return bounds.x + (bounds.w - m.width) / 2;
            case TextAlign::right: return bounds.x + bounds.w - m.width;
            default: return bounds.x; // start/end resolved above
        }
    }
    void onPaint(QPainter &ctx) override {
        // Baseline: one ascent below the top.
        drawText(ctx, str, textX(), bounds.y + m.ascent, opts.size, opts.bold, opts.color);
    }
    /// The glyphs' actual rect: the alignment may place them outside the
    /// bounds. Culling and damage consult it.
    bool paintBounds(Rect *out) const override {
        // textX() needs bounds — const_cast is safe (no mutation).
        const TextAlign r = resolveAlign(opts.text_align, direction());
        float x = bounds.x;
        if (r == TextAlign::center) x = bounds.x + (bounds.w - m.width) / 2;
        else if (r == TextAlign::right) x = bounds.x + bounds.w - m.width;
        *out = {x, bounds.y, m.width, m.height};
        return true;
    }
};

} // namespace

KxNode *makeText(const QString &str, const TextOptions &opts) {
    auto *n = new TextNode(str, opts);
    Semantics sem;
    sem.role = Role::text;
    sem.label = str;
    attach(n, sem);
    return n;
}

// ===========================================================================
// Input widgets (src/widgets/input.zig)
// ===========================================================================

namespace {

// --- Button ---

class ButtonNode final : public KxNode {
public:
    ButtonOptions opts;
    std::function<void()> on_pressed;
    bool pressed = false, hovered = false;

    ButtonNode(std::function<void()> cb, const ButtonOptions &o)
        : opts(o), on_pressed(std::move(cb)) {}
    Size onMeasure(const Constraints &c) override {
        Size size{opts.padding.hSum(), opts.padding.vSum()};
        if (!children.empty()) {
            const Size cs = children[0]->measure(c.deflateEdge(opts.padding));
            size = {cs.w + opts.padding.hSum(), cs.h + opts.padding.vSum()};
        }
        return c.constrain(size);
    }
    void onLayout(const Rect &b) override {
        if (children.empty()) return;
        children[0]->layout({
            b.x + opts.padding.left, b.y + opts.padding.top,
            std::max(0.0f, b.w - opts.padding.hSum()),
            std::max(0.0f, b.h - opts.padding.vSum()),
        });
    }
    void onPaint(QPainter &ctx) override {
        const Color bg = pressed ? opts.bg_pressed : hovered ? opts.bg_hover : opts.bg;
        fillRRect(ctx, bounds.x, bounds.y, bounds.w, bounds.h, opts.radius, bg);
    }
    bool onPointer(const PointerEvent &ev) override {
        switch (ev.phase) {
            case PointerPhase::down:
                pressed = true;
                markDirty();
                return true;
            case PointerPhase::up:
                pressed = false;
                markDirty();
                // Click = down + up on the same node (the router captured us).
                if (bounds.contains(ev.x, ev.y) && on_pressed) on_pressed();
                return true;
            case PointerPhase::enter:
                hovered = true;
                markDirty();
                return true;
            case PointerPhase::leave:
                hovered = false;
                markDirty();
                return true;
            default:
                return false;
        }
    }
};

// --- Toggle (switch) ---

class ToggleNode final : public KxNode {
public:
    Signal<bool> *sig;
    ToggleOptions opts;
    std::function<void()> on_changed;

    ToggleNode(Signal<bool> *s, std::function<void()> cb, const ToggleOptions &o)
        : sig(s), opts(o), on_changed(std::move(cb)) {}
    Size onMeasure(const Constraints &c) override {
        return c.constrain({opts.width, opts.height});
    }
    void onPaint(QPainter &ctx) override {
        const bool on = sig->get();
        const Rect &b = bounds;
        fillRRect(ctx, b.x, b.y, b.w, b.h, b.h / 2, on ? opts.track_on : opts.track_off);
        const Color knob_color = on ? opts.knob_on.value_or(opts.knob)
                                    : opts.knob_off.value_or(opts.knob);
        const float knob_size = b.h - 4;
        const float knob_x = on ? b.x + b.w - knob_size - 2 : b.x + 2;
        fillRRect(ctx, knob_x, b.y + 2, knob_size, knob_size, knob_size / 2, knob_color);
    }
    bool onPointer(const PointerEvent &ev) override {
        switch (ev.phase) {
            case PointerPhase::down: return true;
            case PointerPhase::up:
                if (bounds.contains(ev.x, ev.y)) {
                    sig->set(!sig->get());
                    if (on_changed) on_changed();
                }
                return true;
            default: return false;
        }
    }
    /// Repaint + keep the semantic checked state in sync.
    void syncCb() {
        if (semantics) semantics->checked = sig->peek();
        markDirty();
        notifyControlChanged(this); // a11y: the value changed
    }
    void teardown() override {
        sig->unsubscribe(Subscriber::forCallback({}, this));
    }
};

// --- Checkbox ---

class CheckboxNode final : public KxNode {
public:
    Signal<bool> *sig;
    CheckboxOptions opts;
    std::function<void()> on_changed;

    CheckboxNode(Signal<bool> *s, std::function<void()> cb, const CheckboxOptions &o)
        : sig(s), opts(o), on_changed(std::move(cb)) {}
    Size onMeasure(const Constraints &c) override {
        return c.constrain({opts.size, opts.size});
    }
    void onPaint(QPainter &ctx) override {
        const Rect &b = bounds;
        if (sig->get()) {
            fillRRect(ctx, b.x, b.y, b.w, b.h, opts.radius, opts.accent);
            const QString glyph = QString::fromUtf8("\xE2\x9C\x93"); // ✓
            const TextMetrics gm = measureText(glyph, b.h * 0.7f, false);
            drawText(ctx, glyph, b.x + (b.w - gm.width) / 2,
                     b.y + (b.h - gm.height) / 2 + gm.ascent, b.h * 0.7f, false, opts.check);
        } else {
            fillRRect(ctx, b.x, b.y, b.w, b.h, opts.radius, opts.border);
            fillRRect(ctx, b.x + 2, b.y + 2, b.w - 4, b.h - 4,
                      std::max(0.0f, opts.radius - 2), opts.box_color);
        }
    }
    bool onPointer(const PointerEvent &ev) override {
        switch (ev.phase) {
            case PointerPhase::down: return true;
            case PointerPhase::up:
                if (bounds.contains(ev.x, ev.y)) {
                    sig->set(!sig->get());
                    if (on_changed) on_changed();
                }
                return true;
            default: return false;
        }
    }
    void syncCb() {
        if (semantics) semantics->checked = sig->peek();
        markDirty();
        notifyControlChanged(this);
    }
    void teardown() override {
        sig->unsubscribe(Subscriber::forCallback({}, this));
    }
};

// --- Slider ---

class SliderNode final : public KxNode {
public:
    Signal<float> *sig;
    SliderOptions opts;
    std::function<void()> on_changed;

    SliderNode(Signal<float> *s, std::function<void()> cb, const SliderOptions &o)
        : sig(s), opts(o), on_changed(std::move(cb)) {}
    Size onMeasure(const Constraints &c) override {
        const float w = std::isfinite(c.max_w) ? c.max_w : opts.default_width;
        return c.constrain({w, opts.height});
    }
    void onPaint(QPainter &ctx) override {
        const float v = std::clamp(sig->get(), 0.0f, 1.0f);
        const Rect &b = bounds;
        const float track_h = 4;
        const float ty = b.y + (b.h - track_h) / 2;
        fillRRect(ctx, b.x, ty, b.w, track_h, track_h / 2, opts.track);
        fillRRect(ctx, b.x, ty, b.w * v, track_h, track_h / 2, opts.fill);
        const float ks = opts.knob_size;
        fillRRect(ctx, b.x + b.w * v - ks / 2, b.y + (b.h - ks) / 2, ks, ks, ks / 2, opts.knob);
    }
    bool onPointer(const PointerEvent &ev) override {
        switch (ev.phase) {
            // down/move: the router only delivers move while captured (drag).
            case PointerPhase::down:
            case PointerPhase::move: {
                const Rect &b = bounds;
                if (b.w > 0) {
                    const float v = std::clamp((ev.x - b.x) / b.w, 0.0f, 1.0f);
                    sig->set(v);
                    if (on_changed) on_changed();
                }
                return true;
            }
            case PointerPhase::up: return true;
            default: return false;
        }
    }
    bool onKey(const KeyEvent &ev) override {
        if (ev.kind != KeyEvent::Kind::key_down) return false;
        const float step = 0.05f;
        switch (ev.key) {
            case Key::left:
            case Key::down:
                sig->set(std::clamp(sig->peek() - step, 0.0f, 1.0f));
                if (on_changed) on_changed();
                return true;
            case Key::right:
            case Key::up:
                sig->set(std::clamp(sig->peek() + step, 0.0f, 1.0f));
                if (on_changed) on_changed();
                return true;
            default: return false;
        }
    }
    /// Repaint + keep the semantic value in sync ("{d:.0}%" of the clamped
    /// value — an out-of-range signal stays formattable).
    void syncCb() {
        if (semantics) {
            const float v = std::clamp(sig->peek(), 0.0f, 1.0f);
            semantics->value = QString::number(qRound(v * 100.0f)) + QStringLiteral("%");
        }
        markDirty();
        notifyControlChanged(this);
    }
    void teardown() override {
        sig->unsubscribe(Subscriber::forCallback({}, this));
    }
};

// --- TextField ---

class TextFieldNode final : public KxNode {
public:
    QByteArray buf; // the text (UTF-8 bytes, like Zig's u8 buffer)
    QByteArray placeholder;
    TextFieldOptions opts;
    std::function<void()> on_changed, on_submitted;

    TextFieldNode(const TextFieldOptions &o, std::function<void()> changed,
                  std::function<void()> submitted)
        : placeholder(o.placeholder.toUtf8()), opts(o),
          on_changed(std::move(changed)), on_submitted(std::move(submitted)) {
        buf = opts.initial.toUtf8();
    }
    QString text() const { return QString::fromUtf8(buf); }

    Size onMeasure(const Constraints &c) override {
        const QString str = !buf.isEmpty() ? text() : QString::fromUtf8(placeholder);
        const TextMetrics m = measureText(str, opts.size, false);
        return c.constrain({m.width + opts.padding.hSum() + 2,
                            m.height + opts.padding.vSum()});
    }
    void onPaint(QPainter &ctx) override {
        const Rect &b = bounds;
        fillRRect(ctx, b.x, b.y, b.w, b.h, opts.radius, opts.bg);
        const bool empty = buf.isEmpty();
        const QString str = empty ? QString::fromUtf8(placeholder) : text();
        const TextMetrics m = measureText(str, opts.size, false);
        const float text_x = b.x + opts.padding.left;
        const float text_y = b.y + (b.h - m.height) / 2 + m.ascent;
        if (!str.isEmpty())
            drawText(ctx, str, text_x, text_y, opts.size, false,
                     empty ? opts.hint : opts.color);
        if (isFocused(this)) {
            // Cursor bar at the end of the text (P0: cursor always at the end).
            const float cursor_x = text_x + (empty ? 0.0f : m.width + 1);
            fillRect(ctx, cursor_x, b.y + opts.padding.top, 2, m.height, opts.color);
        }
    }
    bool onPointer(const PointerEvent &ev) override {
        switch (ev.phase) {
            case PointerPhase::down:
                requestFocus(this);
                markDirty();
                return true;
            case PointerPhase::up: return true;
            default: return false;
        }
    }
    bool onKey(const KeyEvent &ev) override {
        if (ev.kind == KeyEvent::Kind::text_input) {
            const QByteArray in = ev.text.toUtf8();
            // Reject (never truncate) input that would grow the text past
            // the documented cap — a paste/IME burst is applied whole or
            // not at all.
            if (static_cast<size_t>(buf.size()) + static_cast<size_t>(in.size()) >
                TextSignal::max_len) return true;
            buf += in;
            markDirty();
            if (semantics) semantics->value = text(); // a11y: the value follows edits
            if (on_changed) on_changed();
            return true;
        }
        if (ev.kind == KeyEvent::Kind::key_down) {
            switch (ev.key) {
                case Key::backspace: {
                    // Delete the last UTF-8 codepoint (continuation bytes first).
                    while (!buf.isEmpty()) {
                        const char last = buf.back();
                        buf.chop(1);
                        if ((static_cast<unsigned char>(last) & 0xC0) != 0x80) break;
                    }
                    markDirty();
                    if (semantics) semantics->value = text();
                    if (on_changed) on_changed();
                    return true;
                }
                case Key::enter:
                    if (on_submitted) on_submitted();
                    return true;
                case Key::escape:
                    requestFocus(nullptr);
                    markDirty();
                    return true;
                default: return false;
            }
        }
        return false;
    }
};

} // namespace

KxNode *makeButton(std::function<void()> on_pressed, const ButtonOptions &opts) {
    auto *n = new ButtonNode(std::move(on_pressed), opts);
    Semantics sem;
    sem.role = Role::button;
    sem.focusable = true;
    sem.actions = actionBit(Action::activate);
    attach(n, sem);
    return n;
}

KxNode *makeToggle(Signal<bool> *sig, std::function<void()> on_changed, const ToggleOptions &opts) {
    auto *n = new ToggleNode(sig, std::move(on_changed), opts);
    Semantics sem;
    sem.role = Role::toggle;
    sem.focusable = true;
    sem.checked = sig->peek();
    sem.actions = actionBit(Action::activate);
    attach(n, sem);
    sig->subscribe(Subscriber::forCallback([n] { static_cast<ToggleNode *>(n)->syncCb(); }, n));
    return n;
}

KxNode *makeCheckbox(Signal<bool> *sig, std::function<void()> on_changed, const CheckboxOptions &opts) {
    auto *n = new CheckboxNode(sig, std::move(on_changed), opts);
    Semantics sem;
    sem.role = Role::checkbox;
    sem.focusable = true;
    sem.checked = sig->peek();
    sem.actions = actionBit(Action::activate);
    attach(n, sem);
    sig->subscribe(Subscriber::forCallback([n] { static_cast<CheckboxNode *>(n)->syncCb(); }, n));
    return n;
}

KxNode *makeSlider(Signal<float> *sig, std::function<void()> on_changed, const SliderOptions &opts) {
    auto *n = new SliderNode(sig, std::move(on_changed), opts);
    Semantics sem;
    sem.role = Role::slider;
    sem.focusable = true;
    sem.actions = actionBit(Action::increment) | actionBit(Action::decrement);
    attach(n, sem);
    sig->subscribe(Subscriber::forCallback([n] { static_cast<SliderNode *>(n)->syncCb(); }, n));
    n->syncCb(); // initial semantic value
    return n;
}

KxNode *makeTextField(const TextFieldOptions &opts, std::function<void()> on_changed,
                      std::function<void()> on_submitted) {
    auto *n = new TextFieldNode(opts, std::move(on_changed), std::move(on_submitted));
    Semantics sem;
    sem.role = Role::text_field;
    sem.focusable = true;
    sem.hint = QString::fromUtf8(n->placeholder);
    sem.value = n->text(); // a pre-filled field must announce its content
    attach(n, sem);
    return n;
}

QString textFieldText(KxNode *n) {
    return static_cast<TextFieldNode *>(n)->text();
}

// ===========================================================================
// GestureDetector (src/widgets/gestures.zig)
// ===========================================================================

namespace {

class GestureDetectorNode final : public KxNode {
public:
    GestureArena arena;
    quint64 ticker = 0; // timeline ticker id (long-press precision)

    explicit GestureDetectorNode(const GestureCallbacks &cbs) : arena(cbs) {}
    Size onMeasure(const Constraints &c) override {
        Size size;
        if (!children.empty()) size = children[0]->measure(c);
        return c.constrain(size);
    }
    void onLayout(const Rect &b) override {
        if (children.empty()) return;
        children[0]->layout(b); // fill semantics
    }
    bool onPointer(const PointerEvent &ev) override {
        // Gestures are physical-finger semantics: feed the arena window-space
        // coordinates — a scrollable scrolling under a held finger must not
        // corrupt pan deltas, velocity or pinch distances.
        PointerEvent win = ev;
        win.x = ev.raw_x;
        win.y = ev.raw_y;
        arena.feed(win);
        return true; // a gesture detector claims pointer events on its area
    }
    void teardown() override {
        if (ticker && currentTimeline()) currentTimeline()->removeTicker(ticker);
    }
};

} // namespace

KxNode *makeGestureDetector(const GestureCallbacks &cbs) {
    auto *n = new GestureDetectorNode(cbs);
    // Register the arena as a timeline ticker: long-press fires precisely at
    // the threshold (the host ticks the timeline every loop iteration), and
    // has_pending lets the host bound its idle wait while a pointer is held.
    if (Timeline *tl = currentTimeline()) {
        GestureArena *a = &n->arena;
        n->ticker = tl->addTicker([a](quint64 now) { a->tick(now); },
                                  [a] { return a->hasPendingTimeWork(); });
    }
    return n;
}

// ===========================================================================
// ScrollView (src/widgets/scroll_view.zig)
// ===========================================================================

namespace {

bool svSetOffset(KxNode *n, float value);

class ScrollViewNode final : public KxNode {
public:
    ScrollViewOptions opts;
    ScrollState scroll;
    ScrollInput input;
    float content_h = 0;

    explicit ScrollViewNode(const ScrollViewOptions &o) : opts(o) {}

    Size onMeasure(const Constraints &c) override {
        // The child takes its natural height (unbounded vertically); the
        // ScrollView fills the viewport.
        if (!children.empty()) {
            const Constraints child_c{0, c.max_w, 0, std::numeric_limits<float>::infinity()};
            const Size cs = children[0]->measure(child_c);
            content_h = cs.h;
            scroll.content = cs.h;
        }
        return c.constrain({c.max_w, c.max_h});
    }
    void onLayout(const Rect &b) override {
        scroll.viewport = b.h;
        if (!children.empty()) {
            const Constraints child_c{0, b.w, 0, std::numeric_limits<float>::infinity()};
            const Size cs = children[0]->measure(child_c);
            content_h = cs.h;
            scroll.content = cs.h;
            scroll.setOffset(scroll.offset); // re-clamp after a resize
            children[0]->layout({b.x, b.y, b.w, std::max(cs.h, b.h)});
        }
    }
    void preChildrenPaint(QPainter &ctx) override {
        const Rect &b = bounds;
        clipRect(ctx, b.x, b.y, b.w, b.h);
        ctx.translate(0, -scroll.offset);
    }
    void postChildrenPaint(QPainter &ctx) override {
        clipReset(ctx);
    }
    bool mapPaintRect(Rect *r) const override {
        r->y -= scroll.offset;
        return true;
    }
    bool childClip(Rect *out) const override {
        *out = bounds; // the viewport clip pushed in preChildrenPaint
        return true;
    }
    bool preChildrenHit(float px, float py, float *ox, float *oy) const override {
        *ox = px;
        *oy = py + scroll.offset;
        return true;
    }
    bool onPointer(const PointerEvent &ev) override {
        return input.onPointer(ev, scroll, svSetOffset, this);
    }
    bool onScroll(const ScrollEvent &ev) override {
        return input.onScroll(ev, scroll, opts.wheel_speed, svSetOffset, this);
    }
    bool scrollInfo(ScrollInfo *out) const override {
        *out = scroll.info();
        return true;
    }
    void scrollSetOffset(float value) override {
        svSetOffset(this, value);
    }
};

bool svSetOffset(KxNode *n, float value) {
    auto *sv = static_cast<ScrollViewNode *>(n);
    if (!sv->scroll.setOffset(value)) return false;
    n->markDirty();
    return true;
}

} // namespace

KxNode *makeScrollView(const ScrollViewOptions &opts) { return new ScrollViewNode(opts); }

float scrollViewOffset(KxNode *n) {
    return static_cast<ScrollViewNode *>(n)->scroll.offset;
}

bool scrollViewSetOffset(KxNode *n, float value) {
    return svSetOffset(n, value);
}

// ===========================================================================
// ListView (src/widgets/list_view.zig)
// ===========================================================================

namespace {

bool lvSetOffset(KxNode *n, float value);

class ListViewNode final : public KxNode {
public:
    ListViewOptions opts;
    ScrollState scroll;
    ScrollInput input;
    size_t first = 0; // item index of children[0]

    explicit ListViewNode(const ListViewOptions &o) : opts(o) {}

    float stride() const { return opts.item_height + opts.gap; }
    float contentHeight() const {
        if (opts.item_count == 0) return 0;
        return static_cast<float>(opts.item_count) * stride() - opts.gap;
    }

    void layoutItem(KxNode *child, size_t index) {
        child->layout({
            bounds.x,
            bounds.y + static_cast<float>(index) * stride(),
            bounds.w,
            opts.item_height,
        });
    }

    void syncWindow() {
        if (scroll.viewport <= 0) return;
        const Range range = visibleRange(opts.item_count, stride(), scroll.viewport,
                                         scroll.offset, opts.margin);
        syncItemWindow(this, &first, opts.factory, range,
                       [this](KxNode *n, KxNode *child, size_t index) {
                           Q_UNUSED(n);
                           layoutItem(child, index);
                       });
    }

    Size onMeasure(const Constraints &c) override {
        return c.constrain({c.max_w, c.max_h}); // fill the viewport
    }
    void onLayout(const Rect &b) override {
        scroll.viewport = b.h;
        scroll.content = contentHeight();
        scroll.setOffset(scroll.offset); // re-clamp after a resize
        if (scroll.viewport > 0) syncWindow();
        // Re-lay out every child (bounds may have changed — resize).
        for (size_t i = 0; i < children.size(); ++i)
            layoutItem(children[i], first + i);
    }
    void preChildrenPaint(QPainter &ctx) override {
        const Rect &b = bounds;
        clipRect(ctx, b.x, b.y, b.w, b.h);
        ctx.translate(0, -scroll.offset);
    }
    void postChildrenPaint(QPainter &ctx) override {
        clipReset(ctx);
    }
    bool mapPaintRect(Rect *r) const override {
        r->y -= scroll.offset;
        return true;
    }
    bool childClip(Rect *out) const override {
        *out = bounds;
        return true;
    }
    bool preChildrenHit(float px, float py, float *ox, float *oy) const override {
        *ox = px;
        *oy = py + scroll.offset;
        return true;
    }
    bool onPointer(const PointerEvent &ev) override {
        return input.onPointer(ev, scroll, lvSetOffset, this);
    }
    bool onScroll(const ScrollEvent &ev) override {
        return input.onScroll(ev, scroll, opts.wheel_speed, lvSetOffset, this);
    }
    bool scrollInfo(ScrollInfo *out) const override {
        *out = scroll.info();
        return true;
    }
    void scrollSetOffset(float value) override {
        lvSetOffset(this, value);
    }
};

bool lvSetOffset(KxNode *n, float value) {
    auto *lv = static_cast<ListViewNode *>(n);
    if (!lv->scroll.setOffset(value)) return false;
    lv->syncWindow();
    n->markDirty();
    return true;
}

} // namespace

KxNode *makeListView(const ListViewOptions &opts) { return new ListViewNode(opts); }

float listViewOffset(KxNode *n) {
    return static_cast<ListViewNode *>(n)->scroll.offset;
}

bool listViewSetOffset(KxNode *n, float value) {
    return lvSetOffset(n, value);
}

/// Re-create the live window from the factory: the model changed. Keeps the
/// scroll offset + window position.
void listViewReloadItems(KxNode *n) {
    auto *lv = static_cast<ListViewNode *>(n);
    // Detach-then-deinit from the back — the syncItemWindow invariant.
    while (!n->children.empty()) {
        KxNode *child = n->children.back();
        n->remove(child); // detach then deinit — never the reverse
        child->deinit();
    }
    if (lv->scroll.viewport > 0) {
        const Range range = visibleRange(lv->opts.item_count, lv->stride(),
                                         lv->scroll.viewport, lv->scroll.offset,
                                         lv->opts.margin);
        lv->first = range.first;
        lv->syncWindow();
    } else {
        lv->first = 0;
    }
    n->markLayoutDirty();
    n->markDirty();
}

/// Change the item count and reload the window, re-clamping the offset.
void listViewSetItemCount(KxNode *n, size_t count) {
    auto *lv = static_cast<ListViewNode *>(n);
    lv->opts.item_count = count;
    lv->scroll.content = lv->contentHeight();
    lv->scroll.setOffset(lv->scroll.offset); // re-clamp
    listViewReloadItems(n);
}

size_t listViewFirstIndex(KxNode *n) {
    return static_cast<ListViewNode *>(n)->first;
}

// ===========================================================================
// Localized widgets (src/widgets/i18n.zig)
// ===========================================================================

namespace {

/// The shared base of every localized-text state (i18n.zig L10nBase): the
/// resolved text + the locale-subscription effect.
class L10nNodeBase : public KxNode {
public:
    I18n *i18n;
    QString key;
    QString text;
    L10nTextOptions opts;
    Effect *effect = nullptr;

    L10nNodeBase(I18n *i, const QString &k, const L10nTextOptions &o)
        : i18n(i), key(k), opts(o) {}

    /// Swap the resolved string: repaint + re-layout (the text width may
    /// change); the resolved string is the node's accessible name.
    void resolveBase(const QString &new_text) {
        text = new_text;
        if (semantics) semantics->label = text;
        markDirty();
        markLayoutDirty();
    }

    virtual QString resolve() = 0;

    Size onMeasure(const Constraints &c) override {
        const TextMetrics m = measureText(text, opts.size, opts.bold);
        return c.constrain({m.width, m.height});
    }
    void onPaint(QPainter &ctx) override {
        const TextMetrics m = measureText(text, opts.size, opts.bold);
        const TextAlign r = resolveAlign(opts.text_align, direction());
        float x = bounds.x;
        if (r == TextAlign::center) x = bounds.x + (bounds.w - m.width) / 2;
        else if (r == TextAlign::right) x = bounds.x + bounds.w - m.width;
        drawText(ctx, text, x, bounds.y + m.ascent, opts.size, opts.bold, opts.color);
    }
    bool paintBounds(Rect *out) const override {
        const TextMetrics m = measureText(text, opts.size, opts.bold);
        const TextAlign r = resolveAlign(opts.text_align, direction());
        float x = bounds.x;
        if (r == TextAlign::center) x = bounds.x + (bounds.w - m.width) / 2;
        else if (r == TextAlign::right) x = bounds.x + bounds.w - m.width;
        *out = {x, bounds.y, m.width, m.height};
        return true;
    }
    void teardown() override {
        if (effect) { effect->deinit(); delete effect; effect = nullptr; }
    }
};

// l10nText(key, args): resolves tr(key) interpolated with the arg map.
class L10nTextNode final : public L10nNodeBase {
public:
    QHash<QString, QString> args;
    L10nTextNode(I18n *i, const QString &k, const QHash<QString, QString> &a,
                 const L10nTextOptions &o)
        : L10nNodeBase(i, k, o), args(a) {}
    QString resolve() override { return i18n->trArgs(key, args); }
};

// l10nPlural(key, count): ARB plural block for a fixed count.
class L10nPluralNode final : public L10nNodeBase {
public:
    qint64 count;
    L10nPluralNode(I18n *i, const QString &k, qint64 c, const L10nTextOptions &o)
        : L10nNodeBase(i, k, o), count(c) {}
    QString resolve() override { return i18n->trPlural(key, count); }
};

// l10nPluralSig(key, count_sig): both the count and the locale re-resolve.
class L10nPluralSigNode final : public L10nNodeBase {
public:
    Signal<qint64> *count_sig;
    L10nPluralSigNode(I18n *i, const QString &k, Signal<qint64> *s, const L10nTextOptions &o)
        : L10nNodeBase(i, k, o), count_sig(s) {}
    QString resolve() override { return i18n->trPlural(key, count_sig->peek()); }
    void teardown() override {
        count_sig->unsubscribe(Subscriber::forCallback({}, this));
        L10nNodeBase::teardown();
    }
};

KxNode *finishL10n(L10nNodeBase *n) {
    // The effect's run tracks locale_sig via get() — a locale switch re-runs
    // it; the run re-resolves the text and marks the node.
    L10nNodeBase *b = n;
    b->effect = new Effect([b] {
        b->i18n->locale_sig.get(); // track: re-run on locale switch
        b->resolveBase(b->resolve());
    });
    Semantics sem;
    sem.role = Role::text; // resolved string lands via resolveBase
    attach(n, sem);
    b->effect->run(); // first run: resolves the text + subscribes to locale_sig
    return n;
}

} // namespace

KxNode *makeL10nText(I18n *i18n, const QString &key, const QHash<QString, QString> &args,
                     const L10nTextOptions &opts) {
    return finishL10n(new L10nTextNode(i18n, key, args, opts));
}

KxNode *makeL10nPlural(I18n *i18n, const QString &key, qint64 count, const L10nTextOptions &opts) {
    return finishL10n(new L10nPluralNode(i18n, key, count, opts));
}

KxNode *makeL10nPluralSig(I18n *i18n, const QString &key, Signal<qint64> *count_sig,
                          const L10nTextOptions &opts) {
    auto *n = new L10nPluralSigNode(i18n, key, count_sig, opts);
    // Zig subscribes the resolve fn directly (a callback subscriber), not
    // through the effect — the count sig is not a tracked dependency.
    count_sig->subscribe(Subscriber::forCallback([n] {
        n->resolveBase(n->resolve());
    }, n));
    return finishL10n(n);
}

} // namespace kx
