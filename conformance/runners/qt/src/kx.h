// kx.h — Qt6 port of the Klaxon UI core exercised by the conformance suite.
//
// This header mirrors the Zig sources under src/ui/ + src/widgets/ as
// closely as C++ allows: same type names, same algorithms, same ordering.
// Qt supplies the platform primitives — QPainter rasterisation into a
// QImage (the real Qt Widgets paint path, run offscreen), QFontMetricsF for
// text metrics, Qt event types at the driver boundary — while the DSL
// contract itself (layout, dispatch, damage, signals, a11y, gestures,
// scrolling, i18n, navigation) runs through this ported engine so vector
// expectations measure Klaxon semantics, not Qt widget defaults.
//
// Coordinates are logical pixels, origin top-left. Colors are 0xRRGGBBAA
// (R in the high byte, alpha in the low byte) — the corpus convention.
#pragma once

#include <QtCore/QHash>
#include <QtCore/QJsonObject>
#include <QtCore/QString>
#include <QtCore/QVector>
#include <QtCore/QtMath>
#include <QtGui/QColor>
#include <QtGui/QFont>
#include <QtGui/QFontMetricsF>
#include <QtGui/QImage>
#include <QtGui/QPainter>
#include <QtWidgets/QWidget>

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <functional>
#include <limits>
#include <memory>
#include <optional>
#include <vector>

namespace kx {

class KxNode;
class Effect;
class SignalBase;
class InputRouter;
class FocusManager;
class I18n;
class Timeline;
struct ScrollInfo;
template <typename T> class Signal;

// ---------------------------------------------------------------------------
// Geometry + constraints (src/ui/node.zig Rect + src/ui/layout.zig)
// ---------------------------------------------------------------------------

using Color = quint32; // 0xRRGGBBAA

enum class Axis { horizontal, vertical };
enum class Direction { ltr, rtl };

struct Rect {
    float x = 0, y = 0, w = 0, h = 0;
    bool contains(float px, float py) const {
        return px >= x && px < x + w && py >= y && py < y + h;
    }
    float main(Axis a) const { return a == Axis::horizontal ? w : h; }
    float cross(Axis a) const { return a == Axis::horizontal ? h : w; }
};

Rect rectUnion(const Rect &a, const Rect &b);
Rect rectIntersect(const Rect &a, const Rect &b);
bool rectOverlaps(const Rect &a, const Rect &b);
Rect rectNormalize(const Rect &r);

struct Size {
    float w = 0, h = 0;
    float main(Axis a) const { return a == Axis::horizontal ? w : h; }
    float cross(Axis a) const { return a == Axis::horizontal ? h : w; }
    static Size fromMainCross(Axis a, float m, float c) {
        return a == Axis::horizontal ? Size{m, c} : Size{c, m};
    }
};

struct EdgeInsets {
    float left = 0, top = 0, right = 0, bottom = 0;
    static EdgeInsets all(float v) { return {v, v, v, v}; }
    float hSum() const { return left + right; }
    float vSum() const { return top + bottom; }
};

struct EdgeInsetsDirectional {
    float start = 0, end = 0, top = 0, bottom = 0;
    EdgeInsets resolve(Direction dir) const;
};

struct Constraints {
    float min_w = 0;
    float max_w = std::numeric_limits<float>::infinity();
    float min_h = 0;
    float max_h = std::numeric_limits<float>::infinity();

