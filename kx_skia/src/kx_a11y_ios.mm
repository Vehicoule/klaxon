// kx_a11y_ios.mm — iOS UIAccessibility bridge (Phase 3de, VoiceOver).
//
// Mirror of kx_a11y_macos.mm (NSAccessibility), adapted to UIAccessibility:
// same C ABI (kx_a11y_init/shutdown/root_element implemented here, the Zig
// side in src/a11y_bridge.zig), same flat dump format
// ("depth|role|label|value|focusable|ptr|checked|x|y|w|h\n"), same bridge
// events — VoiceOver-flavored notifications (announcement / layout-changed).
//
// VoiceOver → Klaxon: each element's accessibilityActivate (double-tap)
// calls kx_a11y_activate_node (Zig: synthesized down+up at the node's
// visual center through the input router); accessibilityElementDidBecomeFocused
// calls kx_a11y_focus_node (Zig: FocusManager.focusNode).
//
// Klaxon → VoiceOver: tree_dirty rebuilds the flat element list from the
// dump; focus_changed posts UIAccessibilityLayoutChangedNotification with
// the matching element (moves VoiceOver's cursor); announce posts
// UIAccessibilityAnnouncementNotification.
//
// Container: UIApplication.sharedApplication.keyWindow.rootViewController.view
// (SDL's window — deps/SDL/src/video/uikit/SDL_uikitwindow.m makes it key).
// isAccessibilityElement = NO + accessibilityElements = the flat list — the
// properties are set on the root view itself (UIAccessibilityContainer
// informal protocol), no overlay subview: touches and SDL's own subviews are
// untouched.
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#include <stdint.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>

// --- Forward declarations from Zig (semantics bridge C ABI) ---
extern "C" {
    // BridgeEventC kinds (mirrors BridgeEvent.Kind in ui/semantics.zig).
    enum {
        KX_A11Y_TREE_DIRTY = 0,
        KX_A11Y_FOCUS_CHANGED = 1,
        KX_A11Y_ANNOUNCE = 2,
        KX_A11Y_CONTROL_CHANGED = 3,
    };
    // Install the C bridge callback (from ui/semantics.zig).
    void kx_a11y_set_bridge(void (*fn)(void* userdata, uint32_t kind, uint64_t node_id,
                                       const char* text, size_t text_len, uint32_t region),
                            void* userdata);
    // Flat semantic-tree dump. malloc'd — free with kx_a11y_free_string.
    char* kx_a11y_dump_tree(void* root_node);
    void kx_a11y_free_string(char* s);
    // VoiceOver → Klaxon (Zig exports in src/a11y_bridge.zig).
    void kx_a11y_focus_node(void* root_node, uint64_t ptr);
    void kx_a11y_activate_node(void* root_node, uint64_t ptr);
}

// --- Bridge state ---
static void* g_zig_root_node = NULL;
static UIView* g_root_view = nil;        // retained: the accessibility container
static NSMutableArray* g_elements = nil; // KXUIAccessibilityElement (flat list)

// --- KXUIAccessibilityElement: wraps a flat semantic node description ---
@interface KXUIAccessibilityElement : UIAccessibilityElement {
@public
    NSString* _role;
    NSString* _label;
    NSString* _value;
    BOOL _focusable;
    uint64_t _ptr; // Node pointer (the dump's ptr field) — keys the Zig callbacks
    int _checked;  // 0 = null, 1 = false, 2 = true
    CGRect _frame; // container (window) points
}
- (instancetype)initWithRole:(NSString*)role
                       label:(NSString*)label
                       value:(NSString*)value
                   focusable:(BOOL)focusable
                         ptr:(uint64_t)ptr
                     checked:(int)checked
                       frame:(CGRect)frame
                   container:(id)container;
@end

@implementation KXUIAccessibilityElement

- (instancetype)initWithRole:(NSString*)role label:(NSString*)label value:(NSString*)value
                   focusable:(BOOL)focusable ptr:(uint64_t)ptr checked:(int)checked
                       frame:(CGRect)frame container:(id)container {
    self = [super initWithAccessibilityContainer:container];
    if (self) {
        _role = [role retain]; // MRC: the ivars own their strings
        _label = [label retain];
        _value = [value retain];
        _focusable = focusable;
        _ptr = ptr;
        _checked = checked;
        _frame = frame;
    }
    return self;
}

