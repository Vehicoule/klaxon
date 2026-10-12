// kx_a11y_linux.cpp — Linux AT-SPI2 accessibility bridge (Phase 3a; the
// roadmap's "the AT-SPI bridge lands with Linux" item).
//
// Same contract as kx_a11y_macos.mm (NSAccessibility), kx_a11y_ios.mm
// (UIAccessibility), kx_a11y_android.cpp (TalkBack) and web/kx_a11y.js
// (ARIA hidden DOM): kx_a11y_init(root) installs the C bridge callback the
// Zig semantics module emits on, kx_a11y_shutdown uninstalls it,
// kx_a11y_root_element returns the platform accessibility root.
//
// Design — ATK + the stock at-spi2-atk adaptor (not a raw D-Bus impl):
//   A non-GTK toolkit reaches AT-SPI either by (a) implementing the
//   org.a11y.atspi.Accessible/Application/Registry protocol on the a11y
//   D-Bus directly — the Socket/Embed handshake, droute-style object
//   routing, event-listener negotiation (the Chromium/Qt path, a lot of
//   protocol), or (b) building an AtkObject tree and letting atk-bridge
//   (at-spi2-atk) bridge it onto the bus automatically — the clutter/cally
//   and java-atk-wrapper path. The codebase vendors no D-Bus infra, so
//   (b): libatk + libatk-bridge are standard on every desktop distro and
//   the adaptor owns all the protocol plumbing.
//
// Root registration: atk_bridge_adaptor_init() calls atk_get_root(), which
//   reads the get_root vfunc off the BASE AtkUtilClass — the bridge patches
//   the class before calling adaptor_init (the same "Cally trick" clutter
//   uses in _cally_util_override_atk_util). The adaptor then calls
//   Socket.Embed on the registry with our application root and serves the
//   AtkObject graph over droute.
//
// Threading: the adaptor hooks its a11y D-Bus connection, timeouts and
//   event idles onto the DEFAULT GMainContext — which Klaxon's SDL loop
//   never iterates. kx_a11y_init therefore spawns a dedicated "kx-a11y"
//   thread running g_main_context_iteration; every AtkObject is created,
//   queried and signalled on THAT thread (droute D-Bus handlers run there
//   too, so no locking is needed). Bridge events arrive on the SDL/render
//   thread (the same caller-thread assumption macOS/iOS make) and are
//   marshalled to the a11y thread with g_idle_add; the tree dump is pulled
//   on the caller thread first (the Zig tree is only safe to read there).
//   Screen-reader actions (AtkAction "click", AtkComponent grab_focus)
//   call into Zig straight from the a11y thread — the same cross-thread
//   caveat as the Android bridge (kx_a11y_activate_node /
//   kx_a11y_focus_node; an SDL-user-event queue is the follow-up).
//
//   Zig (SDL thread)                  a11y thread (default GMainContext)
//   ────────────────                  ────────────────────────────────
//   kx_a11y_init ─► AtkUtilClass patch + app root + adaptor_init + thread
//   bridge events ─► dump / g_strndup ──g_idle_add──► rebuild, focus, announce
//   AT actions    ◄── do_action / grab_focus ──► kx_a11y_{activate,focus}_node
//
// ABI note: the bridge callback receives BridgeEventC BY VALUE (extern
// struct) — the field order below mirrors ui/semantics.zig. Do NOT flatten
// it to scalar parameters: that is the wasm ABI only. Verified against the
// Zig 0.17 arm64 C ABI (a flattened callback reads garbage on native).
//
// v1: role mapping, tree sync (children-changed::add/remove with stable
// object identity keyed on the Node pointer), focus + state changes,
// live-region announcements, "click" + grab_focus actions, bounds
// (window-relative — the ABI doesn't expose the window's screen position).
// Follow-ups: AtkText (text-field contents), AtkWindow (window:activate),
// AtkImage, AtkKeySnoopFunc (AT-side key grabs into SDL events).
#include <atk/atk.h>
#include <atk-bridge.h>

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <atomic>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <vector>

// --- Zig bridge ABI (src/a11y_bridge.zig, src/ui/semantics.zig) ---
extern "C" {

// BridgeEventC — extern struct, passed BY VALUE (see the ABI note above).
struct KxBridgeEventC {
    uint32_t kind;    // 0=tree_dirty 1=focus_changed 2=announce 3=control_changed
    uint64_t node_id; // Node pointer (decimal in the dump)
    const char* text; // announce payload (borrowed during the call only)
    size_t text_len;
    uint32_t region;  // LiveRegion: 0=off 1=polite 2=assertive
};

enum {
    KX_A11Y_TREE_DIRTY = 0,
    KX_A11Y_FOCUS_CHANGED = 1,
    KX_A11Y_ANNOUNCE = 2,
    KX_A11Y_CONTROL_CHANGED = 3,
};

void kx_a11y_set_bridge(void (*fn)(void* userdata, KxBridgeEventC event), void* userdata);
char* kx_a11y_dump_tree(void* root_node);
void kx_a11y_free_string(char* s);
// OS bridge -> app (shared with the iOS/Android bridges): focus / activate
// the node whose pointer is `ptr`, resolved from `root` (a real click
// through the input router at the node's visual center).
void kx_a11y_focus_node(void* root, uint64_t ptr);
void kx_a11y_activate_node(void* root, uint64_t ptr);

} // extern "C"

