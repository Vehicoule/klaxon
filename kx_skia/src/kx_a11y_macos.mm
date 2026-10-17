// kx_a11y_macos.mm — macOS NSAccessibility bridge (Phase 3a).
//
// Maps Klaxon's semantic tree (ui/semantics.zig) to macOS NSAccessibility.
// Receives BridgeEventC events via setBridgeC, rebuilds the NSAccessibility
// hierarchy on tree_dirty, syncs focus, posts announcements.
//
// v1: basic role mapping (button, text, text_field, toggle, checkbox, radio,
// slider, image, group, list, list_item, dialog, progress, scrollbar, menu,
// tab). Focus sync + announcements. No actions (click via VoiceOver) yet.
#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <objc/runtime.h>

#include "kx_skia.h"
#include <stdint.h>
#include <stddef.h>

// --- Forward declarations from Zig (semantics bridge C ABI) ---
extern "C" {
    // BridgeEventC kinds (mirrors BridgeEvent.Kind in ui/semantics.zig).
    enum {
        KX_A11Y_TREE_DIRTY = 0,
        KX_A11Y_FOCUS_CHANGED = 1,
        KX_A11Y_ANNOUNCE = 2,
        KX_A11Y_CONTROL_CHANGED = 3,
    };
    // BridgeEventC — extern struct passed BY VALUE (mirrors BridgeEventC in
    // ui/semantics.zig, field for field). Do NOT flatten it to scalar
    // parameters: on arm64 a struct passed by value rides in registers
    // differently than flattened scalars, and a flattened callback reads
    // garbage.
    typedef struct {
        uint32_t kind;       // 0=tree_dirty 1=focus_changed 2=announce 3=control_changed
        uint64_t node_id;    // Node pointer (decimal in the dump)
        const uint8_t* text; // announce payload (borrowed during the call only)
        size_t text_len;
        uint32_t region;     // LiveRegion: 0=off 1=polite 2=assertive
    } KxBridgeEventC;
    // Install the C bridge callback (from ui/semantics.zig).
    void kx_a11y_set_bridge(void (*fn)(void* userdata, KxBridgeEventC event), void* userdata);
    // Build the semantic tree and return a JSON-ish flat description.
    // Returns a malloc'd string (caller frees) or NULL on error.
    // Format: "depth|role|label|value|focusable|ptr|checked|x|y|w|h\n" per node
    // (ptr = Node pointer in decimal, checked = 0/1/2; both ignored here).
    char* kx_a11y_dump_tree(void* root_node);
    void kx_a11y_free_string(char* s);
    void kx_a11y_focus_node(void* root_node, uint64_t ptr);
    void kx_a11y_activate_node(void* root_node, uint64_t ptr);
}

static uint64_t g_focused_ptr = 0;
static void* g_zig_root_node = NULL;

static NSWindow* activeWindow(void) {
    NSWindow* win = [NSApp mainWindow];
    if (!win && [[NSApp windows] count] > 0) {
        win = [[NSApp windows] objectAtIndex:0];
    }
    return win;
}

// --- KXA11yElement: wraps a flat semantic node description ---
@interface KXA11yElement : NSObject <NSAccessibilityElement>
{
@public
    NSString* _role;
    NSString* _label;
    NSString* _value;
    BOOL _focusable;
    uint64_t _ptr;
    int _checked;
    NSRect _frame;
    NSMutableArray<KXA11yElement*>* _children;
    KXA11yElement* _parent;
}
- (instancetype)initWithRole:(NSString*)role
                       label:(NSString*)label
                       value:(NSString*)value
                   focusable:(BOOL)focusable
                         ptr:(uint64_t)ptr
                     checked:(int)checked
                       frame:(NSRect)frame;
@end

@implementation KXA11yElement