    Size constrain(Size s) const;
    Constraints deflate(float amount) const;
    Constraints deflateEdge(const EdgeInsets &e) const;
    Constraints enforcedBy(const Constraints &add) const;
    Constraints loosenMain(Axis a) const;
    Constraints loosen() const { return {0, max_w, 0, max_h}; }
};

enum class MainAlign { start, center, end, space_between, space_around, space_evenly };
enum class CrossAlign { start, center, end, stretch };
enum class TextAlign { left, center, right, start, end };

TextAlign resolveAlign(TextAlign a, Direction dir);

/// 9-point alignment: x/y in [-1, 1].
struct Alignment {
    float x = 0, y = 0;
    Rect position(const Rect &bounds, Size s) const;
    Alignment mirrored(Direction dir) const {
        return dir == Direction::ltr ? *this : Alignment{-x, y};
    }
    static Alignment topLeft() { return {-1, -1}; }
    static Alignment center() { return {0, 0}; }
};

// The process-global text direction (set by I18n).
Direction direction();

/// Flex measure + layout (ui/layout.zig) — shared by Row/Column.
Size flexMeasure(KxNode *n, const Constraints &c, Axis axis, float gap, float padding);
void flexLayout(KxNode *n, const Rect &bounds, Axis axis, float gap, float padding,
                MainAlign main_align, CrossAlign cross_align);

// ---------------------------------------------------------------------------
// Paint (src/ui/paint.zig) — the "ctx" is a QPainter on a raster surface
// ---------------------------------------------------------------------------

struct TextMetrics {
    float width = 0, height = 0, ascent = 0;
};

TextMetrics measureText(const QString &str, float size, bool bold);
void drawText(QPainter &p, const QString &str, float x, float baseline_y,
              float size, bool bold, Color color);
void fillRect(QPainter &p, float x, float y, float w, float h, Color color);
void fillRRect(QPainter &p, float x, float y, float w, float h, float radius, Color color);
/// save + intersect-clip (balanced with clipReset).
void clipRect(QPainter &p, float x, float y, float w, float h);
void clipReset(QPainter &p);

inline QColor toQColor(Color c) {
    return QColor::fromRgba(((c & 0xFF) << 24) | ((c >> 8) & 0xFFFFFF));
}

/// ±2-per-channel diff helper (golden.zig channelDiff / expectPixelApprox).
int channelDiff(Color a, Color b, int shift);

// ---------------------------------------------------------------------------
// Frame — an RGBA readback (src/golden.zig Frame)
// ---------------------------------------------------------------------------

class Frame {
public:
    Frame() = default;
    explicit Frame(const QImage &img); // stored as Format_RGBA8888
    Color pixelAt(int x, int y) const;
    quint64 countColor(Color color) const;
    quint64 countNot(Color color) const;
    quint64 countColorIn(Rect rect, Color color) const;
    quint64 countNotIn(Rect rect, Color color) const;
    quint64 countColorApproxIn(Rect rect, Color color) const;
    int w = 0, h = 0;

private:
    QImage img_;
    Rect clipToFrame(Rect r) const;
};

// ---------------------------------------------------------------------------
// Input events (src/ui/input.zig)
// ---------------------------------------------------------------------------

enum class PointerPhase { down, move, up, enter, leave, outside_down, hover_move };

struct PointerEvent {
    PointerPhase phase = PointerPhase::down;
    float x = 0, y = 0;
    /// Window-space coordinates before ancestor transforms.
    float raw_x = 0, raw_y = 0;
    quint8 button = 1;
    quint64 pointer = 0; // 0 = primary
    quint64 time_ms = 0;
};

/// Platform-independent keys (same codes as the Zig enum(u32)).
enum class Key : quint32 {
    unknown = 0,
    backspace = 0x08,
    tab = 0x09,
    enter = 0x0D,
    escape = 0x1B,
    del = 0x7F,
    left = 0x100,
    right = 0x101,
    back = 0x102,
    up = 0x103,
    down = 0x104,
    space = 0x20,
};

struct KeyEvent {
    enum class Kind { key_down, text_input } kind = Kind::key_down;
    Key key = Key::unknown;
    QString text; // text_input payload
    bool shift = false;
};

struct ScrollEvent {
    float x = 0, y = 0;
    float delta_x = 0, delta_y = 0;
    quint64 pointer = 0;
    quint64 time_ms = 0;
};

struct HitPoint {
    float x = 0, y = 0;
};

// ---------------------------------------------------------------------------
// Semantics (src/ui/semantics.zig)
// ---------------------------------------------------------------------------

enum class Role {
    none, text, heading, button, link, image, text_field, toggle, checkbox,
    radio, slider, progress, scrollbar, list, list_item, dialog, alert, menu,
    menu_item, tab, tab_panel, separator, group,
};
QString roleName(Role r);
Role roleFromName(const QString &s, bool *ok = nullptr);

enum class Action : quint32 { activate = 0, increment, decrement, delete_ };
inline quint32 actionBit(Action a) { return 1u << static_cast<quint32>(a); }
Action actionFromName(const QString &s, bool *ok = nullptr);

enum class LiveRegion { off, polite, assertive };

struct Semantics {
    Role role = Role::none;
    QString label, hint, value;
    std::optional<bool> checked;
    bool disabled = false;
    bool focusable = false;
    quint32 actions = 0;
    LiveRegion live = LiveRegion::off;
};

struct SemanticNode {
    KxNode *node = nullptr;
    Role role = Role::none;
    QString label, hint, value;
    std::optional<bool> checked;
    bool disabled = false;
    bool focusable = false;
    quint32 actions = 0;
    LiveRegion live = LiveRegion::off;
    std::vector<std::unique_ptr<SemanticNode>> children;
};

std::unique_ptr<SemanticNode> buildSemanticTree(KxNode *root);
/// semantics.attach — takes ownership of a copy of `sem` (frees the old).
void attach(KxNode *n, const Semantics &sem);

// --- bridge + live regions ---

struct BridgeEvent {
    enum class Kind { tree_dirty, focus_changed, announce, control_changed } kind;
    KxNode *node = nullptr;
    QString text;
    LiveRegion region = LiveRegion::off;
};
QString bridgeKindName(BridgeEvent::Kind k);

using BridgeFn = std::function<void(const BridgeEvent &)>;
void setBridge(BridgeFn fn); // nullptr clears
void notifyTreeDirty();
void announce(const QString &text, LiveRegion region);
void notifyControlChanged(KxNode *n);

/// Records every bridge event (conformance + headless tests).
class LogBridge {
public:
    struct LoggedEvent {
        BridgeEvent::Kind kind;
        quint64 node_id = 0;
        QString text;
        LiveRegion region = LiveRegion::off;
    };
    QVector<LoggedEvent> events;
    BridgeFn bridge();
};

// --- FocusManager ---

class FocusManager {
public:
    FocusManager();
    ~FocusManager();

