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
// Ganesh Metal (Phase 4c: backend matrix) — legacy Ganesh API on Metal.
#include "include/gpu/ganesh/mtl/GrMtlBackendContext.h"
#include "include/gpu/ganesh/mtl/GrMtlBackendSurface.h"
#include "include/gpu/ganesh/mtl/GrMtlDirectContext.h"

// Graphite Dawn (Metal) — Skia Graphite on Dawn's Metal backend (Phase 3e).
// Same shape as the Graphite Metal path, but the device/queue/texture wrapping
// go through Dawn (libdawn_combined.a): the recipe is skia's
// tools/graphite/dawn/GraphiteDawnTestContext.cpp + dawn's SwapChainMTL.mm.
#include "dawn/dawn_proc.h"
#include "dawn/native/DawnNative.h"
#include "dawn/native/MetalBackend.h"
#include "webgpu/webgpu_cpp.h"
#include "src/dawn/native/metal/TextureMTL.h"
#include "src/dawn/native/metal/QueueMTL.h"
#include "src/dawn/native/metal/CommandRecordingContext.h"
#include "src/dawn/native/metal/Forward.h"
#include "src/dawn/native/ObjectBase.h"
#include "src/dawn/native/ChainUtils.h"
#include "src/dawn/native/ToBackend.h"
#include "include/gpu/graphite/dawn/DawnBackendContext.h"
#include "include/gpu/graphite/dawn/DawnGraphiteTypes.h"

#include <OpenGLES/ES3/gl.h>

