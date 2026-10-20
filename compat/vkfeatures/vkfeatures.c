/*
 * vkfeatures: a vulkan-1.dll for one game's folder that lets a Vulkan game start on MoltenVK when
 * it asks for device features Metal hasn't got, the ones it can do without.
 *
 * No Man's Sky refuses to start without wideLines (lines wider than a pixel; Metal draws only
 * one-pixel lines) and then asks vkCreateDevice for features MoltenVK lacks, which fails with
 * VK_ERROR_FEATURE_NOT_PRESENT. So:
 *  - vkGetPhysicalDeviceFeatures(2): wideLines is reported present;
 *  - vkCreateDevice: requested features the device hasn't got are dropped (and logged), in
 *    VkPhysicalDeviceFeatures, VkPhysicalDeviceFeatures2 and the Vulkan 1.1-1.4 feature structs;
 *  - pipelines' rasterization lineWidth and vkCmdSetLineWidth are clamped to 1;
 *  - a graphics pipeline that failed fails again at once when asked for again (see failed_seen);
 *  - vkGetPhysicalDeviceProperties(2): the sampler limits are raised to the sampled-image ones (see
 *    raise_limits), so No Man's Sky doesn't warn about them at every start.
 * Everything else goes straight to Wine's own vulkan-1.dll (system32), loaded by its path: the
 * pass-through exports are jumps generated from its export list (stubs.S, exports.txt).
 *
 * Logged to stderr, which NotProton keeps in the game's notproton-wine.log, as "vkfeatures: ...".
 */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdarg.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>
// No prototypes: these functions are this DLL's own, exported through the generated .def.
#define VK_NO_PROTOTYPES
#include <vulkan/vulkan.h>

#define EXPORT

static HMODULE real_module;
static PFN_vkGetInstanceProcAddr real_GetInstanceProcAddr;
static PFN_vkGetDeviceProcAddr real_GetDeviceProcAddr;
static PFN_vkGetPhysicalDeviceFeatures real_GetPhysicalDeviceFeatures;
static PFN_vkGetPhysicalDeviceFeatures2 real_GetPhysicalDeviceFeatures2;
static PFN_vkGetPhysicalDeviceProperties real_GetPhysicalDeviceProperties;
static PFN_vkGetPhysicalDeviceProperties2 real_GetPhysicalDeviceProperties2;
static PFN_vkCreateDevice real_CreateDevice;
static PFN_vkCreateInstance real_CreateInstance;
static PFN_vkEnumerateDeviceExtensionProperties real_EnumerateDeviceExtensionProperties;
// Device functions, from the real vkGetDeviceProcAddr (one device is all a game like this makes;
// the pointers are the loader's trampolines, the same for any device).
static PFN_vkCreateGraphicsPipelines real_CreateGraphicsPipelines;
static PFN_vkCmdSetLineWidth real_CmdSetLineWidth;
static PFN_vkCreateComputePipelines real_CreateComputePipelines;
static PFN_vkDestroyShaderModule real_DestroyShaderModule;

static int hidden(const char *name);

// The generated pass-through stubs jump through these (stubs.S).
extern void *vkf_real[];
extern const char *const vkf_names[];
extern const unsigned vkf_count;

static void say(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    fprintf(stderr, "vkfeatures: ");
    vfprintf(stderr, fmt, ap);
    fprintf(stderr, "\n");
    fflush(stderr);
    va_end(ap);
}

static const char *const feature_names[] = {
    "robustBufferAccess", "fullDrawIndexUint32", "imageCubeArray", "independentBlend", "geometryShader",
    "tessellationShader", "sampleRateShading", "dualSrcBlend", "logicOp", "multiDrawIndirect",
    "drawIndirectFirstInstance", "depthClamp", "depthBiasClamp", "fillModeNonSolid", "depthBounds", "wideLines",
    "largePoints", "alphaToOne", "multiViewport", "samplerAnisotropy", "textureCompressionETC2",
    "textureCompressionASTC_LDR", "textureCompressionBC", "occlusionQueryPrecise", "pipelineStatisticsQuery",
    "vertexPipelineStoresAndAtomics", "fragmentStoresAndAtomics", "shaderTessellationAndGeometryPointSize",
    "shaderImageGatherExtended", "shaderStorageImageExtendedFormats", "shaderStorageImageMultisample",
    "shaderStorageImageReadWithoutFormat", "shaderStorageImageWriteWithoutFormat",
    "shaderUniformBufferArrayDynamicIndexing", "shaderSampledImageArrayDynamicIndexing",
    "shaderStorageBufferArrayDynamicIndexing", "shaderStorageImageArrayDynamicIndexing", "shaderClipDistance",
    "shaderCullDistance", "shaderFloat64", "shaderInt64", "shaderInt16", "shaderResourceResidency",
    "shaderResourceMinLod", "sparseBinding", "sparseResidencyBuffer", "sparseResidencyImage2D",
    "sparseResidencyImage3D", "sparseResidency2Samples", "sparseResidency4Samples", "sparseResidency8Samples",
    "sparseResidency16Samples", "sparseResidencyAliased", "variableMultisampleRate", "inheritedQueries",
};