// --- Parsed semantic tree (the dump's flat form) ---
// One line per visible semantic node:
//   "depth|role|label|value|focusable|ptr|checked|x|y|w|h\n"
struct KxA11yNode {
    int depth = 0;
    int parent = -1;   // index of the parent node, -1 = under the app root
    uint64_t ptr = 0;  // Node pointer — the object's identity key
    int checked = 0;   // 0 = null, 1 = false, 2 = true
    bool focusable = false;
    int x = 0, y = 0, w = 0, h = 0; // rect in window space (mapRectToRoot)
    std::string role;
    std::string label;
    std::string value;
};

static void* g_zig_root_node = nullptr;

// --- KxAtkObject: an AtkObject wrapping one semantic-tree node ---

#define KX_TYPE_ATK_OBJECT (kx_atk_object_get_type())
G_DECLARE_FINAL_TYPE(KxAtkObject, kx_atk_object, KX, ATK_OBJECT, AtkObject)

struct _KxAtkObject {
    AtkObject parent_instance;
    uint64_t node_ptr;       // Zig Node* — 0 on the application root
    AtkRole role;            // resolved ATK role
    gchar* klaxon_role;      // dump role string ("button", ...) for attributes
    gchar* label;            // -> accessible-name
    gchar* value;            // -> accessible-description / "value" attribute
    bool focusable;
    int checked;             // 0 = null, 1 = false, 2 = true
    int x, y, w, h;          // window-space rect
    AtkObject* parent_obj;   // not owned (the registry owns all objects)
    uint64_t parent_ptr;     // parent's Node ptr, 0 = application root
    GPtrArray* children;     // KxAtkObject* — not owned (registry-owned too)
    int index_in_parent;
};

// A second type carries the AtkValue interface — interface presence is
// per-GType, and only value-bearing roles (slider/progress/scrollbar) may
// advertise org.a11y.atspi.Value.
#define KX_TYPE_ATK_VALUE_OBJECT (kx_atk_value_object_get_type())
G_DECLARE_FINAL_TYPE(KxAtkValueObject, kx_atk_value_object, KX, ATK_VALUE_OBJECT, KxAtkObject)
struct _KxAtkValueObject {
    KxAtkObject parent_instance;
};

static void kx_atk_component_iface_init(AtkComponentIface* iface);
static void kx_atk_action_iface_init(AtkActionIface* iface);
static void kx_atk_value_iface_init(AtkValueIface* iface);

G_DEFINE_TYPE_WITH_CODE(KxAtkObject, kx_atk_object, ATK_TYPE_OBJECT,
    G_IMPLEMENT_INTERFACE(ATK_TYPE_COMPONENT, kx_atk_component_iface_init)
    G_IMPLEMENT_INTERFACE(ATK_TYPE_ACTION, kx_atk_action_iface_init))
G_DEFINE_TYPE_WITH_CODE(KxAtkValueObject, kx_atk_value_object, KX_TYPE_ATK_OBJECT,
    G_IMPLEMENT_INTERFACE(ATK_TYPE_VALUE, kx_atk_value_iface_init))

// --- Bridge state (a11y thread only — see the header) ---
static KxAtkObject* g_app_root = nullptr; // the AtkUtil get_root object
// Node ptr -> object, owning ref. Stable identity across rebuilds: ATs cache
// object references (D-Bus paths) — never recreate an object that survived.
static std::unordered_map<uint64_t, KxAtkObject*> g_obj_by_ptr;
static uint64_t g_focused_ptr = 0;

static KxAtkObject* lookupObject(uint64_t ptr) {
    auto it = g_obj_by_ptr.find(ptr);
    return it == g_obj_by_ptr.end() ? nullptr : it->second;
}

// Klaxon role (dump field 2) -> AtkRole. window_root is set for the dump's
// depth-0 container: ATK expects the application's children to be frames.
static AtkRole mapRole(const std::string& role, bool window_root) {
    if (window_root && (role == "group" || role == "none")) return ATK_ROLE_FRAME;
    if (role == "button")     return ATK_ROLE_PUSH_BUTTON;
    if (role == "text")       return ATK_ROLE_STATIC;
    if (role == "heading")    return ATK_ROLE_HEADING;
    if (role == "link")       return ATK_ROLE_LINK;
    if (role == "image")      return ATK_ROLE_IMAGE;
    if (role == "text_field") return ATK_ROLE_ENTRY;
    if (role == "toggle")     return ATK_ROLE_TOGGLE_BUTTON;
    if (role == "checkbox")   return ATK_ROLE_CHECK_BOX;
    if (role == "radio")      return ATK_ROLE_RADIO_BUTTON;
    if (role == "slider")     return ATK_ROLE_SLIDER;
    if (role == "progress")   return ATK_ROLE_PROGRESS_BAR;
    if (role == "scrollbar")  return ATK_ROLE_SCROLL_BAR;
    if (role == "list")       return ATK_ROLE_LIST;
    if (role == "list_item")  return ATK_ROLE_LIST_ITEM;
    if (role == "dialog")     return ATK_ROLE_DIALOG;
    if (role == "alert")      return ATK_ROLE_ALERT;
    if (role == "menu")       return ATK_ROLE_MENU;
    if (role == "menu_item")  return ATK_ROLE_MENU_ITEM;
    if (role == "tab")        return ATK_ROLE_PAGE_TAB;
    if (role == "tab_panel")  return ATK_ROLE_PANEL;
    if (role == "separator")  return ATK_ROLE_SEPARATOR;
    if (role == "group")      return ATK_ROLE_PANEL;
    return ATK_ROLE_UNKNOWN;
}

