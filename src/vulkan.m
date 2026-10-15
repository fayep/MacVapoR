// Vulkan swapchains, through MoltenVK. Images are created on the app's own VkDevice and MoltenVK
// hands back the MTLTexture behind each one, so the Metal compositor samples them unchanged; it
// runs on the MTLCommandQueue behind the app's VkQueue, which orders it after the app's work.
//
// Vulkan is called through whichever library owns the app's handles: the Vulkan loader for a
// native app, or MoltenVK directly under CrossOver's Wine, which loads it without a loader.

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <dlfcn.h>
#include <limits.h>
#include <string.h>

#include "vk.h"

static PFN_vkGetInstanceProcAddr g_gipa;
static VkInstance g_instance;

// Talking to MoltenVK with no loader in between, as under CrossOver. Wine only lets a Windows
// app enable extensions it knows how to wrap, so VK_EXT_metal_objects is out of reach there;
// MoltenVK's own exports give the same objects for any image or queue.
static bool g_mvk_direct, g_in_wine;
static VkResult (*p_vkGetMTLTextureMVK)(VkImage, id<MTLTexture> __autoreleasing *);
static VkResult (*p_vkGetMTLCommandQueueMVK)(VkQueue, id<MTLCommandQueue> __autoreleasing *);

static void detect_direct(void) {
    Dl_info info;
    if (!dladdr((void *)g_gipa, &info) || !info.dli_fname || !strstr(info.dli_fname, "MoltenVK")) return;
    void *h = dlopen(info.dli_fname, RTLD_LAZY | RTLD_NOLOAD);
    p_vkGetMTLTextureMVK = h ? dlsym(h, "vkGetMTLTextureMVK") : NULL;
    p_vkGetMTLCommandQueueMVK = h ? dlsym(h, "vkGetMTLCommandQueueMVK") : NULL;
    g_mvk_direct = p_vkGetMTLTextureMVK && p_vkGetMTLCommandQueueMVK;
    if (g_mvk_direct) axr_log("vulkan: MoltenVK without a loader, using its own Metal exports");
}

#define INSTANCE_FN(name) static PFN_##name name##_
INSTANCE_FN(vkCreateInstance);
INSTANCE_FN(vkEnumerateInstanceExtensionProperties);
INSTANCE_FN(vkEnumeratePhysicalDevices);
INSTANCE_FN(vkGetPhysicalDeviceMemoryProperties);
INSTANCE_FN(vkEnumerateDeviceExtensionProperties);
INSTANCE_FN(vkCreateDevice);
INSTANCE_FN(vkGetDeviceProcAddr);

static struct {
    VkDevice device;
    PFN_vkCreateImage create_image;
    PFN_vkDestroyImage destroy_image;
    PFN_vkGetImageMemoryRequirements memory_requirements;
    PFN_vkAllocateMemory allocate;
    PFN_vkFreeMemory free_memory;
    PFN_vkBindImageMemory bind;
    PFN_vkGetDeviceQueue get_queue;
    PFN_vkExportMetalObjectsEXT export_objects;
} g_dev;

bool axr_vk_load(PFN_vkGetInstanceProcAddr gipa) {
    if (gipa) { g_gipa = gipa; detect_direct(); return true; }
    if (g_gipa) return true;
    // A library the process already has, loader first: a native app's handles are the loader's.
    NSString *env = NSProcessInfo.processInfo.environment[@"ALVRXR_VULKAN_LIBRARY"];
    // Inside Wine the app's Vulkan is winevulkan on top of MoltenVK, which Wine loads by name
    // with no loader; it may not be loaded yet, and the same name finds the same library.
    void *wine_dbg = dlsym(RTLD_DEFAULT, "__wine_dbg_output");
    g_in_wine = wine_dbg != NULL;
    // CrossOver keeps it beside the wine directory: lib/wine/<arch>-unix/ntdll.so, lib/<arch>/.
    char beside_wine[PATH_MAX] = "";
    Dl_info ntdll;
    if (g_in_wine && dladdr(wine_dbg, &ntdll) && ntdll.dli_fname) {
        NSString *lib = @(ntdll.dli_fname).stringByDeletingLastPathComponent.stringByDeletingLastPathComponent
                            .stringByDeletingLastPathComponent;
        NSString *arch = [@(ntdll.dli_fname).stringByDeletingLastPathComponent.lastPathComponent
            hasPrefix:@"aarch64"] ? @"aarch64" : @"x86_64";
        snprintf(beside_wine, sizeof beside_wine, "%s/%s/libMoltenVK.dylib", lib.UTF8String, arch.UTF8String);
    }
    const char *native[] = {env.UTF8String, "libvulkan.1.dylib", "/opt/homebrew/lib/libvulkan.1.dylib",
                            "libMoltenVK.dylib", NULL};
    const char *wine[] = {env.UTF8String, "libMoltenVK.dylib", beside_wine[0] ? beside_wine : NULL, NULL, NULL};
    const char **candidates = g_in_wine ? wine : native;
    for (int pass = 0; pass < 2 && !g_gipa; pass++) {
        for (int i = 0; i < 4 && !g_gipa; i++) {
            if (!candidates[i]) continue;
            void *h = dlopen(candidates[i], RTLD_LAZY | (pass == 0 ? RTLD_NOLOAD : 0));
            if (h) {
                g_gipa = (PFN_vkGetInstanceProcAddr)dlsym(h, "vkGetInstanceProcAddr");
                if (g_gipa) axr_log("vulkan: using %s", candidates[i]);
            }
        }
    }
    if (!g_gipa) axr_log("vulkan: no Vulkan library found");
    else detect_direct();
    return g_gipa != NULL;
}

