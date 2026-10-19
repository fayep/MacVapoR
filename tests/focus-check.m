// Exercises the compositor-driven session focus in the runtime: flips the test focus file
// (ALVRXR_TEST_FOCUS_FILE) and checks the XrEventDataSessionStateChanged sequence xrPollEvent
// gives, that xrSyncActions says SESSION_NOT_FOCUSED unless FOCUSED, and shouldRender.
// Needs no headset. Build and run:  tests/focus-check.sh  (uses a scratch ALVRXR_CONFIG_DIR).
#define XR_USE_GRAPHICS_API_METAL
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <dlfcn.h>
#include <openxr/openxr.h>
#include <openxr/openxr_loader_negotiation.h>
#include <openxr/openxr_platform.h>

static PFN_xrGetInstanceProcAddr gipa;
static XrInstance inst;
static int failures;
#define FN(name) PFN_##name name = NULL; gipa(inst, #name, (PFN_xrVoidFunction *)&name)
#define OK(call) do { XrResult r_ = (call); if (XR_FAILED(r_)) { printf("FAIL %s = %d\n", #call, r_); exit(1); } } while (0)
#define EXPECT(c, ...) do { if (!(c)) { failures++; printf("FAIL: "); printf(__VA_ARGS__); printf("\n"); } } while (0)

static const char *name(XrSessionState s) {
    static const char *n[] = {"UNKNOWN", "IDLE", "READY", "SYNCHRONIZED", "VISIBLE", "FOCUSED", "STOPPING", "LOSS_PENDING", "EXITING"};
    return s <= 8 ? n[s] : "?";
}

