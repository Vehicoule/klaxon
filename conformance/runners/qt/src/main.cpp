// main.cpp — Qt6 conformance driver: interprets conformance/tests/*.json
// vectors against the ported widget tree (kx.cpp + widgets.cpp).
//
// A line-for-line port of src/conformance.zig (the harness) and
// src/conformance_main.zig (the report + CLI): the DSL builds the same
// nodes, actions replay through the same input router, and every expect
// key produces the same "expected X got Y" mismatch strings.
//
// Rendering is the real Qt raster path: the tree paints through QPainter
// into a QImage (offscreen), pixels are read back for pixel asserts. Qt
// supplies rasterisation, font metrics and the event boundary — no
// expected values are embedded; every expectation is evaluated against
// actual behavior.

#include "kx.h"

#include <QtCore/QCoreApplication>
#include <QtCore/QDateTime>
#include <QtCore/QDir>
#include <QtCore/QFile>
#include <QtCore/QFileInfo>
#include <QtCore/QJsonArray>
#include <QtCore/QJsonDocument>
#include <QtCore/QJsonObject>
#include <QtCore/QJsonValue>
#include <QtCore/QMap>
#include <QtCore/QTextStream>
#include <QtWidgets/QApplication>

using namespace kx;

static const QJsonObject empty_obj;

// --- JSON value helpers -------------------------------------------------------

static QJsonValue getProp(const QJsonValue &v, const QString &name) {
    if (!v.isObject()) return QJsonValue();
    return v.toObject().value(name);
}

static float num(const QJsonValue &v, float def) {
    if (v.isDouble()) return static_cast<float>(v.toDouble());
    return def;
}

static qint64 intOf(const QJsonValue &v, qint64 def) {
    if (v.isDouble()) return static_cast<qint64>(v.toDouble());
    return def;
}

static std::optional<QString> str(const QJsonValue &v) {
    if (v.isString()) return v.toString();
    return std::nullopt;
}

static QString strOr(const QJsonValue &v, const QString &def) {
    return str(v).value_or(def);
}

static bool boolean(const QJsonValue &v, bool def) {
    if (v.isBool()) return v.toBool();
    return def;
}

static std::optional<Color> parseColor(const QJsonValue &v) {
    if (v.isDouble()) {
        // Zig: the int is bit-cast to u32 (negative ints wrap).
        const qint64 i = intOf(v, 0);
        return static_cast<Color>(static_cast<quint64>(i) & 0xFFFFFFFFu);
    }
    if (v.isString()) {
        QString hex = v.toString();
        if (hex.startsWith('#')) hex = hex.mid(1);
        if (hex.size() != 8) return std::nullopt;
        bool ok = false;
        const quint32 c = hex.toUInt(&ok, 16);
        if (!ok) return std::nullopt;
        return c;
    }
    return std::nullopt;
}

static std::optional<Alignment> parseAlign(const QJsonValue &v) {
    if (!v.isArray() || v.toArray().size() < 2) return std::nullopt;
    const QJsonArray a = v.toArray();
    return Alignment{num(a[0], 0), num(a[1], 0)};
}

static std::optional<Rect> parseRect(const QJsonValue &v) {
    if (!v.isArray() || v.toArray().size() < 4) return std::nullopt;
    const QJsonArray a = v.toArray();
    return Rect{num(a[0], 0), num(a[1], 0), num(a[2], 0), num(a[3], 0)};
}

static std::optional<EdgeInsets> parseInsets(const QJsonValue &v) {
    if (!v.isObject()) {
        const float a = num(v, -1); // scalar shorthand: 8 → all sides
        if (a < 0) return std::nullopt;
        return EdgeInsets::all(a);
    }
    const QJsonObject o = v.toObject();
    return EdgeInsets{num(o.value("left"), 0), num(o.value("top"), 0),
                      num(o.value("right"), 0), num(o.value("bottom"), 0)};
}

static std::optional<EdgeInsetsDirectional> parseDirInsets(const QJsonValue &v) {
    if (!v.isObject()) return std::nullopt;
    const QJsonObject o = v.toObject();
    return EdgeInsetsDirectional{num(o.value("start"), 0), num(o.value("end"), 0),
                                 num(o.value("top"), 0), num(o.value("bottom"), 0)};
}

static MainAlign parseMainAlign(const QString &s) {
    if (s == "center") return MainAlign::center;
    if (s == "end") return MainAlign::end;
    if (s == "space_between") return MainAlign::space_between;
    if (s == "space_around") return MainAlign::space_around;
    if (s == "space_evenly") return MainAlign::space_evenly;
    return MainAlign::start;
}

static CrossAlign parseCrossAlign(const QString &s) {
    if (s == "start") return CrossAlign::start;
    if (s == "center") return CrossAlign::center;
    if (s == "end") return CrossAlign::end;
    return CrossAlign::stretch; // widget default
}

static StackFit parseStackFit(const QString &s) {
    if (s == "expand") return StackFit::expand;
    return StackFit::loose;
}

static TextAlign parseTextAlign(const QString &s) {
    if (s == "center") return TextAlign::center;
    if (s == "right") return TextAlign::right;
    if (s == "start") return TextAlign::start;
    if (s == "end") return TextAlign::end;
    return TextAlign::left;
}

static Key parseKey(const QString &s) {
    if (s == "tab") return Key::tab;
    if (s == "enter") return Key::enter;
    if (s == "space") return Key::space;
    if (s == "escape") return Key::escape;
    if (s == "backspace") return Key::backspace;
    if (s == "delete") return Key::del;
    if (s == "left") return Key::left;
    if (s == "right") return Key::right;
    if (s == "up") return Key::up;
    if (s == "down") return Key::down;
    if (s == "back") return Key::back;
    // Single chars map to their codepoint (like the host's keymap path).
    if (s.size() == 1) return static_cast<Key>(s.at(0).unicode());
    return Key::unknown;
}

static LiveRegion parseRegion(const QString &s) {
    if (s == "assertive") return LiveRegion::assertive;
    return LiveRegion::polite;
}

static PointerPhase parsePhase(const QString &s) {
    if (s == "down") return PointerPhase::down;
    if (s == "up") return PointerPhase::up;
    return PointerPhase::move;
}

static Transition parseTransition(const QString &s) {
    if (s == "none") return Transition::none;
    if (s == "slide_up") return Transition::slide_up;
    if (s == "fade") return Transition::fade;
    if (s == "scale") return Transition::scale;
    return Transition::slide;
}

// --- conformance "box" leaf ----------------------------------------------------
// A deterministic leaf: fixed intrinsic size, solid fill, optional press log.
// Keeps layout/paint vectors independent of font metrics.

struct Harness;

class BoxNode final : public KxNode {
public:
    Harness *h;
    QString id;
    float w = 0, h_ = 0;
    Color color = 0xCCCCCCFF;
    bool on_press = false;
    size_t item_index = ~size_t(0); // set by list_view factories

    BoxNode(Harness *h_, const QString &id_) : h(h_), id(id_) {}
    Size onMeasure(const Constraints &c) override { return c.constrain({w, h_}); }
    void onPaint(QPainter &ctx) override {
        fillRect(ctx, bounds.x, bounds.y, bounds.w, bounds.h, color);
    }
    bool onPointer(const PointerEvent &ev) override;
};

// --- the harness -----------------------------------------------------------------

enum class ScrollKind { view, list };

// list_view factory userdata — survives for the widget's lifetime (the
// owning Harness outlives the tree).
struct ListBuilder {
    Harness *h;
    QString list_id;
    bool item_focusable, item_press;
};

struct EffectDef {
    Harness *h;
    QString name;
    QStringList reads; // "sig" tracked; "peek:sig" untracked; "memo" the test's memo
    enum class Op { add, mul, first } op = Op::add;
    Effect *effect = nullptr;
};

struct Harness {
    InputRouter router;
    Timeline timeline;
    FocusManager fm;
    LogBridge lb;
    I18n *i18n = nullptr;
    Navigator *nav = nullptr;
    KxNode *root = nullptr;
    KxSurface surface; // the QWidget host — paints via the real Qt raster path
    Rect viewport{0, 0, 800, 600};

    QHash<QString, KxNode *> ids;
    QHash<QString, ScrollKind> scroll_kind;
    QHash<QString, Signal<qint64> *> sig_i64;
    QHash<QString, Signal<bool> *> sig_bool;
    QHash<QString, Signal<float> *> sig_f32;
    QHash<QString, TextSignal *> sig_text;
    Memo *memo = nullptr;
    QString memo_name;
    QVector<EffectDef *> effects;
    std::vector<KxNode *> nav_nodes; // page nodes — owned here (never tree-added)
    std::vector<ListBuilder *> list_builders; // live as long as the tree

    QStringList gestures;
    QStringList events;
    QStringList effect_log;
    QString last_error;

    void init() {
        // Deterministic globals: widgets and input dispatch read the
        // process-global router / timeline / focus / bridge.
        setCurrentRouter(&router);
        setCurrentTimeline(&timeline);
        setCurrentFocus(&fm);
        setBridge(lb.bridge());
        surface.setRoot(nullptr);
    }

    /// Tree first (deinit callbacks read the globals), then the globals.
    void deinit() {
        if (root) root->deinit();
        for (KxNode *n : nav_nodes) n->deinit();
        nav_nodes.clear();
        for (ListBuilder *b : list_builders) delete b;
        list_builders.clear();
        if (nav) { nav->deinit(); delete nav; nav = nullptr; }
        for (EffectDef *d : effects) {
            if (d->effect) delete d->effect;
            delete d;
        }
        effects.clear();
        if (memo) { delete memo; memo = nullptr; }
        qDeleteAll(sig_i64); sig_i64.clear();
        qDeleteAll(sig_bool); sig_bool.clear();
        qDeleteAll(sig_f32); sig_f32.clear();
        qDeleteAll(sig_text); sig_text.clear();
        if (i18n) { delete i18n; i18n = nullptr; }
        setCurrentRouter(nullptr);
        setCurrentTimeline(nullptr);
        setCurrentFocus(nullptr);
        setBridge(nullptr);
        setCurrentI18n(nullptr);
    }

