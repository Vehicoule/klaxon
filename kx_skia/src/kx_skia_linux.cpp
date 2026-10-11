// kx_skia_linux.cpp — Linux platform implementation: Ganesh GL (desktop GL
// via SDL's context) + raster fallback. Implements kx_skia_platform.h.
//
// SDL owns the GL context (host.zig creates + makes it current before
// kx_create when the backend is ganesh-gl) — the shim resolves every GL
// entry point through SDL_GL_GetProcAddress via Skia's assembled-interface
// factory, so no EGL/GLX/libGL headers or link deps are needed and the same
// code runs on X11, Wayland, and headless llvmpipe. The FBO-0 wrap and the
// CanvasKit render-target pattern mirror the wasm/android shims.
//
// Graphite Vulkan is the follow-up (needs SDL_Vulkan + VMA + the
// vulkan-headers external) — ganesh-gl covers every GPU driver today.
#include "kx_skia_platform.h"

#include <SDL3/SDL.h>

#include "include/core/SkColorSpace.h"
#include "include/core/SkFontMgr.h"
#include "include/core/SkImageInfo.h"
#include "include/core/SkSurface.h"
#include "include/gpu/ganesh/GrBackendSurface.h"
#include "include/gpu/ganesh/GrDirectContext.h"
#include "include/gpu/ganesh/GrTypes.h"
#include "include/gpu/ganesh/SkSurfaceGanesh.h"
#include "include/gpu/ganesh/gl/GrGLAssembleInterface.h"
#include "include/gpu/ganesh/gl/GrGLBackendSurface.h"
#include "include/gpu/ganesh/gl/GrGLDirectContext.h"
#include "include/gpu/ganesh/gl/GrGLInterface.h"
#include "include/gpu/ganesh/gl/GrGLTypes.h"
#include "include/ports/SkFontMgr_directory.h"
#include "include/ports/SkFontMgr_empty.h"
#include "src/gpu/ganesh/gl/GrGLDefines.h" // GR_GL_RGBA8 / GR_GL_FRAMEBUFFER (private, same as wasm shim)

#include <cstdint>

namespace kx {

// Desktop-GL constants Skia hands back through GrGLTypes — the shim calls
// exactly one GL function directly (glBindFramebuffer), resolved through
// SDL so no GL header is required.
typedef void (*GLBindFramebufferFn)(uint32_t target, uint32_t fb);
static GLBindFramebufferFn glBindFramebuffer_ptr = nullptr;

static GrGLFuncPtr sdl_gl_get_proc(void*, const char name[]) {
    return reinterpret_cast<GrGLFuncPtr>(SDL_GL_GetProcAddress(name));
}

struct GpuState {
    SDL_Window* window = nullptr;
    sk_sp<GrDirectContext> dctx;
    sk_sp<SkSurface> frame_surface;
    sk_sp<SkSurface> warmup_surface; // offscreen target for kx_gpu_warmup
    int width = 0;
    int height = 0;
};

bool gpu_init(GpuState** out, void* sdl_window, int width, int height, kx_backend backend) {
    if (backend != KX_BACKEND_GANESH_GL) return false; // raster/vulkan handled elsewhere
    if (!out || !sdl_window) return false;
    // The caller (host.zig) creates a desktop GL context on the SDL window
    // and makes it current BEFORE kx_create — Ganesh binds to whatever is
    // current here.
    if (!SDL_GL_GetCurrentContext()) return false;

    sk_sp<const GrGLInterface> interface =
        GrGLMakeAssembledGLInterface(nullptr, sdl_gl_get_proc);
    if (!interface) return false;
    sk_sp<GrDirectContext> dctx = GrDirectContexts::MakeGL(std::move(interface));
    if (!dctx) return false;

    glBindFramebuffer_ptr = reinterpret_cast<GLBindFramebufferFn>(
        SDL_GL_GetProcAddress("glBindFramebuffer"));
    if (!glBindFramebuffer_ptr) return false;

    auto* state = new GpuState();
    state->window = static_cast<SDL_Window*>(sdl_window);
    state->dctx = std::move(dctx);
    state->width = width;
    state->height = height;
    *out = state;
    return true;
}

void gpu_shutdown(GpuState* state) {
    if (!state) return;
    state->frame_surface = nullptr;
    if (state->dctx) {
        // Wait for in-flight GPU work before tearing the context down.
        state->dctx->flushAndSubmit(GrSyncCpu::kYes);
        state->dctx = nullptr;
    }
    delete state;
}

void gpu_resize(GpuState* state, int width, int height) {
    if (!state) return;
    // The onscreen target wraps FBO 0 and is re-created from these dimensions
    // on the next gpu_begin_frame.
    state->width = width;
    state->height = height;
}

SkCanvas* gpu_begin_frame(GpuState* state) {
    if (!state || !state->dctx || state->width <= 0 || state->height <= 0) return nullptr;

    // The onscreen canvas is FBO 0 (SDL's default framebuffer). Make it
    // current and tell Skia its GL state is unknown (first frame / context
    // loss / EGLSurface recreated after a window resize).
    glBindFramebuffer_ptr(GR_GL_FRAMEBUFFER, 0);
    state->dctx->resetContext(kRenderTarget_GrGLBackendState | kMisc_GrGLBackendState);

    GrGLFramebufferInfo info;
    info.fFBOID = 0;
    info.fFormat = GR_GL_RGBA8;
    const GrBackendRenderTarget target = GrBackendRenderTargets::MakeGL(
        state->width, state->height, /*sampleCnt=*/0, /*stencilBits=*/8, info);
    state->frame_surface = SkSurfaces::WrapBackendRenderTarget(
        state->dctx.get(), target, kBottomLeft_GrSurfaceOrigin,
        kRGBA_8888_SkColorType, SkColorSpace::MakeSRGB(), nullptr);
    if (!state->frame_surface) return nullptr;
    return state->frame_surface->getCanvas();
}

void gpu_end_frame(GpuState* state) {
    if (!state || !state->dctx) return;
    state->dctx->flushAndSubmit();
    state->frame_surface = nullptr;
    if (state->window) SDL_GL_SwapWindow(state->window);
}

SkCanvas* gpu_begin_offscreen(GpuState* state, int width, int height) {
    // Warmup (Phase 4e.1): a render-target surface on the Ganesh context —
    // same draw ops, same programs as the onscreen frames.
    if (!state || !state->dctx || width <= 0 || height <= 0) return nullptr;
    state->warmup_surface = SkSurfaces::RenderTarget(
        state->dctx.get(), skgpu::Budgeted::kYes,
        SkImageInfo::Make(width, height, kRGBA_8888_SkColorType, kPremul_SkAlphaType, nullptr));
    return state->warmup_surface ? state->warmup_surface->getCanvas() : nullptr;
}

bool gpu_end_offscreen(GpuState* state) {
    if (!state || !state->dctx) return false;
    state->dctx->flushAndSubmit(GrSyncCpu::kYes);
    state->warmup_surface = nullptr;
    return true;
}

sk_sp<SkFontMgr> platform_font_mgr() {
    // System font directories (DejaVu et al. on CI runners).
    for (const char* dir : {"/usr/share/fonts", "/usr/local/share/fonts"}) {
        if (auto mgr = SkFontMgr_New_Custom_Directory(dir)) return mgr;
    }
    return SkFontMgr_New_Custom_Empty();
}

const char* platform_font_family() { return nullptr; }

const char* platform_fallback_font_family() { return nullptr; }

} // namespace kx
