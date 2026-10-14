// kx_skia_linux.cpp — Linux platform implementation. Backend contract
// (docs/ARCHITECTURE.md): graphite-vulkan → ganesh-gl → raster (raster lives
// in kx_skia_common). Implements kx_skia_platform.h.
//
// graphite-vulkan (primary): SDL owns the VkSurfaceKHR (host.zig creates the
// window with SDL_WINDOW_VULKAN); the shim loads libvulkan through
// SDL_Vulkan_LoadLibrary, creates instance/device/swapchain itself, and hands
// Skia a VulkanBackendContext (instance + device + queue + getProc + a
// VulkanMemoryAllocator from Skia's vendored VMA external). Frame flow
// mirrors tools/window/GraphiteNativeVulkanWindowContext.cpp but fully
// synchronous: acquire via fence + Context::submit(SyncToCpu::kYes) means no
// semaphores are needed — the CPU waits for render completion before
// vkQueuePresentKHR (same submit model as the Windows Dawn path).
//
// ganesh-gl (fallback): SDL owns the GL context (host.zig creates + makes it
// current before kx_create when the backend resolves to ganesh-gl) — the
// shim resolves every GL entry point through SDL_GL_GetProcAddress via
// Skia's assembled-interface factory, so no EGL/GLX/libGL headers or link
// deps are needed and the same code runs on X11, Wayland, and headless
// llvmpipe. The FBO-0 wrap and the CanvasKit render-target pattern mirror
// the wasm/android shims.

// <vulkan/vulkan.h> first: when VULKAN_H_ is already defined SDL_vulkan.h
// skips its opaque handle typedefs, avoiding redefinition noise. The headers
// are Skia's vendored copy (deps/skia/include/third_party/vulkan on the
// include path) — no vulkan-headers external or system SDK is required to
// compile the shim.
#include <vulkan/vulkan.h>

#include "kx_skia_platform.h"

#include <SDL3/SDL.h>
#include <SDL3/SDL_vulkan.h>

#include "include/core/SkColor.h"
#include "include/core/SkColorSpace.h"
#include "include/core/SkFontMgr.h"
#include "include/core/SkImageInfo.h"
#include "include/core/SkSize.h"
#include "include/core/SkSurface.h"
#include "include/gpu/ganesh/GrBackendSurface.h"
#include "include/gpu/ganesh/GrDirectContext.h"
#include "include/gpu/ganesh/GrTypes.h"
#include "include/gpu/ganesh/SkImageGanesh.h"
#include "include/gpu/ganesh/SkSurfaceGanesh.h"
#include "include/gpu/ganesh/gl/GrGLAssembleInterface.h"
#include "include/gpu/ganesh/gl/GrGLBackendSurface.h"
#include "include/gpu/ganesh/gl/GrGLDirectContext.h"
#include "include/gpu/ganesh/gl/GrGLInterface.h"
#include "include/gpu/ganesh/gl/GrGLTypes.h"
#include "include/gpu/graphite/BackendTexture.h"
#include "include/gpu/graphite/Context.h"
#include "include/gpu/graphite/ContextOptions.h"
#include "include/gpu/graphite/GraphiteTypes.h"
#include "include/gpu/graphite/Image.h"
#include "include/gpu/graphite/Recorder.h"
#include "include/gpu/graphite/Recording.h"
#include "include/gpu/graphite/Surface.h"
#include "include/gpu/graphite/vk/VulkanGraphiteContext.h"
#include "include/gpu/graphite/vk/VulkanGraphiteTypes.h"
#include "include/gpu/vk/VulkanBackendContext.h"
#include "include/gpu/vk/VulkanExtensions.h"
#include "include/gpu/vk/VulkanMutableTextureState.h"
#include "include/gpu/vk/VulkanPreferredFeatures.h"
#include "include/ports/SkFontMgr_directory.h"
#include "include/ports/SkFontMgr_empty.h"
#include "src/gpu/GpuTypesPriv.h" // skgpu::ThreadSafe (private, same as win shim)
#include "src/gpu/ganesh/gl/GrGLDefines.h" // GR_GL_RGBA8 / GR_GL_FRAMEBUFFER (private, same as wasm shim)
#include "src/gpu/graphite/ContextOptionsPriv.h" // fStoreContextRefInRecorder (private, same as win shim)
#include "src/gpu/vk/vulkanmemoryallocator/VulkanMemoryAllocatorPriv.h" // VulkanMemoryAllocators::Make (private; compiled into libskia by skia_use_vma)

#include <algorithm>
#include <cstdint>
#include <cstring>
#include <vector>

namespace kx {

// ---- Ganesh GL --------------------------------------------------------------
// Desktop-GL constants Skia hands back through GrGLTypes — the shim calls
// exactly one GL function directly (glBindFramebuffer), resolved through
// SDL so no GL header is required.
typedef void (*GLBindFramebufferFn)(uint32_t target, uint32_t fb);
static GLBindFramebufferFn glBindFramebuffer_ptr = nullptr;

static GrGLFuncPtr sdl_gl_get_proc(void*, const char name[]) {
    return reinterpret_cast<GrGLFuncPtr>(SDL_GL_GetProcAddress(name));
}

// ---- Graphite Vulkan --------------------------------------------------------

// Device/instance procs the shim calls itself (Skia pulls everything else
// through VulkanBackendContext::fGetProc).
struct VkProcs {
    PFN_vkGetInstanceProcAddr getInstanceProcAddr = nullptr;
    PFN_vkGetDeviceProcAddr getDeviceProcAddr = nullptr;
    PFN_vkDestroyInstance destroyInstance = nullptr;
    PFN_vkDestroySurfaceKHR destroySurfaceKHR = nullptr;
    PFN_vkDestroyDevice destroyDevice = nullptr;
    PFN_vkDeviceWaitIdle deviceWaitIdle = nullptr;
    PFN_vkGetDeviceQueue getDeviceQueue = nullptr;
    PFN_vkCreateSwapchainKHR createSwapchainKHR = nullptr;
    PFN_vkDestroySwapchainKHR destroySwapchainKHR = nullptr;
    PFN_vkGetSwapchainImagesKHR getSwapchainImagesKHR = nullptr;
    PFN_vkAcquireNextImageKHR acquireNextImageKHR = nullptr;
    PFN_vkQueuePresentKHR queuePresentKHR = nullptr;
    PFN_vkCreateFence createFence = nullptr;
    PFN_vkDestroyFence destroyFence = nullptr;
    PFN_vkWaitForFences waitForFences = nullptr;
    PFN_vkResetFences resetFences = nullptr;
};

// One wrapped SkSurface per swapchain image — surfaces are created once per
// swapchain (resize recreates the whole set); each frame re-acquires an index
// and draws into that image's surface.
struct VkSwapchainState {
    VkSwapchainKHR handle = VK_NULL_HANDLE;
    VkFormat format = VK_FORMAT_UNDEFINED;
    VkExtent2D extent = {0, 0};
    std::vector<sk_sp<SkSurface>> surfaces;
};

struct GpuState {
    SDL_Window* window = nullptr;
    int width = 0;
    int height = 0;

