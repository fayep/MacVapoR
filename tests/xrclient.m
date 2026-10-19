// A small OpenXR Metal client for testing sources and handovers without a headset.
// Each frame's content says who drew it and when: a solid colour per client, and the frame number
// as a row of bars at the centre of each eye (where ALVR's foveation squeezes least), so a frame
// decoded from ALVRXR_DUMP can be traced to the frame that made it. See tests/headless.sh.
//
// The bar row, in eye pixels from the eye's centre: cells of CELL x BAR_H, left to right: one white
// sync cell, 16 bits of the frame number (white 1, black 0), one black end cell. dumpcheck.m reads
// the same layout; keep the two in step.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <dlfcn.h>
#include <stdio.h>
#include <math.h>
#include <unistd.h>

#define XR_USE_GRAPHICS_API_METAL
#include <openxr/openxr.h>
#include <openxr/openxr_loader_negotiation.h>
#include <openxr/openxr_platform.h>

enum { CELL = 16, BAR_H = 64, BITS = 16 };

static PFN_xrGetInstanceProcAddr gipa;
static XrInstance instance;
static int g_id = 0;

static void say(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void say(const char *fmt, ...) {
    va_list a;
    va_start(a, fmt);
    fprintf(stderr, "xrclient: ");
    vfprintf(stderr, fmt, a);
    fprintf(stderr, "\n");
    va_end(a);
}
#define XR(call)                                                                      \
    do {                                                                              \
        XrResult r_ = (call);                                                         \
        if (XR_FAILED(r_)) { say("%s failed: %d", #call, r_); exit(1); }              \
    } while (0)
#define FN(name) PFN_##name name = NULL; XR(gipa(instance, #name, (PFN_xrVoidFunction *)&name))

static const char shader_src[] =
    "#include <metal_stdlib>\nusing namespace metal;\n"
    "vertex float4 vs(uint v [[vertex_id]]) { float2 p = float2((v << 1) & 2, v & 2); return float4(p * 2 - 1, 0, 1); }\n"
    "fragment float4 fs(constant float4 &c [[buffer(0)]]) { return c; }\n";

static float srgb_to_linear(float c) { return c <= 0.04045f ? c / 12.92f : powf((c + 0.055f) / 1.055f, 2.4f); }

static void fill(id<MTLRenderCommandEncoder> enc, NSUInteger x, NSUInteger y, NSUInteger w, NSUInteger h, const float rgb[3]) {
    // Both formats are written linear, so the stream carries the sRGB values asked for.
    float c[4] = {srgb_to_linear(rgb[0]), srgb_to_linear(rgb[1]), srgb_to_linear(rgb[2]), 1};
    [enc setScissorRect:(MTLScissorRect){x, y, w, h}];
    [enc setFragmentBytes:c length:sizeof c atIndex:0];
    [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
}

static void draw_eye(id<MTLCommandBuffer> cmd, id<MTLRenderPipelineState> pso, id<MTLTexture> tex, const float rgb[3], int number) {
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture = tex;
    rp.colorAttachments[0].loadAction = MTLLoadActionDontCare;
    rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLRenderCommandEncoder> enc = [cmd renderCommandEncoderWithDescriptor:rp];
    [enc setRenderPipelineState:pso];
    NSUInteger W = tex.width, H = tex.height;
    fill(enc, 0, 0, W, H, rgb);
    if (number >= 0) {
        NSUInteger x0 = W / 2 - (BITS + 2) * CELL / 2, y0 = H / 2 - BAR_H / 2;
        const float white[3] = {1, 1, 1}, black[3] = {0, 0, 0};
        fill(enc, x0, y0, CELL, BAR_H, white);
        for (int b = 0; b < BITS; b++)
            fill(enc, x0 + (1 + b) * CELL, y0, CELL, BAR_H, (number >> (BITS - 1 - b)) & 1 ? white : black);
        fill(enc, x0 + (1 + BITS) * CELL, y0, CELL, BAR_H, black);
    }
    [enc endEncoding];
}

static void usage(void) {
    fprintf(stderr,
            "usage: xrclient [--runtime PATH] [--color R,G,B] [--frames N] [--seconds S] [--quad] [--black-first N]\n"
            "                [--stall-after N MS] [--exit-after N] [--crash-after N] [--format bgra8srgb|rgba16f]\n"
            "colours are 0-255 sRGB; default runtime is the repo's out/libalvrxr.dylib.\n");
    exit(2);
}

int main(int argc, char **argv) {
    @autoreleasepool {
        NSString *runtime = nil;
        float color[3] = {200 / 255.f, 40 / 255.f, 40 / 255.f};
        int frames = 90, black_first = 0, stall_after = -1, stall_ms = 0, exit_after = -1, crash_after = -1;
        double seconds = 0;
        bool quad = false, f16 = false;
        for (int i = 1; i < argc; i++) {
            const char *a = argv[i];
            bool more = i + 1 < argc;
            if (!strcmp(a, "--runtime") && more) runtime = @(argv[++i]);
            else if (!strcmp(a, "--color") && more) {
                int r, g, b;
                if (sscanf(argv[++i], "%d,%d,%d", &r, &g, &b) != 3) usage();
                color[0] = r / 255.f; color[1] = g / 255.f; color[2] = b / 255.f;
            } else if (!strcmp(a, "--frames") && more) frames = atoi(argv[++i]);
            else if (!strcmp(a, "--seconds") && more) seconds = atof(argv[++i]);
            else if (!strcmp(a, "--quad")) quad = true;
            else if (!strcmp(a, "--black-first") && more) black_first = atoi(argv[++i]);
            else if (!strcmp(a, "--stall-after") && i + 2 < argc) { stall_after = atoi(argv[++i]); stall_ms = atoi(argv[++i]); }
            else if (!strcmp(a, "--exit-after") && more) exit_after = atoi(argv[++i]);
            else if (!strcmp(a, "--crash-after") && more) crash_after = atoi(argv[++i]);
            else if (!strcmp(a, "--format") && more) {
                const char *f = argv[++i];
                if (!strcmp(f, "rgba16f")) f16 = true;
                else if (strcmp(f, "bgra8srgb")) usage();
            } else usage();
        }
        if (!runtime) {
            // The binary lives in repo/build/tests.
            NSString *exe = NSBundle.mainBundle.executablePath ?: @(argv[0]);
            runtime = [[exe stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"../../out/libalvrxr.dylib"].stringByStandardizingPath;
        }
        setvbuf(stdout, NULL, _IOLBF, 0);

        // The same way vapord loads it: no OpenXR loader.
        void *lib = dlopen(runtime.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL);
        if (!lib) { say("%s", dlerror()); return 1; }
        PFN_xrNegotiateLoaderRuntimeInterface negotiate = dlsym(lib, "xrNegotiateLoaderRuntimeInterface");
        XrNegotiateLoaderInfo li = {XR_LOADER_INTERFACE_STRUCT_LOADER_INFO, XR_LOADER_INFO_STRUCT_VERSION, sizeof li, 1,
                                    XR_CURRENT_LOADER_RUNTIME_VERSION, XR_MAKE_VERSION(1, 0, 0), XR_MAKE_VERSION(1, 0x3ff, 0xfff)};
        XrNegotiateRuntimeRequest rr = {XR_LOADER_INTERFACE_STRUCT_RUNTIME_REQUEST, XR_RUNTIME_INFO_STRUCT_VERSION, sizeof rr};
        if (!negotiate || XR_FAILED(negotiate(&li, &rr))) { say("the runtime didn't negotiate"); return 1; }
        gipa = rr.getInstanceProcAddr;

        FN(xrCreateInstance);
        const char *exts[] = {XR_KHR_METAL_ENABLE_EXTENSION_NAME};
        XrInstanceCreateInfo ici = {XR_TYPE_INSTANCE_CREATE_INFO};
        strcpy(ici.applicationInfo.applicationName, "xrclient");
        strcpy(ici.applicationInfo.engineName, "xrclient");
        ici.applicationInfo.apiVersion = XR_MAKE_VERSION(1, 0, 0);
        ici.enabledExtensionCount = 1;
        ici.enabledExtensionNames = exts;
        XR(xrCreateInstance(&ici, &instance));
        FN(xrGetSystem); FN(xrGetMetalGraphicsRequirementsKHR); FN(xrCreateSession); FN(xrDestroySession);
        FN(xrDestroyInstance); FN(xrEnumerateViewConfigurationViews); FN(xrCreateSwapchain);
        FN(xrEnumerateSwapchainImages); FN(xrAcquireSwapchainImage); FN(xrWaitSwapchainImage);
        FN(xrReleaseSwapchainImage); FN(xrCreateReferenceSpace); FN(xrPollEvent); FN(xrBeginSession);
        FN(xrEndSession); FN(xrWaitFrame); FN(xrBeginFrame); FN(xrEndFrame); FN(xrLocateViews);
        FN(xrRequestExitSession);

        XrSystemGetInfo sgi = {XR_TYPE_SYSTEM_GET_INFO, NULL, XR_FORM_FACTOR_HEAD_MOUNTED_DISPLAY};
        XrSystemId system;
        XR(xrGetSystem(instance, &sgi, &system));
        XrGraphicsRequirementsMetalKHR req = {XR_TYPE_GRAPHICS_REQUIREMENTS_METAL_KHR};
        XR(xrGetMetalGraphicsRequirementsKHR(instance, system, &req));
        id<MTLDevice> dev = req.metalDevice ? (__bridge id<MTLDevice>)req.metalDevice : MTLCreateSystemDefaultDevice();
        id<MTLCommandQueue> queue = [dev newCommandQueue];
        XrGraphicsBindingMetalKHR binding = {XR_TYPE_GRAPHICS_BINDING_METAL_KHR, NULL, (__bridge void *)queue};
        XrSessionCreateInfo sci = {XR_TYPE_SESSION_CREATE_INFO, &binding, 0, system};
        XrSession session;
        XR(xrCreateSession(instance, &sci, &session));

        MTLPixelFormat pf = f16 ? MTLPixelFormatRGBA16Float : MTLPixelFormatBGRA8Unorm_sRGB;
        NSError *err = nil;
        id<MTLLibrary> mlib = [dev newLibraryWithSource:@(shader_src) options:nil error:&err];
        MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
        pd.vertexFunction = [mlib newFunctionWithName:@"vs"];
        pd.fragmentFunction = [mlib newFunctionWithName:@"fs"];
        pd.colorAttachments[0].pixelFormat = pf;
        id<MTLRenderPipelineState> pso = [dev newRenderPipelineStateWithDescriptor:pd error:&err];
        if (!pso) { say("pipeline: %s", err.localizedDescription.UTF8String); return 1; }

        XrViewConfigurationView vcv[2] = {{XR_TYPE_VIEW_CONFIGURATION_VIEW}, {XR_TYPE_VIEW_CONFIGURATION_VIEW}};
        uint32_t nv = 0;
        XR(xrEnumerateViewConfigurationViews(instance, system, XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO, 2, &nv, vcv));
        XrSwapchain chains[3];
        id<MTLTexture> images[3][8];
        uint32_t image_count[3];
        int nchains = quad ? 3 : 2;
        for (int c = 0; c < nchains; c++) {
            XrSwapchainCreateInfo ci = {XR_TYPE_SWAPCHAIN_CREATE_INFO};
            ci.usageFlags = XR_SWAPCHAIN_USAGE_COLOR_ATTACHMENT_BIT | XR_SWAPCHAIN_USAGE_SAMPLED_BIT;
            ci.format = pf;
            ci.sampleCount = 1;
            ci.width = c < 2 ? vcv[c].recommendedImageRectWidth : 256;
            ci.height = c < 2 ? vcv[c].recommendedImageRectHeight : 256;
            ci.faceCount = ci.arraySize = ci.mipCount = 1;
            XR(xrCreateSwapchain(session, &ci, &chains[c]));
            XrSwapchainImageMetalKHR imgs[8];
            for (int i = 0; i < 8; i++) imgs[i] = (XrSwapchainImageMetalKHR){XR_TYPE_SWAPCHAIN_IMAGE_METAL_KHR};
            XR(xrEnumerateSwapchainImages(chains[c], 8, &image_count[c], (XrSwapchainImageBaseHeader *)imgs));
            for (uint32_t i = 0; i < image_count[c]; i++) images[c][i] = (__bridge id<MTLTexture>)imgs[i].texture;
        }
        XrReferenceSpaceCreateInfo rci = {XR_TYPE_REFERENCE_SPACE_CREATE_INFO, NULL, XR_REFERENCE_SPACE_TYPE_STAGE, {{0, 0, 0, 1}, {0, 0, 0}}};
        XrSpace stage, view_space;
        XR(xrCreateReferenceSpace(session, &rci, &stage));
        rci.referenceSpaceType = XR_REFERENCE_SPACE_TYPE_VIEW;
        XR(xrCreateReferenceSpace(session, &rci, &view_space));
        // A colour unlike the client's, so a quad shows up apart from the eye fill.
        const float quad_color[3] = {40 / 255.f, 80 / 255.f, 230 / 255.f};

        say("%s: eye %ux%u, %s%s", runtime.UTF8String, vcv[0].recommendedImageRectWidth, vcv[0].recommendedImageRectHeight,
            f16 ? "rgba16f" : "bgra8srgb", quad ? ", quad" : "");

        bool running = false, exiting = false, done = false;
        int frame = 0;
        CFAbsoluteTime t0 = CFAbsoluteTimeGetCurrent();
        while (!done) {
            @autoreleasepool {
                XrEventDataBuffer ev = {XR_TYPE_EVENT_DATA_BUFFER};
                while (xrPollEvent(instance, &ev) == XR_SUCCESS) {
                    if (ev.type == XR_TYPE_EVENT_DATA_SESSION_STATE_CHANGED) {
                        XrEventDataSessionStateChanged *sc = (void *)&ev;
                        printf("state %d at frame %d\n", sc->state, frame);
                        if (sc->state == XR_SESSION_STATE_READY) {
                            XrSessionBeginInfo bi = {XR_TYPE_SESSION_BEGIN_INFO, NULL, XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO};
                            XR(xrBeginSession(session, &bi));
                            running = true;
                        } else if (sc->state == XR_SESSION_STATE_STOPPING) {
                            xrEndSession(session);
                            running = false;
                        } else if (sc->state == XR_SESSION_STATE_EXITING || sc->state == XR_SESSION_STATE_LOSS_PENDING) {
                            done = true;
                        }
                    }
                    ev = (XrEventDataBuffer){XR_TYPE_EVENT_DATA_BUFFER};
                }
                if (done) break;
                if (!running) { usleep(10000); continue; }

                if (!exiting && ((frames > 0 && frame >= frames) || (seconds > 0 && CFAbsoluteTimeGetCurrent() - t0 >= seconds) ||
                                 (exit_after >= 0 && frame >= exit_after))) {
                    exiting = true;
                    printf("requesting exit at frame %d\n", frame);
                    XR(xrRequestExitSession(session));
                }
                if (crash_after >= 0 && frame >= crash_after) { printf("crashing at frame %d\n", frame); fflush(stdout); abort(); }
                if (stall_after >= 0 && frame == stall_after + 1) {
                    printf("stalling %d ms after frame %d\n", stall_ms, stall_after);
                    usleep(stall_ms * 1000);
                }

                XrFrameState fs = {XR_TYPE_FRAME_STATE};
                XR(xrWaitFrame(session, NULL, &fs));
                XR(xrBeginFrame(session, NULL));
                frame++;
                bool black = frame <= black_first;
                printf("frame %d displayTime %lld shouldRender %d%s\n", frame, (long long)fs.predictedDisplayTime,
                       fs.shouldRender, black ? " black (no layers)" : "");
                if (!fs.shouldRender || black) {
                    XrFrameEndInfo idle = {XR_TYPE_FRAME_END_INFO, NULL, fs.predictedDisplayTime, XR_ENVIRONMENT_BLEND_MODE_OPAQUE, 0, NULL};
                    XR(xrEndFrame(session, &idle));
                    continue;
                }
                XrViewLocateInfo vli = {XR_TYPE_VIEW_LOCATE_INFO, NULL, XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO,
                                        fs.predictedDisplayTime, stage};
                XrViewState vs = {XR_TYPE_VIEW_STATE};
                XrView views[2] = {{XR_TYPE_VIEW}, {XR_TYPE_VIEW}};
                uint32_t n = 0;
                XR(xrLocateViews(session, &vli, &vs, 2, &n, views));

                id<MTLCommandBuffer> cmd = [queue commandBuffer];
                XrCompositionLayerProjectionView pv[2];
                for (int c = 0; c < nchains; c++) {
                    uint32_t idx;
                    XR(xrAcquireSwapchainImage(chains[c], NULL, &idx));
                    XrSwapchainImageWaitInfo wi = {XR_TYPE_SWAPCHAIN_IMAGE_WAIT_INFO, NULL, XR_INFINITE_DURATION};
                    XR(xrWaitSwapchainImage(chains[c], &wi));
                    draw_eye(cmd, pso, images[c][idx], c < 2 ? color : quad_color, c < 2 ? frame : -1);
                    if (c < 2)
                        pv[c] = (XrCompositionLayerProjectionView){XR_TYPE_COMPOSITION_LAYER_PROJECTION_VIEW, NULL, views[c].pose, views[c].fov,
                                                                   {chains[c], {{0, 0}, {(int32_t)vcv[c].recommendedImageRectWidth,
                                                                                         (int32_t)vcv[c].recommendedImageRectHeight}}, 0}};
                }
                [cmd commit];
                [cmd waitUntilScheduled];
                for (int c = 0; c < nchains; c++) XR(xrReleaseSwapchainImage(chains[c], NULL));

                XrCompositionLayerProjection layer = {XR_TYPE_COMPOSITION_LAYER_PROJECTION, NULL, 0, stage, 2, pv};
                XrCompositionLayerQuad ql = {XR_TYPE_COMPOSITION_LAYER_QUAD, NULL, 0, view_space, XR_EYE_VISIBILITY_BOTH,
                                             {chains[2], {{0, 0}, {256, 256}}, 0}, {{0, 0, 0, 1}, {0, -0.5f, -1}}, {0.4f, 0.4f}};
                const XrCompositionLayerBaseHeader *layers[] = {(const XrCompositionLayerBaseHeader *)&layer,
                                                                (const XrCompositionLayerBaseHeader *)&ql};
                XrFrameEndInfo fei = {XR_TYPE_FRAME_END_INFO, NULL, fs.predictedDisplayTime, XR_ENVIRONMENT_BLEND_MODE_OPAQUE,
                                      quad ? 2u : 1u, layers};
                XR(xrEndFrame(session, &fei));
            }
        }
        printf("done after %d frames\n", frame);
        xrDestroySession(session);
        xrDestroyInstance(instance);
        (void)g_id;
        return 0;
    }
}