    std::function<void()> taggedCallback(const QString &prefix, const QString &id) {
        const QString tag = prefix + id;
        return [this, tag] { events.append(tag); };
    }

    Signal<qint64> *sigI64(const QString &name, qint64 initial) {
        if (auto *s = sig_i64.value(name, nullptr)) return s;
        auto *s = new Signal<qint64>(initial);
        sig_i64.insert(name, s);
        return s;
    }
    Signal<bool> *sigBool(const QString &name, bool initial) {
        if (auto *s = sig_bool.value(name, nullptr)) return s;
        auto *s = new Signal<bool>(initial);
        sig_bool.insert(name, s);
        return s;
    }
    Signal<float> *sigF32(const QString &name, float initial) {
        if (auto *s = sig_f32.value(name, nullptr)) return s;
        auto *s = new Signal<float>(initial);
        sig_f32.insert(name, s);
        return s;
    }

    /// "a" → tracked read; "peek:a" → untracked; "memo" → the test's memo.
    std::optional<qint64> readRef(const QString &ref) {
        if (ref == "memo") {
            if (!memo) return std::nullopt;
            return memo->get();
        }
        if (ref.startsWith(QStringLiteral("peek:"))) {
            auto *s = sig_i64.value(ref.mid(5), nullptr);
            if (!s) return std::nullopt;
            return s->peek();
        }
        auto *s = sig_i64.value(ref, nullptr);
        if (!s) return std::nullopt;
        return s->get();
    }

    KxNode *findNode(const QString &id) { return ids.value(id, nullptr); }

    /// True when `n` is still inside the live tree (list-view items are
    /// destroyed as they leave the virtualization window — a stale id then
    /// resolves to a detached/freed node).
    bool isLive(KxNode *n) const {
        if (!root) return false;
        for (KxNode *c = n; c; c = c->parent)
            if (c == root) return true;
        return false;
    }

    /// Raster frame: paints through QPainter into a QImage, reads pixels
    /// back (the offscreen equivalent of the QWidget paintEvent path).
    Frame renderFrame() {
        const int w = static_cast<int>(viewport.w);
        const int hgt = static_cast<int>(viewport.h);
        QImage img = surface.renderFrame(w, hgt, 0x000000FF);
        root->clearDamage();
        return Frame(img);
    }
};

bool BoxNode::onPointer(const PointerEvent &ev) {
    if (!on_press) return false;
    switch (ev.phase) {
        case PointerPhase::down: return true; // claim: captures for the up check
        case PointerPhase::up:
            if (bounds.contains(ev.x, ev.y))
                h->events.append(QStringLiteral("press:") + id);
            return true;
        default: return true;
    }
}

// --- effects -------------------------------------------------------------------

static void effectCb(EffectDef *d) {
    qint64 acc = d->op == EffectDef::Op::mul ? 1 : 0;
    bool first = true;
    for (const QString &r : d->reads) {
        const qint64 v = d->h->readRef(r).value_or(0);
        switch (d->op) {
            case EffectDef::Op::add: acc += v; break;
            case EffectDef::Op::mul: acc *= v; break;
            case EffectDef::Op::first: if (first) acc = v; break;
        }
        first = false;
    }
    d->h->effect_log.append(QStringLiteral("%1=%2").arg(d->name).arg(acc));
}

// --- tree builder ----------------------------------------------------------------

static QJsonObject propsOf(const QJsonValue &v) {
    const QJsonValue p = getProp(v, QStringLiteral("props"));
    return p.isObject() ? p.toObject() : empty_obj;
}

/// Attach semantics from props: role/label/hint/value/checked/disabled/
/// focusable/actions (array of strings). Merges into the widget's own
/// descriptor when it exists.
static void attachPropSemantics(KxNode *node, const QJsonObject &props) {
    const QStringList keys = {"role", "label", "focusable", "checked",
                              "disabled", "hint", "value", "actions"};
    bool any = false;
    for (const QString &k : keys)
        if (props.contains(k)) { any = true; break; }
    if (!any) return;
    Semantics *s = node->semantics;
    if (!s) {
        attach(node, Semantics{});
        s = node->semantics;
    }
    if (auto r = str(props.value("role"))) s->role = roleFromName(*r, nullptr);
    if (auto l = str(props.value("label"))) s->label = *l;
    if (auto t = str(props.value("hint"))) s->hint = *t;
    if (auto t = str(props.value("value"))) s->value = *t;
    if (props.contains("checked")) s->checked = boolean(props.value("checked"), false);
    if (props.contains("disabled")) s->disabled = boolean(props.value("disabled"), false);
    if (props.contains("focusable")) s->focusable = boolean(props.value("focusable"), false);
    if (props.contains("actions")) {
        const QJsonValue a = props.value("actions");
        if (a.isArray()) {
            for (const QJsonValue &av : a.toArray()) {
                const auto name = str(av);
                if (!name) continue;
                bool ok = false;
                const Action act = actionFromName(*name, &ok);
                if (ok) s->actions |= actionBit(act);
            }
        }
    }
}

/// Node-level props applied to every DSL node after construction:
/// id/flex/visible/exclude_semantics/damage_overflow + prop semantics.
/// Returns an error name or "".
static QString applyNodeProps(Harness *h, KxNode *node, const QJsonValue &tv,
                              const QString &id) {
    const QJsonObject props = propsOf(tv);
    if (props.contains("flex")) node->flex = static_cast<quint32>(std::max(0.0f, num(props.value("flex"), 1)));
    if (props.contains("visible")) node->visible = boolean(props.value("visible"), true);
    if (auto r = parseRect(props.value("damage_overflow"))) {
        node->damage_overflow = EdgeInsets{r->x, r->y, r->w, r->h};
    }
    if (boolean(props.value("exclude_semantics"), false)) node->exclude_semantics = true;
    attachPropSemantics(node, props);
    if (!id.isEmpty()) {
        if (h->ids.contains(id)) return QStringLiteral("DuplicateId");
        h->ids.insert(id, node);
    }
    return QString();
}

static QString buildNode(Harness *h, const QJsonValue &tv, KxNode **out);

static QString buildChildren(Harness *h, KxNode *parent, const QJsonValue &tv) {
    const QJsonValue kids = getProp(tv, QStringLiteral("children"));
    if (!kids.isArray()) return QString();
    for (const QJsonValue &kv : kids.toArray()) {
        KxNode *child = nullptr;
        const QString e = buildNode(h, kv, &child);
        if (!e.isEmpty()) return e;
        parent->add(child);
    }
    return QString();
}

/// Items are alternating-color boxes registered as "<list>.item<i>" — id
/// expectations locate them; `first_item` reads the first child's index.
static KxNode *listItem(ListBuilder *b, size_t index) {
    Harness *h = b->h;
    const QString name = QStringLiteral("%1.item%2").arg(b->list_id).arg(index);
    static const Color palette[3] = {0xFF0000FF, 0x00FF00FF, 0x0000FFFF};
    auto *n = new BoxNode(h, name);
    n->color = palette[index % 3];
    n->on_press = b->item_press;
    n->item_index = index;
    if (b->item_focusable) {
        Semantics sem;
        sem.role = Role::list_item;
        sem.focusable = true;
        attach(n, sem);
    }
    h->ids.insert(name, n);
    return n;
}

static QString buildListView(Harness *h, const QJsonObject &props, const QString &id,
                             KxNode **out) {
    auto *builder = new ListBuilder{
        h,
        !id.isEmpty() ? id : QStringLiteral("list"),
        boolean(props.value("item_focusable"), false),
        boolean(props.value("item_press"), false),
    };
    h->list_builders.push_back(builder);
    ListViewOptions opts;
    opts.factory = [builder](size_t index) { return listItem(builder, index); };
    opts.item_count = static_cast<size_t>(std::max(0.0f, num(props.value("item_count"), 0)));
    opts.item_height = num(props.value("item_height"), 48);
    opts.gap = num(props.value("gap"), 0);
    opts.margin = static_cast<size_t>(std::max(0.0f, num(props.value("margin"), 2)));
    opts.wheel_speed = num(props.value("wheel_speed"), 48);
    *out = makeListView(opts);
    return QString();
}