- (instancetype)initWithRole:(NSString*)role label:(NSString*)label value:(NSString*)value
                   focusable:(BOOL)focusable ptr:(uint64_t)ptr checked:(int)checked frame:(NSRect)frame {
    self = [super init];
    if (self) {
        // MRC (-fno-objc-arc): copy the strings + alloc the array — the
        // autoreleased arguments would dangle after the pool drains.
        _role = [role copy];
        _label = [label copy];
        _value = [value copy];
        _focusable = focusable;
        _ptr = ptr;
        _checked = checked;
        _frame = frame;
        _children = [[NSMutableArray alloc] init];
    }
    return self;
}

- (void)dealloc {
    [_role release];
    [_label release];
    [_value release];
    [_children release]; // releases the child elements it retained
    [super dealloc];
}

- (BOOL)isAccessibilityElement { return YES; }

- (NSRect)accessibilityFrame {
    // Convert top-left window coordinates (_frame) into AppKit bottom-left
    // screen coordinates when a window is attached.
    NSWindow* win = activeWindow();
    NSView* cv = win ? [win contentView] : nil;
    if (win && cv) {
        CGFloat vh = cv.bounds.size.height;
        NSRect viewRect = NSMakeRect(
            _frame.origin.x,
            vh - _frame.origin.y - _frame.size.height,
            _frame.size.width,
            _frame.size.height
        );
        NSRect winRect = [cv convertRect:viewRect toView:nil];
        return [win convertRectToScreen:winRect];
    }
    return _frame;
}

- (id)accessibilityParent {
    if (_parent) return _parent;
    NSWindow* win = activeWindow();
    return (win && [win contentView]) ? (id)[win contentView] : (id)win;
}

- (NSArray*)accessibilityChildren { return _children; }
- (BOOL)isAccessibilityFocused { return _ptr != 0 && _ptr == g_focused_ptr; }

- (void)setAccessibilityFocused:(BOOL)focused {
    if (focused && g_zig_root_node && _ptr != 0) {
        kx_a11y_focus_node(g_zig_root_node, _ptr);
    }
}

- (BOOL)accessibilityPerformPress {
    if (!g_zig_root_node || _ptr == 0) return NO;
    kx_a11y_activate_node(g_zig_root_node, _ptr);
    return YES;
}

- (NSString*)accessibilityRole {
    // Map Klaxon role → NSAccessibility role.
    if ([_role isEqualToString:@"button"]) return NSAccessibilityButtonRole;
    if ([_role isEqualToString:@"text"]) return NSAccessibilityStaticTextRole;
    if ([_role isEqualToString:@"heading"]) return NSAccessibilityHeadingRole;
    if ([_role isEqualToString:@"text_field"]) return NSAccessibilityTextFieldRole;
    if ([_role isEqualToString:@"toggle"]) return NSAccessibilityCheckBoxRole;
    if ([_role isEqualToString:@"checkbox"]) return NSAccessibilityCheckBoxRole;
    if ([_role isEqualToString:@"radio"]) return NSAccessibilityRadioButtonRole;
    if ([_role isEqualToString:@"slider"]) return NSAccessibilitySliderRole;
    if ([_role isEqualToString:@"image"]) return NSAccessibilityImageRole;
    if ([_role isEqualToString:@"progress"]) return NSAccessibilityProgressIndicatorRole;
    if ([_role isEqualToString:@"scrollbar"]) return NSAccessibilityScrollBarRole;
    if ([_role isEqualToString:@"list"]) return NSAccessibilityListRole;
    if ([_role isEqualToString:@"list_item"]) return NSAccessibilityRowRole;
    if ([_role isEqualToString:@"dialog"]) return NSAccessibilityGroupRole;
    if ([_role isEqualToString:@"alert"]) return NSAccessibilityGroupRole;
    if ([_role isEqualToString:@"menu"]) return NSAccessibilityMenuRole;
    if ([_role isEqualToString:@"menu_item"]) return NSAccessibilityMenuItemRole;
    if ([_role isEqualToString:@"tab"]) return NSAccessibilityRadioButtonRole;
    if ([_role isEqualToString:@"link"]) return NSAccessibilityLinkRole;
    return NSAccessibilityGroupRole;
}