    // --- ganesh-gl ---
    sk_sp<GrDirectContext> dctx;
    sk_sp<SkSurface> frame_surface;
    sk_sp<SkSurface> warmup_surface; // offscreen target for kx_gpu_warmup

    // --- graphite-vulkan ---
    bool vk_lib_loaded = false;   // SDL_Vulkan_LoadLibrary ref held by the shim
    VkProcs vk;
    skgpu::VulkanGetProc vk_get_proc;
    VkInstance vk_instance = VK_NULL_HANDLE;
    VkPhysicalDevice vk_phys = VK_NULL_HANDLE;
    VkDevice vk_device = VK_NULL_HANDLE;
    VkQueue vk_gfx_queue = VK_NULL_HANDLE;
    VkQueue vk_present_queue = VK_NULL_HANDLE;
    uint32_t vk_gfx_family = 0;
    uint32_t vk_present_family = 0;
    VkSurfaceKHR vk_surface = VK_NULL_HANDLE;
    skgpu::VulkanExtensions vk_extensions;
    std::unique_ptr<skgpu::graphite::Context> gcontext;
    std::unique_ptr<skgpu::graphite::Recorder> grecorder;
    VkSwapchainState swapchain;
    bool swapchain_dirty = false;   // resize / OUT_OF_DATE: recreate next frame
    VkFence acquire_fence = VK_NULL_HANDLE;
    uint32_t acquired_index = 0;
    bool frame_acquired = false;    // begin_frame acquired a swapchain image
};

// Fetch an instance-level proc; null-checked by callers.
static PFN_vkVoidFunction vk_iproc(const VkProcs& vk, VkInstance inst, const char* name) {
    return vk.getInstanceProcAddr ? vk.getInstanceProcAddr(inst, name) : nullptr;
}
static PFN_vkVoidFunction vk_dproc(const VkProcs& vk, VkDevice dev, const char* name) {
    if (vk.getDeviceProcAddr && dev != VK_NULL_HANDLE) {
        if (PFN_vkVoidFunction p = vk.getDeviceProcAddr(dev, name)) return p;
    }
    return vk.getInstanceProcAddr ? vk.getInstanceProcAddr(VK_NULL_HANDLE, name) : nullptr;
}

// Drop the wrapped surfaces and destroy the swapchain object (device must be
// idle — callers waitIdle first). Used by recreate + teardown.
static void vulkan_destroy_swapchain(GpuState* st) {
    st->swapchain.surfaces.clear();
    if (st->swapchain.handle != VK_NULL_HANDLE) {
        st->vk.destroySwapchainKHR(st->vk_device, st->swapchain.handle, nullptr);
        st->swapchain.handle = VK_NULL_HANDLE;
    }
}

// Release every Vulkan object in dependency order. Safe on a partially
// initialized GpuState — every handle is null-checked.
static void vulkan_teardown(GpuState* st) {
    if (st->vk_device != VK_NULL_HANDLE && st->vk.deviceWaitIdle) {
        st->vk.deviceWaitIdle(st->vk_device);
    }
    st->frame_surface = nullptr;
    st->warmup_surface = nullptr;
    st->frame_acquired = false;

    if (st->acquire_fence != VK_NULL_HANDLE && st->vk.destroyFence) {
        st->vk.destroyFence(st->vk_device, st->acquire_fence, nullptr);
        st->acquire_fence = VK_NULL_HANDLE;
    }
    if (st->vk.destroySwapchainKHR) vulkan_destroy_swapchain(st);

    // Graphite owns Skia-side Vulkan resources (pipeline cache, VMA) — drop
    // the recorder and context before the device dies.
    st->grecorder.reset();
    st->gcontext.reset();

    if (st->vk_surface != VK_NULL_HANDLE && st->vk.destroySurfaceKHR) {
        st->vk.destroySurfaceKHR(st->vk_instance, st->vk_surface, nullptr);
        st->vk_surface = VK_NULL_HANDLE;
    }
    if (st->vk_device != VK_NULL_HANDLE && st->vk.destroyDevice) {
        st->vk.destroyDevice(st->vk_device, nullptr);
        st->vk_device = VK_NULL_HANDLE;
    }
    st->vk_phys = VK_NULL_HANDLE;
    if (st->vk_instance != VK_NULL_HANDLE && st->vk.destroyInstance) {
        st->vk.destroyInstance(st->vk_instance, nullptr);
        st->vk_instance = VK_NULL_HANDLE;
    }
    if (st->vk_lib_loaded) {
        SDL_Vulkan_UnloadLibrary();
        st->vk_lib_loaded = false;
    }
    st->vk = VkProcs{};
    st->vk_get_proc = nullptr;
}

// Pick the swapchain surface format: prefer linear RGBA8/BGRA8 (the hardware
// sRGB variants need a linear-gamut dst colorspace we don't set up), fall
// back to whatever the driver offers first.
static VkSurfaceFormatKHR pick_surface_format(const std::vector<VkSurfaceFormatKHR>& formats) {
    if (formats.size() == 1 && formats[0].format == VK_FORMAT_UNDEFINED) {
        return {VK_FORMAT_B8G8R8A8_UNORM, VK_COLOR_SPACE_SRGB_NONLINEAR_KHR};
    }
    for (VkFormat want : {VK_FORMAT_B8G8R8A8_UNORM, VK_FORMAT_R8G8B8A8_UNORM}) {
        for (const auto& f : formats) {
            if (f.format == want) return f;
        }
    }
    for (const auto& f : formats) {
        if (f.format != VK_FORMAT_B8G8R8A8_SRGB && f.format != VK_FORMAT_R8G8B8A8_SRGB &&
            f.format != VK_FORMAT_A8B8G8R8_SRGB_PACK32) {
            return f;
        }
    }
    return formats[0];
}


static bool vulkan_init(GpuState* st);
static SkCanvas* vulkan_begin_frame(GpuState* st);
static void vulkan_end_frame(GpuState* st);
static SkCanvas* vulkan_begin_offscreen(GpuState* st, int width, int height);
static bool vulkan_end_offscreen(GpuState* st);

bool gpu_init(GpuState** out, void* sdl_window, int width, int height, kx_backend backend) {
    if (!out || !sdl_window) return false;
    if (backend != KX_BACKEND_GANESH_GL && backend != KX_BACKEND_GRAPHITE_VULKAN) return false;

    auto* state = new GpuState();
    state->window = static_cast<SDL_Window*>(sdl_window);
    state->width = width;
    state->height = height;

    bool ok = false;
    if (backend == KX_BACKEND_GRAPHITE_VULKAN) {
        ok = vulkan_init(state);
    } else {
        // Ganesh GL: the caller (host.zig) creates a desktop GL context on
        // the SDL window and makes it current BEFORE kx_create — Ganesh
        // binds to whatever is current here.
        if (SDL_GL_GetCurrentContext()) {
            sk_sp<const GrGLInterface> interface =
                GrGLMakeAssembledGLInterface(nullptr, sdl_gl_get_proc);
            if (interface) {
                state->dctx = GrDirectContexts::MakeGL(std::move(interface));
            }
            if (state->dctx) {
                glBindFramebuffer_ptr = reinterpret_cast<GLBindFramebufferFn>(
                    SDL_GL_GetProcAddress("glBindFramebuffer"));
            }
            ok = state->dctx && glBindFramebuffer_ptr;
        }
    }
    if (!ok) { gpu_shutdown(state); return false; }
    *out = state;
    return true;
}

// ---- vulkan_init ------------------------------------------------------------

static bool vulkan_init(GpuState* st) {
    if (!SDL_Vulkan_LoadLibrary(nullptr)) return false;
    st->vk_lib_loaded = true;
    st->vk.getInstanceProcAddr =
        (PFN_vkGetInstanceProcAddr)SDL_Vulkan_GetVkGetInstanceProcAddr();
    if (!st->vk.getInstanceProcAddr) return false;

    PFN_vkEnumerateInstanceExtensionProperties enumInstExt =
        (PFN_vkEnumerateInstanceExtensionProperties)vk_iproc(
            st->vk, VK_NULL_HANDLE, "vkEnumerateInstanceExtensionProperties");
    PFN_vkCreateInstance createInstance =
        (PFN_vkCreateInstance)vk_iproc(st->vk, VK_NULL_HANDLE, "vkCreateInstance");
    if (!enumInstExt || !createInstance) return false;

    // Skia needs Vulkan 1.1 minimum; request exactly that (most portable —
    // same pin as Skia's own vk test harness).
    const uint32_t api_version = VK_API_VERSION_1_1;

    // Instance extensions: everything SDL says the windowing system needs,
    // plus whatever Skia's VulkanPreferredFeatures wants on top.
    skgpu::VulkanPreferredFeatures skia_features;
    skia_features.init(api_version);
    uint32_t sdl_ext_count = 0;
    char const* const* sdl_exts = SDL_Vulkan_GetInstanceExtensions(&sdl_ext_count);
    if (!sdl_exts || sdl_ext_count == 0) return false;
    std::vector<const char*> inst_ext_names(sdl_exts, sdl_exts + sdl_ext_count);

    uint32_t avail_inst_count = 0;
    std::vector<VkExtensionProperties> avail_inst_exts;
    std::vector<const char*> avail_inst_names;
    if (enumInstExt(nullptr, &avail_inst_count, nullptr) == VK_SUCCESS && avail_inst_count) {
        avail_inst_exts.resize(avail_inst_count);
        enumInstExt(nullptr, &avail_inst_count, avail_inst_exts.data());
        for (const auto& e : avail_inst_exts) avail_inst_names.push_back(e.extensionName);
        skia_features.addToInstanceExtensions(avail_inst_exts.data(), avail_inst_exts.size(),
                                              inst_ext_names);
    }

    VkApplicationInfo app{};
    app.sType = VK_STRUCTURE_TYPE_APPLICATION_INFO;
    app.pApplicationName = "klaxon";
    app.pEngineName = "klaxon";
    app.apiVersion = api_version;
    VkInstanceCreateInfo ici{};
    ici.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO;
    ici.pApplicationInfo = &app;
    ici.enabledExtensionCount = (uint32_t)inst_ext_names.size();
    ici.ppEnabledExtensionNames = inst_ext_names.data();
    if (createInstance(&ici, nullptr, &st->vk_instance) != VK_SUCCESS) return false;

    st->vk.getDeviceProcAddr = (PFN_vkGetDeviceProcAddr)vk_iproc(
        st->vk, st->vk_instance, "vkGetDeviceProcAddr");
    st->vk.destroyInstance =
        (PFN_vkDestroyInstance)vk_iproc(st->vk, st->vk_instance, "vkDestroyInstance");
    st->vk.destroySurfaceKHR = (PFN_vkDestroySurfaceKHR)vk_iproc(
        st->vk, st->vk_instance, "vkDestroySurfaceKHR");
    if (!st->vk.getDeviceProcAddr || !st->vk.destroyInstance || !st->vk.destroySurfaceKHR)
        return false;

    // The getProc Skia uses for every call: device procs through
    // vkGetDeviceProcAddr, the rest through vkGetInstanceProcAddr.
    PFN_vkGetInstanceProcAddr gipa = st->vk.getInstanceProcAddr;
    PFN_vkGetDeviceProcAddr gdpa = st->vk.getDeviceProcAddr;
    st->vk_get_proc = [gipa, gdpa](const char* name, VkInstance inst,
                                 VkDevice dev) -> PFN_vkVoidFunction {
        if (dev != VK_NULL_HANDLE && gdpa) {
            if (PFN_vkVoidFunction p = gdpa(dev, name)) return p;
        }
        return gipa(inst, name);
    };

    // Surface on the SDL window (the window carries SDL_WINDOW_VULKAN).
    if (!SDL_Vulkan_CreateSurface(st->window, st->vk_instance, nullptr, &st->vk_surface))
        return false;

    // Physical device: prefer discrete, then integrated, then anything —
    // each must offer a graphics queue that can also present (prefer the
    // same family for both; a split present family still works via
    // CONCURRENT swapchain sharing).
    PFN_vkEnumeratePhysicalDevices enumPhys = (PFN_vkEnumeratePhysicalDevices)vk_iproc(
        st->vk, st->vk_instance, "vkEnumeratePhysicalDevices");
    PFN_vkGetPhysicalDeviceProperties getProps = (PFN_vkGetPhysicalDeviceProperties)vk_iproc(
        st->vk, st->vk_instance, "vkGetPhysicalDeviceProperties");
    PFN_vkGetPhysicalDeviceQueueFamilyProperties getQueueProps =
        (PFN_vkGetPhysicalDeviceQueueFamilyProperties)vk_iproc(
            st->vk, st->vk_instance, "vkGetPhysicalDeviceQueueFamilyProperties");
    PFN_vkGetPhysicalDeviceSurfaceSupportKHR getSurfaceSupport =
        (PFN_vkGetPhysicalDeviceSurfaceSupportKHR)vk_iproc(
            st->vk, st->vk_instance, "vkGetPhysicalDeviceSurfaceSupportKHR");
    PFN_vkGetPhysicalDeviceFeatures2 getFeatures2 = (PFN_vkGetPhysicalDeviceFeatures2)vk_iproc(
        st->vk, st->vk_instance, "vkGetPhysicalDeviceFeatures2");
    PFN_vkEnumerateDeviceExtensionProperties enumDevExt =
        (PFN_vkEnumerateDeviceExtensionProperties)vk_iproc(
            st->vk, st->vk_instance, "vkEnumerateDeviceExtensionProperties");
    PFN_vkCreateDevice createDevice =
        (PFN_vkCreateDevice)vk_iproc(st->vk, st->vk_instance, "vkCreateDevice");
    if (!enumPhys || !getProps || !getQueueProps || !getSurfaceSupport || !getFeatures2 ||
        !enumDevExt || !createDevice)
        return false;

    uint32_t gpu_count = 0;
    if (enumPhys(st->vk_instance, &gpu_count, nullptr) != VK_SUCCESS || gpu_count == 0)
        return false;
    std::vector<VkPhysicalDevice> gpus(gpu_count);
    if (enumPhys(st->vk_instance, &gpu_count, gpus.data()) != VK_SUCCESS) return false;

    auto device_score = [&](VkPhysicalDevice pd) -> int {
        VkPhysicalDeviceProperties props;
        getProps(pd, &props);
        switch (props.deviceType) {
            case VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU: return 3;
            case VK_PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU: return 2;
            default: return 1;
        }
    };
    std::stable_sort(gpus.begin(), gpus.end(), [&](VkPhysicalDevice a, VkPhysicalDevice b) {
        return device_score(a) > device_score(b);
    });

    VkPhysicalDevice phys = VK_NULL_HANDLE;
    uint32_t gfx_family = UINT32_MAX, present_family = UINT32_MAX;
    for (VkPhysicalDevice pd : gpus) {
        uint32_t family_count = 0;
        getQueueProps(pd, &family_count, nullptr);
        if (!family_count) continue;
        std::vector<VkQueueFamilyProperties> families(family_count);
        getQueueProps(pd, &family_count, families.data());
        uint32_t gfx = UINT32_MAX, present = UINT32_MAX;
        // Pass 1: a single family supporting graphics AND present (the
        // common case — one EXCLUSIVE-sharing swapchain).
        for (uint32_t i = 0; i < family_count; i++) {
            if (!(families[i].queueFlags & VK_QUEUE_GRAPHICS_BIT)) continue;
            if (gfx == UINT32_MAX) gfx = i;
            VkBool32 can_present = VK_FALSE;
            getSurfaceSupport(pd, i, st->vk_surface, &can_present);
            if (can_present) { gfx = present = i; break; }
        }
        // Pass 2: no combined family — first graphics family + first present
        // family (swapchain images then share CONCURRENT across both).
        if (present == UINT32_MAX) {
            for (uint32_t i = 0; i < family_count; i++) {
                VkBool32 can_present = VK_FALSE;
                getSurfaceSupport(pd, i, st->vk_surface, &can_present);
                if (can_present) { present = i; break; }
            }
        }
        if (gfx != UINT32_MAX && present != UINT32_MAX) {
            phys = pd; gfx_family = gfx; present_family = present; break;
        }
    }
    if (phys == VK_NULL_HANDLE) return false;
    st->vk_phys = phys;
    st->vk_gfx_family = gfx_family;
    st->vk_present_family = present_family;

    // Device extensions: swapchain is required, Skia adds whatever
    // VulkanPreferredFeatures asks for.
    uint32_t avail_dev_count = 0;
    std::vector<VkExtensionProperties> avail_dev_exts;
    std::vector<const char*> avail_dev_names;
    if (enumDevExt(phys, nullptr, &avail_dev_count, nullptr) != VK_SUCCESS) return false;
    avail_dev_exts.resize(avail_dev_count);
    if (enumDevExt(phys, nullptr, &avail_dev_count, avail_dev_exts.data()) != VK_SUCCESS)
        return false;
    for (const auto& e : avail_dev_exts) avail_dev_names.push_back(e.extensionName);

    bool has_swapchain_ext = false;
    for (const auto& e : avail_dev_exts) {
        if (std::strcmp(e.extensionName, VK_KHR_SWAPCHAIN_EXTENSION_NAME) == 0)
            has_swapchain_ext = true;
    }
    if (!has_swapchain_ext) return false;
    std::vector<const char*> dev_ext_names = {VK_KHR_SWAPCHAIN_EXTENSION_NAME};

    // Feature negotiation: query VkPhysicalDeviceFeatures2 with Skia's
    // chained structs, drop robustBufferAccess (perf hazard on some GPUs),
    // then let Skia enable what it wants. skia_features must outlive
    // vkCreateDevice (its members hang off device_features.pNext).
    VkPhysicalDeviceFeatures2 device_features{};
    device_features.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2;
    skia_features.addFeaturesToQuery(avail_dev_exts.data(), avail_dev_exts.size(),
                                   device_features);
    getFeatures2(phys, &device_features);
    device_features.features.robustBufferAccess = VK_FALSE;
    skia_features.addFeaturesToEnable(dev_ext_names, device_features);

    float queue_priority = 0.0f;
    VkDeviceQueueCreateInfo queue_infos[2]{};
    queue_infos[0].sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO;
    queue_infos[0].queueFamilyIndex = gfx_family;
    queue_infos[0].queueCount = 1;
    queue_infos[0].pQueuePriorities = &queue_priority;
    uint32_t queue_info_count = 1;
    if (present_family != gfx_family) {
        queue_infos[1].sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO;
        queue_infos[1].queueFamilyIndex = present_family;
        queue_infos[1].queueCount = 1;
        queue_infos[1].pQueuePriorities = &queue_priority;
        queue_info_count = 2;
    }
    VkDeviceCreateInfo dci{};
    dci.sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO;
    dci.pNext = &device_features;
    dci.queueCreateInfoCount = queue_info_count;
    dci.pQueueCreateInfos = queue_infos;
    dci.enabledExtensionCount = (uint32_t)dev_ext_names.size();
    dci.ppEnabledExtensionNames = dev_ext_names.data();
    if (createDevice(phys, &dci, nullptr, &st->vk_device) != VK_SUCCESS) return false;

    st->vk.destroyDevice =
        (PFN_vkDestroyDevice)vk_dproc(st->vk, st->vk_device, "vkDestroyDevice");
    st->vk.deviceWaitIdle =
        (PFN_vkDeviceWaitIdle)vk_dproc(st->vk, st->vk_device, "vkDeviceWaitIdle");
    st->vk.getDeviceQueue =
        (PFN_vkGetDeviceQueue)vk_dproc(st->vk, st->vk_device, "vkGetDeviceQueue");
    st->vk.createSwapchainKHR = (PFN_vkCreateSwapchainKHR)vk_dproc(
        st->vk, st->vk_device, "vkCreateSwapchainKHR");
    st->vk.destroySwapchainKHR = (PFN_vkDestroySwapchainKHR)vk_dproc(
        st->vk, st->vk_device, "vkDestroySwapchainKHR");
    st->vk.getSwapchainImagesKHR = (PFN_vkGetSwapchainImagesKHR)vk_dproc(
        st->vk, st->vk_device, "vkGetSwapchainImagesKHR");
    st->vk.acquireNextImageKHR = (PFN_vkAcquireNextImageKHR)vk_dproc(
        st->vk, st->vk_device, "vkAcquireNextImageKHR");
    st->vk.queuePresentKHR =
        (PFN_vkQueuePresentKHR)vk_dproc(st->vk, st->vk_device, "vkQueuePresentKHR");
    st->vk.createFence =
        (PFN_vkCreateFence)vk_dproc(st->vk, st->vk_device, "vkCreateFence");
    st->vk.destroyFence =
        (PFN_vkDestroyFence)vk_dproc(st->vk, st->vk_device, "vkDestroyFence");
    st->vk.waitForFences =
        (PFN_vkWaitForFences)vk_dproc(st->vk, st->vk_device, "vkWaitForFences");
    st->vk.resetFences =
        (PFN_vkResetFences)vk_dproc(st->vk, st->vk_device, "vkResetFences");
    if (!st->vk.destroyDevice || !st->vk.deviceWaitIdle || !st->vk.getDeviceQueue ||
        !st->vk.createSwapchainKHR || !st->vk.destroySwapchainKHR ||
        !st->vk.getSwapchainImagesKHR || !st->vk.acquireNextImageKHR ||
        !st->vk.queuePresentKHR || !st->vk.createFence || !st->vk.destroyFence ||
        !st->vk.waitForFences || !st->vk.resetFences)
        return false;

    st->vk.getDeviceQueue(st->vk_device, gfx_family, 0, &st->vk_gfx_queue);
    st->vk.getDeviceQueue(st->vk_device, present_family, 0, &st->vk_present_queue);
    if (st->vk_gfx_queue == VK_NULL_HANDLE || st->vk_present_queue == VK_NULL_HANDLE)
        return false;

    st->vk_extensions.init(st->vk_get_proc, st->vk_instance, phys,
                           (uint32_t)avail_inst_names.size(), avail_inst_names.data(),
                           (uint32_t)avail_dev_names.size(), avail_dev_names.data());

    skgpu::VulkanBackendContext backend_ctx{};
    backend_ctx.fInstance = st->vk_instance;
    backend_ctx.fPhysicalDevice = phys;
    backend_ctx.fDevice = st->vk_device;
    backend_ctx.fQueue = st->vk_gfx_queue;
    backend_ctx.fGraphicsQueueIndex = gfx_family;
    backend_ctx.fMaxAPIVersion = api_version;
    backend_ctx.fVkExtensions = &st->vk_extensions;
    backend_ctx.fDeviceFeatures2 = &device_features;
    backend_ctx.fGetProc = st->vk_get_proc;
    backend_ctx.fMemoryAllocator =
        skgpu::VulkanMemoryAllocators::Make(backend_ctx, skgpu::ThreadSafe::kYes);
    if (!backend_ctx.fMemoryAllocator) return false;

    skgpu::graphite::ContextOptions options;
    skgpu::graphite::ContextOptionsPriv priv;
    priv.fStoreContextRefInRecorder = true; // required for sync readPixels
    options.fOptionsPriv = &priv;
    st->gcontext = skgpu::graphite::ContextFactory::MakeVulkan(backend_ctx, options);
    if (!st->gcontext) return false;
    st->grecorder = st->gcontext->makeRecorder();
    if (!st->grecorder) return false;

    VkFenceCreateInfo fence_ci{};
    fence_ci.sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO;
    if (st->vk.createFence(st->vk_device, &fence_ci, nullptr, &st->acquire_fence) != VK_SUCCESS)
        return false;

    st->swapchain_dirty = true; // build the swapchain lazily on first frame
    return true;
}

// Populate st->swapchain.surfaces — one wrapped SkSurface per swapchain
// image. The images are borrowed (owned by the swapchain): the surfaces are
// recreated whenever the swapchain is.
static bool vulkan_populate_surfaces(GpuState* st, VkImageUsageFlags usage,
                                     VkSharingMode sharing) {
    uint32_t count = 0;
    if (st->vk.getSwapchainImagesKHR(st->vk_device, st->swapchain.handle, &count, nullptr) !=
            VK_SUCCESS || count == 0)
        return false;
    std::vector<VkImage> images(count);
    if (st->vk.getSwapchainImagesKHR(st->vk_device, st->swapchain.handle, &count,
                                     images.data()) != VK_SUCCESS)
        return false;

    st->swapchain.surfaces.clear();
    st->swapchain.surfaces.reserve(count);
    const SkISize dims = {(int)st->swapchain.extent.width, (int)st->swapchain.extent.height};
    for (VkImage image : images) {
        skgpu::graphite::VulkanTextureInfo info;
        info.fFormat = st->swapchain.format;
        info.fImageUsageFlags = usage;
        info.fSharingMode = sharing;
        auto backend_tex = skgpu::graphite::BackendTextures::MakeVulkan(
            dims, info, VK_IMAGE_LAYOUT_UNDEFINED, st->vk_present_family, image,
            skgpu::VulkanAlloc());
        sk_sp<SkSurface> surface = SkSurfaces::WrapBackendTexture(
            st->grecorder.get(), backend_tex, SkColorSpace::MakeSRGB(), nullptr);
        if (!surface) {
            st->swapchain.surfaces.clear();
            return false;
        }
        st->swapchain.surfaces.push_back(std::move(surface));
    }
    return true;
}

// Recreate the swapchain (first frame, resize, OUT_OF_DATE). Waits for the
// device before dropping the old images' wrapped surfaces.
static bool vulkan_recreate_swapchain(GpuState* st) {
    PFN_vkGetPhysicalDeviceSurfaceCapabilitiesKHR getCaps =
        (PFN_vkGetPhysicalDeviceSurfaceCapabilitiesKHR)vk_iproc(
            st->vk, st->vk_instance, "vkGetPhysicalDeviceSurfaceCapabilitiesKHR");
    PFN_vkGetPhysicalDeviceSurfaceFormatsKHR getFormats =
        (PFN_vkGetPhysicalDeviceSurfaceFormatsKHR)vk_iproc(
            st->vk, st->vk_instance, "vkGetPhysicalDeviceSurfaceFormatsKHR");
    PFN_vkGetPhysicalDeviceSurfacePresentModesKHR getModes =
        (PFN_vkGetPhysicalDeviceSurfacePresentModesKHR)vk_iproc(
            st->vk, st->vk_instance, "vkGetPhysicalDeviceSurfacePresentModesKHR");
    if (!getCaps || !getFormats || !getModes) return false;

    VkSurfaceCapabilitiesKHR caps;
    if (getCaps(st->vk_phys, st->vk_surface, &caps) != VK_SUCCESS) return false;

    uint32_t format_count = 0;
    if (getFormats(st->vk_phys, st->vk_surface, &format_count, nullptr) != VK_SUCCESS ||
        format_count == 0)
        return false;
    std::vector<VkSurfaceFormatKHR> formats(format_count);
    if (getFormats(st->vk_phys, st->vk_surface, &format_count, formats.data()) != VK_SUCCESS)
        return false;
    const VkSurfaceFormatKHR surface_format = pick_surface_format(formats);

    uint32_t mode_count = 0;
    VkPresentModeKHR present_mode = VK_PRESENT_MODE_FIFO_KHR;
    if (getModes(st->vk_phys, st->vk_surface, &mode_count, nullptr) == VK_SUCCESS &&
        mode_count) {
        std::vector<VkPresentModeKHR> modes(mode_count);
        getModes(st->vk_phys, st->vk_surface, &mode_count, modes.data());
        for (VkPresentModeKHR m : modes) {
            if (m == VK_PRESENT_MODE_MAILBOX_KHR) present_mode = m;
        }
    }

    VkExtent2D extent = caps.currentExtent;
    if (extent.width == 0xFFFFFFFFu) {
        extent.width = (uint32_t)std::max(st->width, 1);
        extent.height = (uint32_t)std::max(st->height, 1);
    }
    extent.width = std::clamp(extent.width, caps.minImageExtent.width, caps.maxImageExtent.width);
    extent.height =
        std::clamp(extent.height, caps.minImageExtent.height, caps.maxImageExtent.height);
    if (extent.width == 0 || extent.height == 0) return false; // minimized

    uint32_t image_count = caps.minImageCount + 2;
    if (caps.maxImageCount > 0 && image_count > caps.maxImageCount)
        image_count = caps.maxImageCount;

    VkImageUsageFlags usage =
        VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT |
        VK_IMAGE_USAGE_TRANSFER_DST_BIT;
    if (caps.supportedUsageFlags & VK_IMAGE_USAGE_INPUT_ATTACHMENT_BIT)
        usage |= VK_IMAGE_USAGE_INPUT_ATTACHMENT_BIT;
    if (caps.supportedUsageFlags & VK_IMAGE_USAGE_SAMPLED_BIT)
        usage |= VK_IMAGE_USAGE_SAMPLED_BIT;

    VkCompositeAlphaFlagBitsKHR composite =
        (caps.supportedCompositeAlpha & VK_COMPOSITE_ALPHA_INHERIT_BIT_KHR)
            ? VK_COMPOSITE_ALPHA_INHERIT_BIT_KHR
            : VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR;

    VkSwapchainCreateInfoKHR ci{};
    ci.sType = VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR;
    ci.surface = st->vk_surface;
    ci.minImageCount = image_count;
    ci.imageFormat = surface_format.format;
    ci.imageColorSpace = surface_format.colorSpace;
    ci.imageExtent = extent;
    ci.imageArrayLayers = 1;
    ci.imageUsage = usage;
    const uint32_t families[2] = {st->vk_gfx_family, st->vk_present_family};
    if (st->vk_gfx_family != st->vk_present_family) {
        ci.imageSharingMode = VK_SHARING_MODE_CONCURRENT;
        ci.queueFamilyIndexCount = 2;
        ci.pQueueFamilyIndices = families;
    } else {
        ci.imageSharingMode = VK_SHARING_MODE_EXCLUSIVE;
    }
    ci.preTransform = caps.currentTransform;
    ci.compositeAlpha = composite;
    ci.presentMode = present_mode;
    ci.clipped = VK_TRUE;
    ci.oldSwapchain = st->swapchain.handle;

    VkSwapchainKHR swapchain = VK_NULL_HANDLE;
    if (st->vk.createSwapchainKHR(st->vk_device, &ci, nullptr, &swapchain) != VK_SUCCESS)
        return false;

    // Old swapchain images go idle only once the GPU drains — wait, then
    // drop the wrapped surfaces + old swapchain together.
    st->vk.deviceWaitIdle(st->vk_device);
    vulkan_destroy_swapchain(st);
    st->swapchain.handle = swapchain;
    st->swapchain.format = surface_format.format;
    st->swapchain.extent = extent;
    st->swapchain_dirty = false;
    return vulkan_populate_surfaces(st, usage, ci.imageSharingMode);
}

static SkCanvas* vulkan_begin_frame(GpuState* st) {
    if (!st->gcontext || !st->grecorder) return nullptr;
    if (st->swapchain_dirty && !vulkan_recreate_swapchain(st)) return nullptr;
    if (st->swapchain.surfaces.empty()) return nullptr;

    uint32_t index = 0;
    VkResult res = st->vk.acquireNextImageKHR(st->vk_device, st->swapchain.handle,
                                              UINT64_MAX, VK_NULL_HANDLE, st->acquire_fence,
                                              &index);
    if (res == VK_ERROR_OUT_OF_DATE_KHR) {
        // Surface resized under us — rebuild once and retry.
        st->swapchain_dirty = true;
        if (!vulkan_recreate_swapchain(st)) return nullptr;
        res = st->vk.acquireNextImageKHR(st->vk_device, st->swapchain.handle, UINT64_MAX,
                                         VK_NULL_HANDLE, st->acquire_fence, &index);
    }
    if (res == VK_SUBOPTIMAL_KHR) st->swapchain_dirty = true; // renderable; recreate later
    if (res != VK_SUCCESS && res != VK_SUBOPTIMAL_KHR) return nullptr;
    if (index >= st->swapchain.surfaces.size()) return nullptr;

    // Acquisition is complete on the CPU once the fence signals (with an
    // infinite timeout the call already blocked until then) — wait, then
    // reset for the next frame.
    st->vk.waitForFences(st->vk_device, 1, &st->acquire_fence, VK_TRUE, UINT64_MAX);
    st->vk.resetFences(st->vk_device, 1, &st->acquire_fence);

    st->acquired_index = index;
    st->frame_acquired = true;
    st->frame_surface = st->swapchain.surfaces[index];
    return st->frame_surface->getCanvas();
}

static void vulkan_end_frame(GpuState* st) {
    if (!st->frame_acquired || !st->gcontext || !st->grecorder) return;
    st->frame_acquired = false;

    std::unique_ptr<skgpu::graphite::Recording> recording = st->grecorder->snap();
    if (!recording && st->frame_surface) {
        // An empty frame still must transition the image to PRESENT_SRC
        // before presenting — record a transparent clear so snap() yields a
        // recording (real frames always paint; this only covers a begin/end
        // pair with zero draws in between).
        st->frame_surface->getCanvas()->clear(SK_ColorTRANSPARENT);
        recording = st->grecorder->snap();
    }
    if (recording) {
        skgpu::MutableTextureState present_state = skgpu::MutableTextureStates::MakeVulkan(
            VK_IMAGE_LAYOUT_PRESENT_SRC_KHR, st->vk_present_family);
        skgpu::graphite::InsertRecordingInfo info{};
        info.fRecording = recording.get();
        info.fTargetSurface = st->frame_surface.get();
        info.fTargetTextureState = &present_state;
        st->gcontext->insertRecording(info);
        // Synchronous submit (same as the Windows Dawn path): the wrapped
        // swapchain image must be fully rendered before QueuePresent — with
        // SyncToCpu::kYes there are no semaphores to manage.
        st->gcontext->submit(skgpu::graphite::SyncToCpu::kYes);

        VkPresentInfoKHR present{};
        present.sType = VK_STRUCTURE_TYPE_PRESENT_INFO_KHR;
        present.swapchainCount = 1;
        present.pSwapchains = &st->swapchain.handle;
        present.pImageIndices = &st->acquired_index;
        VkResult res = st->vk.queuePresentKHR(st->vk_present_queue, &present);
        if (res == VK_ERROR_OUT_OF_DATE_KHR || res == VK_SUBOPTIMAL_KHR)
            st->swapchain_dirty = true;
    }
    // No recording: nothing was drawn — leave the acquired image to cycle
    // back through the swapchain (no present: the image never left
    // LAYOUT_UNDEFINED).
    st->frame_surface = nullptr;
}

static SkCanvas* vulkan_begin_offscreen(GpuState* st, int width, int height) {
    if (!st || !st->grecorder || width <= 0 || height <= 0) return nullptr;
    st->warmup_surface = SkSurfaces::RenderTarget(
        st->grecorder.get(),
        SkImageInfo::Make(width, height, kRGBA_8888_SkColorType, kPremul_SkAlphaType, nullptr));
    return st->warmup_surface ? st->warmup_surface->getCanvas() : nullptr;
}

static bool vulkan_end_offscreen(GpuState* st) {
    if (!st || !st->gcontext || !st->grecorder) return false;
    std::unique_ptr<skgpu::graphite::Recording> recording = st->grecorder->snap();
    if (recording) {
        skgpu::graphite::InsertRecordingInfo info{};
        info.fRecording = recording.get();
        st->gcontext->insertRecording(info);
    }
    st->gcontext->submit(skgpu::graphite::SyncToCpu::kYes);
    st->warmup_surface = nullptr;
    return true;
}

// ---- platform interface -----------------------------------------------------

void gpu_shutdown(GpuState* state) {
    if (!state) return;
    if (state->gcontext || state->vk_instance != VK_NULL_HANDLE || state->vk_lib_loaded) {
        vulkan_teardown(state);
    }
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
    state->width = width;
    state->height = height;
    // Vulkan: rebuild the swapchain lazily on the next begin_frame (coalesces
    // resize storms; the driver reports the new extent via surface caps).
    state->swapchain_dirty = true;
}

SkCanvas* gpu_begin_frame(GpuState* state) {
    if (!state || state->width <= 0 || state->height <= 0) return nullptr;

    if (state->gcontext) return vulkan_begin_frame(state);
    if (!state->dctx) return nullptr;

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
    if (!state) return;
    if (state->gcontext) { vulkan_end_frame(state); return; }
    if (!state->dctx) return;
    state->dctx->flushAndSubmit();
    state->frame_surface = nullptr;
    if (state->window) SDL_GL_SwapWindow(state->window);
}

SkCanvas* gpu_begin_offscreen(GpuState* state, int width, int height) {
    if (state && state->gcontext) return vulkan_begin_offscreen(state, width, height);
    // Warmup (Phase 4e.1): a render-target surface on the Ganesh context —
    // same draw ops, same programs as the onscreen frames.
    if (!state || !state->dctx || width <= 0 || height <= 0) return nullptr;
    state->warmup_surface = SkSurfaces::RenderTarget(
        state->dctx.get(), skgpu::Budgeted::kYes,
        SkImageInfo::Make(width, height, kRGBA_8888_SkColorType, kPremul_SkAlphaType, nullptr));
    return state->warmup_surface ? state->warmup_surface->getCanvas() : nullptr;
}

bool gpu_end_offscreen(GpuState* state) {
    if (state && state->gcontext) return vulkan_end_offscreen(state);
    if (!state || !state->dctx) return false;
    state->dctx->flushAndSubmit(GrSyncCpu::kYes);
    state->warmup_surface = nullptr;
    return true;
}

sk_sp<SkSurface> gpu_offscreen_surface(GpuState* state, int width, int height) {
    if (!state) return nullptr;
    const SkImageInfo info =
        SkImageInfo::Make(width, height, kRGBA_8888_SkColorType, kPremul_SkAlphaType, nullptr);
    if (state->gcontext && state->grecorder)
        return SkSurfaces::RenderTarget(state->grecorder.get(), info); // graphite-vulkan
    if (state->dctx)
        return SkSurfaces::RenderTarget(state->dctx.get(), skgpu::Budgeted::kYes, info); // ganesh-gl
    return nullptr;
}

sk_sp<SkImage> gpu_image_upload(GpuState* state, sk_sp<SkImage> img) {
    if (!state || !img || img->isTextureBacked()) return img;
    if (state->gcontext && state->grecorder) {
        if (sk_sp<SkImage> up = SkImages::TextureFromImage(state->grecorder.get(), img.get(), {}))
            return up; // graphite-vulkan
    } else if (state->dctx) {
        if (sk_sp<SkImage> up = SkImages::TextureFromImage(state->dctx.get(), img.get()))
            return up; // ganesh-gl
    }
    return img;
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
