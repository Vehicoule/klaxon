// kx_skia_ios.mm — iOS platform implementation: Graphite (Metal) onscreen
// backend + CoreText font manager. Same backend as macOS; the difference is
// DPR handling: the host passes window sizes in PIXELS (SDL_GetWindowSizeInPixels)
// while the widget layout works in points (dp), so the frame canvas is scaled
// by pixels/points at the start of every frame (crisp on Retina).
//
// Backend contract (docs/ARCHITECTURE.md): iOS ships graphite-metal only —
// Metal covers every supported device; raster is the last resort. The old
// ganesh-metal / ganesh-gles / graphite-dawn codepaths are in git history.
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
#include "include/gpu/graphite/Image.h"
#include "include/gpu/graphite/Recorder.h"
#include "include/gpu/graphite/Recording.h"
#include "include/gpu/graphite/Surface.h"
#include "include/gpu/graphite/mtl/MtlBackendContext.h"
#include "include/gpu/graphite/mtl/MtlGraphiteTypes_cpp.h"
#include "include/ports/SkCFObject.h"
#include "include/ports/SkFontMgr_mac_ct.h"
#include "include/ports/SkFontMgr_directory.h"

#include <memory>

namespace kx {

struct GpuState {
    std::unique_ptr<skgpu::graphite::Context> context;
    std::unique_ptr<skgpu::graphite::Recorder> recorder;
    sk_sp<SkSurface> warmup_surface;
    CAMetalLayer* layer = nil;
    SDL_MetalView metal_view = nullptr;
    id<CAMetalDrawable> drawable = nil;
    id<MTLTexture> drawable_texture = nil;
    id<MTLCommandQueue> command_queue = nil;
    // Shared
    sk_sp<SkSurface> frame_surface;
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
    if (backend != KX_BACKEND_GRAPHITE_METAL) return false; // iOS chain: metal → raster
    auto* state = new GpuState();
    state->width = width;
    state->height = height;

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
    // Share a single MTLCommandQueue between Graphite and presentDrawable so
    // GPU rendering and presentation execute in order on the same queue.
    state->command_queue = [device newCommandQueue];
    if (!state->command_queue) { [device release]; SDL_Metal_DestroyView(state->metal_view); delete state; return false; }
    sync_layer(state);