- (NSString*)accessibilityLabel { return _label; }
- (id)accessibilityValue {
    if (_value && [_value length] > 0) return _value;
    if (_checked != 0 &&
        ([_role isEqualToString:@"toggle"] ||
         [_role isEqualToString:@"checkbox"] ||
         [_role isEqualToString:@"radio"] ||
         [_role isEqualToString:@"tab"])) {
        return @(_checked == 2 ? 1 : 0);
    }
    return _value;
}

@end

// --- Bridge state ---
static KXA11yElement* g_root = nil;

static KXA11yElement* findElementByPtr(KXA11yElement* el, uint64_t ptr) {
    if (!el || ptr == 0) return nil;
    if (el->_ptr == ptr) return el;
    for (KXA11yElement* child in el->_children) {
        KXA11yElement* found = findElementByPtr(child, ptr);
        if (found) return found;
    }
    return nil;
}

static void attachRootToWindow(void) {
    NSWindow* win = activeWindow();
    NSView* cv = win ? [win contentView] : nil;
    if (cv) {
        if (g_root) {
            [cv setAccessibilityChildren:@[g_root]];
        } else {
            [cv setAccessibilityChildren:nil];
        }
    }
}

// Parse the flat tree dump and build the NSAccessibility hierarchy.
static KXA11yElement* buildHierarchy(const char* dump) {
    if (!dump) return nil;
    // The dump format is "depth|role|label|value|focusable|ptr|checked|x|y|w|h|vmin|vmax|vnow\n"
    KXA11yElement* root = [[KXA11yElement alloc] initWithRole:@"group"
                                                        label:@"Klaxon"
                                                        value:nil
                                                    focusable:NO
                                                          ptr:0
                                                      checked:0
                                                        frame:NSMakeRect(0, 0, 800, 600)];
    KXA11yElement* stack[128];
    for (int i = 0; i < 128; i++) stack[i] = nil;
    const char* p = dump;
    while (*p) {
        const char* eol = strchr(p, '\n');
        size_t len = eol ? (size_t)(eol - p) : strlen(p);
        char line[2048];
        if (len >= sizeof(line)) len = sizeof(line) - 1;
        memcpy(line, p, len);
        line[len] = 0;
        // Split on '|': depth|role|label|value|focusable|ptr|checked|x|y|w|h
        char* fields[11] = {0};
        int nf = 0;
        fields[nf++] = line;
        for (char* q = line; *q && nf < 11; q++) {
            if (*q == '|') {
                *q = 0;
                fields[nf++] = q + 1;
            }
        }
        if (nf >= 11) {
            const int depth = atoi(fields[0]);
            NSString* role = fields[1][0] ? [NSString stringWithUTF8String:fields[1]] : @"group";
            NSString* label = fields[2][0] ? [NSString stringWithUTF8String:fields[2]] : nil;
            NSString* value = fields[3][0] ? [NSString stringWithUTF8String:fields[3]] : nil;
            const int focusable = atoi(fields[4]);
            const uint64_t ptr = strtoull(fields[5], NULL, 10);
            const int checked = atoi(fields[6]);
            const float x = strtof(fields[7], NULL);
            const float y = strtof(fields[8], NULL);
            const float w = strtof(fields[9], NULL);
            const float h = strtof(fields[10], NULL);
            KXA11yElement* child = [[KXA11yElement alloc] initWithRole:role
                                                               label:label
                                                               value:value
                                                          focusable:(BOOL)focusable
                                                                 ptr:ptr
                                                             checked:checked
                                                              frame:NSMakeRect(x, y, w, h)];
            // Parent = nearest element on the stack above this depth (the
            // dump's depth-0 root itself attaches under the synthetic root).
            KXA11yElement* parent = root;
            for (int d = depth - 1; d >= 0; d--) {
                if (stack[d]) { parent = stack[d]; break; }
            }
            child->_parent = parent;
            [parent->_children addObject:child];
            [child release]; // the array owns it now
            if (depth < 128) {
                stack[depth] = child;
                // A new element at this depth closes every deeper level.
                for (int d = depth + 1; d < 128 && stack[d]; d++) stack[d] = nil;
            }
        }
        if (!eol) break;
        p = eol + 1;
    }
    return root;
}

