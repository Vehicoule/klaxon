// klaxon.h — Klaxon's canonical C ABI contract (ADR-0009).
//
// Exposes the language-agnostic boundary for driving the Klaxon UI framework
// from C or any FFI host (LuaJIT, Python ctypes/cffi, Go cgo, Swift, Kotlin/Native,
// C# P/Invoke).
//
// Boundary rules (ADR-0009):
//   1. No Zig-specific types cross this header (no slices, optionals, error unions).
//   2. All framework objects cross as opaque pointers (`kx_node*`, `kx_signal_*`).
//   3. Callbacks are plain C function pointers + `void* userdata`.
//   4. Strings crossing ownership are NUL-terminated and freed via the matching
//      `kx_*_free_string` / `kx_free_json` entry point.

#ifndef KLAXON_H
#define KLAXON_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifndef KX_SKIA_H
#include "../kx_skia/include/kx_skia.h"
#endif

#ifdef __cplusplus
extern "C" {
#endif

// --- Geometry & Layout Plain Data ---

typedef struct kx_rect {
    float x;
    float y;
    float w;
    float h;
} kx_rect;

typedef struct kx_size {
    float w;
    float h;
} kx_size;

typedef struct kx_constraints {
    float min_w;
    float max_w;
    float min_h;
    float max_h;
} kx_constraints;

typedef struct kx_edge_insets {
    float top;
    float right;
    float bottom;
    float left;
} kx_edge_insets;

// --- Accessibility Bridge Event (matches ui.semantics.BridgeEventC) ---

typedef enum kx_a11y_event_kind {
    KX_A11Y_TREE_DIRTY = 0,
    KX_A11Y_FOCUS_CHANGED = 1,
    KX_A11Y_ANNOUNCE = 2,
    KX_A11Y_CONTROL_CHANGED = 3,
} kx_a11y_event_kind;

typedef enum kx_a11y_live_region {
    KX_A11Y_LIVE_OFF = 0,
    KX_A11Y_LIVE_POLITE = 1,
    KX_A11Y_LIVE_ASSERTIVE = 2,
} kx_a11y_live_region;

typedef struct kx_a11y_bridge_event {
    uint32_t kind;
    uint64_t node_id;
    const uint8_t* text;
    size_t text_len;
    uint32_t region;
} kx_a11y_bridge_event;

typedef void (*kx_a11y_bridge_fn)(void* userdata, kx_a11y_bridge_event event);

// --- Compile-time ABI layout verification ---
#if defined(__cplusplus)
static_assert(sizeof(kx_rect) == 16, "kx_rect must be 16 bytes");
static_assert(sizeof(kx_size) == 8, "kx_size must be 8 bytes");
static_assert(sizeof(kx_constraints) == 16, "kx_constraints must be 16 bytes");
static_assert(sizeof(kx_edge_insets) == 16, "kx_edge_insets must be 16 bytes");
#elif defined(__STDC_VERSION__) && __STDC_VERSION__ >= 201112L
_Static_assert(sizeof(kx_rect) == 16, "kx_rect must be 16 bytes");
_Static_assert(sizeof(kx_size) == 8, "kx_size must be 8 bytes");
_Static_assert(sizeof(kx_constraints) == 16, "kx_constraints must be 16 bytes");
_Static_assert(sizeof(kx_edge_insets) == 16, "kx_edge_insets must be 16 bytes");
#endif

// --- Opaque Framework Handles ---

typedef struct kx_node kx_node;
typedef struct kx_signal_i32 kx_signal_i32;
typedef struct kx_signal_f32 kx_signal_f32;
typedef struct kx_signal_bool kx_signal_bool;

typedef void (*kx_callback_fn)(void* userdata);

// --- Versioning ---

const char* kx_c_abi_version(void);

// --- Signals (Phase 1a / ADR-0009 C-subscribable reactivity) ---

kx_signal_i32* kx_signal_i32_create(int32_t initial);
int32_t kx_signal_i32_get(kx_signal_i32* sig);
void kx_signal_i32_set(kx_signal_i32* sig, int32_t value);
void kx_signal_i32_subscribe(kx_signal_i32* sig, kx_callback_fn fn_ptr, void* userdata);
void kx_signal_i32_unsubscribe(kx_signal_i32* sig, kx_callback_fn fn_ptr, void* userdata);
void kx_signal_i32_destroy(kx_signal_i32* sig);

kx_signal_f32* kx_signal_f32_create(float initial);
float kx_signal_f32_get(kx_signal_f32* sig);
void kx_signal_f32_set(kx_signal_f32* sig, float value);
void kx_signal_f32_subscribe(kx_signal_f32* sig, kx_callback_fn fn_ptr, void* userdata);
void kx_signal_f32_unsubscribe(kx_signal_f32* sig, kx_callback_fn fn_ptr, void* userdata);
void kx_signal_f32_destroy(kx_signal_f32* sig);

kx_signal_bool* kx_signal_bool_create(bool initial);
bool kx_signal_bool_get(kx_signal_bool* sig);
void kx_signal_bool_set(kx_signal_bool* sig, bool value);
void kx_signal_bool_subscribe(kx_signal_bool* sig, kx_callback_fn fn_ptr, void* userdata);
void kx_signal_bool_unsubscribe(kx_signal_bool* sig, kx_callback_fn fn_ptr, void* userdata);
void kx_signal_bool_destroy(kx_signal_bool* sig);

// --- Retained Widget Tree Nodes ---

kx_rect kx_node_get_bounds(const kx_node* node);
void kx_node_set_bounds(kx_node* node, kx_rect bounds);
void kx_node_layout(kx_node* node, kx_rect bounds);
void kx_node_mark_dirty(kx_node* node);
void kx_node_mark_layout_dirty(kx_node* node);
bool kx_node_is_visible(const kx_node* node);
void kx_node_set_visible(kx_node* node, bool visible);
size_t kx_node_child_count(const kx_node* node);
void kx_node_destroy(kx_node* node);

// --- Declarative Registry / JSON Tree Serialization ---

kx_node* kx_tree_from_json(const char* json_utf8, size_t json_len, void** out_build_ctx);
char* kx_tree_to_json(kx_node* root, void* build_ctx);
void kx_free_json(char* json_str);
void kx_build_ctx_destroy(void* build_ctx);

// --- Accessibility Bridge Entry Points ---

void kx_a11y_set_bridge(kx_a11y_bridge_fn fn_ptr, void* userdata);
char* kx_a11y_dump_tree(void* root_node);
void kx_a11y_free_string(char* s);
void kx_a11y_focus_node(void* root_node, uint64_t ptr);
void kx_a11y_activate_node(void* root_node, uint64_t ptr);

#ifdef __cplusplus
}
#endif

#endif // KLAXON_H