static BOOL load_real(void) {
    if (real_module) return TRUE;
    WCHAR path[MAX_PATH];
    UINT n = GetSystemDirectoryW(path, MAX_PATH);
    if (!n || n + 16 > MAX_PATH) return FALSE;
    wcscpy(path + n, L"\\vulkan-1.dll");
    real_module = LoadLibraryW(path);
    HMODULE self = NULL;
    GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                       (LPCWSTR)load_real, &self);
    if (!real_module || real_module == self) {
        say("couldn't load the system vulkan-1.dll (%s)", real_module ? "got this one back" : "not found");
        real_module = NULL;
        return FALSE;
    }
    for (unsigned i = 0; i < vkf_count; i++) vkf_real[i] = (void *)GetProcAddress(real_module, vkf_names[i]);
    real_GetInstanceProcAddr = (PFN_vkGetInstanceProcAddr)GetProcAddress(real_module, "vkGetInstanceProcAddr");
    real_GetDeviceProcAddr = (PFN_vkGetDeviceProcAddr)GetProcAddress(real_module, "vkGetDeviceProcAddr");
    real_GetPhysicalDeviceFeatures = (PFN_vkGetPhysicalDeviceFeatures)GetProcAddress(real_module, "vkGetPhysicalDeviceFeatures");
    real_GetPhysicalDeviceFeatures2 = (PFN_vkGetPhysicalDeviceFeatures2)GetProcAddress(real_module, "vkGetPhysicalDeviceFeatures2");
    real_GetPhysicalDeviceProperties =
        (PFN_vkGetPhysicalDeviceProperties)GetProcAddress(real_module, "vkGetPhysicalDeviceProperties");
    real_GetPhysicalDeviceProperties2 =
        (PFN_vkGetPhysicalDeviceProperties2)GetProcAddress(real_module, "vkGetPhysicalDeviceProperties2");
    real_CreateDevice = (PFN_vkCreateDevice)GetProcAddress(real_module, "vkCreateDevice");
    real_CreateInstance = (PFN_vkCreateInstance)GetProcAddress(real_module, "vkCreateInstance");
    real_EnumerateDeviceExtensionProperties =
        (PFN_vkEnumerateDeviceExtensionProperties)GetProcAddress(real_module, "vkEnumerateDeviceExtensionProperties");
    say("loaded: wideLines reported present, unsupported device features dropped, line widths clamped to 1");
    return TRUE;
}

BOOL WINAPI DllMain(HINSTANCE inst, DWORD reason, LPVOID reserved) {
    (void)inst; (void)reserved;
    if (reason == DLL_PROCESS_ATTACH) return load_real();
    return TRUE;
}

PFN_vkVoidFunction VKAPI_CALL vkGetInstanceProcAddr(VkInstance inst, const char *name);
PFN_vkVoidFunction VKAPI_CALL vkGetDeviceProcAddr(VkDevice dev, const char *name);

// ---------------------------------------------------------------------------- features

EXPORT VKAPI_ATTR void VKAPI_CALL vkGetPhysicalDeviceFeatures(VkPhysicalDevice pd, VkPhysicalDeviceFeatures *f) {
    real_GetPhysicalDeviceFeatures(pd, f);
    if (f) f->wideLines = VK_TRUE;
}

EXPORT VKAPI_ATTR void VKAPI_CALL vkGetPhysicalDeviceFeatures2(VkPhysicalDevice pd, VkPhysicalDeviceFeatures2 *f) {
    real_GetPhysicalDeviceFeatures2(pd, f);
    if (f) f->features.wideLines = VK_TRUE;
}

static VKAPI_ATTR void VKAPI_CALL GetPhysicalDeviceFeatures2KHR(VkPhysicalDevice pd, VkPhysicalDeviceFeatures2 *f) {
    vkGetPhysicalDeviceFeatures2(pd, f);
}

// ---------------------------------------------------------------------------- limits

// MoltenVK reports 16 samplers a stage (Metal's fixed sampler slots) even when descriptor sets go
// in Metal argument buffers, which hold many more; No Man's Sky then warns at every start that the
// driver hasn't enough, though its shaders with more than 16 compile and run (MoltenVK 1.4,
// argument buffers on). The sampler limits are raised to the sampled-image ones MoltenVK reports
// (256 a stage, 1280 a set on an M4 Max).
static void raise_limits(VkPhysicalDeviceLimits *l) {
    static int said;
    if (!said++)
        say("sampler limits raised: %u -> %u a stage, %u -> %u a set", l->maxPerStageDescriptorSamplers,
            l->maxPerStageDescriptorSampledImages, l->maxDescriptorSetSamplers, l->maxDescriptorSetSampledImages);
    if (l->maxPerStageDescriptorSamplers < l->maxPerStageDescriptorSampledImages)
        l->maxPerStageDescriptorSamplers = l->maxPerStageDescriptorSampledImages;
    if (l->maxDescriptorSetSamplers < l->maxDescriptorSetSampledImages)
        l->maxDescriptorSetSamplers = l->maxDescriptorSetSampledImages;
}