- (void)dealloc {
    [_role release];
    [_label release];
    [_value release];
    [super dealloc];
}

- (BOOL)isAccessibilityElement { return YES; }

- (NSString*)accessibilityLabel {
    // An empty label announces nothing — VoiceOver skips nil labels.
    return [_label length] > 0 ? _label : nil;
}

- (NSString*)accessibilityValue {
    if ([_value length] > 0) return _value;
    // Toggle-like roles expose their checked state as on/off.
    if (_checked != 0 &&
        ([_role isEqualToString:@"toggle"] ||
         [_role isEqualToString:@"checkbox"] ||
         [_role isEqualToString:@"radio"])) {
        return _checked == 2 ? @"on" : @"off";
    }
    return nil;
}

- (CGRect)accessibilityFrame {
    // UIAccessibility frames are screen coordinates; the dump's rects are
    // in window (container) points — convert (identity for a full-screen
    // app, correct if the root view is ever offset).
    id container = self.accessibilityContainer;
    if ([container isKindOfClass:[UIView class]]) {
        return [container convertRect:_frame toView:nil];
    }
    return _frame;
}

- (UIAccessibilityTraits)accessibilityTraits {
    // Klaxon role → UIAccessibilityTraits.
    UIAccessibilityTraits t = UIAccessibilityTraitNone;
    if ([_role isEqualToString:@"button"]) t = UIAccessibilityTraitButton;
    else if ([_role isEqualToString:@"text"]) t = UIAccessibilityTraitStaticText;
    else if ([_role isEqualToString:@"heading"]) t = UIAccessibilityTraitHeader;
    else if ([_role isEqualToString:@"link"]) t = UIAccessibilityTraitLink;
    else if ([_role isEqualToString:@"image"]) t = UIAccessibilityTraitImage;
    else if ([_role isEqualToString:@"toggle"]) t = UIAccessibilityTraitButton;
    else if ([_role isEqualToString:@"checkbox"]) t = UIAccessibilityTraitButton;
    else if ([_role isEqualToString:@"radio"]) t = UIAccessibilityTraitButton;
    else if ([_role isEqualToString:@"slider"]) t = UIAccessibilityTraitAdjustable;
    else if ([_role isEqualToString:@"progress"]) t = UIAccessibilityTraitUpdatesFrequently;
    else if ([_role isEqualToString:@"list"]) t = UIAccessibilityTraitButton;
    else if ([_role isEqualToString:@"list_item"]) t = UIAccessibilityTraitButton;
    else if ([_role isEqualToString:@"menu"]) t = UIAccessibilityTraitButton;
    else if ([_role isEqualToString:@"menu_item"]) t = UIAccessibilityTraitButton;
    else if ([_role isEqualToString:@"tab"]) t = UIAccessibilityTraitButton;
    // text_field: no dedicated trait — the label + value carry it.
    // Selected state (list items, checked = 2).
    if (_checked == 2 &&
        ([_role isEqualToString:@"list"] || [_role isEqualToString:@"list_item"])) {
        t |= UIAccessibilityTraitSelected;
    }
    return t;
}

- (BOOL)accessibilityActivate {
    // VoiceOver double-tap → Klaxon: synthesized down+up at the node center.
    kx_a11y_activate_node(g_zig_root_node, _ptr);
    return YES;
}

- (void)accessibilityElementDidBecomeFocused {
    // VoiceOver's cursor landed here → move Klaxon's focus to the node.
    kx_a11y_focus_node(g_zig_root_node, _ptr);
}

@end