/// Build one DSL node: {"type":"row","id":"r","props":{...},"children":[...]}.
/// Returns an error name or "" (setup errors abort the test).
static QString buildNode(Harness *h, const QJsonValue &tv, KxNode **out) {
    const auto wtype_o = str(getProp(tv, QStringLiteral("type")));
    if (!wtype_o) return QStringLiteral("MissingType");
    const QString wtype = *wtype_o;
    const QString id = strOr(getProp(tv, QStringLiteral("id")), QString());
    const QJsonObject props = propsOf(tv);

    KxNode *node = nullptr;
    if (wtype == "box") {
        auto *n = new BoxNode(h, id);
        n->w = num(props.value("w"), 0);
        n->h_ = num(props.value("h"), 0);
        n->color = parseColor(props.value("color")).value_or(0xCCCCCCFF);
        n->on_press = boolean(props.value("on_press"), false);
        node = n;
    } else if (wtype == "row" || wtype == "column") {
        FlexOptions opts;
        opts.gap = num(props.value("gap"), 0);
        opts.padding = num(props.value("padding"), 0);
        opts.main_align = parseMainAlign(strOr(props.value("main_align"), "start"));
        opts.cross_align = parseCrossAlign(strOr(props.value("cross_align"), "stretch"));
        node = makeFlex(wtype == "row" ? Axis::horizontal : Axis::vertical, opts);
    } else if (wtype == "stack") {
        StackOptions opts;
        opts.fit = parseStackFit(strOr(props.value("fit"), "loose"));
        opts.alignment = parseAlign(props.value("alignment")).value_or(Alignment::topLeft());
        node = makeStack(opts);
    } else if (wtype == "grid") {
        GridOptions opts;
        opts.columns = static_cast<size_t>(std::max(0.0f, num(props.value("columns"), 2)));
        opts.gap = num(props.value("gap"), 0);
        opts.padding = num(props.value("padding"), 0);
        node = makeGrid(opts);
    } else if (wtype == "padding") {
        node = makePadding(parseInsets(props.value("padding")).value_or(EdgeInsets{}));
    } else if (wtype == "padding_directional") {
        node = makePaddingDir(parseDirInsets(props).value_or(EdgeInsetsDirectional{}));
    } else if (wtype == "center") {
        node = makeCenter();
    } else if (wtype == "align") {
        node = makeAlign(parseAlign(props.value("alignment")).value_or(Alignment::center()));
    } else if (wtype == "constrained_box") {
        ConstrainedBoxOptions opts;
        opts.min_w = num(props.value("min_w"), 0);
        opts.min_h = num(props.value("min_h"), 0);
        opts.max_w = props.contains("max_w") ? num(props.value("max_w"), 0)
                                             : std::numeric_limits<float>::infinity();
        opts.max_h = props.contains("max_h") ? num(props.value("max_h"), 0)
                                             : std::numeric_limits<float>::infinity();
        node = makeConstrainedBox(opts);
    } else if (wtype == "expanded") {
        node = makeExpanded(static_cast<quint32>(std::max(0.0f, num(props.value("weight"), 1))));
    } else if (wtype == "container") {
        ContainerOptions opts;
        opts.color = parseColor(props.value("color"));
        opts.padding = parseInsets(props.value("padding")).value_or(EdgeInsets{});
        node = makeContainer(opts);
    } else if (wtype == "text") {
        TextOptions opts;
        opts.size = num(props.value("size"), 16);
        opts.color = parseColor(props.value("color")).value_or(0x000000FF);
        opts.bold = boolean(props.value("bold"), false);
        opts.text_align = parseTextAlign(strOr(props.value("text_align"), "left"));
        node = makeText(strOr(props.value("text"), QString()), opts);
    } else if (wtype == "button") {
        node = makeButton(h->taggedCallback(QStringLiteral("press:"), id), ButtonOptions{});
    } else if (wtype == "toggle") {
        Signal<bool> *sig = h->sigBool(strOr(props.value("signal"), id),
                                       boolean(props.value("checked"), false));
        node = makeToggle(sig, h->taggedCallback(QStringLiteral("change:"), id), ToggleOptions{});
    } else if (wtype == "checkbox") {
        Signal<bool> *sig = h->sigBool(strOr(props.value("signal"), id),
                                       boolean(props.value("checked"), false));
        node = makeCheckbox(sig, h->taggedCallback(QStringLiteral("change:"), id), CheckboxOptions{});
    } else if (wtype == "slider") {
        Signal<float> *sig = h->sigF32(strOr(props.value("signal"), id),
                                       num(props.value("value"), 0.5f));
        SliderOptions opts;
        opts.default_width = num(props.value("width"), 200);
        node = makeSlider(sig, h->taggedCallback(QStringLiteral("change:"), id), opts);
    } else if (wtype == "text_field") {
        TextFieldOptions opts;
        opts.placeholder = strOr(props.value("placeholder"), QString());
        opts.initial = strOr(props.value("initial"), QString());
        node = makeTextField(opts,
                             h->taggedCallback(QStringLiteral("change:"), id),
                             h->taggedCallback(QStringLiteral("submit:"), id));
    } else if (wtype == "gesture_detector") {
        GestureCallbacks cbs;
        const QJsonValue gs = props.value("gestures");
        if (gs.isArray()) {
            for (const QJsonValue &gv : gs.toArray()) {
                const auto name = str(gv);
                if (!name) continue;
                const QString g = *name;
                auto log = [this_h = h](QString tag) {
                    return [this_h, tag] { this_h->gestures.append(tag); };
                };
                if (g == "tap") cbs.on_tap = log("tap");
                if (g == "double_tap") cbs.on_double_tap = log("double_tap");
                if (g == "long_press") cbs.on_long_press = log("long_press");
                if (g == "pan_start") cbs.on_pan_start = [this_h = h](float, float) {
                    this_h->gestures.append("pan_start"); };
                if (g == "pan_update") cbs.on_pan_update = [this_h = h](float, float) {
                    this_h->gestures.append("pan_update"); };
                if (g == "pan_end") cbs.on_pan_end = [this_h = h](float, float, float, float) {
                    this_h->gestures.append("pan_end"); };
                if (g == "swipe") cbs.on_swipe = [this_h = h](SwipeDirection d, float, float) {
                    this_h->gestures.append(QStringLiteral("swipe:") + swipeDirectionName(d)); };
                if (g == "pinch") cbs.on_pinch = [this_h = h](float) {
                    this_h->gestures.append("pinch"); };
                if (g == "rotate") cbs.on_rotate = [this_h = h](float) {
                    this_h->gestures.append("rotate"); };
            }
        }
        node = makeGestureDetector(cbs);
    } else if (wtype == "scroll_view") {
        ScrollViewOptions opts;
        opts.wheel_speed = num(props.value("wheel_speed"), 48);
        node = makeScrollView(opts);
        if (!id.isEmpty()) h->scroll_kind.insert(id, ScrollKind::view);
    } else if (wtype == "list_view") {
        const QString e = buildListView(h, props, id, &node);
        if (!e.isEmpty()) return e;
        if (!id.isEmpty()) h->scroll_kind.insert(id, ScrollKind::list);
    } else if (wtype == "l10n_text") {
        if (!h->i18n) return QStringLiteral("MissingI18n");
        L10nTextOptions opts;
        opts.size = num(props.value("size"), 14);
        node = makeL10nText(h->i18n, strOr(props.value("key"), QString()), {}, opts);
    } else if (wtype == "l10n_plural") {
        if (!h->i18n) return QStringLiteral("MissingI18n");
        L10nTextOptions opts;
        if (auto cs = str(props.value("count_signal"))) {
            Signal<qint64> *sig = h->sigI64(*cs, intOf(props.value("count"), 0));
            node = makeL10nPluralSig(h->i18n, strOr(props.value("key"), QString()), sig, opts);
        } else {
            node = makeL10nPlural(h->i18n, strOr(props.value("key"), QString()),
                                  intOf(props.value("count"), 0), opts);
        }
    } else {
        return QStringLiteral("UnknownType");
    }

    const QString e1 = buildChildren(h, node, tv);
    if (!e1.isEmpty()) return e1;
    const QString e2 = applyNodeProps(h, node, tv, id);
    if (!e2.isEmpty()) return e2;
    *out = node;
    return QString();
}

// --- setup -----------------------------------------------------------------------

static QString setupSignals(Harness *h, const QJsonValue &sigs) {
    if (!sigs.isObject()) return QString();
    const QJsonObject o = sigs.toObject();
    for (auto it = o.begin(); it != o.end(); ++it) {
        const QString name = it.key();
        const QJsonValue &v = it.value();
        if (v.isBool()) {
            h->sigBool(name, v.toBool());
        } else if (v.isDouble()) {
            const double d = v.toDouble();
            // int when the value is integral (Zig distinguishes .int/.float).
            if (d == std::floor(d) && std::abs(d) < 9.0e15) h->sigI64(name, static_cast<qint64>(d));
            else h->sigF32(name, static_cast<float>(d));
        } else if (v.isString()) {
            h->sig_text.insert(name, new TextSignal(v.toString()));
        } else if (v.isObject()) {
            if (strOr(getProp(v, QStringLiteral("type")), QString()) == "text") {
                h->sig_text.insert(name, new TextSignal(strOr(getProp(v, QStringLiteral("value")), QString())));
            }
        }
    }
    return QString();
}

/// effects: [{"name":"e1","reads":["a","b"],"op":"add|mul|first"}] — the log
/// records "name=value" on every run.
static QString setupEffects(Harness *h, const QJsonValue &defs) {
    if (!defs.isArray()) return QString();
    for (const QJsonValue &dv : defs.toArray()) {
        auto *d = new EffectDef;
        d->h = h;
        if (getProp(dv, QStringLiteral("reads")).isArray()) {
            for (const QJsonValue &rv : getProp(dv, QStringLiteral("reads")).toArray())
                if (auto r = str(rv)) d->reads.append(*r);
        }
        const QString op_name = strOr(getProp(dv, QStringLiteral("op")), QStringLiteral("add"));
        d->op = op_name == "mul" ? EffectDef::Op::mul
              : op_name == "first" ? EffectDef::Op::first : EffectDef::Op::add;
        d->name = strOr(getProp(dv, QStringLiteral("name")), QStringLiteral("effect"));
        d->effect = new Effect([d] { effectCb(d); });
        h->effects.append(d);
        d->effect->run(); // first run: resolve + subscribe
    }
    return QString();
}

/// memo: {"name":"m","op":"add|sub|mul","args":["a","b"]} — at most one per test.
static QString setupMemo(Harness *h, const QJsonValue &def) {
    if (!def.isObject()) return QString();
    const QJsonValue args_v = getProp(def, QStringLiteral("args"));
    if (!args_v.isArray() || args_v.toArray().size() < 2) return QString();
    const QJsonArray args = args_v.toArray();
    Signal<qint64> *a = h->sig_i64.value(strOr(args[0], QString()), nullptr);
    Signal<qint64> *b = h->sig_i64.value(strOr(args[1], QString()), nullptr);
    if (!a || !b) return QString();
    const QString op_name = strOr(getProp(def, QStringLiteral("op")), QStringLiteral("add"));
    enum class MOp { add, sub, mul } op = op_name == "sub" ? MOp::sub
                                        : op_name == "mul" ? MOp::mul : MOp::add;
    h->memo = new Memo([a, b, op] {
        switch (op) {
            case MOp::add: return a->get() + b->get();
            case MOp::sub: return a->get() - b->get();
            case MOp::mul: return a->get() * b->get();
        }
        return qint64(0);
    });
    h->memo_name = strOr(getProp(def, QStringLiteral("name")), QStringLiteral("memo"));
    return QString();
}