EXPORT VKAPI_ATTR void VKAPI_CALL vkGetPhysicalDeviceProperties(VkPhysicalDevice pd, VkPhysicalDeviceProperties *p) {
    real_GetPhysicalDeviceProperties(pd, p);
    if (p) raise_limits(&p->limits);
}

EXPORT VKAPI_ATTR void VKAPI_CALL vkGetPhysicalDeviceProperties2(VkPhysicalDevice pd, VkPhysicalDeviceProperties2 *p) {
    real_GetPhysicalDeviceProperties2(pd, p);
    if (p) raise_limits(&p->properties.limits);
}

static VKAPI_ATTR void VKAPI_CALL GetPhysicalDeviceProperties2KHR(VkPhysicalDevice pd, VkPhysicalDeviceProperties2 *p) {
    vkGetPhysicalDeviceProperties2(pd, p);
}

// The Vulkan 1.1-1.4 feature structs: sType, pNext, then nothing but VkBool32s.
typedef struct {
    VkStructureType type;
    size_t size;
    const char *name;
} bool_struct;

static const bool_struct bool_structs[] = {
    {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_1_FEATURES, sizeof(VkPhysicalDeviceVulkan11Features), "Vulkan11"},
    {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_FEATURES, sizeof(VkPhysicalDeviceVulkan12Features), "Vulkan12"},
    {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES, sizeof(VkPhysicalDeviceVulkan13Features), "Vulkan13"},
    {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_4_FEATURES, sizeof(VkPhysicalDeviceVulkan14Features), "Vulkan14"},
};

#define MAX_STRUCT_BYTES 512
#define MAX_SAVED 16

typedef struct {
    void *at;
    size_t size;
    unsigned char bytes[MAX_STRUCT_BYTES];
} saved;

// Clears in `want` (count VkBool32s) what `have` hasn't, after saving `want`; logs each one.
static void drop_missing(VkBool32 *want, const VkBool32 *have, unsigned count, const char *where,
                         const char *const *names) {
    for (unsigned i = 0; i < count; i++) {
        if (want[i] && !have[i]) {
            if (names) say("dropped %s.%s (not supported)", where, names[i]);
            else say("dropped %s field %u (not supported)", where, i);
            want[i] = VK_FALSE;
        }
    }
}

EXPORT VKAPI_ATTR VkResult VKAPI_CALL vkCreateDevice(VkPhysicalDevice pd, const VkDeviceCreateInfo *ci,
                                                    const VkAllocationCallbacks *alloc, VkDevice *dev) {
    // The application's structs are changed in place for the call and put back after: copying a
    // pNext chain needs every struct's size, and only these few are ever touched.
    static saved keep[MAX_SAVED];
    unsigned nkeep = 0;
    VkPhysicalDeviceFeatures have;
    real_GetPhysicalDeviceFeatures(pd, &have);
    const unsigned nfeatures = sizeof(VkPhysicalDeviceFeatures) / sizeof(VkBool32);

    if (ci && ci->pEnabledFeatures && nkeep < MAX_SAVED) {
        keep[nkeep].at = (void *)ci->pEnabledFeatures;
        keep[nkeep].size = sizeof(VkPhysicalDeviceFeatures);
        memcpy(keep[nkeep++].bytes, ci->pEnabledFeatures, sizeof(VkPhysicalDeviceFeatures));
        drop_missing((VkBool32 *)ci->pEnabledFeatures, (const VkBool32 *)&have, nfeatures, "pEnabledFeatures",
                     feature_names);
    }
    for (VkBaseOutStructure *s = ci ? (VkBaseOutStructure *)ci->pNext : NULL; s; s = s->pNext) {
        if (s->sType == VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2) {
            VkPhysicalDeviceFeatures2 *f2 = (VkPhysicalDeviceFeatures2 *)s;
            if (nkeep < MAX_SAVED) {
                keep[nkeep].at = &f2->features;
                keep[nkeep].size = sizeof(VkPhysicalDeviceFeatures);
                memcpy(keep[nkeep++].bytes, &f2->features, sizeof(VkPhysicalDeviceFeatures));
                drop_missing((VkBool32 *)&f2->features, (const VkBool32 *)&have, nfeatures, "features2", feature_names);
            }
            continue;
        }
        for (size_t b = 0; b < sizeof(bool_structs) / sizeof(bool_structs[0]); b++) {
            const bool_struct *bs = &bool_structs[b];
            if (s->sType != bs->type || bs->size > MAX_STRUCT_BYTES || nkeep >= MAX_SAVED) continue;
            unsigned char query[MAX_STRUCT_BYTES] = {0};
            ((VkBaseOutStructure *)query)->sType = bs->type;
            VkPhysicalDeviceFeatures2 f2 = {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2, query};
            real_GetPhysicalDeviceFeatures2(pd, &f2);
            size_t head = offsetof(VkPhysicalDeviceVulkan11Features, storageBuffer16BitAccess);
            keep[nkeep].at = s;
            keep[nkeep].size = bs->size;
            memcpy(keep[nkeep++].bytes, s, bs->size);
            drop_missing((VkBool32 *)((char *)s + head), (const VkBool32 *)(query + head),
                         (unsigned)((bs->size - head) / sizeof(VkBool32)), bs->name, NULL);
        }
    }
    for (uint32_t i = 0; ci && i < ci->enabledExtensionCount; i++)
        say("device extension %s%s", ci->ppEnabledExtensionNames[i],
            hidden(ci->ppEnabledExtensionNames[i]) ? " (enabled though hidden!)" : "");
    VkResult r = real_CreateDevice(pd, ci, alloc, dev);
    // Put the application's structs back as they were, pNext links included (they weren't touched).
    while (nkeep--) memcpy(keep[nkeep].at, keep[nkeep].bytes, keep[nkeep].size);
    if (r != VK_SUCCESS) say("vkCreateDevice still failed: %d", (int)r);
    return r;
}