static bool isValueRole(const std::string& role) {
    return role == "slider" || role == "progress" || role == "scrollbar";
}

// --- AtkObject vfuncs ---

static const gchar* kx_atk_object_get_name(AtkObject* obj) {
    KxAtkObject* self = KX_ATK_OBJECT(obj);
    return (self->label && self->label[0]) ? self->label : nullptr;
}

static const gchar* kx_atk_object_get_description(AtkObject* obj) {
    // The value string reaches ATs through the description (same spoken
    // channel as macOS accessibilityValue): "Wi-Fi, toggle button, off".
    KxAtkObject* self = KX_ATK_OBJECT(obj);
    return (self->value && self->value[0]) ? self->value : nullptr;
}

static AtkObject* kx_atk_object_get_parent(AtkObject* obj) {
    return KX_ATK_OBJECT(obj)->parent_obj;
}

static gint kx_atk_object_get_n_children(AtkObject* obj) {
    KxAtkObject* self = KX_ATK_OBJECT(obj);
    return self->children ? (gint)self->children->len : 0;
}

static AtkObject* kx_atk_object_ref_child(AtkObject* obj, gint i) {
    KxAtkObject* self = KX_ATK_OBJECT(obj);
    if (!self->children || i < 0 || (guint)i >= self->children->len) return nullptr;
    return ATK_OBJECT(g_object_ref(self->children->pdata[i]));
}

static gint kx_atk_object_get_index_in_parent(AtkObject* obj) {
    return KX_ATK_OBJECT(obj)->index_in_parent;
}

static AtkRelationSet* kx_atk_object_ref_relation_set(AtkObject*) {
    return atk_relation_set_new(); // no relations yet (labels, described-by)
}

static AtkRole kx_atk_object_get_role(AtkObject* obj) {
    return KX_ATK_OBJECT(obj)->role;
}

static AtkLayer kx_atk_object_get_layer(AtkObject*) {
    return ATK_LAYER_WIDGET;
}

static gint kx_atk_object_get_mdi_zorder(AtkObject* obj) {
    return KX_ATK_OBJECT(obj)->index_in_parent;
}

static AtkStateSet* kx_atk_object_ref_state_set(AtkObject* obj) {
    KxAtkObject* self = KX_ATK_OBJECT(obj);
    AtkStateSet* set = atk_state_set_new();
    // The dump only carries visible nodes (flattenInto skips !visible).
    atk_state_set_add_state(set, ATK_STATE_VISIBLE);
    atk_state_set_add_state(set, ATK_STATE_SHOWING);
    atk_state_set_add_state(set, ATK_STATE_ENABLED);
    atk_state_set_add_state(set, ATK_STATE_SENSITIVE);
    if (self->focusable) atk_state_set_add_state(set, ATK_STATE_FOCUSABLE);
    if (self->node_ptr && self->node_ptr == g_focused_ptr)
        atk_state_set_add_state(set, ATK_STATE_FOCUSED);
    if (self->checked == 2) atk_state_set_add_state(set, ATK_STATE_CHECKED);
    if (self->klaxon_role) {
        if (!strcmp(self->klaxon_role, "text_field")) {
            atk_state_set_add_state(set, ATK_STATE_EDITABLE);
            atk_state_set_add_state(set, ATK_STATE_SINGLE_LINE);
            atk_state_set_add_state(set, ATK_STATE_FOCUSABLE);
        }
        if (!strcmp(self->klaxon_role, "list_item") ||
            !strcmp(self->klaxon_role, "radio") ||
            !strcmp(self->klaxon_role, "tab")) {
            atk_state_set_add_state(set, ATK_STATE_SELECTABLE);
            if (self->checked == 2) atk_state_set_add_state(set, ATK_STATE_SELECTED);
        }
    }
    return set;
}

static AtkAttributeSet* kx_atk_object_get_attributes(AtkObject* obj) {
    KxAtkObject* self = KX_ATK_OBJECT(obj);
    AtkAttributeSet* set = nullptr;
    if (self->klaxon_role && self->klaxon_role[0]) {
        AtkAttribute* a = g_new(AtkAttribute, 1);
        a->name = g_strdup("klaxon-role");
        a->value = g_strdup(self->klaxon_role);
        set = g_slist_prepend(set, a);
    }
    if (self->value && self->value[0]) {
        AtkAttribute* a = g_new(AtkAttribute, 1);
        a->name = g_strdup("value");
        a->value = g_strdup(self->value);
        set = g_slist_prepend(set, a);
    }
    return set;
}

static void kx_atk_object_init(KxAtkObject* self) {
    self->children = g_ptr_array_new();
    self->index_in_parent = -1;
}

static void kx_atk_object_finalize(GObject* object) {
    KxAtkObject* self = KX_ATK_OBJECT(object);
    g_free(self->klaxon_role);
    g_free(self->label);
    g_free(self->value);
    if (self->children) g_ptr_array_unref(self->children);
    G_OBJECT_CLASS(kx_atk_object_parent_class)->finalize(object);
}