/// i18n: {"locale":"en","fallback":"en","locales":{"en":{...arb...}},
///         "dirs":{"ar":"rtl"}} — ARB objects pass straight through.
static QString setupI18n(Harness *h, const QJsonValue &v) {
    if (!v.isObject()) return QString();
    auto *i18n = new I18n(strOr(getProp(v, QStringLiteral("fallback")), QStringLiteral("en")));
    h->i18n = i18n;
    const QJsonValue locs = getProp(v, QStringLiteral("locales"));
    if (locs.isObject()) {
        const QJsonObject lo = locs.toObject();
        const QJsonValue dirs = getProp(v, QStringLiteral("dirs"));
        for (auto it = lo.begin(); it != lo.end(); ++it) {
            Direction dir = Direction::ltr;
            if (dirs.isObject()) {
                const QJsonValue dv = dirs.toObject().value(it.key());
                if (strOr(dv, QStringLiteral("ltr")) == "rtl") dir = Direction::rtl;
            }
            if (!it.value().isObject()) continue;
            QString err;
            i18n->addArb(it.key(), it.value().toObject(), dir, &err);
            if (!err.isEmpty()) return err;
        }
    }
    if (auto tag = str(getProp(v, QStringLiteral("locale")))) {
        QString err;
        if (!i18n->setLocale(*tag, &err)) return err;
    }
    setCurrentI18n(i18n);
    return QString();
}

/// navigator: {"routes":[{"pattern":"home"},{"pattern":"anime/{id}"}]}.
/// Page content is a fixed box — nav semantics don't depend on page content.
/// Stack changes log "nav:<kind>" into the events log.
static QString setupNavigator(Harness *h, const QJsonValue &v) {
    if (!v.isObject()) return QString();
    auto *nv = new Navigator;
    h->nav = nv;
    nv->setOnChange([h](ChangeKind kind) {
        h->events.append(QStringLiteral("nav:") + changeKindName(kind));
    });
    const QJsonValue rs = getProp(v, QStringLiteral("routes"));
    if (rs.isArray()) {
        for (const QJsonValue &rv : rs.toArray()) {
            const auto pattern = str(getProp(rv, QStringLiteral("pattern")));
            if (!pattern) continue;
            const Transition t = parseTransition(strOr(getProp(rv, QStringLiteral("transition")),
                                                         QStringLiteral("slide")));
            nv->define(*pattern, [h](const Route &) -> KxNode * {
                auto *n = new BoxNode(h, QStringLiteral("page"));
                n->w = 10; n->h_ = 10;
                n->color = 0x333333FF;
                h->nav_nodes.push_back(n);
                return n;
            }, t);
        }
    }
    return QString();
}

// --- actions -----------------------------------------------------------------------

static std::vector<Param> paramsFromJson(const QJsonValue &v) {
    std::vector<Param> list;
    if (v.isObject()) {
        const QJsonObject o = v.toObject();
        for (auto it = o.begin(); it != o.end(); ++it)
            list.push_back(Param{it.key(), strOr(it.value(), QString())});
    }
    return list;
}

static QString runActionInner(Harness *h, const QString &op, const QJsonValue &av);

/// One action. Errors land in h.last_error (the `action_error` expect key
/// checks them) instead of failing the test — error cases ARE testable.
static void runAction(Harness *h, const QJsonValue &av) {
    const QString op = strOr(getProp(av, QStringLiteral("op")), QString());
    const QString e = runActionInner(h, op, av);
    if (!e.isEmpty()) h->last_error = e;
}

static QString runActionInner(Harness *h, const QString &op, const QJsonValue &av) {
    // The tree is required only by ops that dispatch into it — signal/memo/
    // nav/focus ops run on tree-less state tests.
    if (op == "pointer") {
        KxNode *root = h->root;
        if (!root) return QStringLiteral("NoTree");
        PointerEvent ev;
        ev.phase = parsePhase(strOr(getProp(av, QStringLiteral("phase")), QStringLiteral("move")));
        ev.x = num(getProp(av, QStringLiteral("x")), 0);
        ev.y = num(getProp(av, QStringLiteral("y")), 0);
        ev.pointer = static_cast<quint64>(std::max<qint64>(0, intOf(getProp(av, QStringLiteral("pointer")), 0)));
        ev.time_ms = static_cast<quint64>(std::max<qint64>(0, intOf(getProp(av, QStringLiteral("t")), 0)));
        h->router.dispatchPointer(root, ev);
    } else if (op == "scroll") {
        KxNode *root = h->root;
        if (!root) return QStringLiteral("NoTree");
        ScrollEvent ev;
        ev.x = num(getProp(av, QStringLiteral("x")), 0);
        ev.y = num(getProp(av, QStringLiteral("y")), 0);
        ev.delta_x = num(getProp(av, QStringLiteral("dx")), 0);
        ev.delta_y = num(getProp(av, QStringLiteral("dy")), 0);
        ev.time_ms = static_cast<quint64>(std::max<qint64>(0, intOf(getProp(av, QStringLiteral("t")), 0)));
        h->router.dispatchScroll(root, ev);
        h->router.refreshHover(root); // mirrors the host (content moves under the pointer)
    } else if (op == "key") {
        KeyEvent ev;
        ev.kind = KeyEvent::Kind::key_down;
        ev.key = parseKey(strOr(getProp(av, QStringLiteral("key")), QStringLiteral("unknown")));
        ev.shift = boolean(getProp(av, QStringLiteral("shift")), false);
        // Host dispatch order (host.zig): Escape/Back → dispatchBack; Tab →
        // the focus manager; anything else → focused chain, then the FM's
        // activation fallback (Enter/Space).
        if (ev.key == Key::escape || ev.key == Key::back) {
            h->router.dispatchBack();
        } else if (ev.key == Key::tab) {
            h->fm.handleKey(ev);
        } else {
            if (!h->router.dispatchKey(ev)) h->fm.handleKey(ev);
        }
    } else if (op == "text_input") {
        KeyEvent ev;
        ev.kind = KeyEvent::Kind::text_input;
        ev.text = strOr(getProp(av, QStringLiteral("text")), QString());
        h->router.dispatchKey(ev);
    } else if (op == "tick") {
        h->timeline.tick(static_cast<quint64>(std::max<qint64>(0, intOf(getProp(av, QStringLiteral("ms")), 0))));
    } else if (op == "focus") {
        if (auto id = str(getProp(av, QStringLiteral("id")))) {
            KxNode *n = h->findNode(*id);
            if (!n) return QStringLiteral("UnknownNode");
            h->fm.focusNode(n);
        } else {
            h->fm.focusNode(nullptr);
        }
    } else if (op == "mark_dirty") {
        KxNode *n = h->findNode(strOr(getProp(av, QStringLiteral("id")), QString()));
        if (!n) return QStringLiteral("UnknownNode");
        n->markDirty();
    } else if (op == "mark_dirty_rect") {
        KxNode *n = h->findNode(strOr(getProp(av, QStringLiteral("id")), QString()));
        if (!n) return QStringLiteral("UnknownNode");
        const auto r = parseRect(getProp(av, QStringLiteral("rect")));
        if (!r) return QStringLiteral("BadRect");
        n->markDirtyRect(*r);
    } else if (op == "relayout") {
        h->viewport.w = num(getProp(av, QStringLiteral("w")), h->viewport.w);
        h->viewport.h = num(getProp(av, QStringLiteral("h")), h->viewport.h);
        KxNode *root = h->root;
        if (!root) return QStringLiteral("NoTree");
        root->layout(h->viewport);
    } else if (op == "paint") {
        Frame f = h->renderFrame();
        Q_UNUSED(f);
    } else if (op == "set_scroll") {
        const QString id = strOr(getProp(av, QStringLiteral("id")), QString());
        KxNode *n = h->findNode(id);
        if (!n) return QStringLiteral("UnknownNode");
        const ScrollKind kind = h->scroll_kind.value(id, ScrollKind::view);
        const float off = num(getProp(av, QStringLiteral("offset")), 0);
        if (kind == ScrollKind::view) scrollViewSetOffset(n, off);
        else listViewSetOffset(n, off);
    } else if (op == "list_count") {
        KxNode *n = h->findNode(strOr(getProp(av, QStringLiteral("id")), QString()));
        if (!n) return QStringLiteral("UnknownNode");
        listViewSetItemCount(n, static_cast<size_t>(std::max<qint64>(0, intOf(getProp(av, QStringLiteral("count")), 0))));
    } else if (op == "list_reload") {
        KxNode *n = h->findNode(strOr(getProp(av, QStringLiteral("id")), QString()));
        if (!n) return QStringLiteral("UnknownNode");
        listViewReloadItems(n);
    } else if (op == "set_locale") {
        if (!h->i18n) return QStringLiteral("MissingI18n");
        QString err;
        if (!h->i18n->setLocale(strOr(getProp(av, QStringLiteral("tag")), QString()), &err))
            return err.isEmpty() ? QStringLiteral("UnknownLocale") : err;
    } else if (op == "signal_set") {
        const QString name = strOr(getProp(av, QStringLiteral("name")), QString());
        const QJsonValue v = getProp(av, QStringLiteral("value")).isUndefined()
            ? QJsonValue(0.0) : getProp(av, QStringLiteral("value"));
        if (auto *s = h->sig_i64.value(name, nullptr)) {
            s->set(intOf(v, 0));
        } else if (auto *s = h->sig_bool.value(name, nullptr)) {
            s->set(boolean(v, false));
        } else if (auto *s = h->sig_f32.value(name, nullptr)) {
            s->set(num(v, 0));
        } else if (auto *s = h->sig_text.value(name, nullptr)) {
            QString val;
            if (getProp(av, QStringLiteral("len")).isDouble()) {
                // Generate `len` filler bytes — exercises the 1 MiB cap
                // without embedding it in the vector.
                val = QString(static_cast<qsizetype>(std::max<qint64>(0, intOf(getProp(av, QStringLiteral("len")), 0))), QLatin1Char('x'));
            } else {
                val = strOr(v, QString());
            }
            if (!s->set(val)) return QStringLiteral("TextTooLong");
        } else return QStringLiteral("UnknownSignal");
    } else if (op == "signal_notify") {
        const QString name = strOr(getProp(av, QStringLiteral("name")), QString());
        if (auto *s = h->sig_i64.value(name, nullptr)) {
            s->forceNotify();
        } else if (auto *s = h->sig_text.value(name, nullptr)) {
            s->forceNotify();
        } else return QStringLiteral("UnknownSignal");
    } else if (op == "nav_push") {
        if (!h->nav) return QStringLiteral("MissingNavigator");
        return h->nav->push(strOr(getProp(av, QStringLiteral("pattern")), QString()),
                            paramsFromJson(getProp(av, QStringLiteral("params"))));
    } else if (op == "nav_push_path") {
        if (!h->nav) return QStringLiteral("MissingNavigator");
        return h->nav->pushPath(strOr(getProp(av, QStringLiteral("path")), QString()),
                                paramsFromJson(getProp(av, QStringLiteral("params"))));
    } else if (op == "navigate") {
        if (!h->nav) return QStringLiteral("MissingNavigator");
        return h->nav->navigateTo(strOr(getProp(av, QStringLiteral("uri")), QString()));
    } else if (op == "nav_replace") {
        if (!h->nav) return QStringLiteral("MissingNavigator");
        return h->nav->replace(strOr(getProp(av, QStringLiteral("pattern")), QString()),
                               paramsFromJson(getProp(av, QStringLiteral("params"))));
    } else if (op == "nav_pop") {
        if (!h->nav) return QStringLiteral("MissingNavigator");
        h->nav->pop();
    } else if (op == "nav_back") {
        if (!h->nav) return QStringLiteral("MissingNavigator");
        h->nav->onBack();
    } else if (op == "nav_pop_to_root") {
        if (!h->nav) return QStringLiteral("MissingNavigator");
        h->nav->popToRoot();
    } else if (op == "announce") {
        announce(strOr(getProp(av, QStringLiteral("text")), QString()),
                 parseRegion(strOr(getProp(av, QStringLiteral("region")), QStringLiteral("polite"))));
    } else {
        return QStringLiteral("UnknownOp");
    }
    return QString();
}