// --- Dump parsing ---
// One dump line: "depth|role|label|value|focusable|ptr|checked|x|y|w|h".
// Empty fields are legal (label/value may be "") — a manual '|' split keeps
// them (sscanf's %[^|] fails on an empty field and would drop the node).
static int splitFields(const char* line, const char* fields[11], size_t lens[11]) {
    int nf = 0;
    const char* start = line;
    for (const char* p = line; nf < 11; p++) {
        if (*p == '|' || *p == '\n' || *p == '\0') {
            fields[nf] = start;
            lens[nf] = (size_t)(p - start);
            nf++;
            if (*p != '|') break;
            start = p + 1;
        }
    }
    return nf;
}

static void copyField(const char* src, size_t len, char* dst, size_t dst_sz) {
    size_t n = len < dst_sz - 1 ? len : dst_sz - 1;
    memcpy(dst, src, n);
    dst[n] = '\0';
}

// Rebuild the flat element list from the dump (tree_dirty + once at init).
// Elements are keyed by their Node pointer (the dump's ptr field) so
// focus_changed / control_changed events can find them.
static void rebuildElements(const char* dump) {
    [g_elements removeAllObjects];
    if (!dump) return;
    const char* p = dump;
    while (*p) {
        const char* fields[11] = {0};
        size_t lens[11] = {0};
        if (splitFields(p, fields, lens) < 11) {
            while (*p && *p != '\n') p++;
            if (*p == '\n') p++;
            continue;
        }
        char role[64], label[256], value[256];
        char f_depth[16], f_focusable[8], f_ptr[32], f_checked[8];
        char f_x[32], f_y[32], f_w[32], f_h[32];
        copyField(fields[0], lens[0], f_depth, sizeof f_depth);
        copyField(fields[1], lens[1], role, sizeof role);
        copyField(fields[2], lens[2], label, sizeof label);
        copyField(fields[3], lens[3], value, sizeof value);
        copyField(fields[4], lens[4], f_focusable, sizeof f_focusable);
        copyField(fields[5], lens[5], f_ptr, sizeof f_ptr);
        copyField(fields[6], lens[6], f_checked, sizeof f_checked);
        copyField(fields[7], lens[7], f_x, sizeof f_x);
        copyField(fields[8], lens[8], f_y, sizeof f_y);
        copyField(fields[9], lens[9], f_w, sizeof f_w);
        copyField(fields[10], lens[10], f_h, sizeof f_h);
        (void)f_depth; // depth: the iOS bridge keeps a flat list (v1)
        KXUIAccessibilityElement* el = [[KXUIAccessibilityElement alloc]
            initWithRole:[NSString stringWithUTF8String:role]
                   label:[NSString stringWithUTF8String:label]
                   value:[NSString stringWithUTF8String:value]
               focusable:(BOOL)atoi(f_focusable)
                     ptr:strtoull(f_ptr, NULL, 10)
                 checked:atoi(f_checked)
                   frame:CGRectMake(strtof(f_x, NULL), strtof(f_y, NULL),
                                 strtof(f_w, NULL), strtof(f_h, NULL))
               container:g_root_view];
        [g_elements addObject:el];
        [el release]; // the array owns it now (MRC)
        // Advance past this line.
        while (*p && *p != '\n') p++;
        if (*p == '\n') p++;
    }
    // The root view's accessibilityElements may hold a copy of the previous
    // array — re-assign so VoiceOver reads the fresh list, then tell it the
    // layout changed (it re-reads the container's elements).
    if (g_root_view) {
        g_root_view.accessibilityElements = g_elements;
        UIAccessibilityPostNotification(UIAccessibilityLayoutChangedNotification, nil);
    }
}

static KXUIAccessibilityElement* findElementByPtr(uint64_t ptr) {
    for (KXUIAccessibilityElement* el in g_elements) {
        if (el->_ptr == ptr) return el;
    }
    return nil;
}

