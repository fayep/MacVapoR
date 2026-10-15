// Vulkan helpers for runtime.m (vulkan.m).
#pragma once
#define VK_NO_PROTOTYPES
#define VK_USE_PLATFORM_METAL_EXT
#include <vulkan/vulkan.h>

#define XR_USE_GRAPHICS_API_VULKAN
#include <openxr/openxr.h>
#include <openxr/openxr_platform.h>

#include "alvrxr.h"

bool axr_vk_load(PFN_vkGetInstanceProcAddr gipa);   // NULL: find the library the app uses
const char *axr_vk_instance_extensions(void);
const char *axr_vk_device_extensions(void);
VkResult axr_vk_physical_device(VkInstance inst, VkPhysicalDevice *out);
VkResult axr_vk_create_instance(PFN_vkGetInstanceProcAddr gipa, const VkInstanceCreateInfo *ci,
                                const VkAllocationCallbacks *alloc, VkInstance *out);
VkResult axr_vk_create_device(VkPhysicalDevice phys, const VkDeviceCreateInfo *ci, const VkAllocationCallbacks *alloc,
                              VkDevice *out);

#ifdef __OBJC__
id<MTLCommandQueue> axr_vk_session_queue(VkInstance inst, VkDevice dev, uint32_t family, uint32_t index);
id<MTLTexture> axr_vk_create_image(VkDevice dev, const XrSwapchainCreateInfo *ci, VkImage *image, VkDeviceMemory *memory);
#endif
void axr_vk_destroy_image(VkDevice dev, VkImage image, VkDeviceMemory memory);