// ---------------------------------------------------------------------------- driver messages

// MoltenVK reports why a shader didn't compile to debug messengers; one is attached to every
// instance (VK_EXT_debug_utils, added if the game didn't ask for it) and prints warnings and
// errors, the first 200 of each kind.
static VKAPI_ATTR VkBool32 VKAPI_CALL messenger(VkDebugUtilsMessageSeverityFlagBitsEXT severity,
                                                VkDebugUtilsMessageTypeFlagsEXT types,
                                                const VkDebugUtilsMessengerCallbackDataEXT *data, void *user) {
    (void)types; (void)user;
    static volatile LONG errors, warnings;
    int error = severity >= VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT;
    if (InterlockedIncrement(error ? &errors : &warnings) <= 200 && data && data->pMessage)
        say("driver %s: %s", error ? "error" : "warning", data->pMessage);
    return VK_FALSE;
}

EXPORT VKAPI_ATTR VkResult VKAPI_CALL vkCreateInstance(const VkInstanceCreateInfo *ci, const VkAllocationCallbacks *alloc,
                                                      VkInstance *inst) {
    if (!ci) return real_CreateInstance(ci, alloc, inst);
    VkInstanceCreateInfo mine = *ci;
    const char *names[128];
    uint32_t n = ci->enabledExtensionCount < 127 ? ci->enabledExtensionCount : 127;
    int has = 0;
    for (uint32_t i = 0; i < n; i++) {
        names[i] = ci->ppEnabledExtensionNames[i];
        has |= !strcmp(names[i], VK_EXT_DEBUG_UTILS_EXTENSION_NAME);
    }
    if (!has) names[n++] = VK_EXT_DEBUG_UTILS_EXTENSION_NAME;
    mine.enabledExtensionCount = n;
    mine.ppEnabledExtensionNames = names;
    VkDebugUtilsMessengerCreateInfoEXT dm = {VK_STRUCTURE_TYPE_DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT, ci->pNext, 0,
                                             VK_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT |
                                                 VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT,
                                             VK_DEBUG_UTILS_MESSAGE_TYPE_GENERAL_BIT_EXT |
                                                 VK_DEBUG_UTILS_MESSAGE_TYPE_VALIDATION_BIT_EXT |
                                                 VK_DEBUG_UTILS_MESSAGE_TYPE_PERFORMANCE_BIT_EXT,
                                             messenger, NULL};
    // MoltenVK's own settings (MoltenVK 1.3+): its log level, so it reports why a shader failed.
    static const int32_t log_level = 2;   // warnings and errors
    VkLayerSettingEXT settings[] = {
        {"MoltenVK", "MVK_CONFIG_LOG_LEVEL", VK_LAYER_SETTING_TYPE_INT32_EXT, 1, &log_level},
        {"MoltenVK", "LOG_LEVEL", VK_LAYER_SETTING_TYPE_INT32_EXT, 1, &log_level},
    };
    VkLayerSettingsCreateInfoEXT ls = {VK_STRUCTURE_TYPE_LAYER_SETTINGS_CREATE_INFO_EXT, ci->pNext,
                                       sizeof(settings) / sizeof(settings[0]), settings};
    dm.pNext = &ls;
    mine.pNext = &dm;
    VkResult r = real_CreateInstance(&mine, alloc, inst);
    if (r != VK_SUCCESS) {
        say("vkCreateInstance with the messenger failed (%d); without it", (int)r);
        return real_CreateInstance(ci, alloc, inst);
    }
    // And a messenger made the ordinary way, which Wine certainly forwards.
    PFN_vkCreateDebugUtilsMessengerEXT create =
        (PFN_vkCreateDebugUtilsMessengerEXT)real_GetInstanceProcAddr(*inst, "vkCreateDebugUtilsMessengerEXT");
    VkDebugUtilsMessengerEXT handle;
    dm.pNext = NULL;
    VkResult m = create ? create(*inst, &dm, NULL, &handle) : VK_ERROR_EXTENSION_NOT_PRESENT;
    say("driver messages attached to the instance (messenger: %d)", (int)m);
    return r;
}

// ---------------------------------------------------------------------------- extensions