    void setRoot(KxNode *r) { root = r; }
    QVector<KxNode *> focusOrder() const;
    void setFocused(KxNode *n); // focus signal + ring damage + bridge event
    void focusNode(KxNode *n); // semantic focus + router focus
    void onRouterFocusChanged(KxNode *n);
    void focusNext();
    void focusPrev();
    bool handleKey(const KeyEvent &ev);

    KxNode *root = nullptr;
    KxNode *focused = nullptr;
    Signal<KxNode *> *focused_sig;
    float ring_width = 2, ring_offset = 3;
    Color ring_color = 0x1C7ED6FF;
};

void setCurrentFocus(FocusManager *fm);
FocusManager *currentFocus();
void focusNodeDestroyed(KxNode *n);
void routerFocusChanged(KxNode *n);

// ---------------------------------------------------------------------------
// KxNode — retained tree node (src/ui/node.zig)
// ---------------------------------------------------------------------------

class KxNode {
public:
    KxNode() = default;
    virtual ~KxNode() = default;
    KxNode(const KxNode &) = delete;
    KxNode &operator=(const KxNode &) = delete;

    KxNode *parent = nullptr;
    std::vector<KxNode *> children;
    Rect bounds;
    bool dirty = true;
    bool layout_dirty = true;
    bool visible = true;
    quint32 flex = 0;
    Semantics *semantics = nullptr;
    bool exclude_semantics = false;
    bool internal = false;
    bool defer_paint = false;
    Rect damage;
    bool damage_valid = false;
    EdgeInsets damage_overflow;
    bool zombie = false;
    bool torn_down = false;

    // --- VTable equivalents (Zig hooks → virtuals; "no hook" → default) ---
    virtual Size onMeasure(const Constraints &c) = 0;
    virtual void onLayout(const Rect &b) { Q_UNUSED(b); }
    virtual void onPaint(QPainter &ctx) { Q_UNUSED(ctx); }
    virtual bool onPointer(const PointerEvent &ev) { Q_UNUSED(ev); return false; }
    virtual bool onKey(const KeyEvent &ev) { Q_UNUSED(ev); return false; }
    virtual bool onScroll(const ScrollEvent &ev) { Q_UNUSED(ev); return false; }
    /// Teardown hook (vtable.deinit): runs during deinitBody, after children.
    virtual void teardown() {}
    /// Scrollable hooks (scroll_info / scroll_set_offset).
    virtual bool scrollInfo(ScrollInfo *out) const;
    virtual void scrollSetOffset(float value) { Q_UNUSED(value); }
    /// Paint-pass hooks (pre/post_children_paint, child_clip, map_paint_rect,
    /// paint_bounds, hit_bounds, pre_children_hit). bool return = hook present.
    virtual void preChildrenPaint(QPainter &ctx) { Q_UNUSED(ctx); }
    virtual void postChildrenPaint(QPainter &ctx) { Q_UNUSED(ctx); }
    virtual bool mapPaintRect(Rect *r) const { Q_UNUSED(r); return false; }
    virtual bool childClip(Rect *out) const { Q_UNUSED(out); return false; }
    virtual bool paintBounds(Rect *out) const { Q_UNUSED(out); return false; }
    virtual bool hitBounds(Rect *out) const { Q_UNUSED(out); return false; }
    virtual bool preChildrenHit(float px, float py, float *ox, float *oy) const;
    virtual void paintOverlay(QPainter &ctx) { Q_UNUSED(ctx); }

    // --- tree ops ---
    void add(KxNode *child);
    void insert(size_t index, KxNode *child);
    bool remove(KxNode *child);
    void deinit(); // deferred-safe teardown (zombie queue)