int main(void) {
    @autoreleasepool {
        const char *cfg = getenv("ALVRXR_CONFIG_DIR"), *ff = getenv("ALVRXR_TEST_FOCUS_FILE"), *rt = getenv("ALVRXR_RUNTIME");
        if (!cfg || !ff || !rt) { printf("set ALVRXR_CONFIG_DIR (scratch), ALVRXR_TEST_FOCUS_FILE, ALVRXR_RUNTIME\n"); return 2; }
        setenv("ALVRXR_DUMP", [NSString stringWithFormat:@"%s/dump.bin", cfg].UTF8String, 1);
        void *lib = dlopen(rt, RTLD_NOW | RTLD_LOCAL);
        if (!lib) { printf("%s\n", dlerror()); return 2; }
        PFN_xrNegotiateLoaderRuntimeInterface neg = dlsym(lib, "xrNegotiateLoaderRuntimeInterface");
        XrNegotiateLoaderInfo li = {XR_LOADER_INTERFACE_STRUCT_LOADER_INFO, XR_LOADER_INFO_STRUCT_VERSION, sizeof li, 1,
                                    XR_CURRENT_LOADER_RUNTIME_VERSION, XR_MAKE_VERSION(1, 0, 0), XR_MAKE_VERSION(1, 0x3ff, 0xfff)};
        XrNegotiateRuntimeRequest rr = {XR_LOADER_INTERFACE_STRUCT_RUNTIME_REQUEST, XR_RUNTIME_INFO_STRUCT_VERSION, sizeof rr};
        OK(neg(&li, &rr));
        gipa = rr.getInstanceProcAddr;
        PFN_xrCreateInstance create = NULL;
        gipa(XR_NULL_HANDLE, "xrCreateInstance", (PFN_xrVoidFunction *)&create);
        const char *exts[] = {XR_KHR_METAL_ENABLE_EXTENSION_NAME};
        XrInstanceCreateInfo ici = {XR_TYPE_INSTANCE_CREATE_INFO};
        strcpy(ici.applicationInfo.applicationName, "focus-check");
        ici.applicationInfo.apiVersion = XR_MAKE_VERSION(1, 0, 0);
        ici.enabledExtensionCount = 1;
        ici.enabledExtensionNames = exts;
        OK(create(&ici, &inst));
        FN(xrGetSystem); FN(xrGetMetalGraphicsRequirementsKHR); FN(xrCreateSession); FN(xrPollEvent);
        FN(xrBeginSession); FN(xrEndSession); FN(xrWaitFrame); FN(xrBeginFrame); FN(xrEndFrame);
        FN(xrStringToPath); FN(xrCreateActionSet); FN(xrCreateAction); FN(xrSuggestInteractionProfileBindings);
        FN(xrAttachSessionActionSets); FN(xrSyncActions); FN(xrRequestExitSession);
        XrSystemGetInfo sgi = {XR_TYPE_SYSTEM_GET_INFO, NULL, XR_FORM_FACTOR_HEAD_MOUNTED_DISPLAY};
        XrSystemId sys;
        OK(xrGetSystem(inst, &sgi, &sys));
        XrGraphicsRequirementsMetalKHR req = {XR_TYPE_GRAPHICS_REQUIREMENTS_METAL_KHR};
        OK(xrGetMetalGraphicsRequirementsKHR(inst, sys, &req));
        id<MTLDevice> dev = req.metalDevice ? (__bridge id<MTLDevice>)req.metalDevice : MTLCreateSystemDefaultDevice();
        id<MTLCommandQueue> q = [dev newCommandQueue];
        XrGraphicsBindingMetalKHR b = {XR_TYPE_GRAPHICS_BINDING_METAL_KHR, NULL, (__bridge void *)q};
        XrSessionCreateInfo sci = {XR_TYPE_SESSION_CREATE_INFO, &b, 0, sys};
        XrSession ses;
        OK(xrCreateSession(inst, &sci, &ses));

        XrActionSetCreateInfo asi = {XR_TYPE_ACTION_SET_CREATE_INFO};
        strcpy(asi.actionSetName, "t"); strcpy(asi.localizedActionSetName, "t");
        XrActionSet set;
        OK(xrCreateActionSet(inst, &asi, &set));
        XrActionCreateInfo ai = {XR_TYPE_ACTION_CREATE_INFO};
        strcpy(ai.actionName, "a"); strcpy(ai.localizedActionName, "a");
        ai.actionType = XR_ACTION_TYPE_BOOLEAN_INPUT;
        XrAction act;
        OK(xrCreateAction(set, &ai, &act));
        XrPath prof, bind;
        xrStringToPath(inst, "/interaction_profiles/oculus/touch_controller", &prof);
        xrStringToPath(inst, "/user/hand/right/input/a/click", &bind);
        XrActionSuggestedBinding sb = {act, bind};
        XrInteractionProfileSuggestedBinding spb = {XR_TYPE_INTERACTION_PROFILE_SUGGESTED_BINDING, NULL, prof, 1, &sb};
        OK(xrSuggestInteractionProfileBindings(inst, &spb));
        XrSessionActionSetsAttachInfo att = {XR_TYPE_SESSION_ACTION_SETS_ATTACH_INFO, NULL, 1, &set};
        OK(xrAttachSessionActionSets(ses, &att));

        // Every event, as "STATE" strings, drained into a log.
        NSMutableArray *log = [NSMutableArray array];
        void (^drain)(void) = ^{
            XrEventDataBuffer ev = {XR_TYPE_EVENT_DATA_BUFFER};
            while (xrPollEvent(inst, &ev) == XR_SUCCESS) {
                if (ev.type == XR_TYPE_EVENT_DATA_SESSION_STATE_CHANGED)
                    [log addObject:@(name(((XrEventDataSessionStateChanged *)&ev)->state))];
                ev = (XrEventDataBuffer){XR_TYPE_EVENT_DATA_BUFFER};
            }
        };
        void (^set_focus)(const char *) = ^(const char *v) {
            [@(v) writeToFile:@(ff) atomically:YES encoding:NSUTF8StringEncoding error:nil];
            usleep(150000);   // past the runtime's 100 ms re-read
        };
        void (^expect)(const char *, NSString *) = ^(const char *what, NSString *want) {
            drain();
            NSString *got = [log componentsJoinedByString:@" "];
            printf("%-34s %s\n", what, got.length ? got.UTF8String : "(none)");
            EXPECT([got isEqualToString:want], "%s: wanted '%s'", what, want.UTF8String);
            [log removeAllObjects];
        };

        set_focus("2");
        drain();   // IDLE READY
        XrSessionBeginInfo bi = {XR_TYPE_SESSION_BEGIN_INFO, NULL, XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO};
        [log removeAllObjects];
        OK(xrBeginSession(ses, &bi));
        expect("begin", @"SYNCHRONIZED VISIBLE FOCUSED");

        XrActiveActionSet aas = {set, XR_NULL_PATH};
        XrActionsSyncInfo syn = {XR_TYPE_ACTIONS_SYNC_INFO, NULL, 1, &aas};
        __block XrFrameState fs;
        void (^wait)(void) = ^{ fs = (XrFrameState){XR_TYPE_FRAME_STATE}; OK(xrWaitFrame(ses, NULL, &fs)); OK(xrBeginFrame(ses, NULL));
                                XrFrameEndInfo e = {XR_TYPE_FRAME_END_INFO, NULL, fs.predictedDisplayTime, XR_ENVIRONMENT_BLEND_MODE_OPAQUE, 0, NULL};
                                OK(xrEndFrame(ses, &e)); };
        wait();
        EXPECT(fs.shouldRender, "shouldRender while FOCUSED");
        EXPECT(xrSyncActions(ses, &syn) == XR_SUCCESS, "sync while FOCUSED");

        set_focus("1");
        expect("FOCUSED -> VISIBLE", @"VISIBLE");
        wait();
        EXPECT(fs.shouldRender, "shouldRender while VISIBLE (render=1)");
        XrResult r = xrSyncActions(ses, &syn);
        printf("%-34s xrSyncActions = %s\n", "while VISIBLE", r == XR_SESSION_NOT_FOCUSED ? "XR_SESSION_NOT_FOCUSED" : "(other)");
        EXPECT(r == XR_SESSION_NOT_FOCUSED, "sync while VISIBLE gave %d", r);
        set_focus("2");
        expect("VISIBLE -> FOCUSED", @"FOCUSED");
        EXPECT(xrSyncActions(ses, &syn) == XR_SUCCESS, "sync after refocus");

        set_focus("0");   // two steps; wake via xrWaitFrame, not xrPollEvent
        wait();
        expect("FOCUSED -> HIDDEN (via WaitFrame)", @"VISIBLE SYNCHRONIZED");
        wait();
        EXPECT(!fs.shouldRender, "shouldRender while SYNCHRONIZED");
        EXPECT(xrSyncActions(ses, &syn) == XR_SESSION_NOT_FOCUSED, "sync while SYNCHRONIZED");
        set_focus("2");
        expect("HIDDEN -> FOCUSED", @"VISIBLE FOCUSED");

        set_focus("1 0");   // visible but the compositor wants no frames
        wait();
        drain(); [log removeAllObjects];
        wait();
        EXPECT(!fs.shouldRender, "shouldRender false when should_render=0");
        printf("%-34s shouldRender=%d\n", "VISIBLE, should_render=0", fs.shouldRender);
        set_focus("2");
        expect("back to FOCUSED", @"FOCUSED");

        OK(xrRequestExitSession(ses));
        expect("exit request", @"VISIBLE SYNCHRONIZED STOPPING");
        set_focus("2"); usleep(150000);
        expect("no focus events while stopping", @"");
        OK(xrEndSession(ses));
        expect("end", @"IDLE EXITING");

        printf("%s (%d failures)\n", failures ? "FAILED" : "PASSED", failures);
        return failures ? 1 : 0;
    }
}