// Hidden from the game: with push descriptors a set can't go in a Metal argument buffer, so
// MoltenVK binds its textures and samplers to Metal's fixed slots (16 samplers a stage), and No
// Man's Sky's terrain shaders then fail to compile. Without it, the game uses ordinary sets.
static const char *const hidden_extensions[] = {VK_KHR_PUSH_DESCRIPTOR_EXTENSION_NAME};

static int hidden(const char *name) {
    for (size_t i = 0; i < sizeof(hidden_extensions) / sizeof(hidden_extensions[0]); i++)
        if (!strcmp(name, hidden_extensions[i])) return 1;
    return 0;
}

EXPORT VKAPI_ATTR VkResult VKAPI_CALL vkEnumerateDeviceExtensionProperties(VkPhysicalDevice pd, const char *layer,
                                                                          uint32_t *count, VkExtensionProperties *props) {
    if (layer || !count) return real_EnumerateDeviceExtensionProperties(pd, layer, count, props);
    uint32_t n = 0;
    VkResult r = real_EnumerateDeviceExtensionProperties(pd, NULL, &n, NULL);
    if (r != VK_SUCCESS) return r;
    VkExtensionProperties *all = (VkExtensionProperties *)calloc(n ? n : 1, sizeof(*all));
    if (!all) return VK_ERROR_OUT_OF_HOST_MEMORY;
    r = real_EnumerateDeviceExtensionProperties(pd, NULL, &n, all);
    uint32_t kept = 0;
    for (uint32_t i = 0; i < n; i++)
        if (!hidden(all[i].extensionName)) all[kept++] = all[i];
    if (!props) {
        *count = kept;
    } else {
        uint32_t m = *count < kept ? *count : kept;
        memcpy(props, all, m * sizeof(*all));
        *count = m;
        if (m < kept) r = VK_INCOMPLETE;
    }
    free(all);
    return r;
}

// ---------------------------------------------------------------------------- failed pipelines

// No Man's Sky asks again, every frame, for a pipeline MoltenVK couldn't make (its terrain
// tessellation pipelines: SPIRV-Cross's address-space bug, see docs/steam-games.md), and each try
// translates the shaders again: ~90,000 failures a session, two threads kept busy, the frame rate
// down. A failed pipeline is remembered by a hash of what decides whether it compiles (its shaders,
// their entry points and specialization, the vertex input, topology, tessellation, layout and
// render pass) and fails again without the work. Shaders count by a hash of their SPIR-V, kept per
// module handle from vkCreateShaderModule, so a handle reused for other code is another shader.

#define FAILED_SLOTS 32768
static uint64_t failed[FAILED_SLOTS];   // 0: empty
static unsigned failed_count, failed_repeats;
static SRWLOCK failed_lock = SRWLOCK_INIT;

static uint64_t fnv(uint64_t h, const void *p, size_t n) {
    const unsigned char *b = (const unsigned char *)p;
    for (size_t i = 0; i < n; i++) h = (h ^ b[i]) * 0x100000001b3ULL;
    return h;
}

// Shader module handle -> hash of its code (open addressing; a destroyed one is a tombstone).
#define MODULE_SLOTS 65536
#define TOMBSTONE ((uint64_t)-1)
static struct { uint64_t module, code; } modules[MODULE_SLOTS];
static unsigned modules_used;
static SRWLOCK modules_lock = SRWLOCK_INIT;
static PFN_vkCreateShaderModule real_CreateShaderModule;

// Opt-in: with a vkfeatures-dump folder next to this DLL, each shader module's SPIR-V is saved there
// as <code hash>.spv, and failed pipelines name their stages' hashes, to reproduce them offline.
static WCHAR dump_dir[MAX_PATH];
static int dump_state;   // 0 unknown, 1 on, -1 off

static int dumping(void) {
    if (dump_state) return dump_state > 0;
    HMODULE self = NULL;
    GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                       (LPCWSTR)dumping, &self);
    DWORD n = GetModuleFileNameW(self, dump_dir, MAX_PATH);
    WCHAR *slash = n ? wcsrchr(dump_dir, L'\\') : NULL;
    dump_state = -1;
    if (slash && (size_t)(slash - dump_dir) + 40 < MAX_PATH) {
        wcscpy(slash + 1, L"vkfeatures-dump");
        DWORD a = GetFileAttributesW(dump_dir);
        if (a != INVALID_FILE_ATTRIBUTES && (a & FILE_ATTRIBUTE_DIRECTORY)) {
            dump_state = 1;
            say("dumping shader modules to vkfeatures-dump");
        }
    }
    return dump_state > 0;
}

static void dump_module(uint64_t code, const void *bytes, size_t size) {
    if (!dumping()) return;
    WCHAR path[MAX_PATH];
    if (_snwprintf(path, MAX_PATH, L"%ls\\%016llx.spv", dump_dir, (unsigned long long)code) < 0) return;
    HANDLE f = CreateFileW(path, GENERIC_WRITE, 0, NULL, CREATE_NEW, FILE_ATTRIBUTE_NORMAL, NULL);
    if (f == INVALID_HANDLE_VALUE) return;   // already there
    DWORD wrote;
    WriteFile(f, bytes, (DWORD)size, &wrote, NULL);
    CloseHandle(f);
}