static void rebuildFromZig(void) {
    if (!g_zig_root_node) return;
    char* dump = kx_a11y_dump_tree(g_zig_root_node);
    if (dump) {
        @autoreleasepool {
            KXA11yElement* new_root = buildHierarchy(dump);
            if (new_root) {
                [g_root release]; // MRC: drop the old hierarchy
                g_root = new_root;
                attachRootToWindow();
            }
        }
        kx_a11y_free_string(dump);
    }
}

// Bridge event callback (called from Zig via setBridgeC).
static void a11y_bridge_callback(void* userdata, KxBridgeEventC event) {
    (void)userdata;
    switch (event.kind) {
        case KX_A11Y_TREE_DIRTY: {
            rebuildFromZig();
            break;
        }
        case KX_A11Y_FOCUS_CHANGED: {
            g_focused_ptr = event.node_id;
            @autoreleasepool {
                KXA11yElement* el = findElementByPtr(g_root, event.node_id);
                id target = el ? (id)el : (id)activeWindow();
                if (target) {
                    NSAccessibilityPostNotification(target, NSAccessibilityFocusedUIElementChangedNotification);
                }
            }
            break;
        }
        case KX_A11Y_ANNOUNCE: {
            if (event.text && event.text_len > 0) {
                NSString* msg = [[NSString alloc] initWithBytes:event.text
                                                          length:event.text_len
                                                        encoding:NSUTF8StringEncoding];
                if (msg) {
                    NSWindow* win = activeWindow();
                    if (win) {
                        NSDictionary* info = @{
                            NSAccessibilityAnnouncementKey: msg,
                            NSAccessibilityPriorityKey: @(event.region == 2 ? 10 : 5) // assertive=high
                        };
                        NSAccessibilityPostNotificationWithUserInfo(win, NSAccessibilityAnnouncementRequestedNotification, info);
                    }
                    [msg release]; // MRC: balance alloc/initWithBytes
                }
            }
            break;
        }
        case KX_A11Y_CONTROL_CHANGED: {
            rebuildFromZig();
            @autoreleasepool {
                KXA11yElement* el = findElementByPtr(g_root, event.node_id);
                if (el) {
                    NSAccessibilityPostNotification(el, NSAccessibilityValueChangedNotification);
                }
            }
            break;
        }
    }
}

// --- Public C API (called from Zig host.zig) ---
extern "C" {

/// Initialize the NSAccessibility bridge. `root_node` is the Klaxon root Node
/// (used to dump the semantic tree on tree_dirty).
void kx_a11y_init(void* root_node) {
    g_zig_root_node = root_node;
    g_focused_ptr = 0;
    // Register the C bridge callback with the Zig semantics module.
    kx_a11y_set_bridge(a11y_bridge_callback, NULL);
    // Register the app as an accessibility client and populate initial tree.
    [NSApplication sharedApplication];
    rebuildFromZig();
}

/// Shut down the bridge.
void kx_a11y_shutdown(void) {
    [g_root release];
    g_root = nil;
    g_focused_ptr = 0;
    attachRootToWindow();
    g_zig_root_node = NULL;
    kx_a11y_set_bridge(NULL, NULL);
}

/// Returns the root NSAccessibility element (for NSApp accessibility hookup).
id kx_a11y_root_element(void) {
    return g_root;
}

} // extern "C"
