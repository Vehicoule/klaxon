// kx_skia_ios.mm — iOS platform implementation: Graphite (Metal) onscreen
// backend + CoreText font manager. Same backend as macOS; the difference is
// DPR handling: the host passes window sizes in PIXELS (SDL_GetWindowSizeInPixels)
// while the widget layout works in points (dp), so the frame canvas is scaled
// by pixels/points at the start of every frame (crisp on Retina).
#include "kx_skia_platform.h"

#include <SDL3/SDL.h>
#include <SDL3/SDL_metal.h>

#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import <UIKit/UIKit.h>

#include "include/core/SkImageInfo.h"
#include "include/core/SkSurface.h"
#include "include/core/SkColorSpace.h"
#include "include/gpu/graphite/Context.h"
#include "include/gpu/graphite/ContextOptions.h"
#include "include/gpu/graphite/GraphiteTypes.h"
#include "include/gpu/graphite/Recorder.h"
#include "include/gpu/graphite/Recording.h"
#include "include/gpu/graphite/Surface.h"
#include "include/gpu/graphite/mtl/MtlBackendContext.h"
#include "include/gpu/graphite/mtl/MtlGraphiteTypes_cpp.h"
#include "include/ports/SkCFObject.h"
#include "include/ports/SkFontMgr_mac_ct.h"
#include "include/ports/SkFontMgr_directory.h"

// Ganesh GLES (Phase 4c: backend matrix) — iOS GL interface + GL types.
#include "include/gpu/ganesh/GrBackendSurface.h"
#include "include/gpu/ganesh/GrDirectContext.h"
#include "include/gpu/ganesh/GrTypes.h"
#include "include/gpu/ganesh/SkSurfaceGanesh.h"
#include "include/gpu/ganesh/gl/GrGLBackendSurface.h"
#include "include/gpu/ganesh/gl/GrGLDirectContext.h"
#include "include/gpu/ganesh/gl/GrGLInterface.h"
#include "include/gpu/ganesh/gl/GrGLTypes.h"
#include "include/gpu/ganesh/gl/ios/GrGLMakeIOSInterface.h"
#include "src/gpu/ganesh/gl/GrGLDefines.h"

#include <OpenGLES/ES3/gl.h>

#include <memory>

namespace kx {

struct GpuState {
    // Graphite Metal path
    std::unique_ptr<skgpu::graphite::Context> context;
    std::unique_ptr<skgpu::graphite::Recorder> recorder;
    CAMetalLayer* layer = nil;
    SDL_MetalView metal_view = nullptr;
    id<CAMetalDrawable> drawable = nil;
    id<MTLTexture> drawable_texture = nil;
    id<MTLCommandQueue> command_queue = nil;
    // Ganesh GLES path
    sk_sp<GrDirectContext> dctx;
    SDL_Window* sdl_window = nullptr;
    SDL_GLContext gl_ctx = nullptr;
    // Shared
    sk_sp<SkSurface> frame_surface;
    kx_backend backend = KX_BACKEND_GRAPHITE_METAL;
    int width = 0;      // pixels (host passes SDL_GetWindowSizeInPixels)
    int height = 0;     // pixels
    float scale = 1.0f; // device pixel ratio: pixels per point
};

// Device pixel ratio: stored pixel width over the view's live point bounds.
// Falls back to 1.0 until the view has a valid size.
static float layer_scale(const GpuState* state) {
    const CGSize bounds = state->layer.bounds.size;
    if (bounds.width <= 0.0f || bounds.height <= 0.0f) return 1.0f;
    return static_cast<float>(state->width) / static_cast<float>(bounds.width);
}

// Keep the layer consistent with the host's pixel sizes: drawableSize in
// pixels and contentsScale = pixels/points, so SDL's own layoutSubviews
// (SDL_uikitmetalview -updateDrawableSize) recomputes the same drawable size
// instead of clobbering it back to points.
static void sync_layer(GpuState* state) {
    state->scale = layer_scale(state);
    state->layer.contentsScale = state->scale;
    state->layer.drawableSize = CGSizeMake(state->width, state->height);
}

bool gpu_init(GpuState** out, void* sdl_window, int width, int height, kx_backend backend) {
    if (!sdl_window || !out) return false;
    auto* state = new GpuState();
    state->width = width;
    state->height = height;
    state->backend = backend;
    state->sdl_window = static_cast<SDL_Window*>(sdl_window);

    if (backend == KX_BACKEND_GANESH_GLES) {
        // Ganesh GLES path: the host creates an SDL GL context (ES 3.0) and
        // makes it current BEFORE kx_create. Skia binds to whatever GL
        // context is current.
        if (!SDL_GL_GetCurrentContext()) return false;
        sk_sp<const GrGLInterface> interface = GrGLInterfaces::MakeIOS();
        if (!interface) return false;
        state->dctx = GrDirectContexts::MakeGL(std::move(interface));
        if (!state->dctx) return false;
        // Re-assert currency every frame (the OS may swap contexts, e.g.
        // Dictation) — see SDL_uikitopengles.m UIKit_GL_RestoreCurrentContext.
        state->gl_ctx = SDL_GL_GetCurrentContext();
        *out = state;
        return true;
    }

    // Graphite Metal path (default).
    // KX_BACKEND_GANESH_METAL: not yet implemented on iOS — fall back to
    // Graphite Metal (which works on the simulator with the fixes below).
    state->metal_view = SDL_Metal_CreateView(static_cast<SDL_Window*>(sdl_window));
    if (!state->metal_view) { delete state; return false; }
    state->layer = (__bridge CAMetalLayer*)SDL_Metal_GetLayer(state->metal_view);
    if (!state->layer) { SDL_Metal_DestroyView(state->metal_view); delete state; return false; }

    // With SDL_WINDOW_METAL, SDL auto-attaches the metal view to the window.
    // Fallback: manually attach if not yet attached (defensive — some SDL
    // versions on iOS don't auto-attach until the first frame).
    SDL_PropertiesID props = SDL_GetWindowProperties(static_cast<SDL_Window*>(sdl_window));
    UIWindow* uiwindow = (__bridge UIWindow*)SDL_GetPointerProperty(props, SDL_PROP_WINDOW_UIKIT_WINDOW_POINTER, nullptr);
    UIView* metal_view = (__bridge UIView*)state->metal_view;
    UIView* root = uiwindow ? uiwindow.rootViewController.view : nil;
    if (root && metal_view.superview == nil) {
        metal_view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [root insertSubview:metal_view atIndex:0];
    }

    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device) { SDL_Metal_DestroyView(state->metal_view); delete state; return false; }
    state->layer.device = device;
    state->layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
    state->layer.framebufferOnly = YES;
    state->command_queue = [device newCommandQueue]; // retained for presentDrawable
    sync_layer(state);