static uint64_t module_code(VkShaderModule m) {
    uint64_t key = (uint64_t)m, code = 0;
    AcquireSRWLockShared(&modules_lock);
    for (unsigned i = (key >> 4) % MODULE_SLOTS, n = 0; n < MODULE_SLOTS && modules[i].module; i = (i + 1) % MODULE_SLOTS, n++)
        if (modules[i].module == key) { code = modules[i].code; break; }
    ReleaseSRWLockShared(&modules_lock);
    return code;
}

static VKAPI_ATTR VkResult VKAPI_CALL CreateShaderModule(VkDevice dev, const VkShaderModuleCreateInfo *ci,
                                                         const VkAllocationCallbacks *alloc, VkShaderModule *out) {
    VkResult r = real_CreateShaderModule(dev, ci, alloc, out);
    if (r != VK_SUCCESS || !ci->pCode) return r;
    uint64_t key = (uint64_t)*out, code = fnv(0xcbf29ce484222325ULL, ci->pCode, ci->codeSize) | 1;
    dump_module(code, ci->pCode, ci->codeSize);
    AcquireSRWLockExclusive(&modules_lock);
    if (modules_used < MODULE_SLOTS * 3 / 4) {
        unsigned i = (key >> 4) % MODULE_SLOTS;
        while (modules[i].module && modules[i].module != TOMBSTONE && modules[i].module != key) i = (i + 1) % MODULE_SLOTS;
        if (modules[i].module != key && modules[i].module != TOMBSTONE) modules_used++;
        modules[i].module = key;
        modules[i].code = code;
    }
    ReleaseSRWLockExclusive(&modules_lock);
    return r;
}

EXPORT VKAPI_ATTR VkResult VKAPI_CALL vkCreateShaderModule(VkDevice dev, const VkShaderModuleCreateInfo *ci,
                                                          const VkAllocationCallbacks *alloc, VkShaderModule *out) {
    if (!real_CreateShaderModule)
        real_CreateShaderModule = (PFN_vkCreateShaderModule)GetProcAddress(real_module, "vkCreateShaderModule");
    return CreateShaderModule(dev, ci, alloc, out);
}

// 0 when the pipeline can't be keyed (shaders not from modules, several in one call).
static uint64_t pipeline_key(const VkGraphicsPipelineCreateInfo *ci) {
    uint64_t h = 0xcbf29ce484222325ULL;
    for (uint32_t i = 0; i < ci->stageCount; i++) {
        const VkPipelineShaderStageCreateInfo *st = &ci->pStages[i];
        if (st->module == VK_NULL_HANDLE || st->pNext) return 0;
        uint64_t code = module_code(st->module);
        if (!code) return 0;
        h = fnv(h, &st->stage, sizeof st->stage);
        h = fnv(h, &code, sizeof code);
        if (st->pName) h = fnv(h, st->pName, strlen(st->pName));
        const VkSpecializationInfo *sp = st->pSpecializationInfo;
        if (sp) {
            if (sp->mapEntryCount) h = fnv(h, sp->pMapEntries, sp->mapEntryCount * sizeof *sp->pMapEntries);
            if (sp->dataSize) h = fnv(h, sp->pData, sp->dataSize);
        }
    }
    const VkPipelineVertexInputStateCreateInfo *vi = ci->pVertexInputState;
    if (vi) {
        if (vi->pNext) return 0;
        if (vi->vertexBindingDescriptionCount)
            h = fnv(h, vi->pVertexBindingDescriptions, vi->vertexBindingDescriptionCount * sizeof *vi->pVertexBindingDescriptions);
        if (vi->vertexAttributeDescriptionCount)
            h = fnv(h, vi->pVertexAttributeDescriptions,
                    vi->vertexAttributeDescriptionCount * sizeof *vi->pVertexAttributeDescriptions);
    }
    if (ci->pInputAssemblyState) h = fnv(h, &ci->pInputAssemblyState->topology, sizeof(VkPrimitiveTopology));
    if (ci->pTessellationState) h = fnv(h, &ci->pTessellationState->patchControlPoints, sizeof(uint32_t));
    h = fnv(h, &ci->layout, sizeof ci->layout);
    h = fnv(h, &ci->renderPass, sizeof ci->renderPass);
    h = fnv(h, &ci->subpass, sizeof ci->subpass);
    return h ? h : 1;
}

static int failed_seen(uint64_t key) {
    AcquireSRWLockShared(&failed_lock);
    int found = 0;
    for (unsigned i = key % FAILED_SLOTS, n = 0; n < FAILED_SLOTS && failed[i]; i = (i + 1) % FAILED_SLOTS, n++)
        if (failed[i] == key) { found = 1; break; }
    ReleaseSRWLockShared(&failed_lock);
    return found;
}

static void failed_add(uint64_t key) {
    AcquireSRWLockExclusive(&failed_lock);
    if (failed_count < FAILED_SLOTS / 2) {
        unsigned i = key % FAILED_SLOTS;
        while (failed[i] && failed[i] != key) i = (i + 1) % FAILED_SLOTS;
        if (!failed[i]) { failed[i] = key; failed_count++; }
    }
    ReleaseSRWLockExclusive(&failed_lock);
}