static void load_instance(VkInstance inst) {
    g_instance = inst;
#define LOAD(name) name##_ = (PFN_##name)g_gipa(inst, #name)
    LOAD(vkEnumeratePhysicalDevices);
    LOAD(vkGetPhysicalDeviceMemoryProperties);
    LOAD(vkEnumerateDeviceExtensionProperties);
    LOAD(vkCreateDevice);
    LOAD(vkGetDeviceProcAddr);
}

static void load_device(VkDevice dev) {
    if (g_dev.device == dev) return;
    g_dev.device = dev;
#define DLOAD(field, name) g_dev.field = (PFN_##name)vkGetDeviceProcAddr_(dev, #name)
    DLOAD(create_image, vkCreateImage);
    DLOAD(destroy_image, vkDestroyImage);
    DLOAD(memory_requirements, vkGetImageMemoryRequirements);
    DLOAD(allocate, vkAllocateMemory);
    DLOAD(free_memory, vkFreeMemory);
    DLOAD(bind, vkBindImageMemory);
    DLOAD(get_queue, vkGetDeviceQueue);
    DLOAD(export_objects, vkExportMetalObjectsEXT);
    if (!g_dev.export_objects && !g_mvk_direct) axr_log("vulkan: the device lacks VK_EXT_metal_objects; frames cannot be shown");
}

// XR_KHR_vulkan_enable's extension lists. Portability is for MoltenVK behind a loader.
const char *axr_vk_instance_extensions(void) {
    axr_vk_load(NULL);
    // Never empty: wineopenxr and DXVK both split "" into one empty extension name.
    return g_mvk_direct || g_in_wine ? "VK_KHR_get_physical_device_properties2" : "VK_KHR_portability_enumeration";
}
const char *axr_vk_device_extensions(void) {
    axr_vk_load(NULL);
    return g_mvk_direct || g_in_wine ? "VK_KHR_maintenance1" : "VK_EXT_metal_objects VK_KHR_portability_subset";
}

VkResult axr_vk_physical_device(VkInstance inst, VkPhysicalDevice *out) {
    if (!axr_vk_load(NULL)) return VK_ERROR_INITIALIZATION_FAILED;
    load_instance(inst);
    uint32_t n = 1;
    VkResult r = vkEnumeratePhysicalDevices_(inst, &n, out);
    if (r < 0 || n == 0) {
        axr_log("vulkan: no physical device (%d); a loader hides MoltenVK unless the instance enables portability enumeration", r);
        return r < 0 ? r : VK_ERROR_INITIALIZATION_FAILED;
    }
    return VK_SUCCESS;
}

static bool has_name(const char *const *list, uint32_t n, const char *name) {
    for (uint32_t i = 0; i < n; i++)
        if (!strcmp(list[i], name)) return true;
    return false;
}