    id<MTLCommandQueue> queue = [device newCommandQueue];

    skgpu::graphite::MtlBackendContext mtl_ctx;
    // No ARC: CFRetain produces the +1 reference that sk_cfp adopts (and releases).
    mtl_ctx.fDevice = sk_cfp<CFTypeRef>((CFTypeRef)CFRetain((__bridge CFTypeRef)device));
    mtl_ctx.fQueue = sk_cfp<CFTypeRef>((CFTypeRef)CFRetain((__bridge CFTypeRef)queue));
    state->context = skgpu::graphite::ContextFactory::MakeMetal(mtl_ctx, skgpu::graphite::ContextOptions{});
    if (!state->context) { SDL_Metal_DestroyView(state->metal_view); delete state; return false; }
    *out = state;
    return true;
}

void gpu_shutdown(GpuState* state) {
    if (!state) return;
    state->frame_surface = nullptr;
    state->drawable_texture = nil;
    state->drawable = nil;
    state->command_queue = nil;
    // Ganesh GLES: flush + release the direct context.
    if (state->dctx) {
        state->dctx->flushAndSubmit(GrSyncCpu::kYes);
        state->dctx = nullptr;
    }
    // Graphite Metal: submit + release the context.
    state->recorder.reset();
    if (state->context) {
        state->context->submit(skgpu::graphite::SyncToCpu::kYes);
        state->context.reset();
    }
    if (state->metal_view) SDL_Metal_DestroyView(state->metal_view);
    delete state;
}

void gpu_resize(GpuState* state, int width, int height) {
    if (!state) return;
    // Ganesh GLES has no layer — the drawable FBO is re-wrapped from these
    // dimensions on the next gpu_begin_frame.
    state->width = width;
    state->height = height;
    if (!state->layer) return;
    sync_layer(state); // drawableSize in pixels, contentsScale = pixels/points
}