// --- Bridge event callback (called from Zig via setBridgeC) ---
static void a11y_bridge_callback(void* userdata, uint32_t kind, uint64_t node_id,
                                 const char* text, size_t text_len, uint32_t region) {
    (void)userdata;
    (void)region; // announcement priority is a macOS (NSAccessibility) concept
    switch (kind) {
        case KX_A11Y_TREE_DIRTY: {
            // Rebuild the flat element list from the semantic tree dump.
            if (g_zig_root_node) {
                char* dump = kx_a11y_dump_tree(g_zig_root_node);
                if (dump) {
                    @autoreleasepool {
                        rebuildElements(dump);
                    }
                    kx_a11y_free_string(dump);
                }
            }
            break;
        }
        case KX_A11Y_FOCUS_CHANGED: {
            // Klaxon's focus moved (keyboard/pointer) → move VoiceOver's
            // cursor to the matching element.
            KXUIAccessibilityElement* el = findElementByPtr(node_id);
            if (el) {
                UIAccessibilityPostNotification(UIAccessibilityLayoutChangedNotification, el);
            }
            break;
        }
        case KX_A11Y_ANNOUNCE: {
            if (text && text_len > 0) {
                NSString* msg = [[NSString alloc] initWithBytes:text
                                                          length:text_len
                                                        encoding:NSUTF8StringEncoding];
                if (msg) {
                    UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification, msg);
                    [msg release]; // posted synchronously — release after posting
                }
            }
            break;
        }
        case KX_A11Y_CONTROL_CHANGED: {
            // A control's value/checked changed — refresh that element.
            KXUIAccessibilityElement* el = findElementByPtr(node_id);
            if (el) {
                UIAccessibilityPostNotification(UIAccessibilityLayoutChangedNotification, el);
            }
            break;
        }
    }
}

// SDL's window: UIApplication.sharedApplication.keyWindow.rootViewController.view.
static UIWindow* keyWindow(void) {
    UIApplication* app = [UIApplication sharedApplication];
    // SDL's UIKit backend creates a plain UIWindow and makes it key
    // (SDL_uikitwindow.m: -makeKeyAndVisible) — no UIScene adoption — so
    // UIApplication.keyWindow is the reliable lookup (deprecated in iOS 13
    // only for multi-scene apps; suppressed here on purpose).
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    if (app.keyWindow) return app.keyWindow;
#pragma clang diagnostic pop
    // Scene-based hosts: scan the window scenes for the key window.
    for (UIScene* scene in app.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        UIWindowScene* ws = (UIWindowScene*)scene;
        for (UIWindow* w in ws.windows) {
            if (w.isKeyWindow) return w;
        }
    }
    return nil;
}

// --- Public C API (called from Zig kx.zig c_extern) ---
extern "C" {

/// Initialize the UIAccessibility bridge. `root_node` is the Klaxon root
/// Node (used to dump the semantic tree on tree_dirty).
void kx_a11y_init(void* root_node) {
    g_zig_root_node = root_node;
    // Register the C bridge callback with the Zig semantics module.
    kx_a11y_set_bridge(a11y_bridge_callback, NULL);
    @autoreleasepool {
        g_elements = [[NSMutableArray alloc] init]; // owned by the bridge
        // The container is the app's root view: not an element itself, it
        // exposes the flat accessibilityElements list to VoiceOver.
        UIWindow* window = keyWindow();
        UIView* root_view = window.rootViewController.view;
        if (root_view) {
            g_root_view = [root_view retain];
            g_root_view.isAccessibilityElement = NO;
            g_root_view.accessibilityElements = g_elements;
        }
        // Populate from the current semantic tree (tree_dirty rebuilds it,
        // but VoiceOver may query before the first event).
        char* dump = kx_a11y_dump_tree(g_zig_root_node);
        if (dump) {
            rebuildElements(dump);
            kx_a11y_free_string(dump);
        }
    }
}

/// Shut down the bridge.
void kx_a11y_shutdown(void) {
    @autoreleasepool {
        if (g_root_view) {
            g_root_view.accessibilityElements = nil;
            g_root_view.isAccessibilityElement = YES; // restore the default
            [g_root_view release];
            g_root_view = nil;
        }
        [g_elements removeAllObjects];
        [g_elements release];
        g_elements = nil;
    }
    g_zig_root_node = NULL;
    kx_a11y_set_bridge(NULL, NULL);
}

/// Returns the container view (the accessibility root for VoiceOver).
id kx_a11y_root_element(void) {
    return g_root_view;
}

} // extern "C"