static void kx_atk_object_class_init(KxAtkObjectClass* klass) {
    AtkObjectClass* atk_class = ATK_OBJECT_CLASS(klass);
    atk_class->get_name = kx_atk_object_get_name;
    atk_class->get_description = kx_atk_object_get_description;
    atk_class->get_parent = kx_atk_object_get_parent;
    atk_class->get_n_children = kx_atk_object_get_n_children;
    atk_class->ref_child = kx_atk_object_ref_child;
    atk_class->get_index_in_parent = kx_atk_object_get_index_in_parent;
    atk_class->ref_relation_set = kx_atk_object_ref_relation_set;
    atk_class->get_role = kx_atk_object_get_role;
    atk_class->get_layer = kx_atk_object_get_layer;
    atk_class->get_mdi_zorder = kx_atk_object_get_mdi_zorder;
    atk_class->ref_state_set = kx_atk_object_ref_state_set;
    atk_class->get_attributes = kx_atk_object_get_attributes;
    G_OBJECT_CLASS(klass)->finalize = kx_atk_object_finalize;
}

// --- AtkComponent ---

static gboolean kx_atk_component_contains(AtkComponent* component, gint x, gint y,
                                          AtkCoordType coord_type) {
    (void)coord_type; // window coords only — see the extents caveat
    KxAtkObject* self = KX_ATK_OBJECT(component);
    return x >= self->x && y >= self->y && x < self->x + self->w && y < self->y + self->h;
}

static void kx_atk_component_get_extents(AtkComponent* component, gint* x, gint* y,
                                         gint* width, gint* height, AtkCoordType coord_type) {
    // The dump carries window-space rects (mapRectToRoot). ATK_XY_SCREEN
    // requests get the same numbers: the ABI doesn't expose the window's
    // screen position (a documented v1 caveat — same as the macOS bridge
    // reporting window frames).
    (void)coord_type;
    KxAtkObject* self = KX_ATK_OBJECT(component);
    *x = self->x;
    *y = self->y;
    *width = self->w;
    *height = self->h;
}

static void kx_atk_component_get_position(AtkComponent* component, gint* x, gint* y,
                                          AtkCoordType coord_type) {
    gint w, h;
    kx_atk_component_get_extents(component, x, y, &w, &h, coord_type);
}

static void kx_atk_component_get_size(AtkComponent* component, gint* width, gint* height) {
    KxAtkObject* self = KX_ATK_OBJECT(component);
    *width = self->w;
    *height = self->h;
}

// Deepest descendant whose rect contains the point (children paint in order,
// so the last match is topmost). ATs use this for hit-testing.
static AtkObject* kx_atk_component_ref_accessible_at_point(AtkComponent* component,
                                                         gint x, gint y, AtkCoordType coord_type) {
    KxAtkObject* self = KX_ATK_OBJECT(component);
    if (!self->children) return nullptr;
    for (gint i = (gint)self->children->len - 1; i >= 0; i--) {
        KxAtkObject* child = KX_ATK_OBJECT(self->children->pdata[i]);
        if (kx_atk_component_contains(ATK_COMPONENT(child), x, y, coord_type)) {
            AtkObject* deeper =
                kx_atk_component_ref_accessible_at_point(ATK_COMPONENT(child), x, y, coord_type);
            return deeper ? deeper : ATK_OBJECT(g_object_ref(child));
        }
    }
    return nullptr;
}

static gboolean kx_atk_component_grab_focus(AtkComponent* component) {
    // AT-side focus request ("grabFocus" over AT-SPI) -> move Klaxon's focus
    // to the node, like VoiceOver's accessibilityElementDidBecomeFocused.
    KxAtkObject* self = KX_ATK_OBJECT(component);
    if (!self->node_ptr || !g_zig_root_node) return FALSE;
    kx_a11y_focus_node(g_zig_root_node, self->node_ptr);
    return TRUE;
}

static gdouble kx_atk_component_get_alpha(AtkComponent*) {
    return 1.0;
}

static AtkLayer kx_atk_component_get_layer(AtkComponent*) {
    return ATK_LAYER_WIDGET;
}

static gint kx_atk_component_get_mdi_zorder(AtkComponent* component) {
    return KX_ATK_OBJECT(component)->index_in_parent;
}

static void kx_atk_component_iface_init(AtkComponentIface* iface) {
    iface->contains = kx_atk_component_contains;
    iface->ref_accessible_at_point = kx_atk_component_ref_accessible_at_point;
    iface->get_extents = kx_atk_component_get_extents;
    iface->get_position = kx_atk_component_get_position;
    iface->get_size = kx_atk_component_get_size;
    iface->grab_focus = kx_atk_component_grab_focus;
    iface->get_layer = kx_atk_component_get_layer;
    iface->get_mdi_zorder = kx_atk_component_get_mdi_zorder;
    iface->get_alpha = kx_atk_component_get_alpha;
    // add/remove_focus_handler and set_* stay NULL — read-only objects.
}

// --- AtkAction ("click" -> synthesized pointer at the node center) ---

static gboolean kx_atk_action_do_action(AtkAction* action, gint i) {
    KxAtkObject* self = KX_ATK_OBJECT(action);
    if (i != 0 || !self->node_ptr || !g_zig_root_node) return FALSE;
    kx_a11y_activate_node(g_zig_root_node, self->node_ptr);
    return TRUE;
}

static gint kx_atk_action_get_n_actions(AtkAction* action) {
    // The application root wraps no node — no action.
    return KX_ATK_OBJECT(action)->node_ptr ? 1 : 0;
}