    // --- layout + damage ---
    Size measure(const Constraints &c) { return onMeasure(c); }
    void layout(const Rect &b);
    void markDirty();
    void markDirtyRect(const Rect &rect);
    void markLayoutDirty();
    void clearDamage();
    /// own-paint region in parent space (paint_bounds or bounds + overflow).
    Rect paintRect() const;

    // --- paint ---
    void paint(QPainter &ctx, const Rect &visible);

    // --- hit testing ---
    KxNode *hitTest(float px, float py);
    struct MappedHit {
        KxNode *node = nullptr;
        float x = 0, y = 0;
    };
    std::optional<MappedHit> hitTestMapped(float px, float py);
    /// Window-space point → this node's parent space (ancestor transforms).
    HitPoint mapPointToParentSpace(float px, float py) const;
    /// Rect in parent space → root space (ancestor map_paint_rect chain).
    Rect mapRectToRoot(Rect r) const;

private:
    void deinitBody();
    friend void traversalEnd();
};

// Deferred-destruction traversal freeze (node.zig).
void traversalBegin();
void traversalEnd();
bool traversalActive();

// ---------------------------------------------------------------------------
// InputRouter (src/ui/input.zig)
// ---------------------------------------------------------------------------

class InputRouter {
public:
    static constexpr int MAX_POINTERS = 8;
    struct Capture {
        quint64 pointer;
        KxNode *node;
    };

    std::optional<Capture> captured[MAX_POINTERS];
    KxNode *hovered = nullptr;
    float last_x = 0, last_y = 0;
    bool has_last = false;
    KxNode *focused = nullptr;
    KxNode *open_popup = nullptr;
    std::function<bool()> back_handler;
    struct BackEntry {
        std::function<bool()> fn;
        void *key = nullptr; // for popBackHandler
    };
    BackEntry back_stack[8];
    int back_stack_len = 0;

