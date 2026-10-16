// kx_skia_platform.h — platform interface for the GPU backends.
// Implemented per OS (kx_skia_macos.mm, kx_skia_linux.cpp, ...). C++ only —
// this header never crosses the Zig ABI.
#pragma once

#include "kx_skia.h"
#include "include/core/SkCanvas.h"
#include "include/core/SkFontMgr.h"
#include "include/core/SkImage.h"
#include "include/core/SkRefCnt.h"
#include "include/core/SkSurface.h"

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

// kx_offscreen_begin on a GPU ctx: a backend render-target surface so the
// snapshot image is GPU-backed (Graphite drops non-Graphite draws; Ganesh
// textures blit faster than re-uploaded rasters). Uses the LIVE frame
// recorder/context — nullptr outside a frame or on raster → the caller
// falls back to a raster offscreen surface.
sk_sp<SkSurface> gpu_offscreen_surface(GpuState* state, int width, int height);

// Upload a client-pixel image to the GPU (Graphite: TextureFromImage on the
// live frame recorder; Ganesh: a texture image). Returns img unchanged when
// the backend has no upload path, no recorder is live, or the image is
// already GPU-backed — so it is safe to call lazily at first draw.
sk_sp<SkImage> gpu_image_upload(GpuState* state, sk_sp<SkImage> img);

// Video-style pixel streaming: upload `rgba` (w×h, RGBA unpremul, tightly
// packed) into a persistent backend texture and return a borrowed SkImage
// view of it — a player's present path (direct texture update, no per-frame
// texture alloc, no render-target pass). The returned image borrows the
// state's texture: it must be drawn (and released) before the next call.
// Returns nullptr on backends without a fast streaming path (Graphite keeps
// its persistent-surface path in kx_draw_pixels).
sk_sp<SkImage> gpu_stream_image(GpuState* state, const void* rgba, int w, int h);

// Platform font manager (macOS: CoreText, Linux: custom directory, ...).
sk_sp<SkFontMgr> platform_font_mgr();

// Default family name passed to legacyMakeTypeface, or nullptr to let the
// manager pick its built-in default (Arial/DejaVu/...).
const char* platform_font_family();

// Fallback family consulted when the default typeface lacks a codepoint in
// the drawn string, or nullptr for no fallback. Windows returns Segoe UI
// Symbol — Segoe UI and Arial lack the Geometric Shapes/Arrows/Dingbats
// codepoints the icon widget paints.
const char* platform_fallback_font_family();

} // namespace kx