static const gchar* kx_atk_action_get_name(AtkAction* action, gint i) {
    KxAtkObject* self = KX_ATK_OBJECT(action);
    return (i == 0 && self->node_ptr) ? "click" : nullptr;
}

static void kx_atk_action_iface_init(AtkActionIface* iface) {
    iface->do_action = kx_atk_action_do_action;
    iface->get_n_actions = kx_atk_action_get_n_actions;
    iface->get_name = kx_atk_action_get_name;
}

// --- AtkValue (slider/progress/scrollbar) ---

static void kx_atk_value_get_value_and_text(AtkValue* value, gdouble* out_value,
                                            gchar** out_text) {
    KxAtkObject* self = KX_ATK_OBJECT(value);
    const gchar* text = (self->value && self->value[0]) ? self->value : "";
    if (out_value) *out_value = g_ascii_strtod(text, nullptr);
    if (out_text) *out_text = g_strdup(text);
}

static AtkRange* kx_atk_value_get_range(AtkValue*) {
    // The dump has no min/max — report the percent convention (0-100); the
    // value text remains the authoritative payload.
    return atk_range_new(0.0, 100.0, nullptr);
}

static void kx_atk_value_iface_init(AtkValueIface* iface) {
    iface->get_value_and_text = kx_atk_value_get_value_and_text;
    iface->get_range = kx_atk_value_get_range;
    // set_value stays NULL — AT writes are out of scope (read-only values).
}

// The value type adds no state or vfuncs of its own — it only carries the
// AtkValue interface on top of KxAtkObject. Empty init/class_init: GObject
// chains the parent's instance_init and class_init automatically.
static void kx_atk_value_object_class_init(KxAtkValueObjectClass*) {}
static void kx_atk_value_object_init(KxAtkValueObject*) {}

// --- AtkUtilClass vfuncs (the Cally trick: patch the BASE class so
// atk_get_root() — called inside atk_bridge_adaptor_init — returns our
// application object) ---

static AtkObject* kx_util_get_root(void) {
    return ATK_OBJECT(g_app_root);
}
static const gchar* kx_util_get_toolkit_name(void) {
    return "klaxon";
}
static const gchar* kx_util_get_toolkit_version(void) {
    return "1.0";
}

// --- Dump parsing (same depth-stack algorithm as the Android bridge) ---

static int parseInt(const char* s, size_t len) {
    int v = 0;
    bool neg = false;
    size_t i = 0;
    if (i < len && s[i] == '-') { neg = true; i++; }
    for (; i < len; i++) v = v * 10 + (s[i] - '0');
    return neg ? -v : v;
}

static unsigned long long parseU64(const char* s, size_t len) {
    unsigned long long v = 0;
    for (size_t i = 0; i < len; i++) v = v * 10 + (unsigned long long)(s[i] - '0');
    return v;
}

// Bounds may be fractional ("10.5") — parse as float and round (the
// digit-only parseInt would read the '.' as a digit).
static int parseCoord(const char* s, size_t len) {
    char buf[32];
    size_t n = len < sizeof(buf) - 1 ? len : sizeof(buf) - 1;
    memcpy(buf, s, n);
    buf[n] = '\0';
    return (int)lroundf(strtof(buf, nullptr));
}

static void parseDump(const char* dump, std::vector<KxA11yNode>& nodes) {
    std::vector<int> stack; // stack[d] = node index at depth d on the current path
    const char* p = dump;
    while (p && *p) {
        const char* eol = p;
        while (*eol && *eol != '\n') eol++;
        const char* fields[11];
        size_t lens[11];
        int nfields = 0;
        const char* s = p;
        while (s < eol && nfields < 11) {
            const char* bar = s;
            while (bar < eol && *bar != '|') bar++;
            fields[nfields] = s;
            lens[nfields] = (size_t)(bar - s);
            nfields++;
            s = (*bar == '|') ? bar + 1 : bar;
        }
        if (nfields >= 7) {
            KxA11yNode node;
            node.depth = parseInt(fields[0], lens[0]);
            node.role.assign(fields[1], lens[1]);
            node.label.assign(fields[2], lens[2]);
            node.value.assign(fields[3], lens[3]);
            node.focusable = parseInt(fields[4], lens[4]) != 0;
            node.ptr = parseU64(fields[5], lens[5]);
            node.checked = parseInt(fields[6], lens[6]);
            if (nfields >= 11) {
                node.x = parseCoord(fields[7], lens[7]);
                node.y = parseCoord(fields[8], lens[8]);
                node.w = parseCoord(fields[9], lens[9]);
                node.h = parseCoord(fields[10], lens[10]);
            }
            while ((int)stack.size() > node.depth) stack.pop_back();
            node.parent = stack.empty() ? -1 : stack.back();
            stack.push_back((int)nodes.size());
            nodes.push_back(std::move(node));
        }
        p = (*eol == '\n') ? eol + 1 : eol;
    }
}

// --- Signal helpers (all emitted on the a11y thread) ---

static void emitPropertyChange(KxAtkObject* obj, const char* property) {
    // The adaptor reads property_name and re-queries the object — the
    // GValues are only used for table/table-cell properties we never emit.
    AtkPropertyValues values = {};
    values.property_name = property;
    char detail[64];
    snprintf(detail, sizeof(detail), "property-change::%s", property);
    g_signal_emit_by_name(obj, detail, &values);
}