    void dispatchPointer(KxNode *root, const PointerEvent &ev);
    bool dispatchKey(const KeyEvent &ev);
    void dispatchScroll(KxNode *root, const ScrollEvent &ev);
    bool dispatchBack();
    void captureNode(const PointerEvent &ev, KxNode *node, KxNode *except);
    KxNode *capturedNode(quint64 pointer) const;
    void refreshHover(KxNode *root);
    void clearHover();
    void releaseNode(KxNode *n);
    void focus(KxNode *n);
    KxNode *hoveredNode() const { return hovered; }
    void setBackHandler(std::function<bool()> h) { back_handler = std::move(h); }
    bool pushBackHandler(std::function<bool()> h, void *key);
    void popBackHandler(void *key);

private:
    int captureSlot(quint64 pointer) const;
    void captureSet(quint64 pointer, KxNode *node);
    void captureClear(quint64 pointer);
    void updateHover(KxNode *root, float x, float y, bool send_move);
};

void setCurrentRouter(InputRouter *r);
InputRouter *currentRouter();
void requestFocus(KxNode *n);
bool isFocused(KxNode *n);
void setOpenPopup(KxNode *n);
void releaseNodeGlobal(KxNode *n);

// ---------------------------------------------------------------------------
// Reactive state (src/ui/state.zig)
// ---------------------------------------------------------------------------

struct Subscriber {
    enum class Kind { effect, node, callback } kind = Kind::callback;
    Effect *effect = nullptr;
    KxNode *node = nullptr;
    std::function<void()> fn;  // callback
    void *key = nullptr;       // match key for callback unsubscribe
    static Subscriber forEffect(Effect *e);
    static Subscriber forNode(KxNode *n);
    static Subscriber forCallback(std::function<void()> f, void *key);
    bool same(const Subscriber &o) const;
};

class SignalBase {
public:
    void subscribe(const Subscriber &s) { subscribers.push_back(s); }
    void unsubscribe(const Subscriber &s);
    /// Notify every subscriber (snapshot + revalidate, like Zig).
    void notify();
    quint64 version = 0;
    std::vector<Subscriber> subscribers;
};

/// current effect being run (dependency tracking context).
Effect *currentEffect();
void setCurrentEffect(Effect *e);

/// Tracks `base` as a dependency of the running effect, if any. Declared
/// here (Effect is incomplete at this point) and defined in kx.cpp.
void trackDep(SignalBase *base);

template <typename T>
class Signal : public SignalBase {
public:
    explicit Signal(const T &initial) : value_(initial) {}
    T get() {
        trackDep(this);
        return value_;
    }
    T peek() const { return value_; }
    void set(const T &v) {
        if (value_ == v) return;
        value_ = v;
        notify();
    }
    void forceNotify() { notify(); }

private:
    T value_{};
};

/// Growable text channel; input over max_len is rejected (never truncated).
class TextSignal : public SignalBase {
public:
    static constexpr size_t max_len = 1 << 20;
    explicit TextSignal(const QString &initial) : value_(initial) {}
    QString get() {
        trackDep(this);
        return value_;
    }
    QString peek() const { return value_; }
    /// Returns false on TextTooLong — the old value stands.
    bool set(const QString &v) {
        if (static_cast<size_t>(v.toUtf8().size()) > max_len) return false;
        if (v == value_) return true;
        value_ = v;
        notify();
        return true;
    }
    void forceNotify() { notify(); }

private:
    QString value_;
};

class Effect {
public:
    explicit Effect(std::function<void()> fn) : fn_(std::move(fn)) {}
    ~Effect() { deinit(); }
    void run();
    void deinit();
    void track(SignalBase *base);

private:
    std::function<void()> fn_;
    std::vector<SignalBase *> deps_;
};

/// Cached derived value (state.zig Memo). Recomputes when deps change and
/// notifies its own subscribers (an effect reading get() tracks the memo).
class Memo {
public:
    explicit Memo(std::function<qint64()> compute);
    ~Memo();
    qint64 get();
    void deinit();
    SignalBase base;

private:
    std::function<qint64()> compute_;
    Effect *effect_;
    qint64 cache_ = 0;
};

/// On signal change: mark the node dirty (state.zig bindNode).
void bindNode(KxNode *node, SignalBase &sig);

// ---------------------------------------------------------------------------
// Timeline (src/ui/anim.zig — tickers only; the corpus has no animations)
// ---------------------------------------------------------------------------

class Timeline {
public:
    struct Ticker {
        quint64 id = 0;
        std::function<void(quint64)> fn;
        std::function<bool()> has_pending;
        bool active = true;
    };
    quint64 addTicker(std::function<void(quint64)> fn, std::function<bool()> has_pending = {});
    void removeTicker(quint64 id);
    void tick(quint64 now_ms);
    bool hasTimedWork() const;
    quint64 last_now_ms = 0;

private:
    std::vector<Ticker> tickers_;
    quint64 next_id_ = 1;
};

void setCurrentTimeline(Timeline *tl);
Timeline *currentTimeline();

// ---------------------------------------------------------------------------
// Scroll state + virtualization (src/ui/scroll.zig + widgets/scroll_util.zig)
// ---------------------------------------------------------------------------

struct ScrollInfo {
    float offset = 0, max_offset = 0, viewport = 0, content = 0;
    bool canScroll() const { return max_offset > 0; }
    float thumbFraction() const {
        if (content <= 0) return 1;
        return std::clamp(viewport / content, 0.05f, 1.0f);
    }
};

struct ScrollState {
    float offset = 0, content = 0, viewport = 0;
    float maxOffset() const { return std::max(0.0f, content - viewport); }
    ScrollInfo info() const { return {offset, maxOffset(), viewport, content}; }
    bool setOffset(float value);
    bool scrollBy(float dy) { return setOffset(offset + dy); }
};

struct Range {
    size_t first = 0, last = 0;
};
Range visibleRange(size_t item_count, float stride, float viewport, float offset, size_t margin);

/// Drag + wheel input shared by the scrollables (widgets/scroll_util.zig).
struct ScrollInput {
    static constexpr int MAX_TRACKS = 8;
    struct Track {
        quint64 pointer = 0;
        float y = 0;
        bool active = false;
    };
    Track tracks[MAX_TRACKS] = {};
    using SetOffset = std::function<bool(KxNode *, float)>;

