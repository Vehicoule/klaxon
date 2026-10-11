// kx_skia_platform.h — platform interface for the GPU backends.
// Implemented per OS (kx_skia_macos.mm, kx_skia_linux.cpp, ...). C++ only —
// this header never crosses the Zig ABI.
#pragma once

#include "kx_skia.h"
#include "include/core/SkCanvas.h"
#include "include/core/SkFontMgr.h"
#include "include/core/SkRefCnt.h"

namespace kx {

// Opaque per-platform GPU state (defined in the platform implementation).
struct GpuState;

// Create the GPU context and attach an onscreen surface to sdl_window (SDL_Window*).
// backend selects the GPU API (Graphite Metal, Ganesh Metal, Ganesh GLES, ...).
bool gpu_init(GpuState** out, void* sdl_window, int width, int height, kx_backend backend);
void gpu_shutdown(GpuState* state);
void gpu_resize(GpuState* state, int width, int height);

// Begin a frame: acquire the onscreen target, return the canvas to draw into.
SkCanvas* gpu_begin_frame(GpuState* state);
// End a frame: snap the recording, submit, present.
void gpu_end_frame(GpuState* state);

// Warmup (Phase 4e.1): create a small offscreen GPU surface so
// kx_gpu_warmup can pre-compile the op set's programs. Returns nullptr when
// the backend has no offscreen path yet (warmup is best-effort — the ABI
// call reports false, the caller logs and moves on).
SkCanvas* gpu_begin_offscreen(GpuState* state, int width, int height);
// Submit the offscreen work (synchronously — the compile cost must land in
// the warmup call, not the next real frame) and release the surface.
bool gpu_end_offscreen(GpuState* state);

// Platform font manager (macOS: CoreText, Linux: custom directory, ...).
sk_sp<SkFontMgr> platform_font_mgr();

} // namespace kx
