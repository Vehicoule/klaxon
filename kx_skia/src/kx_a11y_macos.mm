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
}

// --- KXA11yElement: wraps a flat semantic node description ---
@interface KXA11yElement : NSObject <NSAccessibilityElement>
{
@public
    NSString* _role;
    NSString* _label;
    NSString* _value;
    BOOL _focusable;
    NSRect _frame;
    NSMutableArray<KXA11yElement*>* _children;
    KXA11yElement* _parent;
}
- (instancetype)initWithRole:(NSString*)role
                       label:(NSString*)label
                       value:(NSString*)value
                   focusable:(BOOL)focusable
                       frame:(NSRect)frame;
@end

@implementation KXA11yElement

- (instancetype)initWithRole:(NSString*)role label:(NSString*)label value:(NSString*)value
                   focusable:(BOOL)focusable frame:(NSRect)frame {
    self = [super init];
    if (self) {
        // MRC (-fno-objc-arc): copy the strings + alloc the array — the
        // autoreleased arguments would dangle after the pool drains.
        _role = [role copy];
        _label = [label copy];
        _value = [value copy];
        _focusable = focusable;
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
- (NSRect)accessibilityFrame { return _frame; }
- (id)accessibilityParent { return _parent ?: [NSApp mainWindow]; }
- (NSArray*)accessibilityChildren { return _children; }
- (BOOL)isAccessibilityFocused { return NO; } // v1: focus sync is logged only

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
- (NSString*)accessibilityValue { return _value; }

@end

// --- Bridge state ---
static KXA11yElement* g_root = nil;
static void* g_zig_root_node = NULL;

// Parse the flat tree dump and build the NSAccessibility hierarchy.
static KXA11yElement* buildHierarchy(const char* dump) {
    if (!dump) return nil;
    // v1: create a single root group (full hierarchy rebuild is a follow-up).
    // The dump format is "depth|role|label|value|focusable|ptr|checked|x|y|w|h\n"
    // per line. ptr/checked are parsed for format compatibility and ignored
    // — this bridge keys off the x/y/w/h rects.
    KXA11yElement* root = [[KXA11yElement alloc] initWithRole:@"group"
                                                        label:@"Klaxon"
                                                        value:nil
                                                    focusable:NO
                                                        frame:NSMakeRect(0, 0, 800, 600)];
    // v1: add one child per line (flat list under the root). Manual
    // split — sscanf's [^|] scansets reject EMPTY fields, so a control
    // with no label used to vanish from VoiceOver entirely.
    const char* p = dump;
    while (*p) {
        const char* eol = strchr(p, '\n');
        size_t len = eol ? (size_t)(eol - p) : strlen(p);
        // Fields are sanitized ≤512B each; 2K covers an 11-field line.
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
            (void)atoi(fields[0]); // depth — v1 is flat
            NSString* role = fields[1][0] ? [NSString stringWithUTF8String:fields[1]] : @"group";
            NSString* label = fields[2][0] ? [NSString stringWithUTF8String:fields[2]] : nil;
            NSString* value = fields[3][0] ? [NSString stringWithUTF8String:fields[3]] : nil;
            const int focusable = atoi(fields[4]);
            const float x = strtof(fields[7], NULL);
            const float y = strtof(fields[8], NULL);
            const float w = strtof(fields[9], NULL);
            const float h = strtof(fields[10], NULL);
            KXA11yElement* child = [[KXA11yElement alloc] initWithRole:role
                                                               label:label
                                                               value:value
                                                          focusable:(BOOL)focusable
                                                              frame:NSMakeRect(x, y, w, h)];
            child->_parent = root;
            [root->_children addObject:child];
            [child release]; // the array owns it now
        }
        if (!eol) break;
        p = eol + 1;
    }
    return root;
}

// Bridge event callback (called from Zig via setBridgeC).
static void a11y_bridge_callback(void* userdata, KxBridgeEventC event) {
    (void)userdata;
    (void)event.node_id;
    switch (event.kind) {
        case KX_A11Y_TREE_DIRTY: {
            // Rebuild the hierarchy from the semantic tree dump.
            if (g_zig_root_node) {
                char* dump = kx_a11y_dump_tree(g_zig_root_node);
                if (dump) {
                    @autoreleasepool {
                        KXA11yElement* new_root = buildHierarchy(dump);
                        if (new_root) {
                            [g_root release]; // MRC: drop the old hierarchy
                            g_root = new_root;
                        }
                    }
                    kx_a11y_free_string(dump);
                }
            }
            break;
        }
        case KX_A11Y_FOCUS_CHANGED:
            // v1: logged only (NSAccessibility focus sync is a follow-up).
            break;
        case KX_A11Y_ANNOUNCE: {
            if (event.text && event.text_len > 0) {
                NSString* msg = [[NSString alloc] initWithBytes:event.text
                                                          length:event.text_len
                                                        encoding:NSUTF8StringEncoding];
                if (msg) {
                    NSDictionary* info = @{
                        NSAccessibilityAnnouncementKey: msg,
                        NSAccessibilityPriorityKey: @(event.region == 2 ? 10 : 5) // assertive=high
                    };
                    NSAccessibilityPostNotificationWithUserInfo([NSApp mainWindow], NSAccessibilityAnnouncementRequestedNotification, info);
                }
            }
            break;
        }
        case KX_A11Y_CONTROL_CHANGED:
            break;
    }
}

// --- Public C API (called from Zig host.zig) ---
extern "C" {

/// Initialize the NSAccessibility bridge. `root_node` is the Klaxon root Node
/// (used to dump the semantic tree on tree_dirty).
void kx_a11y_init(void* root_node) {
    g_zig_root_node = root_node;
    // Register the C bridge callback with the Zig semantics module.
    kx_a11y_set_bridge(a11y_bridge_callback, NULL);
    // Register the app as an accessibility client.
    [NSApplication sharedApplication];
}

/// Shut down the bridge.
void kx_a11y_shutdown(void) {
    [g_root release];
    g_root = nil;
    g_zig_root_node = NULL;
    kx_a11y_set_bridge(NULL, NULL);
}

/// Returns the root NSAccessibility element (for NSApp accessibility hookup).
id kx_a11y_root_element(void) {
    return g_root;
}

} // extern "C"
