// The OpenXR surface. One instance and one session at a time, which is all a game uses.

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <math.h>
#include <pthread.h>
#include <string.h>
#include <time.h>

#define XR_USE_GRAPHICS_API_METAL
#define XR_USE_TIMESPEC
#include "vk.h"
#include <openxr/openxr.h>
#include <openxr/openxr_loader_negotiation.h>
#include <openxr/openxr_platform.h>
#include <openxr/openxr_reflection.h>

#include "alvrxr.h"

#define EXPORT __attribute__((visibility("default")))

// ------------------------------------------------------------------------------------ handles

enum { MAGIC_INSTANCE = 0x41585249, MAGIC_SESSION, MAGIC_SPACE, MAGIC_SWAPCHAIN, MAGIC_ACTIONSET, MAGIC_ACTION };

typedef struct instance {
    uint32_t magic;
    NSMutableArray *events;          // NSData of XrEventDataBuffer-sized events, oldest first
    NSMutableDictionary *suggested;  // profile path -> NSMutableArray of @[action ptr, binding path]
} instance;

typedef struct session session;

typedef struct action_set {
    uint32_t magic;
    char name[XR_MAX_ACTION_SET_NAME_SIZE];
    bool attached;
} action_set;

enum { SUB_NONE, SUB_LEFT, SUB_RIGHT, SUB_COUNT };

typedef struct action {
    uint32_t magic;
    action_set *set;
    XrActionType type;
    char name[XR_MAX_ACTION_NAME_SIZE];
    NSMutableArray<NSString *> *bindings;   // for the active profile, resolved at attach
    // State per subaction (none = all), as of the last xrSyncActions.
    float value[SUB_COUNT][2];
    bool active[SUB_COUNT], changed[SUB_COUNT];
    XrTime change_time[SUB_COUNT];
} action;

typedef struct swapchain {
    uint32_t magic;
    session *sess;
    XrSwapchainCreateInfo info;
    id<MTLTexture> __strong images[3];   // for Vulkan, the MTLTextures behind vk_images
    VkImage vk_images[3];
    VkDeviceMemory vk_memory[3];
    uint32_t count, next, acquired[3], acquired_count;
    int32_t released;                       // last released image, -1 before the first
} swapchain;

enum { SPACE_REFERENCE, SPACE_ACTION };

typedef struct space {
    uint32_t magic;
    session *sess;
    int kind;
    XrReferenceSpaceType ref;
    action *act;
    int hand;                               // AXR_LEFT/RIGHT for action spaces
    bool aim;
    XrPosef offset;
} space;

struct session {
    uint32_t magic;
    instance *inst;
    id<MTLCommandQueue> queue;
    bool vulkan;
    VkDevice vk_device;
    XrSessionState state;
    bool running, exit_requested;
    NSMutableArray<NSValue *> *action_sets;
    XrPath profile;                          // active interaction profile
    XrPosef local;                           // LOCAL's origin in STAGE
    bool local_from_headset;
};

static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;
static instance *g_instance;
static session *g_session;
static NSMutableArray<NSString *> *g_paths;

#define CHECK_HANDLE(h, type, magic_)                                       \
    do {                                                                    \
        if (!(h) || ((type *)(h))->magic != (magic_)) return XR_ERROR_HANDLE_INVALID; \
    } while (0)

// The two-call idiom every enumerate function shares.
#define TWO_CALL(capacity, countOut, array, items, n, assign)              \
    do {                                                                    \
        if (!(countOut)) return XR_ERROR_VALIDATION_FAILURE;                \
        *(countOut) = (uint32_t)(n);                                        \
        if ((capacity) == 0) return XR_SUCCESS;                             \
        if ((capacity) < (uint32_t)(n)) return XR_ERROR_SIZE_INSUFFICIENT;  \
        for (uint32_t i_ = 0; i_ < (uint32_t)(n); i_++) { assign; }         \
    } while (0)

static XrResult copy_string(const char *s, uint32_t capacity, uint32_t *countOut, char *buffer) {
    uint32_t n = (uint32_t)strlen(s) + 1;
    if (!countOut) return XR_ERROR_VALIDATION_FAILURE;
    *countOut = n;
    if (capacity == 0) return XR_SUCCESS;
    if (capacity < n) return XR_ERROR_SIZE_INSUFFICIENT;
    memcpy(buffer, s, n);
    return XR_SUCCESS;
}

// --------------------------------------------------------------------------------------- paths

static XrPath path_for(NSString *s) {
    @synchronized(g_paths) {
        NSUInteger i = [g_paths indexOfObject:s];
        if (i == NSNotFound) { [g_paths addObject:s]; i = g_paths.count - 1; }
        return (XrPath)(i + 1);
    }
}

static NSString *path_string(XrPath p) {
    @synchronized(g_paths) {
        return (p >= 1 && p <= g_paths.count) ? g_paths[p - 1] : nil;
    }
}

static XrResult xrStringToPath_(XrInstance inst, const char *s, XrPath *out) {
    CHECK_HANDLE(inst, instance, MAGIC_INSTANCE);
    if (!s || s[0] != '/' || strlen(s) >= XR_MAX_PATH_LENGTH) return XR_ERROR_PATH_FORMAT_INVALID;
    *out = path_for(@(s));
    return XR_SUCCESS;
}

static XrResult xrPathToString_(XrInstance inst, XrPath p, uint32_t cap, uint32_t *n, char *buf) {
    CHECK_HANDLE(inst, instance, MAGIC_INSTANCE);
    NSString *s = path_string(p);
    if (!s) return XR_ERROR_PATH_INVALID;
    return copy_string(s.UTF8String, cap, n, buf);
}

// -------------------------------------------------------------------------------------- events

static void push_event(const void *ev, size_t size) {
    if (!g_instance) return;
    XrEventDataBuffer buf = {0};
    memcpy(&buf, ev, size);
    [g_instance->events addObject:[NSData dataWithBytes:&buf length:sizeof buf]];
}

static void set_state(session *s, XrSessionState st) {
    s->state = st;
    XrEventDataSessionStateChanged ev = {XR_TYPE_EVENT_DATA_SESSION_STATE_CHANGED, NULL, (XrSession)s, st, axr_now_ns()};
    push_event(&ev, sizeof ev);
}

static XrResult xrPollEvent_(XrInstance inst, XrEventDataBuffer *out) {
    CHECK_HANDLE(inst, instance, MAGIC_INSTANCE);
    pthread_mutex_lock(&g_lock);
    NSData *ev = g_instance->events.firstObject;
    if (ev) [g_instance->events removeObjectAtIndex:0];
    pthread_mutex_unlock(&g_lock);
    if (!ev) return XR_EVENT_UNAVAILABLE;
    memcpy(out, ev.bytes, sizeof *out);
    return XR_SUCCESS;
}

// ------------------------------------------------------------------------------------ instance

static const XrExtensionProperties g_extensions[] = {
    {XR_TYPE_EXTENSION_PROPERTIES, NULL, XR_KHR_METAL_ENABLE_EXTENSION_NAME, XR_KHR_metal_enable_SPEC_VERSION},
    {XR_TYPE_EXTENSION_PROPERTIES, NULL, XR_KHR_VULKAN_ENABLE_EXTENSION_NAME, XR_KHR_vulkan_enable_SPEC_VERSION},
    {XR_TYPE_EXTENSION_PROPERTIES, NULL, XR_KHR_VULKAN_ENABLE2_EXTENSION_NAME, XR_KHR_vulkan_enable2_SPEC_VERSION},
    {XR_TYPE_EXTENSION_PROPERTIES, NULL, XR_KHR_CONVERT_TIMESPEC_TIME_EXTENSION_NAME, XR_KHR_convert_timespec_time_SPEC_VERSION},
    {XR_TYPE_EXTENSION_PROPERTIES, NULL, XR_KHR_COMPOSITION_LAYER_DEPTH_EXTENSION_NAME, XR_KHR_composition_layer_depth_SPEC_VERSION},
};
#define EXTENSION_COUNT (sizeof g_extensions / sizeof g_extensions[0])

static XrResult xrEnumerateInstanceExtensionProperties_(const char *layer, uint32_t cap, uint32_t *n,
                                                        XrExtensionProperties *props) {
    if (layer) return XR_ERROR_API_LAYER_NOT_PRESENT;
    TWO_CALL(cap, n, props, g_extensions, EXTENSION_COUNT, props[i_] = g_extensions[i_]);
    return XR_SUCCESS;
}