    skgpu::graphite::MtlBackendContext mtl_ctx;
    // No ARC: CFRetain produces the +1 reference that sk_cfp adopts (and releases).
    // Release the local +1 device reference; state->command_queue retains its +1
    // until gpu_shutdown.
    mtl_ctx.fDevice = sk_cfp<CFTypeRef>((CFTypeRef)CFRetain((__bridge CFTypeRef)device));
    mtl_ctx.fQueue = sk_cfp<CFTypeRef>((CFTypeRef)CFRetain((__bridge CFTypeRef)state->command_queue));
    [device release];
    state->context = skgpu::graphite::ContextFactory::MakeMetal(mtl_ctx, skgpu::graphite::ContextOptions{});
    if (!state->context) {
        [state->command_queue release];
        state->command_queue = nil;
        SDL_Metal_DestroyView(state->metal_view);
        delete state;
        return false;
    }
    state->recorder = state->context->makeRecorder();
    if (!state->recorder) {
        state->context.reset();
        [state->command_queue release];
        state->command_queue = nil;
        SDL_Metal_DestroyView(state->metal_view);
        delete state;
        return false;
    }
    *out = state;
    return true;
}

void gpu_shutdown(GpuState* state) {
    if (!state) return;
    state->frame_surface = nullptr;
    state->warmup_surface = nullptr;
    state->drawable_texture = nil;
    state->drawable = nil;
    state->recorder.reset();
    if (state->context) {
        state->context->submit(skgpu::graphite::SyncToCpu::kYes);
        state->context.reset();
    }
    if (state->command_queue) {
        [state->command_queue release];
        state->command_queue = nil;
    }
    if (state->metal_view) SDL_Metal_DestroyView(state->metal_view);
    delete state;
}

void gpu_resize(GpuState* state, int width, int height) {
    if (!state) return;
    state->width = width;
    state->height = height;
    if (!state->layer) return;
    sync_layer(state); // drawableSize in pixels, contentsScale = pixels/points
}

SkCanvas* gpu_begin_frame(GpuState* state) {
    if (!state || state->width <= 0 || state->height <= 0) return nullptr;

    if (!state->context || !state->layer) return nullptr;
    state->drawable = [state->layer nextDrawable];
    if (!state->drawable) return nullptr;
    // BackendTextures::MakeMetal does NOT retain the texture — keep our own
    // strong reference alive until the frame surface is released.
    state->drawable_texture = state->drawable.texture;
    // The recorder persists across frames (snap() leaves it reusable) —
    // pooled offscreen surfaces and atlas slots created on it stay valid.
    // Per-frame reset orphaned those surfaces on a dead recorder (crash in
    // RecorderPriv::popOrCreateKeyAndDataBuilder on the next pooled draw).
    if (!state->recorder) state->recorder = state->context->makeRecorder();
    if (!state->recorder) return nullptr;
    const skgpu::graphite::BackendTexture backend_tex = skgpu::graphite::BackendTextures::MakeMetal(
        SkISize::Make(state->width, state->height),
        (__bridge CFTypeRef)state->drawable_texture);
    state->frame_surface = SkSurfaces::WrapBackendTexture(
        state->recorder.get(), backend_tex, kBGRA_8888_SkColorType,
        SkColorSpace::MakeSRGB(), nullptr);
    if (!state->frame_surface) return nullptr;
    // Update layer scale for contentsScale tracking; Host.renderFrame applies
    // the uniform DPR canvas scale after kx_begin_frame resets the base matrix.
    state->scale = layer_scale(state);
    return state->frame_surface->getCanvas();
}

void gpu_end_frame(GpuState* state) {
    if (!state) return;
    if (!state->context) return;
    if (state->recorder) {
        std::unique_ptr<skgpu::graphite::Recording> recording = state->recorder->snap();
        if (recording) {
            skgpu::graphite::InsertRecordingInfo info;
            info.fRecording = recording.get();
            info.fTargetSurface = state->frame_surface.get();
            state->context->insertRecording(info);
        }
        // Keep the recorder (macOS parity): surfaces created on it —
        // offscreen pool, row atlas — outlive the frame, snap() already
        // reset the per-recording state.
    }
#if TARGET_OS_SIMULATOR
    // Synchronous submit: the simulator's Metal is software-emulated and may
    // have different timing — guarantee completion before we release the
    // drawable texture.
    state->context->submit(skgpu::graphite::SyncToCpu::kYes);
#else
    // Device: async submit keeps CPU and GPU pipelined — the command
    // buffer's presentDrawable retains the drawable (and thereby its
    // texture) until present completes, so releasing our refs below is safe.
    state->context->submit(skgpu::graphite::SyncToCpu::kNo);
#endif
    // Release the frame surface BEFORE presenting: the surface holds a
    // BackendTexture referencing drawable_texture.
    state->frame_surface = nullptr;
    state->drawable_texture = nil; // release our texture reference
    if (state->drawable) {
        // Present via command buffer on the shared command queue — guaranteed
        // ordered after the Graphite submit above.
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

// Warmup: offscreen graphite surface on the shared recorder — same draw ops
// and target format/colorSpace as onscreen frames.
SkCanvas* gpu_begin_offscreen(GpuState* state, int width, int height) {
    if (!state || !state->context || width <= 0 || height <= 0) return nullptr;
    if (!state->recorder) state->recorder = state->context->makeRecorder();
    if (!state->recorder) return nullptr;
    // BGRA + sRGB like the wrapped CAMetalLayer drawable — pipelines are
    // per-target-format, an RGBA warmup would not prime onscreen draws.
    state->warmup_surface = SkSurfaces::RenderTarget(
        state->recorder.get(),
        SkImageInfo::Make(width, height, kBGRA_8888_SkColorType, kPremul_SkAlphaType,
                          SkColorSpace::MakeSRGB()));
    return state->warmup_surface ? state->warmup_surface->getCanvas() : nullptr;
}
bool gpu_end_offscreen(GpuState* state) {
    if (!state || !state->context) return false;
    if (state->recorder) {
        std::unique_ptr<skgpu::graphite::Recording> recording = state->recorder->snap();
        if (recording) {
            skgpu::graphite::InsertRecordingInfo info;
            info.fRecording = recording.get();
            info.fTargetSurface = state->warmup_surface.get();
            state->context->insertRecording(info);
        }
    }
    // Synchronous: the pipeline compile must complete inside the warmup
    // call, not leak into the next real frame.
    state->context->submit(skgpu::graphite::SyncToCpu::kYes);
    state->warmup_surface = nullptr;
    return true;
}

sk_sp<SkSurface> gpu_offscreen_surface(GpuState* state, int width, int height) {
    if (!state || !state->context || !state->recorder) return nullptr;
    return SkSurfaces::RenderTarget(
        state->recorder.get(),
        SkImageInfo::Make(width, height, kRGBA_8888_SkColorType, kPremul_SkAlphaType, nullptr));
}

sk_sp<SkImage> gpu_image_upload(GpuState* state, sk_sp<SkImage> img) {
    if (!state || !state->recorder || !img || img->isTextureBacked()) return img;
    if (sk_sp<SkImage> up = SkImages::TextureFromImage(state->recorder.get(), img.get(), {}))
        return up;
    return img;
}

sk_sp<SkImage> gpu_stream_image(GpuState* state, const void* rgba, int w, int h) {
    // Graphite Metal keeps the persistent-surface path in kx_draw_pixels.
    (void)state; (void)rgba; (void)w; (void)h;
    return nullptr;
}

const char* platform_font_family() { return nullptr; }

const char* platform_fallback_font_family() { return nullptr; }

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