static void emitChildrenChanged(KxAtkObject* parent, const char* minor,
                                int index, KxAtkObject* child) {
    char detail[64];
    snprintf(detail, sizeof(detail), "children-changed::%s", minor);
    g_signal_emit_by_name(parent, detail, (guint)index, (gpointer)child);
}

// --- Tree rebuild (a11y thread) ---
// Diff the parsed dump against the live object map keyed on Node pointers:
// objects are created/updated/unlinked in place so AT-side references
// (D-Bus paths) stay stable across rebuilds.

// Emit children-changed::remove and unlink `child` from `parent`, keeping
// the array order stable so subsequent indices stay accurate. Returns the
// index the child was at, or -1 if it wasn't linked.
static int emitRemoveAndUnlink(KxAtkObject* parent, KxAtkObject* child) {
    if (!parent->children) return -1;
    for (guint i = 0; i < parent->children->len; i++) {
        if (parent->children->pdata[i] == child) {
            emitChildrenChanged(parent, "remove", (int)i, child);
            g_ptr_array_remove_index(parent->children, i);
            return (int)i;
        }
    }
    return -1;
}

// Assign `kids` as the parent's child list, emitting children-changed
// remove/add for the delta (removals reference the OLD indices, adds the
// NEW ones — the at-spi2-atk listener contract).
static void linkChildren(KxAtkObject* parent, const std::vector<KxAtkObject*>& kids) {
    GPtrArray* old = parent->children;
    for (guint i = 0; i < old->len; i++) {
        KxAtkObject* c = KX_ATK_OBJECT(old->pdata[i]);
        if (std::find(kids.begin(), kids.end(), c) == kids.end())
            emitChildrenChanged(parent, "remove", (int)i, c);
    }
    GPtrArray* arr = g_ptr_array_sized_new((guint)kids.size());
    for (size_t i = 0; i < kids.size(); i++) {
        kids[i]->parent_obj = ATK_OBJECT(parent);
        kids[i]->parent_ptr = parent->node_ptr;
        kids[i]->index_in_parent = (int)i;
        g_ptr_array_add(arr, kids[i]);
    }
    parent->children = arr;
    for (guint i = 0; i < arr->len; i++) {
        KxAtkObject* c = KX_ATK_OBJECT(arr->pdata[i]);
        bool was_child = false;
        for (guint j = 0; j < old->len; j++) {
            if (old->pdata[j] == c) { was_child = true; break; }
        }
        if (!was_child) emitChildrenChanged(parent, "add", (int)i, c);
    }
    g_ptr_array_unref(old);
}

static void updateNode(KxAtkObject* o, const KxA11yNode& n, bool created) {
    const bool label_changed = !created && (!o->label || strcmp(o->label, n.label.c_str()) != 0);
    const bool value_changed = !created && (!o->value || strcmp(o->value, n.value.c_str()) != 0);
    const bool checked_changed = !created && o->checked != n.checked;
    const bool focusable_changed = !created && o->focusable != n.focusable;
    const bool bounds_changed = !created &&
        (o->x != n.x || o->y != n.y || o->w != n.w || o->h != n.h);

    g_free(o->label);
    o->label = g_strdup(n.label.c_str());
    g_free(o->value);
    o->value = g_strdup(n.value.c_str());
    o->checked = n.checked;
    o->focusable = n.focusable;
    o->x = n.x;
    o->y = n.y;
    o->w = n.w;
    o->h = n.h;

    if (created) return; // fresh objects are read whole — no deltas to report
    if (label_changed) emitPropertyChange(o, "accessible-name");
    if (value_changed) emitPropertyChange(o, "accessible-description");
    if (checked_changed)
        atk_object_notify_state_change(ATK_OBJECT(o), ATK_STATE_CHECKED, o->checked == 2);
    if (focusable_changed)
        atk_object_notify_state_change(ATK_OBJECT(o), ATK_STATE_FOCUSABLE, o->focusable);
    if (bounds_changed) {
        AtkRectangle r = { o->x, o->y, o->w, o->h };
        g_signal_emit_by_name(o, "bounds-changed", &r);
    }
}