static XrResult xrCreateInstance_(const XrInstanceCreateInfo *info, XrInstance *out) {
    for (uint32_t i = 0; i < info->enabledExtensionCount; i++) {
        bool known = false;
        for (size_t e = 0; e < EXTENSION_COUNT; e++)
            if (!strcmp(info->enabledExtensionNames[i], g_extensions[e].extensionName)) known = true;
        if (!known) {
            axr_log("app asked for unsupported extension %s", info->enabledExtensionNames[i]);
            return XR_ERROR_EXTENSION_NOT_PRESENT;
        }
    }
    pthread_mutex_lock(&g_lock);
    if (g_instance) { pthread_mutex_unlock(&g_lock); return XR_ERROR_LIMIT_REACHED; }
    instance *inst = calloc(1, sizeof *inst);
    inst->magic = MAGIC_INSTANCE;
    inst->events = [NSMutableArray array];
    inst->suggested = [NSMutableDictionary dictionary];
    CFRetain((__bridge CFTypeRef)inst->events);
    CFRetain((__bridge CFTypeRef)inst->suggested);
    g_instance = inst;
    if (!g_paths) g_paths = [NSMutableArray array];
    pthread_mutex_unlock(&g_lock);
    axr_log("instance for \"%s\" (engine \"%s\")", info->applicationInfo.applicationName, info->applicationInfo.engineName);
    axr_backend_start();
    *out = (XrInstance)inst;
    return XR_SUCCESS;
}

static XrResult xrDestroyInstance_(XrInstance h) {
    CHECK_HANDLE(h, instance, MAGIC_INSTANCE);
    instance *inst = (instance *)h;
    pthread_mutex_lock(&g_lock);
    inst->magic = 0;
    CFRelease((__bridge CFTypeRef)inst->events);
    CFRelease((__bridge CFTypeRef)inst->suggested);
    g_instance = NULL;
    pthread_mutex_unlock(&g_lock);
    free(inst);
    return XR_SUCCESS;
}

static XrResult xrGetInstanceProperties_(XrInstance h, XrInstanceProperties *p) {
    CHECK_HANDLE(h, instance, MAGIC_INSTANCE);
    p->runtimeVersion = XR_MAKE_VERSION(0, 1, 0);
    snprintf(p->runtimeName, sizeof p->runtimeName, "alvrxr (ALVR on macOS)");
    return XR_SUCCESS;
}

static XrResult xrResultToString_(XrInstance h, XrResult r, char buf[XR_MAX_RESULT_STRING_SIZE]) {
    (void)h;
#define RESULT_CASE(name, val) case name: snprintf(buf, XR_MAX_RESULT_STRING_SIZE, #name); return XR_SUCCESS;
    switch (r) { XR_LIST_ENUM_XrResult(RESULT_CASE) default: break; }
    snprintf(buf, XR_MAX_RESULT_STRING_SIZE, r < 0 ? "XR_UNKNOWN_FAILURE_%d" : "XR_UNKNOWN_SUCCESS_%d", r);
    return XR_SUCCESS;
}

static XrResult xrStructureTypeToString_(XrInstance h, XrStructureType t, char buf[XR_MAX_STRUCTURE_NAME_SIZE]) {
    (void)h;
#define TYPE_CASE(name, val) case name: snprintf(buf, XR_MAX_STRUCTURE_NAME_SIZE, #name); return XR_SUCCESS;
    switch (t) { XR_LIST_ENUM_XrStructureType(TYPE_CASE) default: break; }
    snprintf(buf, XR_MAX_STRUCTURE_NAME_SIZE, "XR_UNKNOWN_STRUCTURE_TYPE_%d", t);
    return XR_SUCCESS;
}

static XrResult xrConvertTimespecTimeToTimeKHR_(XrInstance h, const struct timespec *ts, XrTime *t) {
    CHECK_HANDLE(h, instance, MAGIC_INSTANCE);
    *t = (XrTime)ts->tv_sec * 1000000000 + ts->tv_nsec;   // XrTime is CLOCK_MONOTONIC
    return XR_SUCCESS;
}

static XrResult xrConvertTimeToTimespecTimeKHR_(XrInstance h, XrTime t, struct timespec *ts) {
    CHECK_HANDLE(h, instance, MAGIC_INSTANCE);
    ts->tv_sec = t / 1000000000;
    ts->tv_nsec = t % 1000000000;
    return XR_SUCCESS;
}

// -------------------------------------------------------------------------------------- system

#define SYSTEM_ID ((XrSystemId)1)

static XrResult xrGetSystem_(XrInstance h, const XrSystemGetInfo *info, XrSystemId *out) {
    CHECK_HANDLE(h, instance, MAGIC_INSTANCE);
    if (info->formFactor != XR_FORM_FACTOR_HEAD_MOUNTED_DISPLAY) return XR_ERROR_FORM_FACTOR_UNSUPPORTED;
    *out = SYSTEM_ID;
    return XR_SUCCESS;
}

static XrResult xrGetSystemProperties_(XrInstance h, XrSystemId sys, XrSystemProperties *p) {
    CHECK_HANDLE(h, instance, MAGIC_INSTANCE);
    if (sys != SYSTEM_ID) return XR_ERROR_SYSTEM_INVALID;
    p->systemId = SYSTEM_ID;
    p->vendorId = 0x414c;
    snprintf(p->systemName, sizeof p->systemName, "Apple Vision Pro (ALVR)");
    p->graphicsProperties.maxSwapchainImageWidth = 8192;
    p->graphicsProperties.maxSwapchainImageHeight = 8192;
    p->graphicsProperties.maxLayerCount = XR_MIN_COMPOSITION_LAYERS_SUPPORTED;
    p->trackingProperties.orientationTracking = XR_TRUE;
    p->trackingProperties.positionTracking = XR_TRUE;
    return XR_SUCCESS;
}

static XrResult xrEnumerateViewConfigurations_(XrInstance h, XrSystemId sys, uint32_t cap, uint32_t *n,
                                               XrViewConfigurationType *out) {
    CHECK_HANDLE(h, instance, MAGIC_INSTANCE);
    if (sys != SYSTEM_ID) return XR_ERROR_SYSTEM_INVALID;
    TWO_CALL(cap, n, out, x, 1, out[i_] = XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO);
    return XR_SUCCESS;
}

static XrResult xrGetViewConfigurationProperties_(XrInstance h, XrSystemId sys, XrViewConfigurationType t,
                                                  XrViewConfigurationProperties *p) {
    CHECK_HANDLE(h, instance, MAGIC_INSTANCE);
    if (sys != SYSTEM_ID) return XR_ERROR_SYSTEM_INVALID;
    if (t != XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO) return XR_ERROR_VIEW_CONFIGURATION_TYPE_UNSUPPORTED;
    p->viewConfigurationType = t;
    p->fovMutable = XR_FALSE;
    return XR_SUCCESS;
}

static XrResult xrEnumerateViewConfigurationViews_(XrInstance h, XrSystemId sys, XrViewConfigurationType t,
                                                   uint32_t cap, uint32_t *n, XrViewConfigurationView *out) {
    CHECK_HANDLE(h, instance, MAGIC_INSTANCE);
    if (sys != SYSTEM_ID) return XR_ERROR_SYSTEM_INVALID;
    if (t != XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO) return XR_ERROR_VIEW_CONFIGURATION_TYPE_UNSUPPORTED;
    uint32_t w, hh;
    axr_recommended_eye_size(&w, &hh);
    TWO_CALL(cap, n, out, x, 2, {
        out[i_].recommendedImageRectWidth = w;
        out[i_].recommendedImageRectHeight = hh;
        out[i_].maxImageRectWidth = 8192;
        out[i_].maxImageRectHeight = 8192;
        out[i_].recommendedSwapchainSampleCount = 1;
        out[i_].maxSwapchainSampleCount = 1;
    });
    return XR_SUCCESS;
}

static XrResult xrEnumerateEnvironmentBlendModes_(XrInstance h, XrSystemId sys, XrViewConfigurationType t,
                                                  uint32_t cap, uint32_t *n, XrEnvironmentBlendMode *out) {
    CHECK_HANDLE(h, instance, MAGIC_INSTANCE);
    if (sys != SYSTEM_ID) return XR_ERROR_SYSTEM_INVALID;
    if (t != XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO) return XR_ERROR_VIEW_CONFIGURATION_TYPE_UNSUPPORTED;
    TWO_CALL(cap, n, out, x, 1, out[i_] = XR_ENVIRONMENT_BLEND_MODE_OPAQUE);
    return XR_SUCCESS;
}

static XrResult xrGetMetalGraphicsRequirementsKHR_(XrInstance h, XrSystemId sys, XrGraphicsRequirementsMetalKHR *r) {
    CHECK_HANDLE(h, instance, MAGIC_INSTANCE);
    if (sys != SYSTEM_ID) return XR_ERROR_SYSTEM_INVALID;
    // The app takes ownership of this reference (hello_xr wraps it in NS::TransferPtr).
    r->metalDevice = (void *)CFBridgingRetain(axr_metal_device());
    return XR_SUCCESS;
}