VkResult axr_vk_create_instance(PFN_vkGetInstanceProcAddr gipa, const VkInstanceCreateInfo *ci,
                                const VkAllocationCallbacks *alloc, VkInstance *out) {
    axr_vk_load(gipa);
    vkCreateInstance_ = (PFN_vkCreateInstance)g_gipa(NULL, "vkCreateInstance");
    vkEnumerateInstanceExtensionProperties_ =
        (PFN_vkEnumerateInstanceExtensionProperties)g_gipa(NULL, "vkEnumerateInstanceExtensionProperties");
    VkInstanceCreateInfo info = *ci;
    const char *names[64];
    uint32_t n = ci->enabledExtensionCount < 60 ? ci->enabledExtensionCount : 60;
    memcpy(names, ci->ppEnabledExtensionNames, n * sizeof *names);
    // Behind a loader MoltenVK only shows up when the instance asks for portability drivers.
    uint32_t avail = 0;
    vkEnumerateInstanceExtensionProperties_(NULL, &avail, NULL);
    VkExtensionProperties props[avail ?: 1];
    vkEnumerateInstanceExtensionProperties_(NULL, &avail, props);
    for (uint32_t i = 0; i < avail; i++) {
        if (!strcmp(props[i].extensionName, "VK_KHR_portability_enumeration") &&
            !has_name(names, n, "VK_KHR_portability_enumeration")) {
            names[n++] = "VK_KHR_portability_enumeration";
            info.flags |= VK_INSTANCE_CREATE_ENUMERATE_PORTABILITY_BIT_KHR;
        }
    }
    info.enabledExtensionCount = n;
    info.ppEnabledExtensionNames = names;
    VkResult r = vkCreateInstance_(&info, alloc, out);
    if (r == VK_SUCCESS) load_instance(*out);
    return r;
}

VkResult axr_vk_create_device(VkPhysicalDevice phys, const VkDeviceCreateInfo *ci, const VkAllocationCallbacks *alloc,
                              VkDevice *out) {
    VkDeviceCreateInfo info = *ci;
    const char *names[64];
    uint32_t n = ci->enabledExtensionCount < 60 ? ci->enabledExtensionCount : 60;
    memcpy(names, ci->ppEnabledExtensionNames, n * sizeof *names);
    uint32_t avail = 0;
    vkEnumerateDeviceExtensionProperties_(phys, NULL, &avail, NULL);
    VkExtensionProperties props[avail ?: 1];
    vkEnumerateDeviceExtensionProperties_(phys, NULL, &avail, props);
    for (uint32_t i = 0; i < avail; i++) {
        const char *e = props[i].extensionName;
        if ((!strcmp(e, "VK_EXT_metal_objects") || !strcmp(e, "VK_KHR_portability_subset")) && !has_name(names, n, e))
            names[n++] = !strcmp(e, "VK_EXT_metal_objects") ? "VK_EXT_metal_objects" : "VK_KHR_portability_subset";
    }
    info.enabledExtensionCount = n;
    info.ppEnabledExtensionNames = names;
    return vkCreateDevice_(phys, &info, alloc, out);
}

// The MTLCommandQueue behind the app's queue, for composing in order with its rendering.
id<MTLCommandQueue> axr_vk_session_queue(VkInstance inst, VkDevice dev, uint32_t family, uint32_t index) {
    if (!axr_vk_load(NULL)) return nil;
    if (inst != g_instance) load_instance(inst);
    load_device(dev);
    VkQueue q = VK_NULL_HANDLE;
    g_dev.get_queue(dev, family, index, &q);
    if (g_mvk_direct) {
        id<MTLCommandQueue> mq = nil;
        p_vkGetMTLCommandQueueMVK(q, &mq);
        return mq;
    }
    if (!g_dev.export_objects) return nil;
    VkExportMetalDeviceInfoEXT di = {VK_STRUCTURE_TYPE_EXPORT_METAL_DEVICE_INFO_EXT};
    VkExportMetalCommandQueueInfoEXT qi = {VK_STRUCTURE_TYPE_EXPORT_METAL_COMMAND_QUEUE_INFO_EXT, &di, q};
    VkExportMetalObjectsInfoEXT objs = {VK_STRUCTURE_TYPE_EXPORT_METAL_OBJECTS_INFO_EXT, &qi};
    g_dev.export_objects(dev, &objs);
    if (di.mtlDevice != axr_metal_device())
        axr_log("vulkan: the app's GPU is not the compositor's; this will not work");
    return qi.mtlCommandQueue;
}

static bool is_depth(int64_t f) {
    return f == VK_FORMAT_D16_UNORM || f == VK_FORMAT_D32_SFLOAT || f == VK_FORMAT_D32_SFLOAT_S8_UINT ||
           f == VK_FORMAT_D24_UNORM_S8_UINT;
}