// --- expectations ------------------------------------------------------------------

struct Check {
    QStringList *failures;
    float tol;
    void fail(const QString &s) { failures->append(s); }
};

static bool nearEq(float a, float b, float tol) { return std::abs(a - b) <= tol; }
static QString boolStr(bool b) { return b ? QStringLiteral("true") : QStringLiteral("false"); }
static bool rectEq(const Rect &a, const Rect &b, float tol) {
    return nearEq(a.x, b.x, tol) && nearEq(a.y, b.y, tol) &&
           nearEq(a.w, b.w, tol) && nearEq(a.h, b.h, tol);
}

/// Zig {d}-style float formatting for mismatch messages (200 → "200").
static QString fmtN(float v) {
    if (v == std::floor(v) && std::abs(v) < 1e15f)
        return QString::number(static_cast<qint64>(v));
    return QString::number(static_cast<double>(v));
}
static QString fmtR(const Rect &r) {
    return QStringLiteral("[%1,%2,%3,%4]").arg(fmtN(r.x), fmtN(r.y), fmtN(r.w), fmtN(r.h));
}

/// Resolve an id → node only if still live (list items die on scroll).
static KxNode *liveNode(Harness *h, Check *c, const QString &id) {
    KxNode *n = h->findNode(id);
    if (!n) {
        c->fail(QStringLiteral("unknown node id \"%1\"").arg(id));
        return nullptr;
    }
    if (!h->isLive(n)) {
        c->fail(QStringLiteral("node \"%1\" is no longer in the tree").arg(id));
        return nullptr;
    }
    return n;
}

static QString idFor(Harness *h, KxNode *n) {
    for (auto it = h->ids.begin(); it != h->ids.end(); ++it)
        if (it.value() == n) return it.key();
    return QStringLiteral("(unnamed)");
}

static void expectRects(Harness *h, Check *c, const QJsonValue &v) {
    if (!v.isObject()) return;
    const QJsonObject o = v.toObject();
    for (auto it = o.begin(); it != o.end(); ++it) {
        KxNode *n = liveNode(h, c, it.key());
        if (!n) continue;
        const auto want = parseRect(it.value());
        if (!want) {
            c->fail(QStringLiteral("rects.%1: expected [x,y,w,h]").arg(it.key()));
            continue;
        }
        if (!rectEq(n->bounds, *want, c->tol)) {
            c->fail(QStringLiteral("rects.%1: expected %2 got %3")
                        .arg(it.key(), fmtR(*want), fmtR(n->bounds)));
        }
    }
}

static void expectMeasured(Harness *h, Check *c, const QJsonValue &v) {
    if (!v.isObject()) return;
    const QJsonObject o = v.toObject();
    for (auto it = o.begin(); it != o.end(); ++it) {
        KxNode *n = liveNode(h, c, it.key());
        if (!n) continue;
        const auto want = parseAlign(it.value());
        if (!want) {
            c->fail(QStringLiteral("measured.%1: expected [w,h]").arg(it.key()));
            continue;
        }
        Constraints cc;
        cc.max_w = h->viewport.w;
        cc.max_h = h->viewport.h;
        const Size got = n->measure(cc);
        if (!nearEq(got.w, want->x, c->tol) || !nearEq(got.h, want->y, c->tol)) {
            c->fail(QStringLiteral("measured.%1: expected [%2,%3] got [%4,%5]")
                        .arg(it.key(), fmtN(want->x), fmtN(want->y), fmtN(got.w), fmtN(got.h)));
        }
    }
}

static void expectDamage(Harness *h, Check *c, const QJsonValue &v) {
    KxNode *root = h->root;
    if (!root) return;
    if (v.isNull()) {
        if (root->damage_valid)
            c->fail(QStringLiteral("damage: expected none, got %1").arg(fmtR(root->damage)));
        return;
    }
    const auto want = parseRect(v);
    if (!want) {
        c->fail(QStringLiteral("damage: expected [x,y,w,h] or null"));
        return;
    }
    if (!root->damage_valid) {
        c->fail(QStringLiteral("damage: expected %1 got none").arg(fmtR(*want)));
        return;
    }
    if (!rectEq(root->damage, *want, c->tol)) {
        c->fail(QStringLiteral("damage: expected %1 got %2").arg(fmtR(*want), fmtR(root->damage)));
    }
}

static void expectFocused(Harness *h, Check *c, const QJsonValue &v, bool router_side) {
    KxNode *n = router_side ? h->router.focused : h->fm.focused;
    const QString key = router_side ? QStringLiteral("router_focused")
                                    : QStringLiteral("focused");
    if (v.isNull()) {
        if (n) c->fail(QStringLiteral("%1: expected null, got \"%2\"").arg(key, idFor(h, n)));
        return;
    }
    const QString want = strOr(v, QString());
    const QString got = n ? idFor(h, n) : QString();
    if (!n || got != want) {
        c->fail(QStringLiteral("%1: expected \"%2\", got %3")
                    .arg(key, want, n ? got : QStringLiteral("null")));
    }
}

static void expectSeq(Check *c, const QString &key, const QJsonArray &want,
                      const QStringList &got);

static void expectFocusOrder(Harness *h, Check *c, const QJsonValue &v) {
    if (!v.isArray()) return;
    const auto order = h->fm.focusOrder();
    QStringList got;
    for (KxNode *n : order) got.append(idFor(h, n));
    expectSeq(c, QStringLiteral("focus_order"), v.toArray(), got);
}

/// Exact-sequence compare for log-based expects.
static void expectSeq(Check *c, const QString &key, const QJsonArray &want,
                      const QStringList &got) {
    const int n = std::max(want.size(), got.size());
    for (int i = 0; i < n; ++i) {
        const QString w = i < want.size() ? strOr(want[i], QStringLiteral("?"))
                                          : QStringLiteral("<missing>");
        const QString g = i < got.size() ? got[i] : QStringLiteral("<missing>");
        if (w != g) {
            c->fail(QStringLiteral("%1[%2]: expected \"%3\", got \"%4\" (full got: %5)")
                        .arg(key).arg(i).arg(w, g, got.join(',')));
            return;
        }
    }
}

static void expectSignals(Harness *h, Check *c, const QJsonValue &v) {
    if (!v.isObject()) return;
    const QJsonObject o = v.toObject();
    for (auto it = o.begin(); it != o.end(); ++it) {
        const QString &name = it.key();
        if (auto *s = h->sig_i64.value(name, nullptr)) {
            const qint64 want = intOf(it.value(), 0);
            if (s->peek() != want)
                c->fail(QStringLiteral("signals.%1: expected %2, got %3")
                            .arg(name).arg(want).arg(s->peek()));
        } else if (auto *s = h->sig_bool.value(name, nullptr)) {
            const bool want = boolean(it.value(), false);
            if (s->peek() != want)
                c->fail(QStringLiteral("signals.%1: expected %2, got %3")
                            .arg(name, boolStr(want), boolStr(s->peek())));
        } else if (auto *s = h->sig_f32.value(name, nullptr)) {
            const float want = num(it.value(), 0);
            if (!nearEq(s->peek(), want, c->tol))
                c->fail(QStringLiteral("signals.%1: expected %2, got %3")
                            .arg(name, fmtN(want), fmtN(s->peek())));
        } else if (auto *s = h->sig_text.value(name, nullptr)) {
            const QString want = strOr(it.value(), QString());
            if (s->peek() != want)
                c->fail(QStringLiteral("signals.%1: expected \"%2\", got \"%3\"")
                            .arg(name, want, s->peek()));
        } else {
            c->fail(QStringLiteral("signals.%1: unknown signal").arg(name));
        }
    }
}