static void rebuildTree(const char* dump) {
    if (!g_app_root) return;
    std::vector<KxA11yNode> nodes;
    parseDump(dump, nodes);

    // Removals first. Emit children-changed::remove only on a parent that
    // survives this rebuild — the ATK convention for a removed subtree is a
    // single remove at the top, and a dead parent's AtkObject may already be
    // finalized (map iteration order is arbitrary, so never dereference a
    // dead parent_obj). All dead objects stay alive until every remove has
    // been emitted, then lose their registry ref in the second pass.
    std::unordered_set<uint64_t> live;
    live.reserve(nodes.size());
    for (const KxA11yNode& n : nodes) live.insert(n.ptr);
    for (auto& entry : g_obj_by_ptr) {
        KxAtkObject* dead = entry.second;
        if (live.count(entry.first)) continue;
        const bool parent_live =
            dead->parent_ptr == 0 || live.count(dead->parent_ptr);
        KxAtkObject* p = dead->parent_ptr ? lookupObject(dead->parent_ptr)
                                          : g_app_root;
        if (p && parent_live) emitRemoveAndUnlink(p, dead);
    }
    for (auto it = g_obj_by_ptr.begin(); it != g_obj_by_ptr.end();) {
        if (live.count(it->first)) {
            ++it;
            continue;
        }
        g_object_unref(it->second); // drops the registry ref
        it = g_obj_by_ptr.erase(it);
    }
    if (g_focused_ptr && !live.count(g_focused_ptr)) g_focused_ptr = 0;

    // Create-or-update each dump node (identity keyed on the Node pointer).
    std::vector<KxAtkObject*> objs(nodes.size());
    for (size_t i = 0; i < nodes.size(); i++) {
        const KxA11yNode& n = nodes[i];
        auto it = g_obj_by_ptr.find(n.ptr);
        KxAtkObject* o;
        const bool created = it == g_obj_by_ptr.end();
        if (created) {
            GType type = isValueRole(n.role) ? KX_TYPE_ATK_VALUE_OBJECT : KX_TYPE_ATK_OBJECT;
            o = KX_ATK_OBJECT(g_object_new(type, nullptr));
            o->node_ptr = n.ptr;
            o->klaxon_role = g_strdup(n.role.c_str());
            o->role = mapRole(n.role, n.depth == 0);
            g_obj_by_ptr[n.ptr] = o;
        } else {
            o = it->second;
        }
        updateNode(o, n, created);
        objs[i] = o;
    }

    // Re-link: build the desired child lists and diff-emit per parent.
    // Depth-0 nodes hang off the application root (the registry-facing
    // object — it is itself never in the dump).
    std::unordered_map<KxAtkObject*, std::vector<KxAtkObject*>> want;
    for (size_t i = 0; i < nodes.size(); i++) {
        KxAtkObject* parent =
            nodes[i].parent >= 0 ? objs[(size_t)nodes[i].parent] : g_app_root;
        want[parent].push_back(objs[i]);
    }
    linkChildren(g_app_root, want[g_app_root]);
    for (auto& entry : g_obj_by_ptr) linkChildren(entry.second, want[entry.second]);
}

static void focusChanged(uint64_t node_id) {
    KxAtkObject* o = lookupObject(node_id);
    if (!o || g_focused_ptr == node_id) return;
    // Update g_focused_ptr BEFORE emitting: the adaptor's handlers re-query
    // ref_state_set synchronously during the emits.
    KxAtkObject* prev = lookupObject(g_focused_ptr);
    g_focused_ptr = node_id;
    if (prev)
        atk_object_notify_state_change(ATK_OBJECT(prev), ATK_STATE_FOCUSED, FALSE);
    atk_object_notify_state_change(ATK_OBJECT(o), ATK_STATE_FOCUSED, TRUE);
    // Deprecated but load-bearing: the adaptor forwards AT-SPI "focus" events
    // through atk_add_focus_tracker, not the AtkObject::focus-event signal.
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wdeprecated-declarations"
    atk_focus_tracker_notify(ATK_OBJECT(o));
#pragma GCC diagnostic pop
    g_signal_emit_by_name(o, "focus-event", TRUE); // in-process listeners
}

static void announceOnRoot(const gchar* text, uint32_t region) {
    if (!g_app_root || !text || !*text) return;
    if (g_signal_lookup("notification", ATK_TYPE_OBJECT)) {
        // ATK >= 2.50: carries the politeness (AtkLive: 1 polite, 2 assertive).
        g_signal_emit_by_name(g_app_root, "notification", (gpointer)text,
                              (gint)(region == 2 ? 2 : 1));
    } else if (g_signal_lookup("announcement", ATK_TYPE_OBJECT)) {
        // ATK >= 2.46: always forwarded as a polite announcement.
        g_signal_emit_by_name(g_app_root, "announcement", (gpointer)text);
    }
    // Older ATK: no announce channel — the event is dropped silently.
}

// --- SDL thread -> a11y thread marshalling ---

static std::atomic<bool> g_a11y_running{false}; // a11y thread pump flag
static GThread* g_a11y_thread = nullptr;
static bool g_bridge_inited = false;

struct KxA11yTask {
    uint32_t kind;
    uint64_t node_id;
    uint32_t region;
    char* text;        // dump (zig_owned) or announce payload (g_strdup'd)
    bool zig_owned;    // free with kx_a11y_free_string vs g_free
};

static gboolean kx_a11y_task_run(gpointer data) {
    KxA11yTask* t = static_cast<KxA11yTask*>(data);
    switch (t->kind) {
        case KX_A11Y_TREE_DIRTY:
        case KX_A11Y_CONTROL_CHANGED:
            // control_changed rebuilds too (same as the wasm mirror + the
            // Android node cache): the diff emits the value/checked deltas.
            if (t->text) rebuildTree(t->text);
            break;
        case KX_A11Y_FOCUS_CHANGED:
            focusChanged(t->node_id);
            break;
        case KX_A11Y_ANNOUNCE:
            announceOnRoot(t->text, t->region);
            break;
        default:
            break;
    }
    if (t->text) {
        if (t->zig_owned) kx_a11y_free_string(t->text);
        else g_free(t->text);
    }
    delete t;
    return G_SOURCE_REMOVE;
}

static void postTask(KxA11yTask* t) {
    g_idle_add(kx_a11y_task_run, t);
}