    bool onPointer(const PointerEvent &ev, ScrollState &scroll, const SetOffset &set_offset, KxNode *n);
    bool onScroll(const ScrollEvent &ev, ScrollState &scroll, float wheel_speed,
                  const SetOffset &set_offset, KxNode *n);
};

/// The virtualization diff (scroll_util.zig syncItemWindow).
using ItemFactory = std::function<KxNode *(size_t index)>;
using LayoutItem = std::function<void(KxNode *n, KxNode *child, size_t index)>;
void syncItemWindow(KxNode *n, size_t *first, const ItemFactory &factory,
                    Range range, const LayoutItem &layout_item);

// ---------------------------------------------------------------------------
// Gestures (src/ui/gestures.zig)
// ---------------------------------------------------------------------------

inline constexpr float GESTURE_SLOP = 12;
inline constexpr quint64 TAP_TIMEOUT_MS = 200;
inline constexpr quint64 DOUBLE_TAP_MS = 300;
inline constexpr quint64 LONG_PRESS_MS = 500;
inline constexpr float SWIPE_VELOCITY = 500;
inline constexpr quint64 VELOCITY_WINDOW_MS = 100;

enum class SwipeDirection { left, right, up, down };
QString swipeDirectionName(SwipeDirection d);

struct GestureCallbacks {
    std::function<void()> on_tap;
    std::function<void()> on_double_tap;
    std::function<void()> on_long_press;
    std::function<void(float, float)> on_pan_start;
    std::function<void(float, float)> on_pan_update;
    std::function<void(float, float, float, float)> on_pan_end;
    std::function<void(SwipeDirection, float, float)> on_swipe;
    std::function<void(float)> on_pinch;
    std::function<void(float)> on_rotate;
};

class GestureArena {
public:
    explicit GestureArena(const GestureCallbacks &cbs);
    void feed(const PointerEvent &ev);
    void tick(quint64 now_ms);
    bool hasPendingTimeWork() const;
    void cancel();

    // Nested types are public so the out-of-line implementation in kx.cpp
    // can name them; they remain internal details.
    struct Sample {
        float x = 0, y = 0;
        quint64 t = 0;
    };
    enum class Kind { tap, double_tap, long_press, pan, swipe, pinch, rotate };
    struct Recognizer {
        Kind kind;
        enum class State { idle, possible, accepted, rejected } state = State::idle;
        std::optional<quint64> tracking;
        float start_x = 0, start_y = 0, last_x = 0, last_y = 0;
        quint64 start_time = 0;
        Sample samples[8];
        quint8 sample_len = 0;
        bool has_last_tap = false;
        quint64 last_tap_time = 0;
        float last_tap_x = 0, last_tap_y = 0;
        struct Tracked {
            quint64 id;
            float x, y;
        };
        std::optional<Tracked> ptr_a, ptr_b;
        float initial_distance = 0, initial_angle = 0, last_angle = 0;
        bool long_press_fired = false;
        void reset();
    };
    struct Fire {
        enum class K { none, tap, double_tap, long_press, pan_start, pan_update,
                       pan_end, swipe, pinch, rotate } k = K::none;
        float a = 0, b = 0, c = 0, d = 0;
        SwipeDirection dir = SwipeDirection::left;
    };
private:
    QVector<Recognizer> recognizers_;
    GestureCallbacks cbs_;
    Fire feedRec(Recognizer &rec, const PointerEvent &ev);
    Fire tickRec(Recognizer &rec, quint64 now_ms);
    void invoke(const Fire &f);
};

// ---------------------------------------------------------------------------
// i18n (src/ui/i18n.zig) — messages/plurals ported; per-locale format data
// matches the reference tables (QLocale yields different group separators
// for fr — U+202F — so the corpus asserts the ported table; see MAPPING.md).
// ---------------------------------------------------------------------------

struct Date {
    qint32 year = 0;
    quint8 month = 0, day = 0;
};
enum class DateKind { short_, medium, long_ };
struct NumberOptions {
    std::optional<quint8> decimals;
    bool percent = false;
    bool grouping = true;
};

struct KxLocale {
    QString tag;
    Direction direction = Direction::ltr;
    QHash<QString, QString> messages;
    QString decimal_sep = ".";
    QString group_sep = ",";
    QString date_short = "M/d/yy";
    QString date_medium = "MMM d, y";
    QString date_long = "MMMM d, y";
    QString month_long[12] = {"January", "February", "March", "April", "May", "June",
                              "July", "August", "September", "October", "November", "December"};
    QString month_short[12] = {"Jan", "Feb", "Mar", "Apr", "May", "Jun",
                               "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"};

    QString formatNumber(double value, const NumberOptions &opts) const;
    QString formatDate(const Date &d, DateKind kind) const;
};

/// Apply the built-in format data for a known tag (en/fr/ja/ar).
void applyFormatData(KxLocale &loc);

enum class PluralCategory { zero, one, two, few, many, other };
PluralCategory pluralCategory(const QString &tag, qint64 n);

struct PluralBranch {
    std::optional<qint64> exact;
    std::optional<PluralCategory> category;
    QString text;
};
struct PluralMsg {
    PluralBranch branches[16];
    quint32 len = 0;
    QString prefix, suffix;
};
std::optional<PluralMsg> parsePlural(const QString &msg);
std::optional<QString> selectPlural(const PluralMsg &msg, const QString &tag, qint64 count);

QString interpolate(const QString &msg, const QHash<QString, QString> &args);

class I18n {
public:
    explicit I18n(const QString &fallback_tag);
    ~I18n();