static void checkSemNode(Check *c, const QJsonValue &ev, const SemanticNode &got);

/// Flattened semantic tree: pre-order, dropping the synthetic group wrapper
/// the builder adds when the root has no semantics of its own.
static void flattenSem(Harness *h, Check *c, const QJsonValue &v) {
    KxNode *root = h->root;
    if (!root) return;
    auto tree = buildSemanticTree(root);
    QVector<const SemanticNode *> list;
    const bool synthetic = tree->role == Role::group && tree->label.isEmpty() &&
                           root->semantics == nullptr;
    std::function<void(const SemanticNode *)> flattenNode =
        [&list, &flattenNode](const SemanticNode *sn) {
            list.append(sn);
            for (const auto &ch : sn->children) flattenNode(ch.get());
        };
    if (synthetic) {
        for (const auto &ch : tree->children) flattenNode(ch.get());
    } else {
        flattenNode(tree.get());
    }
    if (!v.isArray()) return;
    const QJsonArray want = v.toArray();
    if (want.size() != list.size()) {
        c->fail(QStringLiteral("a11y: expected %1 semantic nodes, got %2")
                    .arg(want.size()).arg(list.size()));
        return;
    }
    for (int i = 0; i < want.size(); ++i)
        checkSemNode(c, want[i], *list[i]);
}

static void checkSemNode(Check *c, const QJsonValue &ev, const SemanticNode &got) {
    if (auto r = str(getProp(ev, QStringLiteral("role")))) {
        bool ok = false;
        const Role want = roleFromName(*r, &ok);
        if (got.role != want)
            c->fail(QStringLiteral("a11y role: expected \"%1\", got \"%2\"")
                        .arg(*r, roleName(got.role)));
    }
    if (auto l = str(getProp(ev, QStringLiteral("label")))) {
        if (got.label != *l)
            c->fail(QStringLiteral("a11y label: expected \"%1\", got \"%2\"").arg(*l, got.label));
    }
    if (auto t = str(getProp(ev, QStringLiteral("hint")))) {
        if (got.hint != *t)
            c->fail(QStringLiteral("a11y hint: expected \"%1\", got \"%2\"").arg(*t, got.hint));
    }
    if (auto t = str(getProp(ev, QStringLiteral("value")))) {
        if (got.value != *t)
            c->fail(QStringLiteral("a11y value: expected \"%1\", got \"%2\"").arg(*t, got.value));
    }
    if (getProp(ev, QStringLiteral("checked")).isDouble() ||
        getProp(ev, QStringLiteral("checked")).isBool()) {
        const bool want = boolean(getProp(ev, QStringLiteral("checked")), false);
        const bool g = got.checked.value_or(false);
        if (g != want)
            c->fail(QStringLiteral("a11y checked: expected %1, got %2").arg(boolStr(want), boolStr(g)));
    }
    if (getProp(ev, QStringLiteral("focusable")).isBool() ||
        getProp(ev, QStringLiteral("focusable")).isDouble()) {
        const bool want = boolean(getProp(ev, QStringLiteral("focusable")), false);
        if (got.focusable != want)
            c->fail(QStringLiteral("a11y focusable: expected %1, got %2").arg(boolStr(want), boolStr(got.focusable)));
    }
    if (getProp(ev, QStringLiteral("disabled")).isBool() ||
        getProp(ev, QStringLiteral("disabled")).isDouble()) {
        const bool want = boolean(getProp(ev, QStringLiteral("disabled")), false);
        if (got.disabled != want)
            c->fail(QStringLiteral("a11y disabled: expected %1, got %2").arg(boolStr(want), boolStr(got.disabled)));
    }
}

static QString bridgeKindStr(BridgeEvent::Kind k) {
    return bridgeKindName(k);
}

static void expectA11yEvents(Harness *h, Check *c, const QJsonValue &v) {
    if (!v.isArray()) return;
    const QJsonArray want = v.toArray();
    for (int i = 0; i < want.size(); ++i) {
        if (i >= h->lb.events.size()) {
            c->fail(QStringLiteral("a11y_events[%1]: expected \"%2\", log ended at %3 events")
                        .arg(i).arg(strOr(getProp(want[i], QStringLiteral("kind")), QStringLiteral("?")))
                        .arg(h->lb.events.size()));
            return;
        }
        const auto &got = h->lb.events[i];
        if (auto k = str(getProp(want[i], QStringLiteral("kind")))) {
            if (bridgeKindStr(got.kind) != *k) {
                c->fail(QStringLiteral("a11y_events[%1]: expected kind \"%2\", got \"%3\"")
                            .arg(i).arg(*k, bridgeKindStr(got.kind)));
                return;
            }
        }
        if (auto t = str(getProp(want[i], QStringLiteral("text")))) {
            if (got.text != *t) {
                c->fail(QStringLiteral("a11y_events[%1]: expected text \"%2\", got \"%3\"")
                            .arg(i).arg(*t, got.text));
                return;
            }
        }
    }
    if (h->lb.events.size() != want.size()) {
        c->fail(QStringLiteral("a11y_events: expected %1 events, got %2")
                    .arg(want.size()).arg(h->lb.events.size()));
    }
}

static void expectText(Harness *h, Check *c, const QJsonValue &v) {
    if (!v.isObject()) return;
    const QJsonObject o = v.toObject();
    for (auto it = o.begin(); it != o.end(); ++it) {
        KxNode *n = liveNode(h, c, it.key());
        if (!n) continue;
        if (!n->semantics) {
            c->fail(QStringLiteral("text.%1: node has no semantics").arg(it.key()));
            continue;
        }
        const QString got = !n->semantics->label.isEmpty() ? n->semantics->label
                                                         : n->semantics->value;
        const QString want = strOr(it.value(), QString());
        if (got != want)
            c->fail(QStringLiteral("text.%1: expected \"%2\", got \"%3\"").arg(it.key(), want, got));
    }
}

/// i18n service calls: "tr:key" / "plural:key:N" / "num:V[:opts]" /
/// "date:Y-M-D:kind" / "direction".
static void expectI18n(Harness *h, Check *c, const QJsonValue &v) {
    if (!h->i18n) {
        c->fail(QStringLiteral("i18n expects require setup.i18n"));
        return;
    }
    if (!v.isObject()) return;
    const QJsonObject o = v.toObject();
    for (auto it = o.begin(); it != o.end(); ++it) {
        const QString want = strOr(it.value(), QString());
        QString got;
        const QString &name = it.key();
        if (name == "direction") {
            got = h->i18n->dir() == Direction::rtl ? QStringLiteral("rtl") : QStringLiteral("ltr");
        } else if (name.startsWith(QStringLiteral("tr:"))) {
            got = h->i18n->tr(name.mid(3));
        } else if (name.startsWith(QStringLiteral("plural:"))) {
            const QString rest = name.mid(7);
            const int ci = rest.lastIndexOf(':');
            if (ci >= 0) {
                const qint64 n = rest.mid(ci + 1).toLongLong();
                got = h->i18n->trPlural(rest.left(ci), n);
            }
        } else if (name.startsWith(QStringLiteral("num:"))) {
            const QString rest = name.mid(4);
            NumberOptions opts;
            QString valstr = rest;
            const int ci = rest.indexOf(':');
            if (ci >= 0) {
                valstr = rest.left(ci);
                for (const QString &tok : rest.mid(ci + 1).split(',')) {
                    if (tok == "pct") opts.percent = true;
                    if (tok == "nogroup") opts.grouping = false;
                    if (tok.startsWith("dec=")) opts.decimals = static_cast<quint8>(tok.mid(4).toInt());
                }
            }
            KxLocale *loc = h->i18n->locale();
            if (!loc) continue;
            got = loc->formatNumber(valstr.toDouble(), opts);
        } else if (name.startsWith(QStringLiteral("date:"))) {
            const QString rest = name.mid(5);
            // "date:2024-03-05:long"
            const int ci = rest.lastIndexOf(':');
            if (ci >= 0) {
                const QString kind_s = rest.mid(ci + 1);
                const DateKind kind = kind_s == "long" ? DateKind::long_
                                    : kind_s == "medium" ? DateKind::medium : DateKind::short_;
                const QStringList ymd = rest.left(ci).split('-');
                Date d;
                d.year = ymd.value(0).toInt();
                d.month = static_cast<quint8>(ymd.value(1).toInt());
                d.day = static_cast<quint8>(ymd.value(2).toInt());
                KxLocale *loc = h->i18n->locale();
                if (!loc) continue;
                got = loc->formatDate(d, kind);
            }
        }
        if (got != want) {
            c->fail(QStringLiteral("i18n.%1: expected \"%2\", got \"%3\"").arg(name, want, got));
        }
    }
}

static void expectPixels(Harness *h, Check *c, const QJsonValue &v) {
    if (!v.isArray()) return;
    Frame frame = h->renderFrame();
    const QJsonArray arr = v.toArray();
    for (int i = 0; i < arr.size(); ++i) {
        const QJsonValue &pv = arr[i];
        const auto want_o = parseColor(getProp(pv, QStringLiteral("color")));
        if (!want_o) {
            c->fail(QStringLiteral("pixels[%1]: missing color").arg(i));
            continue;
        }
        const Color want = *want_o;
        const Color got = frame.pixelAt(static_cast<int>(num(getProp(pv, QStringLiteral("x")), 0)),
                                        static_cast<int>(num(getProp(pv, QStringLiteral("y")), 0)));
        const bool approx = boolean(getProp(pv, QStringLiteral("approx")), false);
        const bool ok = approx
            ? (channelDiff(got, want, 24) <= 2 && channelDiff(got, want, 16) <= 2 &&
               channelDiff(got, want, 8) <= 2 && channelDiff(got, want, 0) <= 2)
            : got == want;
        if (!ok) {
            c->fail(QStringLiteral("pixels[%1] at (%2,%3): expected #%4, got #%5")
                        .arg(i)
                        .arg(num(getProp(pv, QStringLiteral("x")), 0))
                        .arg(num(getProp(pv, QStringLiteral("y")), 0))
                        .arg(want, 8, 16, QLatin1Char('0'))
                        .arg(got, 8, 16, QLatin1Char('0')));
        }
    }
}

