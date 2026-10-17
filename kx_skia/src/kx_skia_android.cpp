// kx_skia_android.cpp — Android platform implementation: Ganesh GLES (EGL)
// onscreen backend (FBO-0 pattern, mirror of kx_skia_wasm.cpp with EGL instead
// of WebGL2) + Android NDK font manager. Implements kx_skia_platform.h for
// aarch64-linux-android.
//
// Build (Phase 3d): CMake/NDK compiles this TU — Zig only builds the app
// static library (addAndroidLib in build.zig); the Gradle/CMake project links
// shim .o + libSDL3.so + libskia*.a into lib<app>.so. NDK clang++, flags
// -std=c++20 -fno-exceptions -fno-rtti -DSK_GANESH -DSK_GL
// -DSK_FORCE_8_BYTE_ALIGNMENT. Include roots: deps/skia, deps/skia/include,
// deps/SDL/include (this file's own directory provides kx_skia_platform.h).
//
// Raster is unavailable on Android (SDL's Android video backend does not
// implement SDL_CreateWindowFramebuffer), so Ganesh GLES is the only onscreen
// backend. The app (host.zig) requests an ES 3.0 context
// (SDL_GL_CONTEXT_PROFILE_ES, major 3, 8-bit stencil, double-buffered) and
// makes it current BEFORE kx_create. gpu_end_frame submits +
// SDL_GL_SwapWindow — eglSwapBuffers on SDL's EGLSurface presents the frame.
//
// GrGLMakeNativeInterface() is the EGL variant on Android: Skia's BUILD.gn
// compiles src/gpu/ganesh/gl/egl/GrGLMakeNativeInterface_egl.cpp for
// target_os="android", which resolves GL entry points through
// eglGetProcAddress (GrGLInterfaces::MakeEGL). GLES declarations come from
// the NDK sysroot (<GLES3/gl3.h>) — EGL itself declares no GL symbols.
#include "kx_skia_platform.h"

#include <SDL3/SDL.h>

#include <android/api-level.h>     // android_get_device_api_level (NDK builtin)
#include <android/native_window.h> // ANativeWindow

#include <GLES3/gl3.h> // NDK sysroot GLES3 header; glBindFramebuffer, GL_FRAMEBUFFER

#include "include/core/SkColorSpace.h"
#include "include/core/SkData.h"                   // SkData::MakeWithCopy (deferred-upload pixel ownership)
#include "include/core/SkFontScanner.h"           // complete type for SkFontMgr_New_AndroidNDK's unique_ptr param
#include "include/core/SkFontStyle.h"
#include "include/core/SkTypeface.h"              // unicharToGlyph (family coverage check)
#include "include/core/SkImageInfo.h"
#include "include/core/SkSurface.h"
#include "include/gpu/ganesh/GrBackendSurface.h"    // GrBackendRenderTarget (complete type; GrGLBackendSurface.h only fwd-declares it)
#include "include/gpu/ganesh/GrDirectContext.h"
#include "include/gpu/GpuTypes.h"                   // skgpu::Mipmapped, GrRenderable
#include "include/gpu/ganesh/SkImageGanesh.h"        // SkImages::TextureFromImage (Ganesh)
#include "include/gpu/ganesh/GrTypes.h"              // kBottomLeft_GrSurfaceOrigin, k*_GrGLBackendState, GrSyncCpu
#include "include/gpu/ganesh/SkSurfaceGanesh.h"      // SkSurfaces::WrapBackendRenderTarget
#include "include/gpu/ganesh/gl/GrGLBackendSurface.h" // GrBackendRenderTargets::MakeGL
#include "include/gpu/ganesh/gl/GrGLDirectContext.h"  // GrDirectContexts::MakeGL
#include "include/gpu/ganesh/gl/GrGLInterface.h"      // GrGLMakeNativeInterface (EGL variant on Android)
#include "include/gpu/ganesh/gl/GrGLTypes.h"          // GrGLFramebufferInfo
#include "src/gpu/ganesh/gl/GrGLDefines.h"            // GR_GL_RGBA8 (same private include as the wasm shim)
#include "include/ports/SkFontMgr_android_ndk.h"      // SkFontMgr_New_AndroidNDK (API >= 29)
#include "include/ports/SkFontMgr_directory.h"        // SkFontMgr_New_Custom_Directory
#include "include/ports/SkFontMgr_empty.h"            // SkFontMgr_New_Custom_Empty

#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstring>