static VKAPI_ATTR void VKAPI_CALL DestroyShaderModule(VkDevice dev, VkShaderModule module, const VkAllocationCallbacks *alloc) {
    uint64_t key = (uint64_t)module;
    AcquireSRWLockExclusive(&modules_lock);
    for (unsigned i = (key >> 4) % MODULE_SLOTS, n = 0; n < MODULE_SLOTS && modules[i].module; i = (i + 1) % MODULE_SLOTS, n++)
        if (modules[i].module == key) { modules[i].module = TOMBSTONE; break; }
    ReleaseSRWLockExclusive(&modules_lock);
    real_DestroyShaderModule(dev, module, alloc);
}

EXPORT VKAPI_ATTR void VKAPI_CALL vkDestroyShaderModule(VkDevice dev, VkShaderModule module, const VkAllocationCallbacks *alloc) {
    if (!real_DestroyShaderModule)
        real_DestroyShaderModule = (PFN_vkDestroyShaderModule)GetProcAddress(real_module, "vkDestroyShaderModule");
    DestroyShaderModule(dev, module, alloc);
}

// ---------------------------------------------------------------------------- line width

static VKAPI_ATTR VkResult VKAPI_CALL CreateGraphicsPipelines(VkDevice dev, VkPipelineCache cache, uint32_t n,
                                                              const VkGraphicsPipelineCreateInfo *infos,
                                                              const VkAllocationCallbacks *alloc, VkPipeline *out) {
    uint64_t key = n == 1 ? pipeline_key(infos) : 0;
    if (key && failed_seen(key)) {
        out[0] = VK_NULL_HANDLE;
        unsigned k = ++failed_repeats;
        if ((k & (k - 1)) == 0) say("%u repeats of failed pipelines answered without compiling", k);
        return VK_ERROR_INITIALIZATION_FAILED;
    }
    float widths[64];
    uint32_t m = n < 64 ? n : 64;
    for (uint32_t i = 0; i < m; i++) {
        VkPipelineRasterizationStateCreateInfo *rs = (VkPipelineRasterizationStateCreateInfo *)infos[i].pRasterizationState;
        widths[i] = rs ? rs->lineWidth : 1.0f;
        if (rs && rs->lineWidth != 1.0f) rs->lineWidth = 1.0f;
    }
    VkResult r = real_CreateGraphicsPipelines(dev, cache, n, infos, alloc, out);
    if (r != VK_SUCCESS) {
        if (key) failed_add(key);
        char stages[256] = "";
        size_t used = 0;
        for (uint32_t i = 0; n == 1 && i < infos->stageCount && used + 40 < sizeof stages; i++)
            used += (size_t)snprintf(stages + used, sizeof stages - used, " stage %#x %016llx", (unsigned)infos->pStages[i].stage,
                                     (unsigned long long)module_code(infos->pStages[i].module));
        say("vkCreateGraphicsPipelines(%u) failed: %d%s%s", n, (int)r, key ? " (remembered)" : "", stages);
    }
    for (uint32_t i = 0; i < m; i++) {
        VkPipelineRasterizationStateCreateInfo *rs = (VkPipelineRasterizationStateCreateInfo *)infos[i].pRasterizationState;
        if (rs) rs->lineWidth = widths[i];
    }
    return r;
}

EXPORT VKAPI_ATTR VkResult VKAPI_CALL vkCreateGraphicsPipelines(VkDevice dev, VkPipelineCache cache, uint32_t n,
                                                               const VkGraphicsPipelineCreateInfo *infos,
                                                               const VkAllocationCallbacks *alloc, VkPipeline *out) {
    if (!real_CreateGraphicsPipelines)
        real_CreateGraphicsPipelines = (PFN_vkCreateGraphicsPipelines)GetProcAddress(real_module, "vkCreateGraphicsPipelines");
    return CreateGraphicsPipelines(dev, cache, n, infos, alloc, out);
}

static VKAPI_ATTR void VKAPI_CALL CmdSetLineWidth(VkCommandBuffer cb, float width) {
    (void)width;
    real_CmdSetLineWidth(cb, 1.0f);
}

EXPORT VKAPI_ATTR void VKAPI_CALL vkCmdSetLineWidth(VkCommandBuffer cb, float width) {
    if (!real_CmdSetLineWidth) real_CmdSetLineWidth = (PFN_vkCmdSetLineWidth)GetProcAddress(real_module, "vkCmdSetLineWidth");
    CmdSetLineWidth(cb, width);
}

static VKAPI_ATTR VkResult VKAPI_CALL CreateComputePipelines(VkDevice dev, VkPipelineCache cache, uint32_t n,
                                                             const VkComputePipelineCreateInfo *infos,
                                                             const VkAllocationCallbacks *alloc, VkPipeline *out) {
    VkResult r = real_CreateComputePipelines(dev, cache, n, infos, alloc, out);
    if (r != VK_SUCCESS) say("vkCreateComputePipelines(%u) failed: %d", n, (int)r);
    return r;
}