static void expectPixelCounts(Harness *h, Check *c, const QJsonValue &v) {
    if (!v.isArray()) return;
    Frame frame = h->renderFrame();
    const QJsonArray arr = v.toArray();
    for (int i = 0; i < arr.size(); ++i) {
        const QJsonValue &pv = arr[i];
        const auto color_o = parseColor(getProp(pv, QStringLiteral("color")));
        if (!color_o) {
            c->fail(QStringLiteral("pixel_counts[%1]: missing color").arg(i));
            continue;
        }
        const Color color = *color_o;
        const auto rect = parseRect(getProp(pv, QStringLiteral("rect")));
        const quint64 n = rect ? frame.countColorIn(*rect, color) : frame.countColor(color);
        if (getProp(pv, QStringLiteral("exact")).isDouble()) {
            const quint64 want = static_cast<quint64>(std::max<qint64>(0, intOf(getProp(pv, QStringLiteral("exact")), 0)));
            if (n != want)
                c->fail(QStringLiteral("pixel_counts[%1]: expected exactly %2 of #%3, got %4")
                            .arg(i).arg(want).arg(color, 8, 16, QLatin1Char('0')).arg(n));
        }
        if (getProp(pv, QStringLiteral("min")).isDouble()) {
            const quint64 want = static_cast<quint64>(std::max<qint64>(0, intOf(getProp(pv, QStringLiteral("min")), 0)));
            if (n < want)
                c->fail(QStringLiteral("pixel_counts[%1]: expected ≥%2 of #%3, got %4")
                            .arg(i).arg(want).arg(color, 8, 16, QLatin1Char('0')).arg(n));
        }
        if (getProp(pv, QStringLiteral("max")).isDouble()) {
            const quint64 want = static_cast<quint64>(std::max<qint64>(0, intOf(getProp(pv, QStringLiteral("max")), 0)));
            if (n > want)
                c->fail(QStringLiteral("pixel_counts[%1]: expected ≤%2 of #%3, got %4")
                            .arg(i).arg(want).arg(color, 8, 16, QLatin1Char('0')).arg(n));
        }
    }
}

static void expectScroll(Harness *h, Check *c, const QJsonValue &v) {
    if (!v.isObject()) return;
    const QJsonObject o = v.toObject();
    for (auto it = o.begin(); it != o.end(); ++it) {
        KxNode *n = liveNode(h, c, it.key());
        if (!n) continue;
        const ScrollKind kind = h->scroll_kind.value(it.key(), ScrollKind::view);
        const float got = kind == ScrollKind::view ? scrollViewOffset(n) : listViewOffset(n);
        const float want = num(it.value(), 0);
        if (!nearEq(got, want, c->tol))
            c->fail(QStringLiteral("scroll.%1: expected %2, got %3").arg(it.key(), fmtN(want), fmtN(got)));
    }
}

/// scroll_info: {id: {"offset":N,"max_offset":N,"viewport":N,"content":N,
/// "thumb":N}} — reads the scrollable's generic vtable hook.
static void expectScrollInfo(Harness *h, Check *c, const QJsonValue &v) {
    if (!v.isObject()) return;
    const QJsonObject o = v.toObject();
    static const char *const fields[] = {"offset", "max_offset", "viewport", "content", "thumb"};
    for (auto it = o.begin(); it != o.end(); ++it) {
        KxNode *n = liveNode(h, c, it.key());
        if (!n) continue;
        ScrollInfo info;
        if (!n->scrollInfo(&info)) {
            c->fail(QStringLiteral("scroll_info.%1: node is not scrollable").arg(it.key()));
            continue;
        }
        if (!it.value().isObject()) continue;
        const QJsonObject fo = it.value().toObject();
        for (const char *fname_c : fields) {
            const QString fname = QString::fromLatin1(fname_c);
            if (!fo.contains(fname)) continue;
            float got;
            if (fname == "thumb") got = info.thumbFraction();
            else if (fname == "offset") got = info.offset;
            else if (fname == "max_offset") got = info.max_offset;
            else if (fname == "viewport") got = info.viewport;
            else got = info.content;
            const float want = num(fo.value(fname), 0);
            if (!nearEq(got, want, c->tol))
                c->fail(QStringLiteral("scroll_info.%1.%2: expected %3, got %4")
                            .arg(it.key(), fname, fmtN(want), fmtN(got)));
        }
    }
}

static void expectChildren(Harness *h, Check *c, const QJsonValue &v) {
    if (!v.isObject()) return;
    const QJsonObject o = v.toObject();
    for (auto it = o.begin(); it != o.end(); ++it) {
        KxNode *n = liveNode(h, c, it.key());
        if (!n) continue;
        const size_t want = static_cast<size_t>(std::max<qint64>(0, intOf(it.value(), 0)));
        if (n->children.size() != want)
            c->fail(QStringLiteral("children.%1: expected %2, got %3")
                        .arg(it.key()).arg(want).arg(n->children.size()));
    }
}

static void expectFirstItem(Harness *h, Check *c, const QJsonValue &v) {
    if (!v.isObject()) return;
    const QJsonObject o = v.toObject();
    for (auto it = o.begin(); it != o.end(); ++it) {
        KxNode *n = liveNode(h, c, it.key());
        if (!n) continue;
        if (n->children.empty()) {
            c->fail(QStringLiteral("first_item.%1: no live items").arg(it.key()));
            continue;
        }
        auto *box = dynamic_cast<BoxNode *>(n->children[0]);
        const size_t got = box ? box->item_index : ~size_t(0);
        const size_t want = static_cast<size_t>(std::max<qint64>(0, intOf(it.value(), 0)));
        if (got != want)
            c->fail(QStringLiteral("first_item.%1: expected %2, got %3")
                        .arg(it.key()).arg(want).arg(got));
    }
}

static void expectNav(Harness *h, Check *c, const QJsonValue &v) {
    if (!h->nav) {
        c->fail(QStringLiteral("nav expects require setup.navigator"));
        return;
    }
    if (!v.isObject()) return;
    if (getProp(v, QStringLiteral("depth")).isDouble()) {
        const size_t want = static_cast<size_t>(std::max<qint64>(0, intOf(getProp(v, QStringLiteral("depth")), 0)));
        if (h->nav->depth() != want)
            c->fail(QStringLiteral("nav.depth: expected %1, got %2").arg(want).arg(h->nav->depth()));
    }
    if (auto want = str(getProp(v, QStringLiteral("current")))) {
        const Page *cur = h->nav->current();
        const QString got = cur ? cur->route.path : QString();
        if (got != *want)
            c->fail(QStringLiteral("nav.current: expected \"%1\", got \"%2\"").arg(*want, got));
    }
    if (getProp(v, QStringLiteral("params")).isObject()) {
        const Page *cur = h->nav->current();
        if (!cur) {
            c->fail(QStringLiteral("nav.params: stack empty"));
            return;
        }
        const QJsonObject po = getProp(v, QStringLiteral("params")).toObject();
        for (auto it = po.begin(); it != po.end(); ++it) {
            const QString got = cur->route.params.get(it.key());
            if (got != strOr(it.value(), QString()))
                c->fail(QStringLiteral("nav.params.%1: expected \"%2\", got \"%3\"")
                            .arg(it.key(), strOr(it.value(), QString()), got));
        }
    }
}

// --- the runner --------------------------------------------------------------------

struct TestResult {
    QString id, domain, rule;
    bool passed = false;
    QStringList failures;
};

static void checkExpect(Harness *h, Check *c, const QString &key, const QJsonValue &v) {
    if (key == "rects") {
        expectRects(h, c, v);
    } else if (key == "measured") {
        expectMeasured(h, c, v);
    } else if (key == "damage") {
        expectDamage(h, c, v);
    } else if (key == "focused") {
        expectFocused(h, c, v, false);
    } else if (key == "router_focused") {
        expectFocused(h, c, v, true);
    } else if (key == "focus_order") {
        expectFocusOrder(h, c, v);
    } else if (key == "gestures") {
        if (v.isArray()) expectSeq(c, "gestures", v.toArray(), h->gestures);
    } else if (key == "events") {
        if (v.isArray()) expectSeq(c, "events", v.toArray(), h->events);
    } else if (key == "effect_log") {
        if (v.isArray()) expectSeq(c, "effect_log", v.toArray(), h->effect_log);
    } else if (key == "signals") {
        expectSignals(h, c, v);
    } else if (key == "memo_value") {
        if (!h->memo) {
            c->fail(QStringLiteral("memo_value: no memo in setup"));
            return;
        }
        const qint64 want = intOf(v, 0);
        if (h->memo->get() != want)
            c->fail(QStringLiteral("memo_value: expected %1, got %2").arg(want).arg(h->memo->get()));
    } else if (key == "a11y") {
        flattenSem(h, c, v);
    } else if (key == "a11y_events") {
        expectA11yEvents(h, c, v);
    } else if (key == "text") {
        expectText(h, c, v);
    } else if (key == "i18n") {
        expectI18n(h, c, v);
    } else if (key == "pixels") {
        expectPixels(h, c, v);
    } else if (key == "pixel_counts") {
        expectPixelCounts(h, c, v);
    } else if (key == "scroll") {
        expectScroll(h, c, v);
    } else if (key == "scroll_info") {
        expectScrollInfo(h, c, v);
    } else if (key == "children") {
        expectChildren(h, c, v);
    } else if (key == "first_item") {
        expectFirstItem(h, c, v);
    } else if (key == "nav") {
        expectNav(h, c, v);
    } else if (key == "action_error") {
        const QString want = strOr(v, QString());
        const QString got = h->last_error;
        if (got != want)
            c->fail(QStringLiteral("action_error: expected \"%1\", got \"%2\"").arg(want, got));
    } else {
        c->fail(QStringLiteral("unknown expect key \"%1\"").arg(key));
    }
}

