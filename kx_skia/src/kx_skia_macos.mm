// kx_skia_macos.mm — macOS platform implementation: Graphite (Metal) onscreen
// backend + CoreText font manager. arm64 only (no x64).
#include "kx_skia_platform.h"

#include <SDL3/SDL.h>
#include <SDL3/SDL_metal.h>

#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>

#include "include/core/SkImageInfo.h"
#include "include/core/SkSurface.h"
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

#include <memory>

namespace kx {

struct GpuState {
    std::unique_ptr<skgpu::graphite::Context> context;
    std::unique_ptr<skgpu::graphite::Recorder> recorder;
    sk_sp<SkSurface> frame_surface;
    // Warmup (Phase 4e.1): recorder + surface for the offscreen pre-compile pass.
    std::unique_ptr<skgpu::graphite::Recorder> warmup_recorder;
    sk_sp<SkSurface> warmup_surface;
    CAMetalLayer* layer = nil;
    SDL_MetalView metal_view = nullptr;
    id<CAMetalDrawable> drawable = nil;
    int width = 0;
    int height = 0;
};

bool gpu_init(GpuState** out, void* sdl_window, int width, int height, kx_backend backend) {
    (void)backend; // unused on this platform
    if (!sdl_window || !out) return false;
    auto* state = new GpuState();
    state->width = width;
    state->height = height;

    state->metal_view = SDL_Metal_CreateView(static_cast<SDL_Window*>(sdl_window));
    if (!state->metal_view) { delete state; return false; }
    state->layer = (__bridge CAMetalLayer*)SDL_Metal_GetLayer(state->metal_view);
    if (!state->layer) { SDL_Metal_DestroyView(state->metal_view); delete state; return false; }

    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device) { SDL_Metal_DestroyView(state->metal_view); delete state; return false; }
    state->layer.device = device;
    state->layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
    state->layer.framebufferOnly = YES;
    state->layer.drawableSize = CGSizeMake(width, height);

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
    state->recorder.reset();
    if (state->context) {
        state->context->submit(skgpu::graphite::SyncToCpu::kYes);
        state->context.reset();
    }
    if (state->metal_view) SDL_Metal_DestroyView(state->metal_view);
    delete state;
}

void gpu_resize(GpuState* state, int width, int height) {
    if (!state || !state->layer) return;
    state->width = width;
    state->height = height;
    state->layer.drawableSize = CGSizeMake(width, height);
}

SkCanvas* gpu_begin_frame(GpuState* state) {
    if (!state || !state->context || !state->layer) return nullptr;
    state->drawable = [state->layer nextDrawable];
    if (!state->drawable) return nullptr;
    // One recorder for the ctx lifetime: Recorder::snap() leaves it
    // reusable (it drains the task list and resets the buffer managers).
    // Resetting it per frame killed every RenderTarget surface created on
    // it — the offscreen pool had to be dropped each frame and the row
    // atlas could not persist at all.
    if (!state->recorder) {
        state->recorder = state->context->makeRecorder();
        if (!state->recorder) return nullptr;
    }
    const skgpu::graphite::BackendTexture backend_tex = skgpu::graphite::BackendTextures::MakeMetal(
        SkISize::Make(state->width, state->height),
        (__bridge CFTypeRef)state->drawable.texture);
    state->frame_surface = SkSurfaces::WrapBackendTexture(
        state->recorder.get(), backend_tex, kBGRA_8888_SkColorType, nullptr, nullptr);
    if (!state->frame_surface) return nullptr;
    return state->frame_surface->getCanvas();
}

void gpu_end_frame(GpuState* state) {
    if (!state || !state->context) return;
    if (state->recorder) {
        std::unique_ptr<skgpu::graphite::Recording> recording = state->recorder->snap();
        if (recording) {
            skgpu::graphite::InsertRecordingInfo info;
            info.fRecording = recording.get();
            info.fTargetSurface = state->frame_surface.get();
            state->context->insertRecording(info);
        }
        // Keep the recorder: surfaces created on it (offscreen pool, row
        // atlas) stay alive across frames — snap() already reset the
        // per-recording state.
    }
    state->context->submit();
    if (state->drawable) {
        [state->drawable present];
        state->drawable = nil;
    }
    state->frame_surface = nullptr;
}

SkCanvas* gpu_begin_offscreen(GpuState* state, int width, int height) {
    // Warmup (Phase 4e.1): a Graphite render-target surface on its own
    // recorder — the same draw ops, so the same pipelines the onscreen
    // frames use (Metal compiles pipelines lazily on first use, like
    // Ganesh's programs).
    if (!state || !state->context || width <= 0 || height <= 0) return nullptr;
    state->warmup_recorder = state->context->makeRecorder();
    if (!state->warmup_recorder) return nullptr;
    // Signature at the pinned Skia (include/gpu/graphite/Surface.h):
    // RenderTarget(Recorder*, const SkImageInfo&, Mipmapped = kNo,
    //              const SkSurfaceProps* = nullptr, std::string_view = {})
    // — no Budgeted parameter on the graphite overload at this pin.
    // BGRA like the wrapped CAMetalLayer drawable — Graphite pipelines are
    // per-target-format, so an RGBA warmup would not prime onscreen draws.
    state->warmup_surface = SkSurfaces::RenderTarget(
        state->warmup_recorder.get(),
        SkImageInfo::Make(width, height, kBGRA_8888_SkColorType, kPremul_SkAlphaType, nullptr));
    return state->warmup_surface ? state->warmup_surface->getCanvas() : nullptr;
}

bool gpu_end_offscreen(GpuState* state) {
    if (!state || !state->context) return false;
    if (state->warmup_recorder) {
        std::unique_ptr<skgpu::graphite::Recording> recording = state->warmup_recorder->snap();
        if (recording) {
            skgpu::graphite::InsertRecordingInfo info;
            info.fRecording = recording.get();
            info.fTargetSurface = state->warmup_surface.get();
            state->context->insertRecording(info);
        }
        state->warmup_recorder.reset();
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

sk_sp<SkFontMgr> platform_font_mgr() {
    return SkFontMgr_New_CoreText(nullptr);
}

const char* platform_font_family() { return nullptr; }

const char* platform_fallback_font_family() { return nullptr; }

} // namespace kx