static XrResult xrGetVulkanGraphicsRequirementsKHR_(XrInstance h, XrSystemId sys, XrGraphicsRequirementsVulkanKHR *r) {
    CHECK_HANDLE(h, instance, MAGIC_INSTANCE);
    if (sys != SYSTEM_ID) return XR_ERROR_SYSTEM_INVALID;
    r->minApiVersionSupported = XR_MAKE_VERSION(1, 0, 0);
    r->maxApiVersionSupported = XR_MAKE_VERSION(1, 4, 0);
    return XR_SUCCESS;
}

static XrResult xrGetVulkanGraphicsRequirements2KHR_(XrInstance h, XrSystemId sys, XrGraphicsRequirementsVulkan2KHR *r) {
    return xrGetVulkanGraphicsRequirementsKHR_(h, sys, (XrGraphicsRequirementsVulkanKHR *)r);
}

static XrResult xrGetVulkanInstanceExtensionsKHR_(XrInstance h, XrSystemId sys, uint32_t cap, uint32_t *n, char *buf) {
    CHECK_HANDLE(h, instance, MAGIC_INSTANCE);
    if (sys != SYSTEM_ID) return XR_ERROR_SYSTEM_INVALID;
    return copy_string(axr_vk_instance_extensions(), cap, n, buf);
}

static XrResult xrGetVulkanDeviceExtensionsKHR_(XrInstance h, XrSystemId sys, uint32_t cap, uint32_t *n, char *buf) {
    CHECK_HANDLE(h, instance, MAGIC_INSTANCE);
    if (sys != SYSTEM_ID) return XR_ERROR_SYSTEM_INVALID;
    return copy_string(axr_vk_device_extensions(), cap, n, buf);
}

static XrResult xrGetVulkanGraphicsDeviceKHR_(XrInstance h, XrSystemId sys, VkInstance vk, VkPhysicalDevice *out) {
    CHECK_HANDLE(h, instance, MAGIC_INSTANCE);
    if (sys != SYSTEM_ID) return XR_ERROR_SYSTEM_INVALID;
    return axr_vk_physical_device(vk, out) == VK_SUCCESS ? XR_SUCCESS : XR_ERROR_RUNTIME_FAILURE;
}

static XrResult xrGetVulkanGraphicsDevice2KHR_(XrInstance h, const XrVulkanGraphicsDeviceGetInfoKHR *info,
                                               VkPhysicalDevice *out) {
    return xrGetVulkanGraphicsDeviceKHR_(h, info->systemId, info->vulkanInstance, out);
}

static XrResult xrCreateVulkanInstanceKHR_(XrInstance h, const XrVulkanInstanceCreateInfoKHR *info, VkInstance *out,
                                           VkResult *vr) {
    CHECK_HANDLE(h, instance, MAGIC_INSTANCE);
    if (info->systemId != SYSTEM_ID) return XR_ERROR_SYSTEM_INVALID;
    *vr = axr_vk_create_instance(info->pfnGetInstanceProcAddr, info->vulkanCreateInfo, info->vulkanAllocator, out);
    return XR_SUCCESS;
}

static XrResult xrCreateVulkanDeviceKHR_(XrInstance h, const XrVulkanDeviceCreateInfoKHR *info, VkDevice *out,
                                         VkResult *vr) {
    CHECK_HANDLE(h, instance, MAGIC_INSTANCE);
    if (info->systemId != SYSTEM_ID) return XR_ERROR_SYSTEM_INVALID;
    axr_vk_load(info->pfnGetInstanceProcAddr);
    *vr = axr_vk_create_device(info->vulkanPhysicalDevice, info->vulkanCreateInfo, info->vulkanAllocator, out);
    return XR_SUCCESS;
}

// ------------------------------------------------------------------------------------- session

static XrResult xrCreateSession_(XrInstance h, const XrSessionCreateInfo *info, XrSession *out) {
    CHECK_HANDLE(h, instance, MAGIC_INSTANCE);
    if (info->systemId != SYSTEM_ID) return XR_ERROR_SYSTEM_INVALID;
    const XrGraphicsBindingMetalKHR *binding = NULL;
    const XrGraphicsBindingVulkanKHR *vk = NULL;   // also XrGraphicsBindingVulkan2KHR
    for (const XrBaseInStructure *n = info->next; n; n = n->next) {
        if (n->type == XR_TYPE_GRAPHICS_BINDING_METAL_KHR) binding = (const XrGraphicsBindingMetalKHR *)n;
        if (n->type == XR_TYPE_GRAPHICS_BINDING_VULKAN_KHR) vk = (const XrGraphicsBindingVulkanKHR *)n;
    }
    id<MTLCommandQueue> queue = nil;
    if (binding) queue = (__bridge id<MTLCommandQueue>)binding->commandQueue;
    else if (vk) queue = axr_vk_session_queue(vk->instance, vk->device, vk->queueFamilyIndex, vk->queueIndex);
    if (!queue) return XR_ERROR_GRAPHICS_DEVICE_INVALID;
    pthread_mutex_lock(&g_lock);
    if (g_session) { pthread_mutex_unlock(&g_lock); return XR_ERROR_LIMIT_REACHED; }
    session *s = calloc(1, sizeof *s);
    s->magic = MAGIC_SESSION;
    s->inst = (instance *)h;
    s->queue = queue;
    s->vulkan = vk != NULL;
    s->vk_device = vk ? vk->device : VK_NULL_HANDLE;
    s->action_sets = [NSMutableArray array];
    s->local = (XrPosef){{0, 0, 0, 1}, {0, 1.6f, 0}};
    g_session = s;
    set_state(s, XR_SESSION_STATE_IDLE);
    set_state(s, XR_SESSION_STATE_READY);
    pthread_mutex_unlock(&g_lock);
    axr_log("session created (%s)", vk ? "Vulkan" : "Metal");
    *out = (XrSession)s;
    return XR_SUCCESS;
}

static XrResult xrDestroySession_(XrSession h) {
    CHECK_HANDLE(h, session, MAGIC_SESSION);
    session *s = (session *)h;
    pthread_mutex_lock(&g_lock);
    s->magic = 0;
    s->queue = nil;
    s->action_sets = nil;
    g_session = NULL;
    pthread_mutex_unlock(&g_lock);
    free(s);
    axr_log("session destroyed");
    return XR_SUCCESS;
}

static XrResult xrBeginSession_(XrSession h, const XrSessionBeginInfo *info) {
    CHECK_HANDLE(h, session, MAGIC_SESSION);
    session *s = (session *)h;
    if (info->primaryViewConfigurationType != XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO)
        return XR_ERROR_VIEW_CONFIGURATION_TYPE_UNSUPPORTED;
    pthread_mutex_lock(&g_lock);
    if (s->running) { pthread_mutex_unlock(&g_lock); return XR_ERROR_SESSION_RUNNING; }
    if (s->state != XR_SESSION_STATE_READY) { pthread_mutex_unlock(&g_lock); return XR_ERROR_SESSION_NOT_READY; }
    s->running = true;
    set_state(s, XR_SESSION_STATE_SYNCHRONIZED);
    set_state(s, XR_SESSION_STATE_VISIBLE);
    set_state(s, XR_SESSION_STATE_FOCUSED);
    pthread_mutex_unlock(&g_lock);
    return XR_SUCCESS;
}

static XrResult xrRequestExitSession_(XrSession h) {
    CHECK_HANDLE(h, session, MAGIC_SESSION);
    session *s = (session *)h;
    pthread_mutex_lock(&g_lock);
    if (!s->running) { pthread_mutex_unlock(&g_lock); return XR_ERROR_SESSION_NOT_RUNNING; }
    s->exit_requested = true;
    set_state(s, XR_SESSION_STATE_VISIBLE);
    set_state(s, XR_SESSION_STATE_SYNCHRONIZED);
    set_state(s, XR_SESSION_STATE_STOPPING);
    pthread_mutex_unlock(&g_lock);
    return XR_SUCCESS;
}

static XrResult xrEndSession_(XrSession h) {
    CHECK_HANDLE(h, session, MAGIC_SESSION);
    session *s = (session *)h;
    pthread_mutex_lock(&g_lock);
    if (!s->running) { pthread_mutex_unlock(&g_lock); return XR_ERROR_SESSION_NOT_RUNNING; }
    if (s->state != XR_SESSION_STATE_STOPPING) { pthread_mutex_unlock(&g_lock); return XR_ERROR_SESSION_NOT_STOPPING; }
    s->running = false;
    set_state(s, XR_SESSION_STATE_IDLE);
    if (s->exit_requested) set_state(s, XR_SESSION_STATE_EXITING);
    pthread_mutex_unlock(&g_lock);
    return XR_SUCCESS;
}