// ---------------------------------------------------------------------------- lookups

static PFN_vkVoidFunction ours(const char *name) {
    if (!strcmp(name, "vkGetInstanceProcAddr")) return (PFN_vkVoidFunction)vkGetInstanceProcAddr;
    if (!strcmp(name, "vkGetDeviceProcAddr")) return (PFN_vkVoidFunction)vkGetDeviceProcAddr;
    if (!strcmp(name, "vkGetPhysicalDeviceFeatures")) return (PFN_vkVoidFunction)vkGetPhysicalDeviceFeatures;
    if (!strcmp(name, "vkGetPhysicalDeviceFeatures2")) return (PFN_vkVoidFunction)vkGetPhysicalDeviceFeatures2;
    if (!strcmp(name, "vkGetPhysicalDeviceFeatures2KHR")) return (PFN_vkVoidFunction)GetPhysicalDeviceFeatures2KHR;
    if (!strcmp(name, "vkGetPhysicalDeviceProperties")) return (PFN_vkVoidFunction)vkGetPhysicalDeviceProperties;
    if (!strcmp(name, "vkGetPhysicalDeviceProperties2")) return (PFN_vkVoidFunction)vkGetPhysicalDeviceProperties2;
    if (!strcmp(name, "vkGetPhysicalDeviceProperties2KHR")) return (PFN_vkVoidFunction)GetPhysicalDeviceProperties2KHR;
    if (!strcmp(name, "vkCreateDevice")) return (PFN_vkVoidFunction)vkCreateDevice;
    if (!strcmp(name, "vkCreateInstance")) return (PFN_vkVoidFunction)vkCreateInstance;
    if (!strcmp(name, "vkEnumerateDeviceExtensionProperties")) return (PFN_vkVoidFunction)vkEnumerateDeviceExtensionProperties;
    return NULL;
}

EXPORT VKAPI_ATTR PFN_vkVoidFunction VKAPI_CALL vkGetDeviceProcAddr(VkDevice dev, const char *name) {
    PFN_vkVoidFunction real = real_GetDeviceProcAddr(dev, name);
    if (!real || !name) return real;
    if (!strcmp(name, "vkCreateGraphicsPipelines")) {
        real_CreateGraphicsPipelines = (PFN_vkCreateGraphicsPipelines)real;
        return (PFN_vkVoidFunction)CreateGraphicsPipelines;
    }
    if (!strcmp(name, "vkCmdSetLineWidth")) {
        real_CmdSetLineWidth = (PFN_vkCmdSetLineWidth)real;
        return (PFN_vkVoidFunction)CmdSetLineWidth;
    }
    if (!strcmp(name, "vkCreateComputePipelines")) {
        real_CreateComputePipelines = (PFN_vkCreateComputePipelines)real;
        return (PFN_vkVoidFunction)CreateComputePipelines;
    }
    if (!strcmp(name, "vkDestroyShaderModule")) {
        real_DestroyShaderModule = (PFN_vkDestroyShaderModule)real;
        return (PFN_vkVoidFunction)DestroyShaderModule;
    }
    if (!strcmp(name, "vkCreateShaderModule")) {
        real_CreateShaderModule = (PFN_vkCreateShaderModule)real;
        return (PFN_vkVoidFunction)CreateShaderModule;
    }
    PFN_vkVoidFunction mine = ours(name);
    return mine ? mine : real;
}

EXPORT VKAPI_ATTR PFN_vkVoidFunction VKAPI_CALL vkGetInstanceProcAddr(VkInstance inst, const char *name) {
    PFN_vkVoidFunction real = real_GetInstanceProcAddr(inst, name);
    if (!name) return real;
    // Device functions asked of the instance: only when the real one has them.
    if (real && !strcmp(name, "vkCreateGraphicsPipelines")) {
        real_CreateGraphicsPipelines = (PFN_vkCreateGraphicsPipelines)real;
        return (PFN_vkVoidFunction)CreateGraphicsPipelines;
    }
    if (real && !strcmp(name, "vkCmdSetLineWidth")) {
        real_CmdSetLineWidth = (PFN_vkCmdSetLineWidth)real;
        return (PFN_vkVoidFunction)CmdSetLineWidth;
    }
    if (real && !strcmp(name, "vkDestroyShaderModule")) {
        real_DestroyShaderModule = (PFN_vkDestroyShaderModule)real;
        return (PFN_vkVoidFunction)DestroyShaderModule;
    }
    if (real && !strcmp(name, "vkCreateShaderModule")) {
        real_CreateShaderModule = (PFN_vkCreateShaderModule)real;
        return (PFN_vkVoidFunction)CreateShaderModule;
    }
    PFN_vkVoidFunction mine = ours(name);
    // vkGetPhysicalDeviceFeatures2KHR only if the instance offers it.
    if (mine && !strcmp(name, "vkGetPhysicalDeviceFeatures2KHR") && !real) return NULL;
    if (mine && !strcmp(name, "vkGetPhysicalDeviceProperties2KHR") && !real) return NULL;
    return mine ? mine : real;
}