id<MTLTexture> axr_vk_create_image(VkDevice dev, const XrSwapchainCreateInfo *ci, VkImage *image, VkDeviceMemory *memory) {
    load_device(dev);
    if (!g_dev.export_objects && !g_mvk_direct) return nil;
    bool depth = is_depth(ci->format);
    VkImageUsageFlags usage = VK_IMAGE_USAGE_SAMPLED_BIT;   // the compositor samples every image
    if (ci->usageFlags & XR_SWAPCHAIN_USAGE_COLOR_ATTACHMENT_BIT) usage |= VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT;
    if (ci->usageFlags & XR_SWAPCHAIN_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT) usage |= VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT;
    if (ci->usageFlags & XR_SWAPCHAIN_USAGE_UNORDERED_ACCESS_BIT) usage |= VK_IMAGE_USAGE_STORAGE_BIT;
    if (ci->usageFlags & XR_SWAPCHAIN_USAGE_TRANSFER_SRC_BIT) usage |= VK_IMAGE_USAGE_TRANSFER_SRC_BIT;
    if (ci->usageFlags & XR_SWAPCHAIN_USAGE_TRANSFER_DST_BIT) usage |= VK_IMAGE_USAGE_TRANSFER_DST_BIT;
    if (ci->usageFlags & XR_SWAPCHAIN_USAGE_INPUT_ATTACHMENT_BIT_KHR) usage |= VK_IMAGE_USAGE_INPUT_ATTACHMENT_BIT;
    if (!(usage & (VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT)))
        usage |= depth ? VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT : VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT;
    VkExportMetalObjectCreateInfoEXT ex = {VK_STRUCTURE_TYPE_EXPORT_METAL_OBJECT_CREATE_INFO_EXT, NULL,
                                           VK_EXPORT_METAL_OBJECT_TYPE_METAL_TEXTURE_BIT_EXT};
    VkImageCreateInfo ii = {
        .sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
        .pNext = g_mvk_direct ? NULL : &ex,
        .flags = (ci->usageFlags & XR_SWAPCHAIN_USAGE_MUTABLE_FORMAT_BIT) ? VK_IMAGE_CREATE_MUTABLE_FORMAT_BIT : 0,
        .imageType = VK_IMAGE_TYPE_2D,
        .format = (VkFormat)ci->format,
        .extent = {ci->width, ci->height, 1},
        .mipLevels = ci->mipCount ?: 1,
        .arrayLayers = ci->arraySize ?: 1,
        .samples = VK_SAMPLE_COUNT_1_BIT,
        .tiling = VK_IMAGE_TILING_OPTIMAL,
        .usage = usage,
        .sharingMode = VK_SHARING_MODE_EXCLUSIVE,
        .initialLayout = VK_IMAGE_LAYOUT_UNDEFINED,
    };
    if (g_dev.create_image(dev, &ii, NULL, image) != VK_SUCCESS) return nil;
    VkMemoryRequirements req;
    g_dev.memory_requirements(dev, *image, &req);
    VkPhysicalDeviceMemoryProperties mp;
    VkPhysicalDevice phys;
    uint32_t one = 1;
    vkEnumeratePhysicalDevices_(g_instance, &one, &phys);
    vkGetPhysicalDeviceMemoryProperties_(phys, &mp);
    uint32_t type = UINT32_MAX;
    for (uint32_t i = 0; i < mp.memoryTypeCount && type == UINT32_MAX; i++)
        if ((req.memoryTypeBits & (1u << i)) && (mp.memoryTypes[i].propertyFlags & VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT))
            type = i;
    VkMemoryAllocateInfo ai = {VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, NULL, req.size, type};
    if (type == UINT32_MAX || g_dev.allocate(dev, &ai, NULL, memory) != VK_SUCCESS) {
        g_dev.destroy_image(dev, *image, NULL);
        return nil;
    }
    g_dev.bind(dev, *image, *memory, 0);
    if (g_mvk_direct) {
        id<MTLTexture> tex = nil;
        p_vkGetMTLTextureMVK(*image, &tex);
        return tex;
    }
    VkExportMetalTextureInfoEXT ti = {VK_STRUCTURE_TYPE_EXPORT_METAL_TEXTURE_INFO_EXT, NULL, *image, VK_NULL_HANDLE,
                                      VK_NULL_HANDLE, VK_IMAGE_ASPECT_PLANE_0_BIT};
    VkExportMetalObjectsInfoEXT objs = {VK_STRUCTURE_TYPE_EXPORT_METAL_OBJECTS_INFO_EXT, &ti};
    g_dev.export_objects(dev, &objs);
    return ti.mtlTexture;
}

void axr_vk_destroy_image(VkDevice dev, VkImage image, VkDeviceMemory memory) {
    if (g_dev.device != dev) return;
    g_dev.destroy_image(dev, image, NULL);
    g_dev.free_memory(dev, memory, NULL);
}