// ---------------------------------------------------------------------------------- pose math

static XrQuaternionf qmul(XrQuaternionf a, XrQuaternionf b) {
    return (XrQuaternionf){a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y, a.w * b.y - a.x * b.z + a.y * b.w + a.z * b.x,
                           a.w * b.z + a.x * b.y - a.y * b.x + a.z * b.w, a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z};
}

static XrVector3f qrot(XrQuaternionf q, XrVector3f v) {
    XrQuaternionf p = {v.x, v.y, v.z, 0}, c = {-q.x, -q.y, -q.z, q.w};
    XrQuaternionf r = qmul(qmul(q, p), c);
    return (XrVector3f){r.x, r.y, r.z};
}

static XrPosef pmul(XrPosef a, XrPosef b) {   // a then b: b expressed in a's frame
    XrVector3f t = qrot(a.orientation, b.position);
    return (XrPosef){qmul(a.orientation, b.orientation), {a.position.x + t.x, a.position.y + t.y, a.position.z + t.z}};
}

static XrPosef pinv(XrPosef a) {
    XrQuaternionf c = {-a.orientation.x, -a.orientation.y, -a.orientation.z, a.orientation.w};
    XrVector3f t = qrot(c, a.position);
    return (XrPosef){c, {-t.x, -t.y, -t.z}};
}

static XrPosef from_axr(axr_pose p) {
    return (XrPosef){{p.orientation[0], p.orientation[1], p.orientation[2], p.orientation[3]},
                     {p.position[0], p.position[1], p.position[2]}};
}

static const XrPosef IDENTITY = {{0, 0, 0, 1}, {0, 0, 0}};

// ------------------------------------------------------------------------------------- spaces

static XrResult xrEnumerateReferenceSpaces_(XrSession h, uint32_t cap, uint32_t *n, XrReferenceSpaceType *out) {
    CHECK_HANDLE(h, session, MAGIC_SESSION);
    static const XrReferenceSpaceType types[] = {XR_REFERENCE_SPACE_TYPE_VIEW, XR_REFERENCE_SPACE_TYPE_LOCAL,
                                                 XR_REFERENCE_SPACE_TYPE_STAGE};
    TWO_CALL(cap, n, out, types, 3, out[i_] = types[i_]);
    return XR_SUCCESS;
}

static XrResult new_space(session *s, space proto, XrSpace *out) {
    space *sp = calloc(1, sizeof *sp);
    *sp = proto;
    sp->magic = MAGIC_SPACE;
    sp->sess = s;
    *out = (XrSpace)sp;
    return XR_SUCCESS;
}

static XrResult xrCreateReferenceSpace_(XrSession h, const XrReferenceSpaceCreateInfo *info, XrSpace *out) {
    CHECK_HANDLE(h, session, MAGIC_SESSION);
    switch (info->referenceSpaceType) {
    case XR_REFERENCE_SPACE_TYPE_VIEW:
    case XR_REFERENCE_SPACE_TYPE_LOCAL:
    case XR_REFERENCE_SPACE_TYPE_STAGE: break;
    default: return XR_ERROR_REFERENCE_SPACE_UNSUPPORTED;
    }
    return new_space((session *)h, (space){.kind = SPACE_REFERENCE, .ref = info->referenceSpaceType,
                                           .offset = info->poseInReferenceSpace}, out);
}

static XrResult xrGetReferenceSpaceBoundsRect_(XrSession h, XrReferenceSpaceType t, XrExtent2Df *b) {
    CHECK_HANDLE(h, session, MAGIC_SESSION);
    (void)t;
    b->width = b->height = 0;
    return XR_SPACE_BOUNDS_UNAVAILABLE;
}

static XrResult xrDestroySpace_(XrSpace h) {
    CHECK_HANDLE(h, space, MAGIC_SPACE);
    ((space *)h)->magic = 0;
    free((space *)h);
    return XR_SUCCESS;
}

// LOCAL is where the user's head was, facing where it faced but level. Until the headset reports
// a real pose that is a guess, so it is taken once from the first real head pose, and the app is
// told the space moved.
static XrPosef local_origin(session *s, XrTime t) {
    if (!s->local_from_headset && axr_backend_tracking()) {
        axr_motion head = axr_device_motion(AXR_HEAD, t);
        bool placeholder = head.pose.position[0] == 0 && head.pose.position[1] == 1.2f && head.pose.position[2] == 0;
        if (head.valid && head.pose.position[1] > 0.3f && !placeholder) {
            XrPosef h = from_axr(head.pose);
            XrVector3f fwd = qrot(h.orientation, (XrVector3f){0, 0, -1});
            float yaw = atan2f(-fwd.x, -fwd.z);
            XrPosef origin = {{0, sinf(yaw / 2), 0, cosf(yaw / 2)}, h.position};
            XrEventDataReferenceSpaceChangePending ev = {XR_TYPE_EVENT_DATA_REFERENCE_SPACE_CHANGE_PENDING, NULL,
                                                         (XrSession)s, XR_REFERENCE_SPACE_TYPE_LOCAL, t, XR_TRUE,
                                                         pmul(pinv(s->local), origin)};
            pthread_mutex_lock(&g_lock);
            push_event(&ev, sizeof ev);
            pthread_mutex_unlock(&g_lock);
            s->local = origin;
            s->local_from_headset = true;
            axr_log("LOCAL space at the head: (%.3f, %.3f, %.3f), yaw %.0f deg", origin.position.x, origin.position.y,
                    origin.position.z, yaw * 180 / M_PI);
        }
    }
    return s->local;
}

// A space's pose in STAGE, and whether it is tracked right now.
static bool space_in_stage(space *sp, XrTime t, XrPosef *out, bool *tracked) {
    *tracked = true;
    if (sp->kind == SPACE_REFERENCE) {
        XrPosef base = IDENTITY;
        if (sp->ref == XR_REFERENCE_SPACE_TYPE_VIEW) {
            axr_motion head = axr_device_motion(AXR_HEAD, t);
            base = from_axr(head.pose);
            *tracked = axr_backend_connected();
        } else if (sp->ref == XR_REFERENCE_SPACE_TYPE_LOCAL) {
            base = local_origin(sp->sess, t);
        }
        *out = pmul(base, sp->offset);
        return true;
    }
    axr_motion m = axr_device_motion(sp->hand, t);
    if (!m.valid) return false;
    *out = pmul(from_axr(m.pose), sp->offset);
    return true;
}

static XrResult xrLocateSpace_(XrSpace hs, XrSpace hb, XrTime t, XrSpaceLocation *loc) {
    CHECK_HANDLE(hs, space, MAGIC_SPACE);
    CHECK_HANDLE(hb, space, MAGIC_SPACE);
    if (t <= 0) return XR_ERROR_TIME_INVALID;
    XrPosef a, b;
    bool ta, tb;
    loc->locationFlags = 0;
    if (!space_in_stage((space *)hs, t, &a, &ta) || !space_in_stage((space *)hb, t, &b, &tb)) {
        loc->pose = IDENTITY;
        return XR_SUCCESS;
    }
    loc->pose = pmul(pinv(b), a);
    loc->locationFlags = XR_SPACE_LOCATION_ORIENTATION_VALID_BIT | XR_SPACE_LOCATION_POSITION_VALID_BIT;
    if (ta && tb) loc->locationFlags |= XR_SPACE_LOCATION_ORIENTATION_TRACKED_BIT | XR_SPACE_LOCATION_POSITION_TRACKED_BIT;
    for (XrBaseOutStructure *n = loc->next; n; n = n->next)
        if (n->type == XR_TYPE_SPACE_VELOCITY) ((XrSpaceVelocity *)n)->velocityFlags = 0;
    return XR_SUCCESS;
}