    bool addArb(const QString &tag, const QJsonObject &msgs, Direction dir, QString *err);
    /// Replaces a locale (hot reload) — notifies even when the tag matches.
    bool setLocale(const QString &tag, QString *err);
    Direction dir() const;
    QString tr(const QString &key) const;
    QString trArgs(const QString &key, const QHash<QString, QString> &args) const;
    QString trPlural(const QString &key, qint64 count,
                     const QHash<QString, QString> &args = {}) const;
    KxLocale *locale() const { return current_; }
    Signal<QString> locale_sig{QString()};
    std::function<void()> on_direction_changed;

private:
    QHash<QString, KxLocale *> locales_;
    QString fallback_;
    KxLocale *current_ = nullptr;
};

void setCurrentI18n(I18n *i);
I18n *currentI18n();

// ---------------------------------------------------------------------------
// Navigator (src/ui/navigator.zig)
// ---------------------------------------------------------------------------

enum class Transition { none, slide, slide_up, fade, scale };

struct Param {
    QString key, value;
};

inline constexpr int MAX_PARAMS = 8;

struct Params {
    Param items[MAX_PARAMS];
    quint32 len = 0;
    QString get(const QString &key) const;
    bool add(const QString &key, const QString &value);
    /// Iterate (insertion order) for report code.
    const Param *begin() const { return items; }
    const Param *end() const { return items + len; }
};

struct Route {
    QString pattern; // owned by the RouteDef
    QString path;
    Params params;
    Transition transition = Transition::slide;
};

struct Page {
    quint32 id = 0;
    Route route;
    KxNode *node = nullptr;
};

enum class ChangeKind { push, pop, replace, reset };
QString changeKindName(ChangeKind k);

class Navigator {
public:
    ~Navigator() { deinit(); }
    void deinit(); // frees pages' nodes? No — nodes are tree-owned (see .cpp)

    /// Returns "" on success, else the Zig error name (UnknownRoute, …).
    QString define(const QString &pattern, std::function<KxNode *(const Route &)> builder,
                   Transition transition);
    QString push(const QString &pattern, const std::vector<Param> &params);
    QString pushPath(const QString &path, const std::vector<Param> &params);
    QString navigateTo(const QString &uri);
    QString replace(const QString &pattern, const std::vector<Param> &params);
    bool pop();
    bool onBack() { return pop(); }
    void popToRoot();

    size_t depth() const { return pages_.size(); }
    bool canPop() const { return pages_.size() > 1; }
    const Page *current() const { return pages_.empty() ? nullptr : &pages_.back(); }
    void setOnChange(std::function<void(ChangeKind)> cb) { on_change = std::move(cb); }

private:
    struct RouteDef {
        QString pattern;
        std::function<KxNode *(const Route &)> builder;
        Transition transition = Transition::slide;
    };
    const RouteDef *findDef(const QString &pattern) const;
    QString pushDef(const RouteDef &def, const QString &path, const std::vector<Param> &params);
    QString buildPage(const RouteDef &def, const QString &path,
                      const std::vector<Param> &params, Page *out);
    void notify(ChangeKind k) { if (on_change) on_change(k); }