namespace kx {

struct GpuState {
    SDL_Window* window = nullptr;
    sk_sp<GrDirectContext> dctx;
    sk_sp<SkSurface> frame_surface;
    sk_sp<SkSurface> warmup_surface; // offscreen target for kx_gpu_warmup (Phase 4e.1)
    // Video-style pixel streaming goes through TextureFromImage's deferred
    // upload (the GrDirectContext upload arena): measured 0.39ms/frame on
    // the GLES emulator where updateBackendTexture on a client-owned
    // backend texture costs ~18ms synchronously (SwiftShader can't defer
    // client-texture uploads through the arena — it texSubImage2Ds inline).
    // No persistent stream state needed: GrResourceCache recycles the
    // per-frame backend texture.
    int width = 0;
    int height = 0;
};

bool gpu_init(GpuState** out, void* sdl_window, int width, int height, kx_backend backend) {
    (void)backend; // unused on this platform
    if (!out || !sdl_window) return false;
    auto* window = static_cast<SDL_Window*>(sdl_window);
    // The caller (host, android path) creates an ES 3.0 context on the SDL
    // window and makes it current BEFORE kx_create. Ganesh binds to whatever
    // EGL context is current — GrGLMakeNativeInterface resolves GL entry
    // points via eglGetProcAddress — so the context must already be current.
    // (SDL_GLContext is the EGLContext on Android.)
    if (!SDL_GL_GetCurrentContext()) return false;
    // The ANativeWindow backs SDL's EGLSurface (the FBO-0 target we render
    // into). SDL exposes it on the window properties; this SDL pin has no
    // SDL_GetWindowProperty(window, name) convenience wrapper, so go through
    // SDL_GetWindowProperties + SDL_GetPointerProperty.
    auto* native_window = static_cast<ANativeWindow*>(SDL_GetPointerProperty(
        SDL_GetWindowProperties(window), SDL_PROP_WINDOW_ANDROID_WINDOW_POINTER, nullptr));
    if (!native_window) return false;

    sk_sp<const GrGLInterface> interface = GrGLMakeNativeInterface();
    if (!interface) return false;
    sk_sp<GrDirectContext> dctx = GrDirectContexts::MakeGL(std::move(interface));
    if (!dctx) return false;

    auto* state = new GpuState();
    state->window = window;
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

    // The onscreen canvas is FBO 0 (SDL's EGLSurface on the ANativeWindow).
    // Make it current and tell Skia its GL state is unknown (first frame /
    // context loss / EGLSurface re-created after a window resize).
    glBindFramebuffer(GL_FRAMEBUFFER, 0);
    state->dctx->resetContext(kRenderTarget_GrGLBackendState | kMisc_GrGLBackendState);

    // Wrap FBO 0 in a Skia backend render target (CanvasKit pattern, same as
    // the wasm shim). The GLES window surface is RGBA8 with an 8-bit stencil
    // (the context attributes requested in host.zig).
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
    // Release the wrapped target before present: eglSwapBuffers (via
    // SDL_GL_SwapWindow) composites SDL's EGLSurface onto the ANativeWindow.
    state->frame_surface = nullptr;
    if (state->window) SDL_GL_SwapWindow(state->window);
}

SkCanvas* gpu_begin_offscreen(GpuState* state, int width, int height) {
    // Warmup (Phase 4e.1): a render-target surface on the Ganesh context —
    // the same draw ops, so the same programs the onscreen frames use.
    if (!state || !state->dctx || width <= 0 || height <= 0) return nullptr;
    // Signature at the pinned Skia (include/gpu/ganesh/SkSurfaceGanesh.h):
    // RenderTarget(GrRecordingContext*, skgpu::Budgeted, const SkImageInfo&)
    // — the 3-arg inline overload; skgpu::Budgeted comes from
    // include/gpu/GpuTypes.h via ganesh/GrTypes.h.
    state->warmup_surface = SkSurfaces::RenderTarget(
        state->dctx.get(), skgpu::Budgeted::kYes,
        SkImageInfo::Make(width, height, kRGBA_8888_SkColorType, kPremul_SkAlphaType, nullptr));
    return state->warmup_surface ? state->warmup_surface->getCanvas() : nullptr;
}

bool gpu_end_offscreen(GpuState* state) {
    if (!state || !state->dctx) return false;
    // Synchronous: the program compile must complete inside the warmup call,
    // not leak into the next real frame.
    state->dctx->flushAndSubmit(GrSyncCpu::kYes);
    state->warmup_surface = nullptr;
    return true;
}

sk_sp<SkSurface> gpu_offscreen_surface(GpuState* state, int width, int height) {
    if (!state || !state->dctx) return nullptr;
    return SkSurfaces::RenderTarget(
        state->dctx.get(), skgpu::Budgeted::kYes,
        SkImageInfo::Make(width, height, kRGBA_8888_SkColorType, kPremul_SkAlphaType, nullptr));
}

sk_sp<SkImage> gpu_image_upload(GpuState* state, sk_sp<SkImage> img) {
    if (!state || !state->dctx || !img || img->isTextureBacked()) return img;
    if (sk_sp<SkImage> up = SkImages::TextureFromImage(state->dctx.get(), img.get()))
        return up;
    return img;
}

sk_sp<SkImage> gpu_stream_image(GpuState* state, const void* rgba, int w, int h) {
    if (!state || !state->dctx || !rgba || w <= 0 || h <= 0) return nullptr;
    // Deferred upload through the GrDirectContext arena: TextureFromImage
    // records the copy+upload as deferred work resolved at the next submit,
    // so this call stays ~0.4ms (measured) where updateBackendTexture on a
    // client-owned GrBackendTexture pays ~18ms inline on GLES. The pixel
    // copy is required — the deferred read runs after this call returns.
    const SkImageInfo info = SkImageInfo::Make(
        w, h, kRGBA_8888_SkColorType, kUnpremul_SkAlphaType);
    sk_sp<SkData> data = SkData::MakeWithCopy(rgba, static_cast<size_t>(w) * h * 4);
    sk_sp<SkImage> img = SkImages::RasterFromData(
        info, std::move(data), static_cast<size_t>(w) * 4);
    if (!img) return nullptr;
    return SkImages::TextureFromImage(state->dctx.get(), img.get());
}

sk_sp<SkFontMgr> platform_font_mgr() {
    // SkFontMgr_New_AndroidNDK internally calls
    // SkFontMgr_Android_Parser::GetSystemFontFamilies which is stubbed out
    // (the parser source is not in the prebuilt Skia libs) — calling it
    // crashes with a null pointer dereference. Skip it and use FreeType
    // over the system font directory directly. Cached: one directory scan
    // serves the wrapped manager AND the family resolution below.
    static sk_sp<SkFontMgr> mgr = [] {
        if (sk_sp<SkFontMgr> m = SkFontMgr_New_Custom_Directory("/system/fonts")) {
            return m;
        }
        // Last resort: metrics work, no glyphs.
        return sk_sp<SkFontMgr>(SkFontMgr_New_Custom_Empty());
    }();
    return mgr;
}

static bool familyCovers(SkFontMgr* mgr, const char* family, SkUnichar c) {
    sk_sp<SkTypeface> tf = mgr->legacyMakeTypeface(family, SkFontStyle());
    return tf && tf->unicharToGlyph(c) != 0;
}

// Resolve the default + fallback families FROM THE DEVICE instead of
// assuming them: prefer "Roboto" (ships on every Android) for the default
// and "Droid Sans" (the legacy alias, API < 21 skins) for the fallback,
// else the first family covering Latin letters. Symbol-only faces are
// skipped by the coverage check — /system/fonts sorts AndroidClock.ttf
// first and a digits-only clock face makes labels silently vanish.
static const char* resolveFamily(bool fallback) {
    static char primary[128] = "Roboto";
    static char secondary[128] = "";
    static bool done = false;
    if (!done) {
        done = true;
        if (sk_sp<SkFontMgr> mgr = platform_font_mgr()) {
            SkString name;
            bool roboto = false, droid = false;
            char latin[128] = "";
            for (int i = 0, n = mgr->countFamilies(); i < n; i++) {
                mgr->getFamilyName(i, &name);
                if (name.equals("Roboto")) roboto = true;
                else if (name.equals("Droid Sans")) droid = true;
                else if (latin[0] == '\0' && familyCovers(mgr.get(), name.c_str(), 'a')) {
                    snprintf(latin, sizeof(latin), "%s", name.c_str());
                }
            }
            if (!roboto && latin[0]) snprintf(primary, sizeof(primary), "%s", latin);
            if (droid) snprintf(secondary, sizeof(secondary), "%s", "Droid Sans");
            else if (latin[0] && strcmp(latin, primary)) snprintf(secondary, sizeof(secondary), "%s", latin);
        }
    }
    return fallback ? (secondary[0] ? secondary : nullptr)
                    : (primary[0] ? primary : nullptr);
}

const char* platform_font_family() { return resolveFamily(false); }

const char* platform_fallback_font_family() { return resolveFamily(true); }

} // namespace kx

// Exported for the Zig side's backend selection (Graphite Vulkan on API >= 33,
// Ganesh GLES below). NDK builtin — reads the device API level at runtime.
// (NDK r26+ renamed __android_get_device_api_level to android_get_device_api_level;
// fetch-deps.sh selects the newest NDK, so the new name is the one that links.)
extern "C" int kx_android_api_level() {
    return android_get_device_api_level();
}