static XrResult xrLocateViews_(XrSession h, const XrViewLocateInfo *info, XrViewState *state, uint32_t cap,
                               uint32_t *n, XrView *views) {
    CHECK_HANDLE(h, session, MAGIC_SESSION);
    CHECK_HANDLE(info->space, space, MAGIC_SPACE);
    if (info->viewConfigurationType != XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO)
        return XR_ERROR_VIEW_CONFIGURATION_TYPE_UNSUPPORTED;
    if (info->displayTime <= 0) return XR_ERROR_TIME_INVALID;
    *n = 2;
    if (cap == 0) return XR_SUCCESS;
    if (cap < 2) return XR_ERROR_SIZE_INSUFFICIENT;
    XrPosef base;
    bool tracked;
    space_in_stage((space *)info->space, info->displayTime, &base, &tracked);
    XrPosef head = from_axr(axr_device_motion(AXR_HEAD, info->displayTime).pose);
    axr_views v = axr_current_views();
    XrPosef head_in_base = pmul(pinv(base), head);
    for (int e = 0; e < 2; e++) {
        views[e].pose = pmul(head_in_base, from_axr(v.eye_in_head[e]));
        views[e].fov = (XrFovf){v.fov[e][0], v.fov[e][1], v.fov[e][2], v.fov[e][3]};
    }
    state->viewStateFlags = XR_VIEW_STATE_ORIENTATION_VALID_BIT | XR_VIEW_STATE_POSITION_VALID_BIT;
    if (axr_backend_connected())
        state->viewStateFlags |= XR_VIEW_STATE_ORIENTATION_TRACKED_BIT | XR_VIEW_STATE_POSITION_TRACKED_BIT;
    return XR_SUCCESS;
}

// ----------------------------------------------------------------------------------- swapchains

static const int64_t g_formats[] = {
    MTLPixelFormatRGBA8Unorm_sRGB, MTLPixelFormatBGRA8Unorm_sRGB, MTLPixelFormatRGBA8Unorm, MTLPixelFormatBGRA8Unorm,
    MTLPixelFormatRGBA16Float,     MTLPixelFormatDepth32Float,    MTLPixelFormatDepth16Unorm,
    MTLPixelFormatDepth32Float_Stencil8,
};
#define FORMAT_COUNT (sizeof g_formats / sizeof g_formats[0])

static const int64_t g_vk_formats[] = {
    VK_FORMAT_R8G8B8A8_SRGB, VK_FORMAT_B8G8R8A8_SRGB, VK_FORMAT_R8G8B8A8_UNORM, VK_FORMAT_B8G8R8A8_UNORM,
    VK_FORMAT_R16G16B16A16_SFLOAT, VK_FORMAT_D32_SFLOAT, VK_FORMAT_D16_UNORM, VK_FORMAT_D32_SFLOAT_S8_UINT,
};
_Static_assert(sizeof g_vk_formats == sizeof g_formats, "one Vulkan format per Metal one");

static XrResult xrEnumerateSwapchainFormats_(XrSession h, uint32_t cap, uint32_t *n, int64_t *out) {
    CHECK_HANDLE(h, session, MAGIC_SESSION);
    const int64_t *f = ((session *)h)->vulkan ? g_vk_formats : g_formats;
    TWO_CALL(cap, n, out, f, FORMAT_COUNT, out[i_] = f[i_]);
    return XR_SUCCESS;
}

static XrResult xrCreateSwapchain_(XrSession h, const XrSwapchainCreateInfo *info, XrSwapchain *out) {
    CHECK_HANDLE(h, session, MAGIC_SESSION);
    session *s = (session *)h;
    const int64_t *f = s->vulkan ? g_vk_formats : g_formats;
    bool known = false;
    for (size_t i = 0; i < FORMAT_COUNT; i++) known |= f[i] == info->format;
    if (!known) return XR_ERROR_SWAPCHAIN_FORMAT_UNSUPPORTED;
    if (info->sampleCount > 1 || info->faceCount != 1) return XR_ERROR_FEATURE_UNSUPPORTED;
    if (s->vulkan) {
        swapchain *sc = calloc(1, sizeof *sc);
        sc->magic = MAGIC_SWAPCHAIN;
        sc->sess = s;
        sc->info = *info;
        sc->count = 3;
        sc->released = -1;
        for (uint32_t i = 0; i < sc->count; i++) {
            sc->images[i] = axr_vk_create_image(s->vk_device, info, &sc->vk_images[i], &sc->vk_memory[i]);
            if (!sc->images[i]) {
                for (uint32_t j = 0; j < i; j++) {
                    sc->images[j] = nil;
                    axr_vk_destroy_image(s->vk_device, sc->vk_images[j], sc->vk_memory[j]);
                }
                free(sc);
                return XR_ERROR_RUNTIME_FAILURE;
            }
        }
        *out = (XrSwapchain)sc;
        return XR_SUCCESS;
    }
    MTLTextureDescriptor *d = [MTLTextureDescriptor new];
    d.pixelFormat = (MTLPixelFormat)info->format;
    d.width = info->width;
    d.height = info->height;
    d.mipmapLevelCount = info->mipCount ?: 1;
    d.textureType = info->arraySize > 1 ? MTLTextureType2DArray : MTLTextureType2D;
    d.arrayLength = info->arraySize ?: 1;
    d.storageMode = MTLStorageModePrivate;
    d.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    if (info->usageFlags & XR_SWAPCHAIN_USAGE_UNORDERED_ACCESS_BIT) d.usage |= MTLTextureUsageShaderWrite;
    if (info->usageFlags & XR_SWAPCHAIN_USAGE_MUTABLE_FORMAT_BIT) d.usage |= MTLTextureUsagePixelFormatView;
    swapchain *sc = calloc(1, sizeof *sc);
    sc->magic = MAGIC_SWAPCHAIN;
    sc->sess = (session *)h;
    sc->info = *info;
    sc->count = 3;
    sc->released = -1;
    for (uint32_t i = 0; i < sc->count; i++) {
        sc->images[i] = [axr_metal_device() newTextureWithDescriptor:d];
        if (!sc->images[i]) {
            for (uint32_t j = 0; j < i; j++) sc->images[j] = nil;
            free(sc);
            return XR_ERROR_OUT_OF_MEMORY;
        }
    }
    *out = (XrSwapchain)sc;
    return XR_SUCCESS;
}

static XrResult xrDestroySwapchain_(XrSwapchain h) {
    CHECK_HANDLE(h, swapchain, MAGIC_SWAPCHAIN);
    swapchain *sc = (swapchain *)h;
    sc->magic = 0;
    for (uint32_t i = 0; i < sc->count; i++) {
        sc->images[i] = nil;
        if (sc->sess->vulkan) axr_vk_destroy_image(sc->sess->vk_device, sc->vk_images[i], sc->vk_memory[i]);
    }
    free(sc);
    return XR_SUCCESS;
}

static XrResult xrEnumerateSwapchainImages_(XrSwapchain h, uint32_t cap, uint32_t *n, XrSwapchainImageBaseHeader *out) {
    CHECK_HANDLE(h, swapchain, MAGIC_SWAPCHAIN);
    swapchain *sc = (swapchain *)h;
    if (sc->sess->vulkan) {
        XrSwapchainImageVulkanKHR *vimg = (XrSwapchainImageVulkanKHR *)out;
        TWO_CALL(cap, n, out, x, sc->count, {
            if (vimg[i_].type != XR_TYPE_SWAPCHAIN_IMAGE_VULKAN_KHR) return XR_ERROR_VALIDATION_FAILURE;
            vimg[i_].image = sc->vk_images[i_];
        });
        return XR_SUCCESS;
    }
    XrSwapchainImageMetalKHR *img = (XrSwapchainImageMetalKHR *)out;
    TWO_CALL(cap, n, out, x, sc->count, {
        if (img[i_].type != XR_TYPE_SWAPCHAIN_IMAGE_METAL_KHR) return XR_ERROR_VALIDATION_FAILURE;
        img[i_].texture = (__bridge void *)sc->images[i_];
    });
    return XR_SUCCESS;
}

static XrResult xrAcquireSwapchainImage_(XrSwapchain h, const XrSwapchainImageAcquireInfo *info, uint32_t *index) {
    CHECK_HANDLE(h, swapchain, MAGIC_SWAPCHAIN);
    (void)info;
    swapchain *sc = (swapchain *)h;
    if (sc->acquired_count >= sc->count) return XR_ERROR_CALL_ORDER_INVALID;
    *index = sc->next;
    sc->acquired[sc->acquired_count++] = sc->next;
    sc->next = (sc->next + 1) % sc->count;
    return XR_SUCCESS;
}

static XrResult xrWaitSwapchainImage_(XrSwapchain h, const XrSwapchainImageWaitInfo *info) {
    CHECK_HANDLE(h, swapchain, MAGIC_SWAPCHAIN);
    (void)info;
    return ((swapchain *)h)->acquired_count ? XR_SUCCESS : XR_ERROR_CALL_ORDER_INVALID;
}

static XrResult xrReleaseSwapchainImage_(XrSwapchain h, const XrSwapchainImageReleaseInfo *info) {
    CHECK_HANDLE(h, swapchain, MAGIC_SWAPCHAIN);
    (void)info;
    swapchain *sc = (swapchain *)h;
    if (!sc->acquired_count) return XR_ERROR_CALL_ORDER_INVALID;
    sc->released = (int32_t)sc->acquired[0];
    memmove(sc->acquired, sc->acquired + 1, --sc->acquired_count * sizeof sc->acquired[0]);
    return XR_SUCCESS;
}