static QString runTestInner(Harness &h, const QJsonValue &tv) {
    h.init();
    const QJsonValue setup = getProp(tv, QStringLiteral("setup"));
    const QJsonObject so = setup.isObject() ? setup.toObject() : empty_obj;
    if (auto vp = parseAlign(so.value("viewport"))) {
        h.viewport.w = vp->x;
        h.viewport.h = vp->y;
    }
    QString e;
    e = setupSignals(&h, so.value("signals"));
    if (e.isEmpty()) e = setupI18n(&h, so.value("i18n"));
    if (e.isEmpty()) e = setupNavigator(&h, so.value("navigator"));
    if (e.isEmpty()) e = setupEffects(&h, so.value("effects"));
    if (e.isEmpty()) e = setupMemo(&h, so.value("memo"));
    if (!e.isEmpty()) return e;

    if (so.contains("tree")) {
        const QString be = buildNode(&h, so.value("tree"), &h.root);
        if (!be.isEmpty()) return be;
        h.fm.setRoot(h.root);
        h.surface.setRoot(h.root);
        h.root->layout(h.viewport);
        h.root->clearDamage(); // frame-0 boundary: actions observe a clean accumulator
    }

    const QJsonValue actions = getProp(tv, QStringLiteral("actions"));
    if (actions.isArray()) {
        for (const QJsonValue &av : actions.toArray()) runAction(&h, av);
    }
    return QString();
}

static void runChecks(Harness &h, Check *c, const QJsonValue &tv) {
    const QJsonValue expect = getProp(tv, QStringLiteral("expect"));
    if (!expect.isObject()) return;
    const QJsonObject eo = expect.toObject();
    for (auto it = eo.begin(); it != eo.end(); ++it)
        checkExpect(&h, c, it.key(), it.value());
}

static const float DEFAULT_TOLERANCE = 0.01f;

/// Run one test vector.
static TestResult runTest(const QJsonValue &tv) {
    TestResult res;
    res.id = strOr(getProp(tv, QStringLiteral("id")), QStringLiteral("?"));
    res.domain = strOr(getProp(tv, QStringLiteral("domain")), QStringLiteral("?"));
    res.rule = strOr(getProp(tv, QStringLiteral("rule")), QString());

    Check c{&res.failures, num(getProp(tv, QStringLiteral("tolerance")), DEFAULT_TOLERANCE)};
    Harness h;
    const QString e = runTestInner(h, tv);
    if (!e.isEmpty()) {
        c.fail(QStringLiteral("error: %1").arg(e));
    } else {
        runChecks(h, &c, tv);
    }
    h.deinit();
    res.passed = res.failures.isEmpty();
    return res;
}

// --- the driver (src/conformance_main.zig) ----------------------------------------

/// The corpus is one file per domain — fixed names keep the run order (and
/// the per-domain report) deterministic.
static const char *const DOMAIN_FILES[] = {
    "layout.json", "paint.json", "gestures.json", "i18n.json", "focus.json",
    "a11y.json", "navigation.json", "scrolling.json", "state.json",
};

struct Options {
    QString dir = QStringLiteral("conformance/tests");
    QString file;
    QString filter;
    QString out;
    bool report = true;
    double min_score = 100;
    bool verbose = false;
};

struct DomainScore {
    QString domain;
    quint32 pass = 0, fail = 0;
};

/// Insertion-ordered by_domain (Zig records domains in encounter order).
static DomainScore *domainSlot(QVector<DomainScore> &v, const QString &domain) {
    for (auto &d : v) if (d.domain == domain) return &d;
    v.append({domain, 0, 0});
    return &v.last();
}

static QString jsonEscape(const QString &s) {
    QString out;
    out.reserve(s.size() + 2);
    for (const QChar &ch : s) {
        if (ch == '"') out += QStringLiteral("\\\"");
        else if (ch == '\\') out += QStringLiteral("\\\\");
        else if (ch == '\n') out += QStringLiteral("\\n");
        else out += ch;
    }
    return out;
}

static int runFile(const QString &path, const Options &opts,
                   QVector<TestResult> *results,
                   QVector<DomainScore> *by_domain,
                   QString *err) {
    QFile f(path);
    if (!f.open(QIODevice::ReadOnly)) {
        *err = QStringLiteral("CannotOpenFile");
        return -1;
    }
    const QByteArray text = f.readAll();
    QJsonParseError perr;
    const QJsonDocument doc = QJsonDocument::fromJson(text, &perr);
    if (perr.error != QJsonParseError::NoError || !doc.isObject()) {
        *err = QStringLiteral("BadJson");
        return -1;
    }
    const QJsonValue tests = doc.object().value(QStringLiteral("tests"));
    if (!tests.isArray()) {
        *err = QStringLiteral("NoTests");
        return -1;
    }
    for (const QJsonValue &tv : tests.toArray()) {
        const QString id = strOr(getProp(tv, QStringLiteral("id")), QStringLiteral("?"));
        if (!opts.filter.isEmpty() && !id.contains(opts.filter)) continue;
        const TestResult res = runTest(tv);
        results->append(res);
        DomainScore *ds = domainSlot(*by_domain, res.domain);
        if (res.passed) ds->pass += 1; else ds->fail += 1;
    }
    return 0;
}

int main(int argc, char *argv[]) {
    // Offscreen by default: the QWidget + raster stack runs headless
    // (QT_QPA_PLATFORM=offscreen — run.sh exports it too).
    if (!qEnvironmentVariableIsSet("QT_QPA_PLATFORM"))
        qputenv("QT_QPA_PLATFORM", "offscreen");
    QApplication app(argc, argv);

    Options opts;
    const QStringList args = QCoreApplication::arguments();
    for (const QString &arg : args.mid(1)) {
        if (arg.startsWith("--dir=")) opts.dir = arg.mid(6);
        else if (arg.startsWith("--file=")) opts.file = arg.mid(7);
        else if (arg.startsWith("--test=")) opts.filter = arg.mid(7);
        else if (arg.startsWith("--out=")) opts.out = arg.mid(6);
        else if (arg == "--no-report") opts.report = false;
        else if (arg.startsWith("--min-score=")) opts.min_score = arg.mid(12).toDouble();
        else if (arg == "--verbose") opts.verbose = true;
    }

    QVector<TestResult> results;
    QVector<DomainScore> by_domain;
    QStringList skipped_files;

    QTextStream out(stdout);
    if (!opts.file.isEmpty()) {
        QString err;
        if (runFile(opts.file, opts, &results, &by_domain, &err) != 0) {
            out << "klaxon-qt conformance: cannot run " << opts.file << ": " << err << "\n";
            return 2;
        }
    } else {
        for (const char *name : DOMAIN_FILES) {
            const QString path = opts.dir + QLatin1Char('/') + QLatin1String(name);
            QString err;
            if (runFile(path, opts, &results, &by_domain, &err) != 0) {
                skipped_files.append(QStringLiteral("%1 (%2)").arg(QLatin1String(name), err));
            }
        }
    }

    // --- console summary ---
    quint32 total = 0, passed = 0;
    for (const TestResult &r : results) {
        total += 1;
        if (r.passed) passed += 1;
        if (opts.verbose || !r.passed) {
            out << (r.passed ? "PASS " : "FAIL ") << r.id;
            for (const QString &f : r.failures) out << " — " << f;
            out << "\n";
        }
    }
    for (const DomainScore &s : by_domain) {
        out << "  " << s.domain.leftJustified(11) << " " << s.pass << "/" << (s.pass + s.fail) << "\n";
    }
    const double score = total == 0 ? 0.0 : passed * 100.0 / total;
    out << QString("klaxon-qt conformance: %1/%2 passed (%3%)")
               .arg(passed).arg(total).arg(score, 0, 'f', 1) << "\n";
    for (const QString &s : skipped_files) out << "  (skipped " << s << ")\n";

    if (opts.report && total > 0) {
        const QString ts = QDateTime::currentDateTimeUtc().toString("yyyy-MM-ddTHH-mm-ss");
        const QString out_path = !opts.out.isEmpty()
            ? opts.out
            : QStringLiteral("conformance/results-qt-%1.json").arg(ts);
        QString json;
        json += "{\n  \"framework\": \"qt6\",\n  \"version\": \"p0\",\n";
        json += QString("  \"timestamp\": \"%1\",\n  \"score_pct\": %2,\n")
                    .arg(ts).arg(score, 0, 'f', 2);
        json += "  \"by_domain\": {";
        bool first = true;
        for (const DomainScore &s : by_domain) {
            if (!first) json += ",";
            first = false;
            json += QString("\n    \"%1\": {\"pass\": %2, \"fail\": %3}")
                        .arg(s.domain).arg(s.pass).arg(s.fail);
        }
        json += "\n  },\n  \"tests\": [\n";
        for (int i = 0; i < results.size(); ++i) {
            const TestResult &r = results[i];
            if (i > 0) json += ",\n";
            json += QString("    {\"id\": \"%1\", \"domain\": \"%2\", \"rule\": \"%3\", \"passed\": %4")
                        .arg(r.id, r.domain, r.rule, r.passed ? "true" : "false");
            if (!r.failures.isEmpty()) {
                json += ", \"failures\": [";
                for (int j = 0; j < r.failures.size(); ++j) {
                    if (j > 0) json += ", ";
                    json += '"' + jsonEscape(r.failures[j]) + '"';
                }
                json += "]";
            }
            json += "}";
        }
        json += "\n  ]\n}\n";
        const QString dir = QFileInfo(out_path).absolutePath();
        QDir().mkpath(dir);
        QFile rf(out_path);
        if (rf.open(QIODevice::WriteOnly)) {
            rf.write(json.toUtf8());
            out << "  report: " << out_path << "\n";
        } else {
            out << "klaxon-qt conformance: cannot write '" << out_path << "'\n";
            return 2;
        }
    }

    if (score < opts.min_score) return 1;
    if (total == 0) return 2;
    return 0;
}