    std::vector<Page> pages_;
    std::vector<RouteDef> routes_;
    std::function<void(ChangeKind)> on_change;
    quint32 next_id_ = 1;
};

bool matchPattern(const QString &pattern, const QString &path, Params *params);
struct ParsedUri {
    QString path, query;
};
std::optional<ParsedUri> parseUri(const QString &uri);

// ---------------------------------------------------------------------------
// DSL widget factories (src/widgets/*.zig) — implemented in widgets.cpp
// ---------------------------------------------------------------------------

struct FlexOptions {
    float gap = 0, padding = 0;
    MainAlign main_align = MainAlign::start;
    CrossAlign cross_align = CrossAlign::stretch;
};
KxNode *makeFlex(Axis axis, const FlexOptions &opts);

enum class StackFit { loose, expand };
struct StackOptions {
    StackFit fit = StackFit::loose;
    Alignment alignment = Alignment::topLeft();
};
KxNode *makeStack(const StackOptions &opts);

struct GridOptions {
    size_t columns = 2;
    float gap = 0, padding = 0;
};
KxNode *makeGrid(const GridOptions &opts);
KxNode *makePadding(const EdgeInsets &insets);
KxNode *makePaddingDir(const EdgeInsetsDirectional &insets);
KxNode *makeAlign(const Alignment &a);
KxNode *makeCenter();

struct ConstrainedBoxOptions {
    float min_w = 0, min_h = 0;
    float max_w = std::numeric_limits<float>::infinity();
    float max_h = std::numeric_limits<float>::infinity();
};
KxNode *makeConstrainedBox(const ConstrainedBoxOptions &opts);
KxNode *makeExpanded(quint32 weight);

struct ContainerOptions {
    std::optional<Color> color;
    float radius = 0;
    std::optional<Color> border_color;
    float border_width = 0;
    EdgeInsets padding;
};
KxNode *makeContainer(const ContainerOptions &opts);

struct TextOptions {
    float size = 16;
    Color color = 0x000000FF;
    bool bold = false;
    TextAlign text_align = TextAlign::left;
};
KxNode *makeText(const QString &str, const TextOptions &opts);

struct ButtonOptions {
    Color bg = 0x3B5BDBFF, bg_hover = 0x4C6EF5FF, bg_pressed = 0x364FC7FF;
    float radius = 8;
    EdgeInsets padding{16, 8, 16, 8};
};
KxNode *makeButton(std::function<void()> on_pressed, const ButtonOptions &opts);

struct ToggleOptions {
    float width = 44, height = 24;
    Color track_off = 0x444455FF, track_on = 0x3B5BDBFF, knob = 0xFFFFFFFF;
    std::optional<Color> knob_on, knob_off;
};
KxNode *makeToggle(Signal<bool> *sig, std::function<void()> on_changed, const ToggleOptions &opts);

struct CheckboxOptions {
    float size = 20;
    Color box_color = 0x282838FF, border = 0x555566FF, check = 0xFFFFFFFF;
    Color accent = 0x3B5BDBFF;
    float radius = 4;
};
KxNode *makeCheckbox(Signal<bool> *sig, std::function<void()> on_changed, const CheckboxOptions &opts);

struct SliderOptions {
    float height = 24;
    Color track = 0x444455FF, fill = 0x3B5BDBFF, knob = 0xFFFFFFFF;
    float default_width = 200, knob_size = 16;
};
KxNode *makeSlider(Signal<float> *sig, std::function<void()> on_changed, const SliderOptions &opts);

struct TextFieldOptions {
    float size = 16;
    Color color = 0xFFFFFFFF, hint = 0x888899FF, bg = 0x282838FF;
    float radius = 6;
    EdgeInsets padding{8, 6, 8, 6};
    QString placeholder, initial;
};
KxNode *makeTextField(const TextFieldOptions &opts, std::function<void()> on_changed,
                      std::function<void()> on_submitted);
QString textFieldText(KxNode *n);

KxNode *makeGestureDetector(const GestureCallbacks &cbs);

struct ScrollViewOptions {
    float wheel_speed = 48;
};
KxNode *makeScrollView(const ScrollViewOptions &opts);
float scrollViewOffset(KxNode *n);
bool scrollViewSetOffset(KxNode *n, float value);

struct ListViewOptions {
    ItemFactory factory;
    size_t item_count = 0;
    float item_height = 48, gap = 0;
    size_t margin = 2;
    float wheel_speed = 48;
};
KxNode *makeListView(const ListViewOptions &opts);
float listViewOffset(KxNode *n);
bool listViewSetOffset(KxNode *n, float value);
void listViewReloadItems(KxNode *n);
void listViewSetItemCount(KxNode *n, size_t count);
/// item index of children[0] (first_item expect).
size_t listViewFirstIndex(KxNode *n);

struct L10nTextOptions {
    float size = 16;
    Color color = 0x000000FF;
    bool bold = false;
    TextAlign text_align = TextAlign::start;
};
KxNode *makeL10nText(I18n *i18n, const QString &key, const QHash<QString, QString> &args,
                     const L10nTextOptions &opts);
KxNode *makeL10nPlural(I18n *i18n, const QString &key, qint64 count, const L10nTextOptions &opts);
KxNode *makeL10nPluralSig(I18n *i18n, const QString &key, Signal<qint64> *count_sig,
                          const L10nTextOptions &opts);

// ---------------------------------------------------------------------------
// KxSurface — the QWidget host: paintEvent drives the same paint pass the
// conformance renderer runs into a QImage (real Qt raster path).
// ---------------------------------------------------------------------------

class KxSurface : public QWidget {
public:
    explicit KxSurface(QWidget *parent = nullptr) : QWidget(parent) {}
    void setRoot(KxNode *r) { root_ = r; }
    /// Paint the tree into an RGBA image (the conformance readback path).
    QImage renderFrame(int w, int h, Color bg);
    /// Same traversal inside a real paintEvent (on-screen runs).
    void paintTree(QPainter &p, const Rect &visible);

protected:
    void paintEvent(QPaintEvent *ev) override;

private:
    KxNode *root_ = nullptr;
};

} // namespace kx