// ----------------------------------------------------------------------------------- frames

static XrResult xrWaitFrame_(XrSession h, const XrFrameWaitInfo *info, XrFrameState *st) {
    CHECK_HANDLE(h, session, MAGIC_SESSION);
    (void)info;
    session *s = (session *)h;
    if (!s->running) return XR_ERROR_SESSION_NOT_RUNNING;
    st->predictedDisplayTime = axr_wait_frame();
    st->predictedDisplayPeriod = (XrDuration)(1e9 / axr_refresh_hz());
    st->shouldRender = s->state == XR_SESSION_STATE_VISIBLE || s->state == XR_SESSION_STATE_FOCUSED;
    return XR_SUCCESS;
}

static XrResult xrBeginFrame_(XrSession h, const XrFrameBeginInfo *info) {
    CHECK_HANDLE(h, session, MAGIC_SESSION);
    (void)info;
    return ((session *)h)->running ? XR_SUCCESS : XR_ERROR_SESSION_NOT_RUNNING;
}

static XrResult xrEndFrame_(XrSession h, const XrFrameEndInfo *info) {
    CHECK_HANDLE(h, session, MAGIC_SESSION);
    session *s = (session *)h;
    if (!s->running) return XR_ERROR_SESSION_NOT_RUNNING;
    if (info->displayTime <= 0) return XR_ERROR_TIME_INVALID;
    if (info->environmentBlendMode != XR_ENVIRONMENT_BLEND_MODE_OPAQUE) return XR_ERROR_ENVIRONMENT_BLEND_MODE_UNSUPPORTED;
    // The stream carries one picture per eye, so the first stereo projection layer is it.
    for (uint32_t i = 0; i < info->layerCount; i++) {
        const XrCompositionLayerBaseHeader *l = info->layers[i];
        if (!l || l->type != XR_TYPE_COMPOSITION_LAYER_PROJECTION) continue;
        const XrCompositionLayerProjection *p = (const XrCompositionLayerProjection *)l;
        if (p->viewCount != 2) return XR_ERROR_VALIDATION_FAILURE;
        axr_eye_image eyes[2];
        for (int e = 0; e < 2; e++) {
            const XrSwapchainSubImage *sub = &p->views[e].subImage;
            CHECK_HANDLE(sub->swapchain, swapchain, MAGIC_SWAPCHAIN);
            swapchain *sc = (swapchain *)sub->swapchain;
            if (sc->released < 0) return XR_ERROR_LAYER_INVALID;
            eyes[e] = (axr_eye_image){sc->images[sc->released], sub->imageArrayIndex, sub->imageRect.offset.x,
                                      sub->imageRect.offset.y, sub->imageRect.extent.width, sub->imageRect.extent.height};
        }
        axr_submit(info->displayTime, eyes, s->queue);
        break;
    }
    return XR_SUCCESS;
}

// ------------------------------------------------------------------------------------- actions
//
// ALVR presents every controller as a Quest Touch controller and names its inputs with the
// OpenXR paths themselves, so a binding path is looked up in ALVR's input table directly.

static NSString *const kTouch = @"/interaction_profiles/oculus/touch_controller";
static NSString *const kSimple = @"/interaction_profiles/khr/simple_controller";

static XrResult xrCreateActionSet_(XrInstance h, const XrActionSetCreateInfo *info, XrActionSet *out) {
    CHECK_HANDLE(h, instance, MAGIC_INSTANCE);
    action_set *as = calloc(1, sizeof *as);
    as->magic = MAGIC_ACTIONSET;
    snprintf(as->name, sizeof as->name, "%s", info->actionSetName);
    *out = (XrActionSet)as;
    return XR_SUCCESS;
}

static XrResult xrDestroyActionSet_(XrActionSet h) {
    CHECK_HANDLE(h, action_set, MAGIC_ACTIONSET);
    ((action_set *)h)->magic = 0;   // its actions may still be referenced by a session; leak them
    return XR_SUCCESS;
}

static XrResult xrCreateAction_(XrActionSet h, const XrActionCreateInfo *info, XrAction *out) {
    CHECK_HANDLE(h, action_set, MAGIC_ACTIONSET);
    action_set *as = (action_set *)h;
    if (as->attached) return XR_ERROR_ACTIONSETS_ALREADY_ATTACHED;
    action *a = calloc(1, sizeof *a);
    a->magic = MAGIC_ACTION;
    a->set = as;
    a->type = info->actionType;
    snprintf(a->name, sizeof a->name, "%s", info->actionName);
    a->bindings = [NSMutableArray array];
    CFRetain((__bridge CFTypeRef)a->bindings);
    *out = (XrAction)a;
    return XR_SUCCESS;
}

static XrResult xrDestroyAction_(XrAction h) {
    CHECK_HANDLE(h, action, MAGIC_ACTION);
    ((action *)h)->magic = 0;
    return XR_SUCCESS;
}

static XrResult xrSuggestInteractionProfileBindings_(XrInstance h, const XrInteractionProfileSuggestedBinding *sb) {
    CHECK_HANDLE(h, instance, MAGIC_INSTANCE);
    instance *inst = (instance *)h;
    NSString *profile = path_string(sb->interactionProfile);
    if (!profile) return XR_ERROR_PATH_INVALID;
    NSMutableArray *list = [NSMutableArray array];
    for (uint32_t i = 0; i < sb->countSuggestedBindings; i++) {
        CHECK_HANDLE(sb->suggestedBindings[i].action, action, MAGIC_ACTION);
        NSString *b = path_string(sb->suggestedBindings[i].binding);
        if (!b) return XR_ERROR_PATH_INVALID;
        [list addObject:@[ [NSValue valueWithPointer:sb->suggestedBindings[i].action], b ]];
    }
    pthread_mutex_lock(&g_lock);
    inst->suggested[profile] = list;
    pthread_mutex_unlock(&g_lock);
    return XR_SUCCESS;
}

// A simple-controller path in Touch terms.
static NSString *from_simple(NSString *b) {
    b = [b stringByReplacingOccurrencesOfString:@"/input/select/click" withString:@"/input/trigger/value"];
    return b;
}

static XrResult xrAttachSessionActionSets_(XrSession h, const XrSessionActionSetsAttachInfo *info) {
    CHECK_HANDLE(h, session, MAGIC_SESSION);
    session *s = (session *)h;
    if (s->action_sets.count) return XR_ERROR_ACTIONSETS_ALREADY_ATTACHED;
    pthread_mutex_lock(&g_lock);
    NSDictionary *sug = s->inst->suggested;
    NSString *profile = sug[kTouch] ? kTouch : sug[kSimple] ? kSimple : nil;
    for (uint32_t i = 0; i < info->countActionSets; i++) {
        action_set *as = (action_set *)info->actionSets[i];
        if (!as || as->magic != MAGIC_ACTIONSET) { pthread_mutex_unlock(&g_lock); return XR_ERROR_HANDLE_INVALID; }
        as->attached = true;
        [s->action_sets addObject:[NSValue valueWithPointer:as]];
    }
    for (NSArray *pair in sug[profile]) {
        action *a = [pair[0] pointerValue];
        NSString *b = pair[1];
        [a->bindings addObject:profile == kSimple ? from_simple(b) : b];
    }
    s->profile = profile ? path_for(profile) : XR_NULL_PATH;
    pthread_mutex_unlock(&g_lock);
    axr_log("actions attached, profile %s", profile ? profile.UTF8String : "(none suggested)");
    if (profile) {
        for (NSString *hand in @[ @"/user/hand/left", @"/user/hand/right" ]) {
            XrEventDataInteractionProfileChanged ev = {XR_TYPE_EVENT_DATA_INTERACTION_PROFILE_CHANGED, NULL, h};
            (void)hand;
            push_event(&ev, sizeof ev);
            break;
        }
    }
    return XR_SUCCESS;
}

static XrResult xrGetCurrentInteractionProfile_(XrSession h, XrPath top, XrInteractionProfileState *st) {
    CHECK_HANDLE(h, session, MAGIC_SESSION);
    session *s = (session *)h;
    NSString *t = path_string(top);
    if (!t) return XR_ERROR_PATH_INVALID;
    if (!s->action_sets.count) return XR_ERROR_ACTIONSET_NOT_ATTACHED;
    st->interactionProfile = [t hasPrefix:@"/user/hand/"] ? s->profile : XR_NULL_PATH;
    return XR_SUCCESS;
}

static int sub_of(NSString *binding) {
    if ([binding hasPrefix:@"/user/hand/left/"]) return SUB_LEFT;
    if ([binding hasPrefix:@"/user/hand/right/"]) return SUB_RIGHT;
    return SUB_NONE;
}

