// kx_a11y_win.cpp — Windows UIA (UI Automation) bridge. Phase 3c: stub.
//
// Mirrors the platform a11y contract used by kx_a11y_macos.mm / kx_a11y_ios.mm
// / kx_a11y_android.cpp: kx_a11y_init installs the C bridge callback with the
// Zig semantics module; kx_a11y_shutdown uninstalls it.
//
// v1 plan (follow-up PR): implement IRawElementProviderSimple on the SDL
// window's HWND, map semantic nodes → UIA control types, raise
// UiaRaiseAutomationEvent for tree/focus/announce events, and handle
// WM_GETOBJECT (return UiaReturnRawElementProvider). The SPIKE in
// klaxon-spikes/kx_skia/src/kx_a11y_win.cpp has a full reference bridge.
// NOTE: when the real bridge lands, this file must be compiled WITHOUT
// WIN32_LEAN_AND_MEAN (UIAutomationCore.h needs the ole2 types).
#include "kx_skia.h"

#include <stdint.h>
#include <stddef.h>

// --- Forward declarations from Zig (semantics bridge C ABI) ---
extern "C" {
    void kx_a11y_set_bridge(void (*fn)(void* userdata, uint32_t kind, uint64_t node_id,
                                       const char* text, size_t text_len, uint32_t region),
                            void* userdata);
}

static void* g_root_node = nullptr;

// Event sink: accepts semantic events until the UIA provider exists.
static void a11y_bridge_sink(void* userdata, uint32_t kind, uint64_t node_id,
                             const char* text, size_t text_len, uint32_t region) {
    (void)userdata; (void)kind; (void)node_id; (void)text; (void)text_len; (void)region;
}

extern "C" {

void kx_a11y_init(void* root_node) {
    g_root_node = root_node;
    kx_a11y_set_bridge(a11y_bridge_sink, nullptr);
}

void kx_a11y_shutdown(void) {
    g_root_node = nullptr;
    kx_a11y_set_bridge(nullptr, nullptr);
}

// No UIA root provider yet — callers treat NULL as "a11y disabled".
void* kx_a11y_root_element(void) {
    return nullptr;
}

} // extern "C"
