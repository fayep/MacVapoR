// The runtime side of the dashboard (docs/compositor.md "Dashboard"), with no headset:
//   dashboard-check game   LEGACY, not vapord: an action bound to the system button reads 0 while
//                          one bound to A reads the fake press; exit_request (the test focus
//                          file's third number) gives VISIBLE SYNCHRONIZED STOPPING; the private
//                          functions return XR_ERROR_FUNCTION_UNSUPPORTED.
//   dashboard-check home   SERVER mode, as vapord: the system button reads 1; the private
//                          functions work: state (the held fake press has opened the dashboard
//                          over the lounge alone), close (and it stays closed while the press
//                          lasts), eye height (live in the state and in height.json), recenter,
//                          quit with no game.
// Build and run: tests/dashboard-check.sh (scratch ALVRXR_CONFIG_DIR, tune.json fake presses).
#define XR_USE_GRAPHICS_API_METAL
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <dlfcn.h>
#include <openxr/openxr.h>
#include <openxr/openxr_loader_negotiation.h>
#include <openxr/openxr_platform.h>
#include "alvrxr_ext.h"

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

int main(int argc, char **argv) {
    @autoreleasepool {
        bool home = argc > 1 && !strcmp(argv[1], "home");
        const char *cfg = getenv("ALVRXR_CONFIG_DIR"), *ff = getenv("ALVRXR_TEST_FOCUS_FILE"), *rt = getenv("ALVRXR_RUNTIME");
        if (!cfg || !rt || (!home && !ff)) { printf("set ALVRXR_CONFIG_DIR (scratch), ALVRXR_RUNTIME, and ALVRXR_TEST_FOCUS_FILE for game\n"); return 2; }
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
        strcpy(ici.applicationInfo.applicationName, "dashboard-check");
        ici.applicationInfo.apiVersion = XR_MAKE_VERSION(1, 0, 0);
        ici.enabledExtensionCount = 1;
        ici.enabledExtensionNames = exts;
        OK(create(&ici, &inst));
        FN(xrGetSystem); FN(xrGetMetalGraphicsRequirementsKHR); FN(xrCreateSession); FN(xrPollEvent);
        FN(xrBeginSession); FN(xrEndSession); FN(xrWaitFrame); FN(xrBeginFrame); FN(xrEndFrame);
        FN(xrStringToPath); FN(xrCreateActionSet); FN(xrCreateAction); FN(xrSuggestInteractionProfileBindings);
        FN(xrAttachSessionActionSets); FN(xrSyncActions); FN(xrGetActionStateBoolean);
        FN(xrGetDashboardStateALVRXR); FN(xrCloseDashboardALVRXR); FN(xrQuitGameALVRXR); FN(xrRecenterALVRXR); FN(xrSetEyeHeightALVRXR);
        EXPECT(xrGetDashboardStateALVRXR && xrCloseDashboardALVRXR && xrQuitGameALVRXR && xrRecenterALVRXR && xrSetEyeHeightALVRXR,
               "the private functions are looked up");
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
        XrAction sys_act, a_act;
        XrActionCreateInfo ai = {XR_TYPE_ACTION_CREATE_INFO};
        ai.actionType = XR_ACTION_TYPE_BOOLEAN_INPUT;
        strcpy(ai.actionName, "sys"); strcpy(ai.localizedActionName, "sys");
        OK(xrCreateAction(set, &ai, &sys_act));
        strcpy(ai.actionName, "a"); strcpy(ai.localizedActionName, "a");
        OK(xrCreateAction(set, &ai, &a_act));
        XrPath prof, sys_path, a_path;
        xrStringToPath(inst, "/interaction_profiles/oculus/touch_controller", &prof);
        xrStringToPath(inst, "/user/hand/right/input/system/click", &sys_path);
        xrStringToPath(inst, "/user/hand/right/input/a/click", &a_path);
        XrActionSuggestedBinding sb[2] = {{sys_act, sys_path}, {a_act, a_path}};
        XrInteractionProfileSuggestedBinding spb = {XR_TYPE_INTERACTION_PROFILE_SUGGESTED_BINDING, NULL, prof, 2, sb};
        OK(xrSuggestInteractionProfileBindings(inst, &spb));
        XrSessionActionSetsAttachInfo att = {XR_TYPE_SESSION_ACTION_SETS_ATTACH_INFO, NULL, 1, &set};
        OK(xrAttachSessionActionSets(ses, &att));

        NSMutableArray *log = [NSMutableArray array];
        void (^drain)(void) = ^{
            XrEventDataBuffer ev = {XR_TYPE_EVENT_DATA_BUFFER};
            while (xrPollEvent(inst, &ev) == XR_SUCCESS) {
                if (ev.type == XR_TYPE_EVENT_DATA_SESSION_STATE_CHANGED)
                    [log addObject:@(name(((XrEventDataSessionStateChanged *)&ev)->state))];
                ev = (XrEventDataBuffer){XR_TYPE_EVENT_DATA_BUFFER};
            }
        };
        void (^expect)(const char *, NSString *) = ^(const char *what, NSString *want) {
            drain();
            NSString *got = [log componentsJoinedByString:@" "];
            printf("%-40s %s\n", what, got.length ? got.UTF8String : "(none)");
            EXPECT([got isEqualToString:want], "%s: wanted '%s'", what, want.UTF8String);
            [log removeAllObjects];
        };
        if (ff) [@"2 1 0" writeToFile:@(ff) atomically:YES encoding:NSUTF8StringEncoding error:nil];
        usleep(150000);
        drain();   // IDLE READY
        [log removeAllObjects];
        XrSessionBeginInfo bi = {XR_TYPE_SESSION_BEGIN_INFO, NULL, XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO};
        OK(xrBeginSession(ses, &bi));
        expect("begin", @"SYNCHRONIZED VISIBLE FOCUSED");

        // The fake presses are read from tune.json by the server's event thread within a second.
        usleep(1500000);
        XrActiveActionSet aas = {set, XR_NULL_PATH};
        XrActionsSyncInfo syn = {XR_TYPE_ACTIONS_SYNC_INFO, NULL, 1, &aas};
        OK(xrSyncActions(ses, &syn));
        XrActionStateGetInfo gi = {XR_TYPE_ACTION_STATE_GET_INFO, NULL, sys_act, XR_NULL_PATH};
        XrActionStateBoolean sys_st = {XR_TYPE_ACTION_STATE_BOOLEAN}, a_st = {XR_TYPE_ACTION_STATE_BOOLEAN};
        OK(xrGetActionStateBoolean(ses, &gi, &sys_st));
        gi.action = a_act;
        OK(xrGetActionStateBoolean(ses, &gi, &a_st));
        printf("%-40s system/click %d (active %d), a/click %d (active %d)\n", home ? "home session" : "game session",
               sys_st.currentState, sys_st.isActive, a_st.currentState, a_st.isActive);
        EXPECT(a_st.currentState && a_st.isActive, "the A fake press reads as pressed");
        if (home) EXPECT(sys_st.currentState && sys_st.isActive, "vapord sees the system button");
        else EXPECT(!sys_st.currentState && sys_st.isActive, "a game gets 0 for the system button");

        XrDashboardStateALVRXR st;
        XrResult r = xrGetDashboardStateALVRXR(ses, &st);
        if (!home) {
            EXPECT(r == XR_ERROR_FUNCTION_UNSUPPORTED, "xrGetDashboardStateALVRXR in a game: %d", r);
            EXPECT(xrCloseDashboardALVRXR(ses) == XR_ERROR_FUNCTION_UNSUPPORTED && xrQuitGameALVRXR(ses) == XR_ERROR_FUNCTION_UNSUPPORTED &&
                   xrRecenterALVRXR(ses) == XR_ERROR_FUNCTION_UNSUPPORTED && xrSetEyeHeightALVRXR(ses, 1.2f) == XR_ERROR_FUNCTION_UNSUPPORTED,
                   "the other private functions are refused in a game");
            printf("%-40s refused, as they should be\n", "private functions");

            // The compositor's quit: exit_request in the session region (the test file's third number).
            [@"2 1 1" writeToFile:@(ff) atomically:YES encoding:NSUTF8StringEncoding error:nil];
            usleep(150000);
            expect("exit_request", @"VISIBLE SYNCHRONIZED STOPPING");
            [@"2 1 0" writeToFile:@(ff) atomically:YES encoding:NSUTF8StringEncoding error:nil];
            usleep(150000);
            expect("no focus events while stopping", @"");
            OK(xrEndSession(ses));
            expect("end", @"IDLE EXITING");
        } else {
            EXPECT(r == XR_SUCCESS, "xrGetDashboardStateALVRXR in vapord: %d", r);
            printf("%-40s open %u, game %u \"%s\", battery %.2f/%.2f/%.2f, %.0f fps %.1f Mbps, eye height %.2f offset %.2f\n", "state",
                   st.open, st.game_pid, st.game_name, st.battery[0], st.battery[1], st.battery[2], st.fps, st.mbps, st.eye_height, st.height_offset);
            // The fake press has been held over 0.5 s by now: the compositor opened it, over the lounge alone.
            EXPECT(st.open && st.game_pid == 0 && !st.game_name[0], "opened by the held button, no game");
            EXPECT(xrCloseDashboardALVRXR(ses) == XR_SUCCESS, "close");
            OK(xrGetDashboardStateALVRXR(ses, &st));
            EXPECT(!st.open, "closed by xrCloseDashboardALVRXR");
            usleep(700000);
            OK(xrGetDashboardStateALVRXR(ses, &st));
            EXPECT(!st.open, "stays closed while the button is still held (open %u)", st.open);
            printf("%-40s open %u after close, %u after 0.7 s more of the hold\n", "close", 0u, st.open);
            EXPECT(st.battery[0] == -1 && st.battery[1] == -1 && st.battery[2] == -1, "battery unknown with no headset");
            OK(xrSetEyeHeightALVRXR(ses, 1.2f));
            OK(xrGetDashboardStateALVRXR(ses, &st));
            printf("%-40s eye height %.2f, offset %.2f\n", "after xrSetEyeHeightALVRXR(1.2)", st.eye_height, st.height_offset);
            EXPECT(fabsf(st.eye_height - 1.2f) < 1e-6f && fabsf(st.height_offset - (1.2f - 1.6f)) < 1e-5f, "seated at 1.2 from the head at 1.6");
            NSString *hpath = [@(cfg) stringByAppendingPathComponent:@"height.json"];
            NSDictionary *hj = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:hpath] ?: [NSData data] options:0 error:nil];
            EXPECT(fabs([hj[@"eye_height"] doubleValue] - 1.2) < 1e-6, "height.json holds 1.2: %s", hj.description.UTF8String);
            OK(xrSetEyeHeightALVRXR(ses, 0));
            OK(xrGetDashboardStateALVRXR(ses, &st));
            hj = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:hpath] ?: [NSData data] options:0 error:nil];
            EXPECT(st.eye_height == 0 && st.height_offset == 0 && [hj[@"eye_height"] doubleValue] == 0, "standing again (height.json %s)", hj.description.UTF8String);
            EXPECT(xrSetEyeHeightALVRXR(ses, -1) == XR_ERROR_VALIDATION_FAILURE, "a negative height is refused");
            EXPECT(xrRecenterALVRXR(ses) == XR_SUCCESS, "recenter");
            EXPECT(xrCloseDashboardALVRXR(ses) == XR_SUCCESS, "close with nothing open");
            EXPECT(xrQuitGameALVRXR(ses) == XR_SUCCESS, "quit with no game");
            printf("%-40s state, eye height (live + height.json), recenter, close, quit\n", "private functions");
        }
        printf("%s (%d failures)\n", failures ? "FAILED" : "PASSED", failures);
        return failures ? 1 : 0;
    }
}