static int sub_of_path(XrPath p, bool *ok) {
    *ok = true;
    if (p == XR_NULL_PATH) return SUB_NONE;
    NSString *s = path_string(p);
    if ([s isEqualToString:@"/user/hand/left"]) return SUB_LEFT;
    if ([s isEqualToString:@"/user/hand/right"]) return SUB_RIGHT;
    *ok = false;
    return SUB_NONE;
}

static bool read_input(NSString *path, float *v) { return axr_input(path.UTF8String, v); }

// One binding's value: (x, y), with y only meaningful for vector2 actions.
static bool binding_value(NSString *b, XrActionType type, float out[2]) {
    out[0] = out[1] = 0;
    if (type == XR_ACTION_TYPE_VECTOR2F_INPUT) {
        bool ok = read_input([b stringByAppendingString:@"/x"], &out[0]);
        ok |= read_input([b stringByAppendingString:@"/y"], &out[1]);
        return ok;
    }
    NSString *last = b.lastPathComponent;
    bool component = [@[ @"click", @"touch", @"value", @"force", @"x", @"y" ] containsObject:last];
    NSArray *tries = component ? @[ b ]
                               : (type == XR_ACTION_TYPE_BOOLEAN_INPUT
                                      ? @[ [b stringByAppendingString:@"/click"], [b stringByAppendingString:@"/value"] ]
                                      : @[ [b stringByAppendingString:@"/value"], [b stringByAppendingString:@"/click"] ]);
    for (NSString *p in tries) {
        if (read_input(p, &out[0])) {
            if (type == XR_ACTION_TYPE_BOOLEAN_INPUT) out[0] = out[0] > 0.5f ? 1 : 0;
            return true;
        }
    }
    return false;
}

static XrResult xrSyncActions_(XrSession h, const XrActionsSyncInfo *info) {
    CHECK_HANDLE(h, session, MAGIC_SESSION);
    session *s = (session *)h;
    if (!s->action_sets.count) return XR_ERROR_ACTIONSET_NOT_ATTACHED;
    if (s->state != XR_SESSION_STATE_FOCUSED) return XR_SESSION_NOT_FOCUSED;
    XrTime now = axr_now_ns();
    bool connected = axr_backend_connected();
    for (uint32_t i = 0; i < info->countActiveActionSets; i++) {
        action_set *as = (action_set *)info->activeActionSets[i].actionSet;
        if (!as || as->magic != MAGIC_ACTIONSET) return XR_ERROR_HANDLE_INVALID;
        if (!as->attached) return XR_ERROR_ACTIONSET_NOT_ATTACHED;
    }
    // Every attached action whose set was named; actions are found through the suggestions.
    NSMutableSet *done = [NSMutableSet set];
    for (NSArray *list in s->inst->suggested.allValues) {
        for (NSArray *pair in list) {
            action *a = [pair[0] pointerValue];
            if ([done containsObject:pair[0]] || a->magic != MAGIC_ACTION) continue;
            [done addObject:pair[0]];
            bool synced = false;
            for (uint32_t i = 0; i < info->countActiveActionSets; i++)
                synced |= (action_set *)info->activeActionSets[i].actionSet == a->set;
            if (!synced || a->type == XR_ACTION_TYPE_POSE_INPUT || a->type == XR_ACTION_TYPE_VIBRATION_OUTPUT) {
                for (int u = 0; u < SUB_COUNT; u++) {
                    a->active[u] = synced && connected && a->bindings.count > 0;
                    a->changed[u] = false;
                }
                continue;
            }
            float v[SUB_COUNT][2] = {{0}};
            bool any[SUB_COUNT] = {0};
            for (NSString *b in a->bindings) {
                float bv[2];
                if (!binding_value(b, a->type, bv)) continue;
                int u = sub_of(b);
                for (int k = 0; k < 2; k++) {
                    // Several bindings combine: the larger magnitude wins.
                    if (fabsf(bv[k]) > fabsf(v[u][k])) v[u][k] = bv[k];
                    if (fabsf(bv[k]) > fabsf(v[SUB_NONE][k])) v[SUB_NONE][k] = bv[k];
                }
                any[u] = any[SUB_NONE] = true;
            }
            for (int u = 0; u < SUB_COUNT; u++) {
                bool was = a->active[u];
                a->changed[u] = was && any[u] && (v[u][0] != a->value[u][0] || v[u][1] != a->value[u][1]);
                if (a->changed[u] || (any[u] && !was)) a->change_time[u] = now;
                a->active[u] = any[u];
                a->value[u][0] = v[u][0];
                a->value[u][1] = v[u][1];
            }
        }
    }
    return XR_SUCCESS;
}

static action *state_action(const XrActionStateGetInfo *info, XrActionType want, int *u, XrResult *err) {
    action *a = (action *)info->action;
    if (!a || a->magic != MAGIC_ACTION) { *err = XR_ERROR_HANDLE_INVALID; return NULL; }
    if (a->type != want) { *err = XR_ERROR_ACTION_TYPE_MISMATCH; return NULL; }
    if (!a->set->attached) { *err = XR_ERROR_ACTIONSET_NOT_ATTACHED; return NULL; }
    bool ok;
    *u = sub_of_path(info->subactionPath, &ok);
    if (!ok) { *err = XR_ERROR_PATH_UNSUPPORTED; return NULL; }
    return a;
}

static XrResult xrGetActionStateBoolean_(XrSession h, const XrActionStateGetInfo *info, XrActionStateBoolean *st) {
    CHECK_HANDLE(h, session, MAGIC_SESSION);
    int u;
    XrResult err;
    action *a = state_action(info, XR_ACTION_TYPE_BOOLEAN_INPUT, &u, &err);
    if (!a) return err;
    st->currentState = a->value[u][0] > 0.5f;
    st->changedSinceLastSync = a->changed[u];
    st->lastChangeTime = a->change_time[u];
    st->isActive = a->active[u];
    return XR_SUCCESS;
}

static XrResult xrGetActionStateFloat_(XrSession h, const XrActionStateGetInfo *info, XrActionStateFloat *st) {
    CHECK_HANDLE(h, session, MAGIC_SESSION);
    int u;
    XrResult err;
    action *a = state_action(info, XR_ACTION_TYPE_FLOAT_INPUT, &u, &err);
    if (!a) return err;
    st->currentState = a->value[u][0];
    st->changedSinceLastSync = a->changed[u];
    st->lastChangeTime = a->change_time[u];
    st->isActive = a->active[u];
    return XR_SUCCESS;
}

static XrResult xrGetActionStateVector2f_(XrSession h, const XrActionStateGetInfo *info, XrActionStateVector2f *st) {
    CHECK_HANDLE(h, session, MAGIC_SESSION);
    int u;
    XrResult err;
    action *a = state_action(info, XR_ACTION_TYPE_VECTOR2F_INPUT, &u, &err);
    if (!a) return err;
    st->currentState = (XrVector2f){a->value[u][0], a->value[u][1]};
    st->changedSinceLastSync = a->changed[u];
    st->lastChangeTime = a->change_time[u];
    st->isActive = a->active[u];
    return XR_SUCCESS;
}

static XrResult xrGetActionStatePose_(XrSession h, const XrActionStateGetInfo *info, XrActionStatePose *st) {
    CHECK_HANDLE(h, session, MAGIC_SESSION);
    int u;
    XrResult err;
    action *a = state_action(info, XR_ACTION_TYPE_POSE_INPUT, &u, &err);
    if (!a) return err;
    st->isActive = a->active[u];
    return XR_SUCCESS;
}

static XrResult xrCreateActionSpace_(XrSession h, const XrActionSpaceCreateInfo *info, XrSpace *out) {
    CHECK_HANDLE(h, session, MAGIC_SESSION);
    CHECK_HANDLE(info->action, action, MAGIC_ACTION);
    action *a = (action *)info->action;
    if (a->type != XR_ACTION_TYPE_POSE_INPUT) return XR_ERROR_ACTION_TYPE_MISMATCH;
    bool ok;
    int u = sub_of_path(info->subactionPath, &ok);
    if (!ok) return XR_ERROR_PATH_UNSUPPORTED;
    // The hand comes from the subaction path, or else from where the action is bound.
    int hand = u == SUB_LEFT ? AXR_LEFT : u == SUB_RIGHT ? AXR_RIGHT : AXR_RIGHT;
    bool aim = false;
    for (NSString *b in a->bindings) {
        int bu = sub_of(b);
        if (u != SUB_NONE && bu != u) continue;
        hand = bu == SUB_LEFT ? AXR_LEFT : AXR_RIGHT;
        aim = [b hasSuffix:@"/aim/pose"];
        break;
    }
    // TODO: ALVR reports the controller's grip; aim is the same pose until its offset is measured.
    return new_space((session *)h, (space){.kind = SPACE_ACTION, .act = a, .hand = hand, .aim = aim,
                                           .offset = info->poseInActionSpace}, out);
}

