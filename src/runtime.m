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
#include "alvrxr_ext.h"
#include "compositor.h"
#include "transport.h"
#include "tracking.h"

extern unsigned axr_stat_wait, axr_stat_end, axr_stat_projection;   // backend.m's frame summary
extern unsigned axr_stat_syncs, axr_stat_unfocused_syncs, axr_stat_pressed;

#define EXPORT __attribute__((visibility("default")))

// ------------------------------------------------------------------------------------ handles

enum { MAGIC_INSTANCE = 0x41585249, MAGIC_SESSION, MAGIC_SPACE, MAGIC_SWAPCHAIN, MAGIC_ACTIONSET, MAGIC_ACTION, MAGIC_HAND };

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
    // OpenComposite's double press detection counts a press on every read, and Unity reads each
    // action once per input source, so one press made a double. For those actions a change is
    // reported to the first read after a sync only.
    bool once_per_sync, change_read;
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
    XrPosef offset;
} space;

struct session {
    uint32_t magic;
    instance *inst;
    id<MTLCommandQueue> queue;
    axr_slots *slots;                        // every frame is composed into one of these
    bool vulkan;
    VkDevice vk_device;
    XrSessionState state;
    bool running, exit_requested;
    bool lost;                               // LOSS_PENDING sent: no further state changes
    NSMutableArray<NSValue *> *action_sets;
    XrPath profile;                          // active interaction profile
    XrPosef local;                           // LOCAL's origin in STAGE
    bool local_from_headset;
    uint32_t recenter_seen;                  // axr_recenter_generation() when LOCAL was last taken
    // Images a D3D11 bridge shares rather than copies (wineopenxr on DXMT; see
    // xrSetSwapchainImagesALVRXR): the GPU waits for each one's fence before the next frame reads
    // it, and signals it once that frame is done with it.
    struct {
        swapchain *sc;
        uint32_t index;
        id<MTLSharedEvent> __strong event;
        uint64_t wait, signal;
        bool waited;
    } fences[16];
    uint32_t fence_count;
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

// ---- focus from the compositor
// The compositor decides who has the headset; the session follows with the state machine's own
// steps, one event per step, never skipping a state: FOCUSED <-> VISIBLE <-> SYNCHRONIZED.

// NULL (no slots yet) means always FOCUSED.
static axr_slots *session_slots(session *s) {
    return s->slots;
}

// vapord's own session (MacVapoR sets ALVRXR_HOME for it): the one the system button and the
// private functions (alvrxr_ext.h) belong to.
static bool is_home(void) {
    static int home = -1;
    if (home < 0) home = getenv("ALVRXR_HOME") != NULL;
    return home;
}

// TEST ONLY: ALVRXR_TEST_FOCUS_FILE holds "focus [should_render [exit_request]]" (AXR_FOCUS_*
// 0/1/2) and overrides the compositor's answer, so a driver can flip focus without a compositor.
static bool g_test_exit;
static bool test_focus_override(uint32_t *focus, bool *render) {
    static const char *path;
    static int init;
    static uint64_t checked;
    static uint32_t f = AXR_FOCUS_FOCUSED;
    static bool r = true, have;
    if (!init) { init = 1; path = getenv("ALVRXR_TEST_FOCUS_FILE"); }
    if (!path) return false;
    uint64_t now = (uint64_t)axr_now_ns();
    if (now - checked > 100000000ull) {   // at most every 100 ms
        checked = now;
        FILE *fp = fopen(path, "r");
        unsigned a = 0, b = 1, c = 0;
        if (fp) {
            int n = fscanf(fp, "%u %u %u", &a, &b, &c);
            fclose(fp);
            if (n >= 1) { f = a > AXR_FOCUS_FOCUSED ? AXR_FOCUS_FOCUSED : a; r = n < 2 || b; g_test_exit = n >= 3 && c; have = true; }
        }
    }
    if (!have) return false;
    *focus = f;
    *render = r;
    return true;
}

// The compositor asked the session to end (the dashboard's quit): exit_request in its region.
static bool exit_requested_by_compositor(session *s) {
    uint32_t focus;
    bool render;
    if (test_focus_override(&focus, &render)) return g_test_exit;
    axr_slots *slots = session_slots(s);
    return slots && axr_slots_exit_request(slots);
}

// What xrRequestExitSession does, with g_lock held: the app sees the states down to STOPPING and
// ends the session.
static void request_exit(session *s) {
    s->exit_requested = true;
    set_state(s, XR_SESSION_STATE_VISIBLE);
    set_state(s, XR_SESSION_STATE_SYNCHRONIZED);
    set_state(s, XR_SESSION_STATE_STOPPING);
}

static void desired_focus(session *s, uint32_t *focus, bool *render) {
    *focus = AXR_FOCUS_FOCUSED;
    *render = true;
    if (test_focus_override(focus, render)) return;
    axr_slots *slots = session_slots(s);
    if (!slots) return;
    *focus = axr_slots_focus(slots);
    *render = axr_slots_should_render(slots);
}

// Caller holds g_lock. Only while running: before the begin sequence and after the stop
// sequence the state belongs to those functions.
static void follow_focus(session *s) {
    if (!s || !s->running || s->lost || s->exit_requested) return;
    if (s->state != XR_SESSION_STATE_SYNCHRONIZED && s->state != XR_SESSION_STATE_VISIBLE &&
        s->state != XR_SESSION_STATE_FOCUSED) return;
    if (exit_requested_by_compositor(s)) {
        axr_log("the compositor asked the session to end");
        request_exit(s);
        return;
    }
    uint32_t focus;
    bool render;
    desired_focus(s, &focus, &render);
    XrSessionState target = focus >= AXR_FOCUS_FOCUSED ? XR_SESSION_STATE_FOCUSED
                            : focus == AXR_FOCUS_VISIBLE ? XR_SESSION_STATE_VISIBLE : XR_SESSION_STATE_SYNCHRONIZED;
    while (s->state > target) set_state(s, (XrSessionState)(s->state - 1));
    while (s->state < target) set_state(s, (XrSessionState)(s->state + 1));
}

// The compositor has gone and didn't come back: tells the app to destroy the session. Called by
// the compositor client (WP5); the lead declares it in a header. Safe from any thread.
void axr_session_loss_pending(void) {
    pthread_mutex_lock(&g_lock);
    if (g_session && !g_session->lost) {
        g_session->lost = true;
        set_state(g_session, XR_SESSION_STATE_LOSS_PENDING);
    }
    pthread_mutex_unlock(&g_lock);
}

static XrResult xrPollEvent_(XrInstance inst, XrEventDataBuffer *out) {
    CHECK_HANDLE(inst, instance, MAGIC_INSTANCE);
    pthread_mutex_lock(&g_lock);
    follow_focus(g_session);
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
    {XR_TYPE_EXTENSION_PROPERTIES, NULL, XR_EXT_HAND_TRACKING_EXTENSION_NAME, XR_EXT_hand_tracking_SPEC_VERSION},
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
    // Without the compositor flag this is LEGACY whatever happens, and ALVR starts here as it
    // always has; with it, xrGetSystem decides (start_for_mode).
    if (!axr_compositor_flag()) axr_backend_start();
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

// The mode is decided at the first xrGetSystem, not at xrCreateInstance, which OpenComposite
// calls just to probe. A CLIENT starts nothing of its own: vapord has the headset.
static void start_for_mode(void) {
    axr_mode m = axr_mode_init();
    if (m == AXR_MODE_CLIENT) return;
    axr_backend_start();
    static dispatch_once_t once;
    if (m == AXR_MODE_SERVER)
        dispatch_once(&once, ^{
            axr_compositor_start();
            axr_transport_start();
        });
}

static XrResult xrGetSystem_(XrInstance h, const XrSystemGetInfo *info, XrSystemId *out) {
    CHECK_HANDLE(h, instance, MAGIC_INSTANCE);
    if (info->formFactor != XR_FORM_FACTOR_HEAD_MOUNTED_DISPLAY) return XR_ERROR_FORM_FACTOR_UNSUPPORTED;
    start_for_mode();
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
    for (XrBaseOutStructure *n = (XrBaseOutStructure *)p->next; n; n = n->next)
        if (n->type == XR_TYPE_SYSTEM_HAND_TRACKING_PROPERTIES_EXT)
            ((XrSystemHandTrackingPropertiesEXT *)n)->supportsHandTracking = XR_TRUE;
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
    // The compositor takes Metal frames only (v1): a Vulkan game runs the headset itself.
    if (vk && axr_mode_current() == AXR_MODE_CLIENT) {
        axr_mode_force_legacy();
        axr_backend_start();
    }
    pthread_mutex_lock(&g_lock);
    if (g_session) { pthread_mutex_unlock(&g_lock); return XR_ERROR_LIMIT_REACHED; }
    session *s = calloc(1, sizeof *s);
    s->magic = MAGIC_SESSION;
    s->inst = (instance *)h;
    s->queue = queue;
    axr_tracking_reset_session();
    s->slots = axr_slots_open(queue.device, queue);
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

static void signal_fences(session *s, swapchain *sc, int32_t index);

static XrResult xrDestroySession_(XrSession h) {
    CHECK_HANDLE(h, session, MAGIC_SESSION);
    session *s = (session *)h;
    signal_fences(s, NULL, -1);
    pthread_mutex_lock(&g_lock);
    s->magic = 0;
    axr_slots_close(s->slots);
    s->slots = NULL;
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
    if (s->lost) { pthread_mutex_unlock(&g_lock); return XR_SUCCESS; }   // LOSS_PENDING is the last state
    request_exit(s);
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
                                                 XR_REFERENCE_SPACE_TYPE_STAGE, XR_REFERENCE_SPACE_TYPE_LOCAL_FLOOR};
    TWO_CALL(cap, n, out, types, 4, out[i_] = types[i_]);
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
    case XR_REFERENCE_SPACE_TYPE_STAGE:
    case XR_REFERENCE_SPACE_TYPE_LOCAL_FLOOR: break;   // core in OpenXR 1.1
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
// a real pose that is a guess, so it is taken from the first real head pose, and again whenever the
// user recenters (holding the Digital Crown); each time the app is told the space moved.
static XrPosef local_origin(session *s, XrTime t) {
    uint32_t recenter = axr_recenter_generation();
    if (recenter != s->recenter_seen) {
        s->recenter_seen = recenter;
        s->local_from_headset = false;
    }
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

static XrVector3f vsub(XrVector3f a, XrVector3f b) { return (XrVector3f){a.x - b.x, a.y - b.y, a.z - b.z}; }
static XrVector3f vadd(XrVector3f a, XrVector3f b) { return (XrVector3f){a.x + b.x, a.y + b.y, a.z + b.z}; }
static XrVector3f vcross(XrVector3f a, XrVector3f b) {
    return (XrVector3f){a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x};
}

// A space's motion in STAGE: linear velocity of its origin and angular velocity. ALVR reports
// device velocities in its own (STAGE) frame; a space offset from a device moves with its
// rotation too. Reference spaces other than VIEW stand still.
typedef struct {
    XrVector3f linear, angular;
} space_motion;

static int sub_of(NSString *binding);

// Whether an action space follows the aim pose: what its action is bound to now, since apps may
// make their spaces before attaching the bindings (RiftLift does).
static bool space_is_aim(const space *sp) {
    for (NSString *b in sp->act->bindings) {
        int bu = sub_of(b);
        if ((bu == SUB_LEFT ? AXR_LEFT : AXR_RIGHT) != sp->hand) continue;
        return [b hasSuffix:@"/aim/pose"];
    }
    return false;
}

// A space's pose in STAGE, and whether it is tracked right now.
static bool space_in_stage(space *sp, XrTime t, XrPosef *out, bool *tracked, space_motion *motion) {
    *tracked = true;
    if (motion) *motion = (space_motion){0};
    if (sp->kind == SPACE_REFERENCE) {
        XrPosef base = IDENTITY;
        if (sp->ref == XR_REFERENCE_SPACE_TYPE_VIEW) {
            axr_motion head = axr_device_motion(AXR_HEAD, t);
            base = from_axr(head.pose);
            *tracked = (axr_backend_connected() || axr_fake_tracking());
            if (motion) {
                motion->angular = (XrVector3f){head.angular_velocity[0], head.angular_velocity[1], head.angular_velocity[2]};
                motion->linear = vadd((XrVector3f){head.linear_velocity[0], head.linear_velocity[1], head.linear_velocity[2]},
                                      vcross(motion->angular, qrot(base.orientation, sp->offset.position)));
            }
        } else if (sp->ref == XR_REFERENCE_SPACE_TYPE_LOCAL) {
            base = local_origin(sp->sess, t);
        } else if (sp->ref == XR_REFERENCE_SPACE_TYPE_LOCAL_FLOOR) {
            base = local_origin(sp->sess, t);   // LOCAL, dropped to the floor
            base.position.y = 0;
        }
        *out = pmul(base, sp->offset);
        return true;
    }
    axr_motion m = axr_device_motion(sp->hand, t);
    if (!m.valid) return false;
    XrPosef device = from_axr(m.pose);
    if (space_is_aim(sp)) device = pmul(device, from_axr(axr_aim_offset(sp->hand)));
    *out = pmul(device, sp->offset);
    if (motion) {
        motion->angular = (XrVector3f){m.angular_velocity[0], m.angular_velocity[1], m.angular_velocity[2]};
        motion->linear = vadd((XrVector3f){m.linear_velocity[0], m.linear_velocity[1], m.linear_velocity[2]},
                              vcross(motion->angular, qrot(device.orientation, sp->offset.position)));
    }
    return true;
}

// The space's pose, and motion, in the base space's frame. Unity asks for time 0, meaning now.
static XrResult locate(XrSpace hs, XrSpace hb, XrTime t, XrSpaceLocation *loc, XrSpaceVelocity *vel) {
    CHECK_HANDLE(hs, space, MAGIC_SPACE);
    CHECK_HANDLE(hb, space, MAGIC_SPACE);
    if (t < 0) return XR_ERROR_TIME_INVALID;
    if (t == 0) t = axr_now_ns();
    XrPosef a, b;
    bool ta, tb;
    space_motion ma, mb;
    loc->locationFlags = 0;
    if (vel) vel->velocityFlags = 0;
    if (!space_in_stage((space *)hs, t, &a, &ta, &ma) || !space_in_stage((space *)hb, t, &b, &tb, &mb)) {
        loc->pose = IDENTITY;
        return XR_SUCCESS;
    }
    loc->pose = pmul(pinv(b), a);
    loc->locationFlags = XR_SPACE_LOCATION_ORIENTATION_VALID_BIT | XR_SPACE_LOCATION_POSITION_VALID_BIT;
    if (ta && tb) loc->locationFlags |= XR_SPACE_LOCATION_ORIENTATION_TRACKED_BIT | XR_SPACE_LOCATION_POSITION_TRACKED_BIT;
    if (vel && ta && tb) {
        // Relative to a base that may itself move (VIEW), seen in the base's frame.
        XrQuaternionf inv_b = pinv(b).orientation;
        XrVector3f arm = vsub(a.position, b.position);
        vel->linearVelocity = qrot(inv_b, vsub(vsub(ma.linear, mb.linear), vcross(mb.angular, arm)));
        vel->angularVelocity = qrot(inv_b, vsub(ma.angular, mb.angular));
        vel->velocityFlags = XR_SPACE_VELOCITY_LINEAR_VALID_BIT | XR_SPACE_VELOCITY_ANGULAR_VALID_BIT;
    }
    return XR_SUCCESS;
}

static XrResult xrLocateSpace_(XrSpace hs, XrSpace hb, XrTime t, XrSpaceLocation *loc) {
    XrSpaceVelocity *vel = NULL;
    for (XrBaseOutStructure *n = loc->next; n; n = n->next)
        if (n->type == XR_TYPE_SPACE_VELOCITY) vel = (XrSpaceVelocity *)n;
    return locate(hs, hb, t, loc, vel);
}

static XrResult xrLocateSpaces_(XrSession h, const XrSpacesLocateInfo *info, XrSpaceLocations *out) {
    CHECK_HANDLE(h, session, MAGIC_SESSION);
    if (info->spaceCount != out->locationCount) return XR_ERROR_VALIDATION_FAILURE;
    XrSpaceVelocities *vel = NULL;
    for (XrBaseOutStructure *n = (XrBaseOutStructure *)out->next; n; n = n->next)
        if (n->type == XR_TYPE_SPACE_VELOCITIES) vel = (XrSpaceVelocities *)n;
    for (uint32_t i = 0; i < info->spaceCount; i++) {
        XrSpaceLocation loc = {XR_TYPE_SPACE_LOCATION};
        XrSpaceVelocity v = {XR_TYPE_SPACE_VELOCITY};
        XrResult r = locate(info->spaces[i], info->baseSpace, info->time, &loc, &v);
        if (r != XR_SUCCESS) return r;
        out->locations[i].locationFlags = loc.locationFlags;
        out->locations[i].pose = loc.pose;
        if (vel && i < vel->velocityCount) {
            vel->velocities[i].velocityFlags = v.velocityFlags;
            vel->velocities[i].linearVelocity = v.linearVelocity;
            vel->velocities[i].angularVelocity = v.angularVelocity;
        }
    }
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
    space_in_stage((space *)info->space, info->displayTime, &base, &tracked, NULL);
    XrPosef head = from_axr(axr_device_motion(AXR_HEAD, info->displayTime).pose);
    axr_views v = axr_current_views();
    XrPosef head_in_base = pmul(pinv(base), head);
    for (int e = 0; e < 2; e++) {
        views[e].pose = pmul(head_in_base, from_axr(v.eye_in_head[e]));
        views[e].fov = (XrFovf){v.fov[e][0], v.fov[e][1], v.fov[e][2], v.fov[e][3]};
    }
    state->viewStateFlags = XR_VIEW_STATE_ORIENTATION_VALID_BIT | XR_VIEW_STATE_POSITION_VALID_BIT;
    if ((axr_backend_connected() || axr_fake_tracking()))
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
        axr_log("swapchain %p: %ux%u x%u, %u mips, %u samples, format %lld, create flags %#llx, usage %#llx", (void *)sc, info->width,
                info->height, info->arraySize, info->mipCount, info->sampleCount, (long long)info->format, (unsigned long long)info->createFlags,
                (unsigned long long)info->usageFlags);
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
    axr_log("swapchain %p: %ux%u x%u, %u mips, %u samples, format %lld, create flags %#llx, usage %#llx", (void *)sc, info->width,
            info->height, info->arraySize, info->mipCount, info->sampleCount, (long long)info->format, (unsigned long long)info->createFlags,
            (unsigned long long)info->usageFlags);
    return XR_SUCCESS;
}

static XrResult xrDestroySwapchain_(XrSwapchain h) {
    CHECK_HANDLE(h, swapchain, MAGIC_SWAPCHAIN);
    swapchain *sc = (swapchain *)h;
    signal_fences(sc->sess, sc, -1);
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

// ----------------------------------------------------------------------------- shared images
//
// Two functions of alvrxr's own, for a bridge that has its app render straight into Metal
// textures of its own (wineopenxr, whose D3D11 games render on DXMT): the swapchain then shows
// those instead of its images, with no copy.
//
//   XrResult xrSetSwapchainImagesALVRXR(XrSwapchain, uint32_t count, void *const *mtl_textures)
//     replaces the swapchain's images, one for one; before the first acquire.
//   XrResult xrSetSwapchainImageFenceALVRXR(XrSwapchain, uint32_t index, void *mtl_shared_event,
//                                           uint64_t wait_value, uint64_t signal_value)
//     says, before image index is released, that the app's GPU work on it is done when the
//     event reaches wait_value; the event is set to signal_value once alvrxr is done with it.

static pthread_mutex_t g_fence_lock = PTHREAD_MUTEX_INITIALIZER;

// Commits a command buffer that signals the given fences, waiting first for those not yet
// waited for, and drops them: every fence of sc's (all of them, if NULL), or only index's.
static void signal_fences(session *s, swapchain *sc, int32_t index) {
    pthread_mutex_lock(&g_fence_lock);
    id<MTLCommandBuffer> cmd = nil;
    uint32_t kept = 0;
    for (uint32_t i = 0; i < s->fence_count; i++) {
        if ((sc && s->fences[i].sc != sc) || (index >= 0 && s->fences[i].index != (uint32_t)index)) {
            s->fences[kept++] = s->fences[i];
            continue;
        }
        if (!cmd) cmd = [s->queue commandBuffer];
        if (!s->fences[i].waited) [cmd encodeWaitForEvent:s->fences[i].event value:s->fences[i].wait];
        [cmd encodeSignalEvent:s->fences[i].event value:s->fences[i].signal];
    }
    for (uint32_t i = kept; i < s->fence_count; i++) s->fences[i].event = nil;
    s->fence_count = kept;
    pthread_mutex_unlock(&g_fence_lock);
    [cmd commit];
}

// Has the queue wait for the app's work on every image it has released since.
static void wait_fences(session *s) {
    pthread_mutex_lock(&g_fence_lock);
    id<MTLCommandBuffer> cmd = nil;
    for (uint32_t i = 0; i < s->fence_count; i++) {
        if (s->fences[i].waited) continue;
        if (!cmd) cmd = [s->queue commandBuffer];
        [cmd encodeWaitForEvent:s->fences[i].event value:s->fences[i].wait];
        s->fences[i].waited = true;
    }
    pthread_mutex_unlock(&g_fence_lock);
    [cmd commit];
}

static XrResult xrSetSwapchainImagesALVRXR_(XrSwapchain h, uint32_t count, void *const *textures) {
    CHECK_HANDLE(h, swapchain, MAGIC_SWAPCHAIN);
    swapchain *sc = (swapchain *)h;
    if (sc->sess->vulkan || count != sc->count || !textures) return XR_ERROR_VALIDATION_FAILURE;
    for (uint32_t i = 0; i < count; i++) {
        id<MTLTexture> t = (__bridge id<MTLTexture>)textures[i];
        if (!t || t.width < sc->info.width || t.height < sc->info.height) return XR_ERROR_VALIDATION_FAILURE;
    }
    for (uint32_t i = 0; i < count; i++) sc->images[i] = (__bridge id<MTLTexture>)textures[i];
    axr_log("swapchain %p: shown from the app's own %lux%lu textures, format %lu", (void *)sc,
            (unsigned long)sc->images[0].width, (unsigned long)sc->images[0].height,
            (unsigned long)sc->images[0].pixelFormat);
    return XR_SUCCESS;
}

static XrResult xrSetSwapchainImageFenceALVRXR_(XrSwapchain h, uint32_t index, void *event, uint64_t wait,
                                                uint64_t signal) {
    CHECK_HANDLE(h, swapchain, MAGIC_SWAPCHAIN);
    swapchain *sc = (swapchain *)h;
    session *s = sc->sess;
    if (index >= sc->count || !event) return XR_ERROR_VALIDATION_FAILURE;
    // An image released again before a frame took it, or more pending than there's room for:
    // the older fence is passed on now.
    signal_fences(s, sc, (int32_t)index);
    if (s->fence_count == sizeof s->fences / sizeof s->fences[0]) signal_fences(s, NULL, -1);
    pthread_mutex_lock(&g_fence_lock);
    s->fences[s->fence_count].sc = sc;
    s->fences[s->fence_count].index = index;
    s->fences[s->fence_count].event = (__bridge id<MTLSharedEvent>)event;
    s->fences[s->fence_count].wait = wait;
    s->fences[s->fence_count].signal = signal;
    s->fences[s->fence_count].waited = false;
    s->fence_count++;
    pthread_mutex_unlock(&g_fence_lock);
    return XR_SUCCESS;
}

// ----------------------------------------------------------------------------------- frames

static XrResult xrWaitFrame_(XrSession h, const XrFrameWaitInfo *info, XrFrameState *st) {
    CHECK_HANDLE(h, session, MAGIC_SESSION);
    (void)info;
    session *s = (session *)h;
    if (!s->running) return XR_ERROR_SESSION_NOT_RUNNING;
    axr_stat_wait++;
    st->predictedDisplayTime = axr_wait_frame();
    st->predictedDisplayPeriod = (XrDuration)(1e9 / axr_refresh_hz());
    pthread_mutex_lock(&g_lock);
    follow_focus(s);
    uint32_t focus;
    bool render;
    desired_focus(s, &focus, &render);
    axr_slots_heartbeat(session_slots(s));
    bool visible = s->state == XR_SESSION_STATE_VISIBLE || s->state == XR_SESSION_STATE_FOCUSED;
    pthread_mutex_unlock(&g_lock);
    st->shouldRender = visible && render;
    // The home scene draws only for a headset; games always do, for their window on the Mac.
    if (is_home() && !axr_backend_connected()) st->shouldRender = XR_FALSE;
    return XR_SUCCESS;
}

static XrResult xrBeginFrame_(XrSession h, const XrFrameBeginInfo *info) {
    CHECK_HANDLE(h, session, MAGIC_SESSION);
    (void)info;
    return ((session *)h)->running ? XR_SUCCESS : XR_ERROR_SESSION_NOT_RUNNING;
}

// ------------------------------------------------------------------------------- quad layers
//
// Games put title, splash and loading screens on quad layers: a flat image at a pose in a space,
// often with no projection layer at all. The stream carries one picture per eye, so each frame is
// drawn into an output slot (compositor.h), one half per eye: the projection layer, if any, then
// each quad as that eye sees it at the frame's display time.

static NSString *const kLayerShaders =
    @"#include <metal_stdlib>\n"
     "using namespace metal;\n"
     "struct Quad { float4 pos[4]; float4 uv[4]; uint slice; };\n"
     "struct V { float4 pos [[position]]; float2 uv; };\n"
     "vertex V lvs(uint vid [[vertex_id]], constant Quad &q [[buffer(0)]]) {\n"
     "    V o; o.pos = q.pos[vid]; o.uv = q.uv[vid].xy; return o;\n"
     "}\n"
     "fragment float4 lfs(V in [[stage_in]], texture2d_array<float> t [[texture(0)]],\n"
     "                    constant Quad &q [[buffer(0)]]) {\n"
     "    constexpr sampler s(filter::linear, address::clamp_to_edge);\n"
     "    return t.sample(s, in.uv, q.slice);\n"
     "}\n";

typedef struct {
    float pos[4][4];   // clip space, corners in triangle-strip order
    float uv[4][4];    // .xy used
    uint32_t slice;
} layer_quad;

enum { BLEND_NONE, BLEND_PREMULTIPLIED, BLEND_STRAIGHT, BLEND_COUNT };
// sRGB like the games' own swapchains; Metal blends sRGB targets in linear space.
static const MTLPixelFormat kLayerFormat = MTLPixelFormatBGRA8Unorm_sRGB;
static id<MTLRenderPipelineState> g_layer_pso[BLEND_COUNT];

static bool layer_pipelines(id<MTLDevice> dev) {
    if (g_layer_pso[0]) return true;
    NSError *err = nil;
    id<MTLLibrary> lib = [dev newLibraryWithSource:kLayerShaders options:nil error:&err];
    if (!lib) {
        axr_log("quad layers: shaders didn't compile: %s", err.localizedDescription.UTF8String);
        return false;
    }
    for (int b = 0; b < BLEND_COUNT; b++) {
        MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new];
        d.vertexFunction = [lib newFunctionWithName:@"lvs"];
        d.fragmentFunction = [lib newFunctionWithName:@"lfs"];
        MTLRenderPipelineColorAttachmentDescriptor *c = d.colorAttachments[0];
        c.pixelFormat = kLayerFormat;
        if (b != BLEND_NONE) {
            c.blendingEnabled = YES;
            c.sourceRGBBlendFactor = b == BLEND_STRAIGHT ? MTLBlendFactorSourceAlpha : MTLBlendFactorOne;
            c.destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
            c.sourceAlphaBlendFactor = MTLBlendFactorOne;
            c.destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
        }
        g_layer_pso[b] = [dev newRenderPipelineStateWithDescriptor:d error:&err];
        if (!g_layer_pso[b]) {
            axr_log("quad layers: no pipeline: %s", err.localizedDescription.UTF8String);
            return false;
        }
    }
    return true;
}

static int layer_blend(XrCompositionLayerFlags flags) {
    if (!(flags & XR_COMPOSITION_LAYER_BLEND_TEXTURE_SOURCE_ALPHA_BIT)) return BLEND_NONE;
    return (flags & XR_COMPOSITION_LAYER_UNPREMULTIPLIED_ALPHA_BIT) ? BLEND_STRAIGHT : BLEND_PREMULTIPLIED;
}

// The released image of a sub-image's swapchain, with its rect as texture coordinates.
static id<MTLTexture> sub_image(const XrSwapchainSubImage *sub, float uv[4]) {
    swapchain *sc = (swapchain *)sub->swapchain;
    if (!sc || sc->magic != MAGIC_SWAPCHAIN || sc->released < 0) return nil;
    id<MTLTexture> t = sc->images[sc->released];
    uv[0] = (float)sub->imageRect.offset.x / t.width;
    uv[1] = (float)sub->imageRect.offset.y / t.height;
    uv[2] = (float)(sub->imageRect.offset.x + sub->imageRect.extent.width) / t.width;
    uv[3] = (float)(sub->imageRect.offset.y + sub->imageRect.extent.height) / t.height;
    return axr_array_view(t);
}

// A quad's corners as the eye sees them, in clip space; false if any is behind the eye.
static bool quad_corners(const XrCompositionLayerQuad *q, XrPosef eye, XrFovf fov, XrTime t, float out[4][4]) {
    XrPosef in_stage;
    bool tracked;
    if (!space_in_stage((space *)q->space, t, &in_stage, &tracked, NULL)) return false;
    XrPosef quad = pmul(in_stage, q->pose), to_eye = pinv(eye);
    float hw = q->size.width / 2, hh = q->size.height / 2;
    const float local[4][2] = {{-hw, hh}, {hw, hh}, {-hw, -hh}, {hw, -hh}};   // TL, TR, BL, BR
    float l = tanf(fov.angleLeft), r = tanf(fov.angleRight), u = tanf(fov.angleUp), d = tanf(fov.angleDown);
    for (int i = 0; i < 4; i++) {
        XrVector3f world = vadd(quad.position, qrot(quad.orientation, (XrVector3f){local[i][0], local[i][1], 0}));
        XrVector3f p = vadd(to_eye.position, qrot(to_eye.orientation, world));
        float w = -p.z;   // the eye looks down -Z
        if (w < 0.01f) return false;
        out[i][0] = (2 * p.x / w - (r + l)) / (r - l) * w;
        out[i][1] = (2 * p.y / w - (u + d)) / (u - d) * w;
        out[i][2] = 0.5f * w;
        out[i][3] = w;
    }
    return true;
}

static void draw_layer(id<MTLRenderCommandEncoder> enc, int blend, id<MTLTexture> tex, const layer_quad *q) {
    [enc setRenderPipelineState:g_layer_pso[blend]];
    [enc setVertexBytes:q length:sizeof *q atIndex:0];
    [enc setFragmentBytes:q length:sizeof *q atIndex:0];
    [enc setFragmentTexture:tex atIndex:0];
    [enc drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
}

// Logs the frame's layer stack when it differs from the last one logged; true when it did.
static bool log_layers(const XrFrameEndInfo *info) {
    static char last[1024];
    char now[1024] = "";
    size_t n = 0;
    for (uint32_t i = 0; i < info->layerCount && n < sizeof now - 80; i++) {
        const XrCompositionLayerBaseHeader *l = info->layers[i];
        if (!l) continue;
        if (l->type == XR_TYPE_COMPOSITION_LAYER_QUAD) {
            const XrCompositionLayerQuad *q = (const XrCompositionLayerQuad *)l;
            swapchain *sc = (swapchain *)q->subImage.swapchain;
            n += snprintf(now + n, sizeof now - n, " [quad %p flags %#llx %.2fx%.2fm]", (void *)sc,
                          (unsigned long long)l->layerFlags, q->size.width, q->size.height);
        } else if (l->type == XR_TYPE_COMPOSITION_LAYER_PROJECTION) {
            n += snprintf(now + n, sizeof now - n, " [projection flags %#llx]", (unsigned long long)l->layerFlags);
        } else {
            n += snprintf(now + n, sizeof now - n, " [type %d]", (int)l->type);
        }
    }
    if (strcmp(now, last)) {
        strcpy(last, now);
        axr_log("layers:%s", now);
        return true;
    }
    return false;
}

// Draws the frame's projection layer (if any) and its quads into target with cmd, the left eye in
// its left half; false if it can't.
static bool compose_layers(const XrFrameEndInfo *info, const XrCompositionLayerProjection *proj, bool explain,
                           id<MTLCommandBuffer> cmd, id<MTLTexture> target, axr_pose head_pose, bool transparent) {
    if (!layer_pipelines(cmd.device)) return false;
    uint32_t w = (uint32_t)target.width / 2, h = (uint32_t)target.height;
    XrPosef head = from_axr(head_pose);
    axr_views v = axr_current_views();
    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = target;
    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    // The layers' alpha is kept as they wrote it (the first draws unblended, the rest over it,
    // premultiplied); the lounge's dashboard frames start from nothing so the game shows through
    // where it drew nothing. Games always start from opaque black.
    pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, transparent ? 0 : 1);
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLRenderCommandEncoder> enc = [cmd renderCommandEncoderWithDescriptor:pass];
    for (int e = 0; e < 2; e++) {
        [enc setViewport:(MTLViewport){e * w, 0, w, h, 0, 1}];
        [enc setScissorRect:(MTLScissorRect){e * w, 0, w, h}];
        XrPosef eye = pmul(head, from_axr(v.eye_in_head[e]));
        XrFovf fov = {v.fov[e][0], v.fov[e][1], v.fov[e][2], v.fov[e][3]};
        for (uint32_t i = 0; i < info->layerCount; i++) {
            const XrCompositionLayerBaseHeader *l = info->layers[i];
            layer_quad q = {0};
            float uv[4];
            id<MTLTexture> tex;
            if (l && (const void *)l == (const void *)proj) {
                if (!(tex = sub_image(&proj->views[e].subImage, uv))) continue;
                q.slice = proj->views[e].subImage.imageArrayIndex;
                const float ndc[4][2] = {{-1, 1}, {1, 1}, {-1, -1}, {1, -1}};
                const float corner_uv[4][2] = {{uv[0], uv[1]}, {uv[2], uv[1]}, {uv[0], uv[3]}, {uv[2], uv[3]}};
                for (int c = 0; c < 4; c++) {
                    q.pos[c][0] = ndc[c][0], q.pos[c][1] = ndc[c][1], q.pos[c][2] = 0.5f, q.pos[c][3] = 1;
                    q.uv[c][0] = corner_uv[c][0], q.uv[c][1] = corner_uv[c][1];
                }
                draw_layer(enc, i == 0 ? BLEND_NONE : layer_blend(l->layerFlags), tex, &q);
                continue;
            }
            if (!l || l->type != XR_TYPE_COMPOSITION_LAYER_QUAD) continue;
            const XrCompositionLayerQuad *ql = (const XrCompositionLayerQuad *)l;
            if ((ql->eyeVisibility == XR_EYE_VISIBILITY_LEFT && e != 0) ||
                (ql->eyeVisibility == XR_EYE_VISIBILITY_RIGHT && e != 1))
                continue;
            if (!(tex = sub_image(&ql->subImage, uv))) {
                if (explain && e == 0) axr_log("  layer %u: no released image", i);
                continue;
            }
            if (!quad_corners(ql, eye, fov, info->displayTime, q.pos)) {
                if (explain && e == 0) {
                    XrPosef sp;
                    bool tr;
                    space_in_stage((space *)ql->space, info->displayTime, &sp, &tr, NULL);
                    XrPosef in_eye = pmul(pinv(eye), pmul(sp, ql->pose));
                    axr_log("  layer %u: behind the eye, at (%.2f, %.2f, %.2f) from it; space ref %d",
                            i, in_eye.position.x, in_eye.position.y, in_eye.position.z, ((space *)ql->space)->ref);
                }
                continue;
            }
            if (explain && e == 0)
                axr_log("  layer %u: drawn, %ux%u image, corner w %.2f", i, (unsigned)tex.width, (unsigned)tex.height,
                        q.pos[0][3]);
            q.slice = ql->subImage.imageArrayIndex;
            const float corner_uv[4][2] = {{uv[0], uv[1]}, {uv[2], uv[1]}, {uv[0], uv[3]}, {uv[2], uv[3]}};
            for (int c = 0; c < 4; c++) q.uv[c][0] = corner_uv[c][0], q.uv[c][1] = corner_uv[c][1];
            draw_layer(enc, layer_blend(ql->layerFlags), tex, &q);
        }
    }
    [enc endEncoding];
    return true;
}

static XrResult end_frame(session *s, const XrFrameEndInfo *info);

// The frame reads shared images only once the app's GPU is done with them, and hands them back
// once it has, whether it showed them or not.
static XrResult xrEndFrame_(XrSession h, const XrFrameEndInfo *info) {
    CHECK_HANDLE(h, session, MAGIC_SESSION);
    session *s = (session *)h;
    wait_fences(s);
    XrResult r = end_frame(s, info);
    signal_fences(s, NULL, -1);
    return r;
}

static XrResult end_frame(session *s, const XrFrameEndInfo *info) {
    axr_stat_end++;
    if (!s->running) return XR_ERROR_SESSION_NOT_RUNNING;
    if (info->displayTime <= 0) return XR_ERROR_TIME_INVALID;
    if (info->environmentBlendMode != XR_ENVIRONMENT_BLEND_MODE_OPAQUE) return XR_ERROR_ENVIRONMENT_BLEND_MODE_UNSUPPORTED;
    // The stream carries one picture per eye: the first stereo projection layer, with any quad
    // layers drawn over it (or instead of it).
    const XrCompositionLayerProjection *proj = NULL;
    bool quads = false;
    for (uint32_t i = 0; i < info->layerCount; i++) {
        const XrCompositionLayerBaseHeader *l = info->layers[i];
        if (!l) continue;
        if (l->type == XR_TYPE_COMPOSITION_LAYER_QUAD) quads = true;
        if (l->type != XR_TYPE_COMPOSITION_LAYER_PROJECTION || proj) continue;
        proj = (const XrCompositionLayerProjection *)l;
        axr_stat_projection++;
        if (proj->viewCount != 2) return XR_ERROR_VALIDATION_FAILURE;
        for (int e = 0; e < 2; e++) {
            CHECK_HANDLE(proj->views[e].subImage.swapchain, swapchain, MAGIC_SWAPCHAIN);
            if (((swapchain *)proj->views[e].subImage.swapchain)->released < 0) return XR_ERROR_LAYER_INVALID;
        }
    }
    // Each new layer stack is logged, and explained once.
    bool changed = log_layers(info);
    if (s->slots && axr_slots_stale(s->slots)) {
        axr_slots_close(s->slots);
        s->slots = NULL;
    }
    if (!s->slots) s->slots = axr_slots_open(s->queue.device, s->queue);
    if (!s->slots) return XR_SUCCESS;
    axr_pose head = axr_device_motion(AXR_HEAD, info->displayTime).pose;
    id<MTLCommandBuffer> cmd = [s->queue commandBuffer];
    uint32_t slot;
    id<MTLTexture> target = axr_slot_begin(s->slots, cmd, &slot);
    bool content = proj || quads;
    bool transparent = is_home() && axr_slots_dashboard(s->slots);
    if (content && !compose_layers(info, proj, changed, cmd, target, head, transparent)) content = false;
    axr_slot_end(s->slots, cmd, slot, info->displayTime, content ? AXR_FRAME_HAS_CONTENT : 0, head);
    [cmd commit];
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
    size_t len = strlen(a->name), tail = strlen("-double-click");
    a->once_per_sync = len > tail && !strcmp(a->name + len - tail, "-double-click");
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
            pthread_mutex_lock(&g_lock);
            push_event(&ev, sizeof ev);
            pthread_mutex_unlock(&g_lock);
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
    // The system button is the compositor's (it opens the dashboard): a game's binding to it is
    // live but never pressed, so nothing the player does there reaches the game.
    if (!is_home() && [b rangeOfString:@"/input/system/"].location != NSNotFound) return true;
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
    axr_stat_syncs++;
    if (s->state != XR_SESSION_STATE_FOCUSED) {
        axr_stat_unfocused_syncs++;
        return XR_SESSION_NOT_FOCUSED;
    }
    XrTime now = axr_now_ns();
    bool connected = (axr_backend_connected() || axr_fake_tracking());
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
            a->change_read = false;
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
    if (st->currentState) axr_stat_pressed++;
    st->changedSinceLastSync = a->changed[u];
    if (a->once_per_sync && a->changed[u]) {
        st->changedSinceLastSync = !a->change_read;
        a->change_read = true;
    }
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
    for (NSString *b in a->bindings) {
        int bu = sub_of(b);
        if (u != SUB_NONE && bu != u) continue;
        hand = bu == SUB_LEFT ? AXR_LEFT : AXR_RIGHT;
        break;
    }
    // ALVR reports the controller's grip; aim is offset from it by axr_aim_offset (space_is_aim).
    return new_space((session *)h, (space){.kind = SPACE_ACTION, .act = a, .hand = hand,
                                           .offset = info->poseInActionSpace}, out);
}

// A CLIENT has no ALVR of its own: vapord passes its haptics on.
static void haptics(int hand, float duration_s, float frequency, float amplitude) {
    if (axr_mode_current() == AXR_MODE_CLIENT) axr_client_haptics(hand, duration_s, frequency, amplitude);
    else axr_haptics(hand, duration_s, frequency, amplitude);
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
        haptics(bu == SUB_LEFT ? AXR_LEFT : AXR_RIGHT, duration, freq, vib->amplitude);
    }
    return XR_SUCCESS;
}

static XrResult xrStopHapticFeedback_(XrSession h, const XrHapticActionInfo *info) {
    CHECK_HANDLE(h, session, MAGIC_SESSION);
    CHECK_HANDLE(info->action, action, MAGIC_ACTION);
    action *a = (action *)info->action;
    for (NSString *b in a->bindings) haptics(sub_of(b) == SUB_LEFT ? AXR_LEFT : AXR_RIGHT, 0, 160, 0);
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

// ------------------------------------------------------------------------------- hand tracking
//
// XR_EXT_hand_tracking from the hand skeletons the client sends: its 26 joints in SteamVR's bone
// order match OpenXR's joints one for one, but for the palm, which SteamVR roots at the wrist; it
// is put between the middle finger's metacarpal and knuckle instead.

typedef struct {
    uint32_t magic;
    session *sess;
    int hand;
} hand_tracker;

static XrResult xrCreateHandTrackerEXT_(XrSession h, const XrHandTrackerCreateInfoEXT *info, XrHandTrackerEXT *out) {
    CHECK_HANDLE(h, session, MAGIC_SESSION);
    if (info->handJointSet != XR_HAND_JOINT_SET_DEFAULT_EXT) return XR_ERROR_VALIDATION_FAILURE;
    if (info->hand != XR_HAND_LEFT_EXT && info->hand != XR_HAND_RIGHT_EXT) return XR_ERROR_VALIDATION_FAILURE;
    hand_tracker *t = calloc(1, sizeof *t);
    t->magic = MAGIC_HAND;
    t->sess = (session *)h;
    t->hand = info->hand == XR_HAND_LEFT_EXT ? AXR_LEFT : AXR_RIGHT;
    *out = (XrHandTrackerEXT)t;
    return XR_SUCCESS;
}

static XrResult xrDestroyHandTrackerEXT_(XrHandTrackerEXT h) {
    CHECK_HANDLE(h, hand_tracker, MAGIC_HAND);
    ((hand_tracker *)h)->magic = 0;
    free((void *)h);
    return XR_SUCCESS;
}

static XrResult xrLocateHandJointsEXT_(XrHandTrackerEXT h, const XrHandJointsLocateInfoEXT *info,
                                       XrHandJointLocationsEXT *locs) {
    CHECK_HANDLE(h, hand_tracker, MAGIC_HAND);
    CHECK_HANDLE(info->baseSpace, space, MAGIC_SPACE);
    if (locs->jointCount != XR_HAND_JOINT_COUNT_EXT) return XR_ERROR_VALIDATION_FAILURE;
    hand_tracker *t = (hand_tracker *)h;
    XrHandJointVelocitiesEXT *vel = NULL;
    for (XrBaseOutStructure *n = (XrBaseOutStructure *)locs->next; n; n = n->next)
        if (n->type == XR_TYPE_HAND_JOINT_VELOCITIES_EXT) vel = (XrHandJointVelocitiesEXT *)n;
    if (vel) for (uint32_t i = 0; i < vel->jointCount; i++) vel->jointVelocities[i].velocityFlags = 0;
    for (uint32_t i = 0; i < XR_HAND_JOINT_COUNT_EXT; i++) locs->jointLocations[i].locationFlags = 0;
    locs->isActive = XR_FALSE;

    XrTime when = info->time ? info->time : axr_now_ns();
    axr_pose joints[26];
    XrPosef base;
    bool base_tracked;
    if (!axr_hand_joints(t->hand, when, joints) || !space_in_stage((space *)info->baseSpace, when, &base, &base_tracked, NULL))
        return XR_SUCCESS;
    // Radii, metres: wrist, palm, thumb, then each finger from metacarpal to tip.
    static const float thumb[4] = {0.019f, 0.015f, 0.013f, 0.011f}, finger[5] = {0.020f, 0.011f, 0.009f, 0.008f, 0.007f};
    XrPosef inv_base = pinv(base);
    for (int i = 0; i < 26; i++) {
        XrPosef p = from_axr(joints[i]);
        if (i == XR_HAND_JOINT_PALM_EXT) {
            XrPosef a = from_axr(joints[XR_HAND_JOINT_MIDDLE_METACARPAL_EXT]), b = from_axr(joints[XR_HAND_JOINT_MIDDLE_PROXIMAL_EXT]);
            p = a;
            p.position = (XrVector3f){(a.position.x + b.position.x) / 2, (a.position.y + b.position.y) / 2,
                                      (a.position.z + b.position.z) / 2};
        }
        XrHandJointLocationEXT *l = &locs->jointLocations[i];
        l->pose = pmul(inv_base, p);
        l->radius = i == XR_HAND_JOINT_PALM_EXT ? 0.032f : i == XR_HAND_JOINT_WRIST_EXT ? 0.024f
                    : i <= XR_HAND_JOINT_THUMB_TIP_EXT ? thumb[i - XR_HAND_JOINT_THUMB_METACARPAL_EXT]
                                                       : finger[(i - XR_HAND_JOINT_INDEX_METACARPAL_EXT) % 5];
        l->locationFlags = XR_SPACE_LOCATION_ORIENTATION_VALID_BIT | XR_SPACE_LOCATION_POSITION_VALID_BIT |
                           (base_tracked ? XR_SPACE_LOCATION_ORIENTATION_TRACKED_BIT | XR_SPACE_LOCATION_POSITION_TRACKED_BIT : 0);
    }
    locs->isActive = XR_TRUE;
    return XR_SUCCESS;
}

// ---------------------------------------------------------------------------------- dashboard
//
// The private functions of alvrxr_ext.h, for vapord's panel. Only its own session in SERVER mode
// (the compositor is in this process) may call them.

static bool dashboard_allowed(void) { return is_home() && axr_mode_current() == AXR_MODE_SERVER; }

static XrResult xrGetDashboardStateALVRXR_(XrSession h, XrDashboardStateALVRXR *st) {
    CHECK_HANDLE(h, session, MAGIC_SESSION);
    if (!st) return XR_ERROR_VALIDATION_FAILURE;
    if (!dashboard_allowed()) return XR_ERROR_FUNCTION_UNSUPPORTED;
    memset(st, 0, sizeof *st);
    pid_t pid;
    char name[64];
    st->open = axr_compositor_dashboard(&pid, name);
    st->game_pid = pid > 0 ? (uint32_t)pid : 0;
    snprintf(st->game_name, sizeof st->game_name, "%s", name);
    axr_server_dashboard_stats(st->battery, st->charging, &st->fps, &st->mbps, &st->eye_height, &st->height_offset);
    return XR_SUCCESS;
}

static XrResult xrCloseDashboardALVRXR_(XrSession h) {
    CHECK_HANDLE(h, session, MAGIC_SESSION);
    if (!dashboard_allowed()) return XR_ERROR_FUNCTION_UNSUPPORTED;
    axr_compositor_close_dashboard();
    return XR_SUCCESS;
}

static XrResult xrQuitGameALVRXR_(XrSession h) {
    CHECK_HANDLE(h, session, MAGIC_SESSION);
    if (!dashboard_allowed()) return XR_ERROR_FUNCTION_UNSUPPORTED;
    axr_compositor_quit_game();   // nothing to do with no game
    return XR_SUCCESS;
}

static XrResult xrRecenterALVRXR_(XrSession h) {
    CHECK_HANDLE(h, session, MAGIC_SESSION);
    if (!dashboard_allowed()) return XR_ERROR_FUNCTION_UNSUPPORTED;
    axr_server_recenter();
    return XR_SUCCESS;
}

static XrResult xrSetEyeHeightALVRXR_(XrSession h, float eye_height) {
    CHECK_HANDLE(h, session, MAGIC_SESSION);
    if (!dashboard_allowed()) return XR_ERROR_FUNCTION_UNSUPPORTED;
    if (!isfinite(eye_height) || eye_height < 0 || eye_height > 3) return XR_ERROR_VALIDATION_FAILURE;
    axr_server_set_eye_height(eye_height);
    return XR_SUCCESS;
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
    X(xrGetVulkanGraphicsDevice2KHR) X(xrCreateVulkanInstanceKHR) X(xrCreateVulkanDeviceKHR) X(xrLocateSpaces) \
    X(xrSetSwapchainImagesALVRXR) X(xrSetSwapchainImageFenceALVRXR)                                      \
    X(xrGetDashboardStateALVRXR) X(xrCloseDashboardALVRXR) X(xrQuitGameALVRXR) X(xrRecenterALVRXR)        \
    X(xrSetEyeHeightALVRXR)                                                                               \
    X(xrCreateHandTrackerEXT) X(xrDestroyHandTrackerEXT) X(xrLocateHandJointsEXT)

static XrResult xrGetInstanceProcAddr_(XrInstance inst, const char *name, PFN_xrVoidFunction *fn);

// Shared images are offered only when asked for, with ALVRXR_SHARE_IMAGES=1 or tune.json
// "share_images": true, until a game's loading screens no longer stall on them (the game's render
// thread can wait on a fence alvrxr hasn't signalled yet). Without them wineopenxr copies.
static bool share_images_wanted(void) {
    static int wanted = -1;
    if (wanted < 0) {
        const char *env = getenv("ALVRXR_SHARE_IMAGES");
        NSString *path = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/alvrxr/tune.json"];
        NSData *d = [NSData dataWithContentsOfFile:path];
        id t = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
        wanted = env ? atoi(env) != 0 : [t isKindOfClass:NSDictionary.class] && [t[@"share_images"] boolValue];
        if (wanted) axr_log("shared images offered");
    }
    return wanted;
}

static XrResult xrGetInstanceProcAddr_(XrInstance inst, const char *name, PFN_xrVoidFunction *fn) {
    if (!name || !fn) return XR_ERROR_VALIDATION_FAILURE;
    *fn = NULL;
    // Without an instance only these three may be looked up.
    if (!inst && strcmp(name, "xrEnumerateInstanceExtensionProperties") && strcmp(name, "xrCreateInstance") &&
        strcmp(name, "xrEnumerateApiLayerProperties"))
        return XR_ERROR_HANDLE_INVALID;
    if (!strcmp(name, "xrGetInstanceProcAddr")) { *fn = (PFN_xrVoidFunction)xrGetInstanceProcAddr_; return XR_SUCCESS; }
    if (!strncmp(name, "xrSetSwapchainImage", 19) && !share_images_wanted()) return XR_ERROR_FUNCTION_UNSUPPORTED;
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