#include <memory>
#include <vector>

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
    // Graphite Dawn path (Dawn Metal backend): the graphite Context is the
    // shared `context` field above; Dawn owns the device/queue/instance.
    std::unique_ptr<dawn::native::Instance> dawn_instance;
    wgpu::Instance dawn_wgpu_instance;
    wgpu::Device dawn_device;
    wgpu::Queue dawn_queue;
    // Current frame's wrapped drawable: internal ref (dawn_tex) + wgpu-side
    // ref (dawn_wgpu_tex). BackendTextures::MakeDawn does NOT retain the
    // WGPUTexture — the frame surface retains its own; these two keep the
    // wrapped texture alive until after submit (like the Metal path's
    // drawable_texture).
    dawn::Ref<dawn::native::metal::Texture> dawn_tex;
    wgpu::Texture dawn_wgpu_tex;
    // Ganesh paths (GLES + Metal)
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

    // Metal view + layer: shared by the Graphite Metal (default) and
    // Ganesh Metal paths.
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

    if (backend == KX_BACKEND_GANESH_METAL) {
        // Ganesh Metal (legacy Ganesh API) on the same CAMetalLayer. The
        // direct context renders through state->command_queue; presenting
        // on that same queue keeps submission/present ordering correct.
        GrMtlBackendContext mtl_backend;
        // sk_cfp adopts the +1 CFRetain reference (and releases it).
        mtl_backend.fDevice = sk_cfp<GrMTLHandle>((GrMTLHandle)CFRetain((__bridge CFTypeRef)device));
        mtl_backend.fQueue = sk_cfp<GrMTLHandle>((GrMTLHandle)CFRetain((__bridge CFTypeRef)state->command_queue));
        state->dctx = GrDirectContexts::MakeMetal(mtl_backend);
        if (!state->dctx) { SDL_Metal_DestroyView(state->metal_view); delete state; return false; }
        *out = state;
        return true;
    }

    if (backend == KX_BACKEND_GRAPHITE_DAWN) {
        // Graphite Dawn: Skia Graphite on Dawn's Metal backend. The Metal
        // view/layer/device setup above is shared; Dawn gets its own device
        // (adapter picked by wgpu::BackendType::Metal) on the same MTLDevice
        // and presents through its own queue (gpu_end_frame). Recipe:
        // skia tools/graphite/dawn/GraphiteDawnTestContext.cpp.
        DawnProcTable procs = dawn::native::GetProcs();
        dawnProcSetProcs(&procs);
        // TimedWaitAny: skia's Dawn backend waits on futures with a timeout
        // (DawnGraphicsPipeline/DawnErrorChecker/DawnGraphiteUtils call
        // instance.WaitAny with timeout > 0); without the feature every such
        // wait errors out ("Timeout waits are either not enabled...") and
        // async pipeline creation fails. Same requirement as skia's
        // GraphiteDawnTestContext.
        wgpu::InstanceDescriptor inst_desc{};
        static const wgpu::InstanceFeatureName kTimedWaitAny = wgpu::InstanceFeatureName::TimedWaitAny;
        inst_desc.requiredFeatureCount = 1;
        inst_desc.requiredFeatures = &kTimedWaitAny;
        state->dawn_instance = std::make_unique<dawn::native::Instance>(&inst_desc);
        std::vector<dawn::native::Adapter> adapters = state->dawn_instance->EnumerateAdapters();
        wgpu::Adapter matched;
        for (const auto& adapter : adapters) {
            wgpu::AdapterInfo props;
            wgpu::Adapter(adapter.Get()).GetInfo(&props);
            if (props.backendType == wgpu::BackendType::Metal) {
                matched = wgpu::Adapter(adapter.Get());
                break;
            }
        }
        if (!matched) { SDL_Metal_DestroyView(state->metal_view); delete state; return false; }
        wgpu::DeviceDescriptor dev_desc;
        dev_desc.SetDeviceLostCallback(
            wgpu::CallbackMode::AllowSpontaneous,
            [](const wgpu::Device&, wgpu::DeviceLostReason reason, wgpu::StringView message) {
                SDL_Log("klaxon dawn: device lost (reason %d): %.*s",
                        static_cast<int>(reason), static_cast<int>(message.length), message.data);
            });
        dev_desc.SetUncapturedErrorCallback(
            [](const wgpu::Device&, wgpu::ErrorType type, wgpu::StringView message) {
                SDL_Log("klaxon dawn: device error (type %d): %.*s",
                        static_cast<int>(type), static_cast<int>(message.length), message.data);
            });
        state->dawn_device = matched.CreateDevice(&dev_desc);
        if (!state->dawn_device) { SDL_Metal_DestroyView(state->metal_view); delete state; return false; }
        state->dawn_queue = state->dawn_device.GetQueue();
        state->dawn_wgpu_instance = wgpu::Instance(state->dawn_instance->Get());

        skgpu::graphite::DawnBackendContext dawn_ctx;
        dawn_ctx.fInstance = state->dawn_wgpu_instance;
        dawn_ctx.fDevice = state->dawn_device;
        dawn_ctx.fQueue = state->dawn_queue;
        state->context = skgpu::graphite::ContextFactory::MakeDawn(dawn_ctx, skgpu::graphite::ContextOptions{});
        if (!state->context) { SDL_Metal_DestroyView(state->metal_view); delete state; return false; }
        *out = state;
        return true;
    }

    // Graphite Metal path (default).
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
    // Ganesh (GLES + Metal): flush + release the direct context.
    if (state->dctx) {
        state->dctx->flushAndSubmit(GrSyncCpu::kYes);
        state->dctx = nullptr;
    }
    // Graphite Metal / Dawn: submit + release the context.
    state->recorder.reset();
    if (state->context) {
        state->context->submit(skgpu::graphite::SyncToCpu::kYes);
        state->context.reset();
    }
    // Graphite Dawn: release the wgpu device/queue + instance (after the
    // graphite context — it holds refs to them).
    state->dawn_wgpu_tex = nullptr;
    state->dawn_tex = nullptr;
    state->dawn_queue = nullptr;
    state->dawn_device = nullptr;
    state->dawn_wgpu_instance = nullptr;
    state->dawn_instance.reset();
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

    // Ganesh Metal path: wrap the layer's drawable texture as a Ganesh
    // backend render target (top-left origin, BGRA8 — the layer's format).
    if (state->backend == KX_BACKEND_GANESH_METAL) {
        if (!state->dctx || !state->layer) return nullptr;
        state->drawable = [state->layer nextDrawable];
        if (!state->drawable) return nullptr;
        state->drawable_texture = state->drawable.texture;
        GrMtlTextureInfo tex_info;
        // The sk_cfp adopts the +1 reference; the render target (kept alive
        // by the surface) retains the texture for the frame.
        tex_info.fTexture = sk_cfp<GrMTLHandle>((GrMTLHandle)CFRetain((__bridge CFTypeRef)state->drawable_texture));
        const GrBackendRenderTarget target = GrBackendRenderTargets::MakeMtl(
            state->width, state->height, tex_info);
        state->frame_surface = SkSurfaces::WrapBackendRenderTarget(
            state->dctx.get(), target, kTopLeft_GrSurfaceOrigin,
            kBGRA_8888_SkColorType, SkColorSpace::MakeSRGB(), nullptr);
        if (!state->frame_surface) return nullptr;
        // Same DPR model as the Graphite path: point-space layout, pixel
        // drawable — scale the canvas.
        state->scale = layer_scale(state);
        SkCanvas* canvas = state->frame_surface->getCanvas();
        canvas->scale(state->scale, state->scale);
        return canvas;
    }

    // Graphite Dawn path: wrap the layer's drawable texture as a wgpu texture
    // through Dawn's Metal backend (dawn::native::metal::Texture::CreateWrapping
    // — the SwapChainMTL pattern), then WrapBackendTexture like the Metal path.
    if (state->backend == KX_BACKEND_GRAPHITE_DAWN) {
        if (!state->context || !state->layer || !state->dawn_device) return nullptr;
        state->drawable = [state->layer nextDrawable];
        if (!state->drawable) return nullptr;
        state->drawable_texture = state->drawable.texture;
        dawn::native::metal::Device* dawn_dev =
            dawn::native::metal::ToBackend(dawn::native::FromAPI(state->dawn_device.Get()));
        dawn::native::TextureDescriptor tex_desc;
        tex_desc.usage = wgpu::TextureUsage::RenderAttachment;
        tex_desc.dimension = wgpu::TextureDimension::e2D;
        tex_desc.size = {(uint32_t)state->width, (uint32_t)state->height, 1u};
        tex_desc.format = wgpu::TextureFormat::BGRA8Unorm;
        tex_desc.mipLevelCount = 1;
        tex_desc.sampleCount = 1;
        state->dawn_tex = dawn::native::metal::Texture::CreateWrapping(
            dawn_dev, dawn::native::Unpack(&tex_desc),
            dawn::NSPRef<id<MTLTexture>>(state->drawable_texture));
        if (!state->dawn_tex) return nullptr;
        state->dawn_wgpu_tex = wgpu::Texture(dawn::native::ToAPI(state->dawn_tex.Get()));
        state->recorder = state->context->makeRecorder();
        if (!state->recorder) return nullptr;
        const skgpu::graphite::BackendTexture backend_tex =
            skgpu::graphite::BackendTextures::MakeDawn(state->dawn_wgpu_tex.Get());
        state->frame_surface = SkSurfaces::WrapBackendTexture(
            state->recorder.get(), backend_tex, kBGRA_8888_SkColorType,
            SkColorSpace::MakeSRGB(), nullptr);
        if (!state->frame_surface) return nullptr;
        // Same DPR model as the Graphite Metal path: point-space layout,
        // pixel drawable — scale the canvas.
        state->scale = layer_scale(state);
        SkCanvas* canvas = state->frame_surface->getCanvas();
        canvas->scale(state->scale, state->scale);
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

    // Ganesh Metal path: flush, then present on the same queue (Skia's
    // submissions and the presentDrawable are ordered on one queue).
    if (state->backend == KX_BACKEND_GANESH_METAL) {
        if (!state->dctx) return;
        state->dctx->flushAndSubmit();
        state->frame_surface = nullptr;
        state->drawable_texture = nil;
        if (state->drawable) {
            if (state->command_queue) {
                id<MTLCommandBuffer> cb = [state->command_queue commandBuffer];
                [cb presentDrawable:state->drawable];
                [cb commit];
            }
            state->drawable = nil;
        }
        return;
    }

    // Graphite Dawn path: snap + insert + submit like Graphite Metal, then
    // present through DAWN's queue (presenting on Klaxon's own command_queue
    // risks presenting before Dawn's GPU work lands).
    if (state->backend == KX_BACKEND_GRAPHITE_DAWN) {
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
        // Synchronous submit (same as Graphite Metal): GPU work completes
        // before we release the wrapped drawable texture.
        state->context->submit(skgpu::graphite::SyncToCpu::kYes);
        // Release the frame surface BEFORE presenting (same as Graphite
        // Metal): the surface holds a BackendTexture referencing the wrapped
        // drawable texture.
        state->frame_surface = nullptr;
        state->dawn_wgpu_tex = nullptr;
        state->dawn_tex = nullptr;
        state->drawable_texture = nil;
        if (state->drawable) {
            // Present through Dawn's queue (SwapChainMTL::PresentImpl): append
            // presentDrawable to Dawn's pending command buffer and submit it.
            dawn::native::metal::Queue* dawn_queue =
                dawn::native::metal::ToBackend(dawn::native::FromAPI(state->dawn_queue.Get()));
            dawn::native::metal::CommandRecordingContext* command_context =
                dawn_queue->GetPendingCommandContext();
            [command_context->GetCommands() presentDrawable:state->drawable];
            (void)dawn_queue->SubmitPendingCommandBuffer();
            state->drawable = nil;
        }
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

// Warmup (Phase 4e.1): stubs — per-backend offscreen surfaces (Graphite
// Metal, Graphite Dawn, Ganesh Metal, Ganesh GLES) are Phase 4e.1b; warmup
// is best-effort, so kx_gpu_warmup returns false on iOS until then (the
// host logs it and moves on).
SkCanvas* gpu_begin_offscreen(GpuState* state, int width, int height) {
    (void)state;
    (void)width;
    (void)height;
    return nullptr;
}
bool gpu_end_offscreen(GpuState* state) {
    (void)state;
    return false;
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