// --- Bridge event callback (called from Zig on the SDL/render thread) ---
static void a11yBridgeCallback(void* userdata, KxBridgeEventC ev) {
    (void)userdata;
    if (!g_a11y_running.load()) return; // no a11y bus / shutting down
    KxA11yTask* t = new KxA11yTask();
    t->kind = ev.kind;
    t->node_id = ev.node_id;
    t->region = ev.region;
    t->text = nullptr;
    t->zig_owned = false;
    switch (ev.kind) {
        case KX_A11Y_TREE_DIRTY:
        case KX_A11Y_CONTROL_CHANGED:
            // Pull the dump HERE on the caller thread — the Zig semantic tree
            // is only safe to read from the thread semantics runs on.
            if (g_zig_root_node) {
                t->text = kx_a11y_dump_tree(g_zig_root_node);
                t->zig_owned = true;
            }
            if (!t->text) { delete t; return; }
            break;
        case KX_A11Y_ANNOUNCE:
            if (!ev.text || ev.text_len == 0) { delete t; return; }
            t->text = g_strndup(ev.text, ev.text_len); // borrowed payload — copy now
            break;
        case KX_A11Y_FOCUS_CHANGED:
            break;
        default:
            delete t;
            return;
    }
    postTask(t);
}

// --- a11y thread: pump the default GMainContext the adaptor hooked ---

static gpointer kxA11yThreadMain(gpointer) {
    GMainContext* ctx = g_main_context_default();
    while (g_a11y_running.load())
        g_main_context_iteration(ctx, TRUE);
    // Drain anything queued just before shutdown (a posted rebuild/announce).
    while (g_main_context_pending(ctx))
        g_main_context_iteration(ctx, FALSE);
    return nullptr;
}

// --- Public C API (called from Zig host.zig, like the macOS bridge) ---
extern "C" {

/// Initialize the ATK/AT-SPI bridge. `root_node` is the Klaxon root Node
/// (used to dump the semantic tree on tree_dirty).
void kx_a11y_init(void* root_node) {
    g_zig_root_node = root_node;
    // Register the C bridge callback with the Zig semantics module.
    kx_a11y_set_bridge(a11yBridgeCallback, nullptr);
    if (g_app_root) return; // already initialized

    // The application root must exist BEFORE adaptor_init — it calls
    // atk_get_root() synchronously and bails on NULL.
    g_app_root = KX_ATK_OBJECT(g_object_new(KX_TYPE_ATK_OBJECT, nullptr));
    g_app_root->role = ATK_ROLE_APPLICATION;
    g_app_root->label = g_strdup(g_get_prgname() ? g_get_prgname() : "klaxon");

    // Patch the BASE AtkUtilClass vfuncs — the Cally trick (see the header).
    // The class ref is never released: the vfuncs stay installed for the
    // process lifetime.
    AtkUtilClass* util_class = ATK_UTIL_CLASS(g_type_class_ref(ATK_TYPE_UTIL));
    util_class->get_root = kx_util_get_root;
    util_class->get_toolkit_name = kx_util_get_toolkit_name;
    util_class->get_toolkit_version = kx_util_get_toolkit_version;

    // Bridge onto the a11y D-Bus. Returns -1 without a session a11y bus
    // (headless CI) or when NO_AT_BRIDGE=1 — the app then runs with a11y
    // off, matching the other bridges' fail-soft behaviour.
    int argc = 1;
    char* arg0 = const_cast<char*>("klaxon");
    char* argv_arr[] = { arg0, nullptr };
    char** argv = argv_arr;
    if (atk_bridge_adaptor_init(&argc, &argv) != 0) {
        g_message("kx_a11y: no AT-SPI bus (headless or NO_AT_BRIDGE) — bridge inert");
        return;
    }
    g_bridge_inited = true;

    // The adaptor registered its D-Bus watches + timeouts on the default
    // GMainContext — pump it on a dedicated thread (the SDL loop never does).
    g_a11y_running.store(true);
    g_a11y_thread = g_thread_new("kx-a11y", kxA11yThreadMain, nullptr);

    // Populate from the current semantic tree — ATs may query before the
    // first tree_dirty (same as the iOS bridge's initial rebuild).
    if (char* dump = kx_a11y_dump_tree(root_node)) {
        KxA11yTask* t = new KxA11yTask();
        t->kind = KX_A11Y_TREE_DIRTY;
        t->node_id = 0;
        t->region = 0;
        t->text = dump;
        t->zig_owned = true;
        postTask(t);
    }
}

/// Shut down the bridge: unregister the callback, stop the a11y thread,
/// detach the adaptor, destroy the object tree.
void kx_a11y_shutdown(void) {
    kx_a11y_set_bridge(nullptr, nullptr);
    g_a11y_running.store(false);
    if (g_a11y_thread) {
        g_main_context_wakeup(g_main_context_default());
        g_thread_join(g_a11y_thread);
        g_a11y_thread = nullptr;
    }
    if (g_bridge_inited) {
        atk_bridge_adaptor_cleanup();
        g_bridge_inited = false;
    }
    // Single-threaded now: safe to tear down the object graph.
    for (auto& entry : g_obj_by_ptr) g_object_unref(entry.second);
    g_obj_by_ptr.clear();
    if (g_app_root) {
        g_object_unref(g_app_root);
        g_app_root = nullptr;
    }
    g_focused_ptr = 0;
    g_zig_root_node = nullptr;
}

/// Opaque handle on the application root AtkObject (API parity with the
/// other bridges).
void* kx_a11y_root_element(void) {
    return g_app_root;
}

} // extern "C"