SkCanvas* gpu_begin_frame(GpuState* state) {
    if (!state || state->width <= 0 || state->height <= 0) return nullptr;

    // Ganesh GLES path: wrap SDL's drawable FBO. On iOS SDL does NOT render
    // to the GL default framebuffer (FBO 0): SDL_uikitopenglview creates its
    // own FBO + renderbuffer backed by the CAEAGLLayer and exposes them as
    // window properties. Rendering to FBO 0 goes nowhere (magenta screen).
    if (state->backend == KX_BACKEND_GANESH_GLES) {
        if (!state->dctx) return nullptr;
        if (state->gl_ctx) SDL_GL_MakeCurrent(state->sdl_window, state->gl_ctx);
        const SDL_PropertiesID props = SDL_GetWindowProperties(state->sdl_window);
        const Sint64 fbo = SDL_GetNumberProperty(props, SDL_PROP_WINDOW_UIKIT_OPENGL_FRAMEBUFFER_NUMBER, 0);
        if (fbo <= 0) return nullptr;
        glBindFramebuffer(GL_FRAMEBUFFER, (GLuint)fbo);
        state->dctx->resetContext(kRenderTarget_GrGLBackendState | kMisc_GrGLBackendState);
        GrGLFramebufferInfo info;
        info.fFBOID = (GrGLuint)fbo;
        info.fFormat = GR_GL_RGBA8;
        const GrBackendRenderTarget target = GrBackendRenderTargets::MakeGL(
            state->width, state->height, 0, 8, info);
        state->frame_surface = SkSurfaces::WrapBackendRenderTarget(
            state->dctx.get(), target, kBottomLeft_GrSurfaceOrigin,
            kRGBA_8888_SkColorType, SkColorSpace::MakeSRGB(), nullptr);
        if (!state->frame_surface) return nullptr;
        state->scale = 1.0f; // GL path: host scales the canvas
        SkCanvas* canvas = state->frame_surface->getCanvas();
        return canvas;
    }

    // Graphite Metal path.
    if (!state->context || !state->layer) return nullptr;
    state->drawable = [state->layer nextDrawable];
    if (!state->drawable) return nullptr;
    // BackendTextures::MakeMetal does NOT retain the texture — keep our own
    // strong reference alive until the frame surface is released.
    state->drawable_texture = state->drawable.texture;
    state->recorder = state->context->makeRecorder();
    if (!state->recorder) return nullptr;
    const skgpu::graphite::BackendTexture backend_tex = skgpu::graphite::BackendTextures::MakeMetal(
        SkISize::Make(state->width, state->height),
        (__bridge CFTypeRef)state->drawable_texture);
    state->frame_surface = SkSurfaces::WrapBackendTexture(
        state->recorder.get(), backend_tex, kBGRA_8888_SkColorType,
        SkColorSpace::MakeSRGB(), nullptr);
    if (!state->frame_surface) return nullptr;
    // Layout is in points, the drawable is in pixels: scale the canvas so
    // point-space drawing lands 1:1 on the pixel grid. Recomputed per frame
    // from the live view bounds (tracks rotation / display changes).
    state->scale = layer_scale(state);
    SkCanvas* canvas = state->frame_surface->getCanvas();
    canvas->scale(state->scale, state->scale);
    return canvas;
}

void gpu_end_frame(GpuState* state) {
    if (!state) return;

    // Ganesh GLES path: flush + swap.
    if (state->backend == KX_BACKEND_GANESH_GLES) {
        if (!state->dctx) return;
        state->dctx->flushAndSubmit();
        state->frame_surface = nullptr;
        // EAGL presents whichever renderbuffer is bound to GL_RENDERBUFFER;
        // SDL's swapBuffers expects the view's renderbuffer to be bound
        // (Skia leaves its own scratch renderbuffer bound after the flush).
        const SDL_PropertiesID props = SDL_GetWindowProperties(state->sdl_window);
        const Sint64 rb = SDL_GetNumberProperty(props, SDL_PROP_WINDOW_UIKIT_OPENGL_RENDERBUFFER_NUMBER, 0);
        if (rb > 0) glBindRenderbuffer(GL_RENDERBUFFER, (GLuint)rb);
        if (state->sdl_window) SDL_GL_SwapWindow(state->sdl_window);
        return;
    }

    // Graphite Metal path.
    if (!state->context) return;
    if (state->recorder) {
        std::unique_ptr<skgpu::graphite::Recording> recording = state->recorder->snap();
        if (recording) {
            skgpu::graphite::InsertRecordingInfo info;
            info.fRecording = recording.get();
            info.fTargetSurface = state->frame_surface.get();
            state->context->insertRecording(info);
        }
        state->recorder.reset();
    }
    // Synchronous submit: ensures GPU work completes before we release the
    // drawable texture. The simulator's Metal is software-emulated and may
    // have different timing than real hardware.
    state->context->submit(skgpu::graphite::SyncToCpu::kYes);
    // Release the frame surface BEFORE presenting: the surface holds a
    // BackendTexture referencing drawable_texture.
    state->frame_surface = nullptr;
    state->drawable_texture = nil; // release our texture reference
    if (state->drawable) {
        // Present via command buffer (not [drawable present]) — the simulator
        // requires presentDrawable to go through the command queue.
        if (state->command_queue) {
            id<MTLCommandBuffer> cb = [state->command_queue commandBuffer];
            [cb presentDrawable:state->drawable];
            [cb commit];
        }
        state->drawable = nil;
    }
}

sk_sp<SkFontMgr> platform_font_mgr() {
    // CoreText font manager can crash on the iOS simulator (SkRefCntBase::unref
    // in typeface lifecycle). Try directory-based first, fall back to empty.
    if (sk_sp<SkFontMgr> mgr = SkFontMgr_New_Custom_Directory("/System/Library/Fonts")) {
        return mgr;
    }
    return SkFontMgr_New_CoreText(nullptr);
}

// iOS: check if the UIWindow's root view is attached — presents before the
// view is mapped to the window are silently lost (black screen).
extern "C" bool kx_ios_window_mapped(void* uiwindow) {
    if (!uiwindow) return false;
    UIWindow* w = (__bridge UIWindow*)uiwindow;
    if (!w || w.isHidden) return false;
    UIView* v = w.rootViewController.view;
    return (v && v.window == w);
}

} // namespace kx