static XrResult xrApplyHapticFeedback_(XrSession h, const XrHapticActionInfo *info, const XrHapticBaseHeader *hap) {
    CHECK_HANDLE(h, session, MAGIC_SESSION);
    CHECK_HANDLE(info->action, action, MAGIC_ACTION);
    action *a = (action *)info->action;
    if (a->type != XR_ACTION_TYPE_VIBRATION_OUTPUT) return XR_ERROR_ACTION_TYPE_MISMATCH;
    if (hap->type != XR_TYPE_HAPTIC_VIBRATION) return XR_ERROR_VALIDATION_FAILURE;
    const XrHapticVibration *vib = (const XrHapticVibration *)hap;
    bool ok;
    int u = sub_of_path(info->subactionPath, &ok);
    if (!ok) return XR_ERROR_PATH_UNSUPPORTED;
    float duration = vib->duration <= 0 ? 0.05f : vib->duration / 1e9f;
    float freq = vib->frequency <= 0 ? 160.0f : vib->frequency;
    for (NSString *b in a->bindings) {
        int bu = sub_of(b);
        if (u != SUB_NONE && bu != u) continue;
        axr_haptics(bu == SUB_LEFT ? AXR_LEFT : AXR_RIGHT, duration, freq, vib->amplitude);
    }
    return XR_SUCCESS;
}

static XrResult xrStopHapticFeedback_(XrSession h, const XrHapticActionInfo *info) {
    CHECK_HANDLE(h, session, MAGIC_SESSION);
    CHECK_HANDLE(info->action, action, MAGIC_ACTION);
    action *a = (action *)info->action;
    for (NSString *b in a->bindings) axr_haptics(sub_of(b) == SUB_LEFT ? AXR_LEFT : AXR_RIGHT, 0, 160, 0);
    return XR_SUCCESS;
}

static XrResult xrEnumerateBoundSourcesForAction_(XrSession h, const XrBoundSourcesForActionEnumerateInfo *info,
                                                  uint32_t cap, uint32_t *n, XrPath *out) {
    CHECK_HANDLE(h, session, MAGIC_SESSION);
    CHECK_HANDLE(info->action, action, MAGIC_ACTION);
    action *a = (action *)info->action;
    if (!a->set->attached) return XR_ERROR_ACTIONSET_NOT_ATTACHED;
    TWO_CALL(cap, n, out, x, a->bindings.count, out[i_] = path_for(a->bindings[i_]));
    return XR_SUCCESS;
}

static XrResult xrGetInputSourceLocalizedName_(XrSession h, const XrInputSourceLocalizedNameGetInfo *info,
                                               uint32_t cap, uint32_t *n, char *buf) {
    CHECK_HANDLE(h, session, MAGIC_SESSION);
    NSString *p = path_string(info->sourcePath);
    if (!p) return XR_ERROR_PATH_INVALID;
    NSMutableArray *parts = [NSMutableArray array];
    if (info->whichComponents & XR_INPUT_SOURCE_LOCALIZED_NAME_USER_PATH_BIT)
        [parts addObject:[p containsString:@"/left"] ? @"Left Hand" : @"Right Hand"];
    if (info->whichComponents & XR_INPUT_SOURCE_LOCALIZED_NAME_INTERACTION_PROFILE_BIT)
        [parts addObject:@"PS VR2 Sense (as Touch)"];
    if (info->whichComponents & XR_INPUT_SOURCE_LOCALIZED_NAME_COMPONENT_BIT)
        [parts addObject:[p componentsSeparatedByString:@"/input/"].lastObject ?: p];
    return copy_string([parts componentsJoinedByString:@" "].UTF8String, cap, n, buf);
}

// ------------------------------------------------------------------------------------ dispatch

#define FUNCTIONS(X)                                                                                      \
    X(xrEnumerateInstanceExtensionProperties) X(xrCreateInstance) X(xrDestroyInstance)                    \
    X(xrGetInstanceProperties) X(xrPollEvent) X(xrResultToString) X(xrStructureTypeToString)              \
    X(xrGetSystem) X(xrGetSystemProperties) X(xrEnumerateEnvironmentBlendModes) X(xrCreateSession)        \
    X(xrDestroySession) X(xrEnumerateReferenceSpaces) X(xrCreateReferenceSpace)                           \
    X(xrGetReferenceSpaceBoundsRect) X(xrCreateActionSpace) X(xrLocateSpace) X(xrDestroySpace)            \
    X(xrEnumerateViewConfigurations) X(xrGetViewConfigurationProperties)                                  \
    X(xrEnumerateViewConfigurationViews) X(xrEnumerateSwapchainFormats) X(xrCreateSwapchain)              \
    X(xrDestroySwapchain) X(xrEnumerateSwapchainImages) X(xrAcquireSwapchainImage)                        \
    X(xrWaitSwapchainImage) X(xrReleaseSwapchainImage) X(xrBeginSession) X(xrEndSession)                  \
    X(xrRequestExitSession) X(xrWaitFrame) X(xrBeginFrame) X(xrEndFrame) X(xrLocateViews)                 \
    X(xrStringToPath) X(xrPathToString) X(xrCreateActionSet) X(xrDestroyActionSet) X(xrCreateAction)      \
    X(xrDestroyAction) X(xrSuggestInteractionProfileBindings) X(xrAttachSessionActionSets)                \
    X(xrGetCurrentInteractionProfile) X(xrGetActionStateBoolean) X(xrGetActionStateFloat)                 \
    X(xrGetActionStateVector2f) X(xrGetActionStatePose) X(xrSyncActions)                                  \
    X(xrEnumerateBoundSourcesForAction) X(xrGetInputSourceLocalizedName) X(xrApplyHapticFeedback)         \
    X(xrStopHapticFeedback) X(xrGetMetalGraphicsRequirementsKHR) X(xrConvertTimespecTimeToTimeKHR)        \
    X(xrConvertTimeToTimespecTimeKHR) X(xrGetVulkanGraphicsRequirementsKHR) X(xrGetVulkanGraphicsRequirements2KHR)   \
    X(xrGetVulkanInstanceExtensionsKHR) X(xrGetVulkanDeviceExtensionsKHR) X(xrGetVulkanGraphicsDeviceKHR)  \
    X(xrGetVulkanGraphicsDevice2KHR) X(xrCreateVulkanInstanceKHR) X(xrCreateVulkanDeviceKHR)

static XrResult xrGetInstanceProcAddr_(XrInstance inst, const char *name, PFN_xrVoidFunction *fn);

static XrResult xrGetInstanceProcAddr_(XrInstance inst, const char *name, PFN_xrVoidFunction *fn) {
    if (!name || !fn) return XR_ERROR_VALIDATION_FAILURE;
    *fn = NULL;
    // Without an instance only these three may be looked up.
    if (!inst && strcmp(name, "xrEnumerateInstanceExtensionProperties") && strcmp(name, "xrCreateInstance") &&
        strcmp(name, "xrEnumerateApiLayerProperties"))
        return XR_ERROR_HANDLE_INVALID;
    if (!strcmp(name, "xrGetInstanceProcAddr")) { *fn = (PFN_xrVoidFunction)xrGetInstanceProcAddr_; return XR_SUCCESS; }
#define LOOKUP(f) if (!strcmp(name, #f)) { *fn = (PFN_xrVoidFunction)f##_; return XR_SUCCESS; }
    FUNCTIONS(LOOKUP)
    return XR_ERROR_FUNCTION_UNSUPPORTED;
}

EXPORT XrResult xrNegotiateLoaderRuntimeInterface(const XrNegotiateLoaderInfo *loader, XrNegotiateRuntimeRequest *req) {
    if (!loader || !req || loader->structType != XR_LOADER_INTERFACE_STRUCT_LOADER_INFO ||
        req->structType != XR_LOADER_INTERFACE_STRUCT_RUNTIME_REQUEST)
        return XR_ERROR_INITIALIZATION_FAILED;
    if (loader->minInterfaceVersion > XR_CURRENT_LOADER_RUNTIME_VERSION ||
        loader->maxInterfaceVersion < XR_CURRENT_LOADER_RUNTIME_VERSION)
        return XR_ERROR_INITIALIZATION_FAILED;
    req->runtimeInterfaceVersion = XR_CURRENT_LOADER_RUNTIME_VERSION;
    req->runtimeApiVersion = XR_CURRENT_API_VERSION;
    req->getInstanceProcAddr = xrGetInstanceProcAddr_;
    return XR_SUCCESS;
}
