// slots-check: a minimal OpenXR Metal app that draws a fixed picture for 40 frames, to compare
// what a runtime encodes (ALVRXR_DUMP) before and after a change to its frame path.
//
// Usage: slots-check RUNTIME.dylib bgra|half|quad
//   bgra   projection only, BGRA8Unorm_sRGB swapchains
//   half   projection only, RGBA16Float swapchains (linear)
//   quad   bgra's projection plus a half-transparent quad 1 m ahead in VIEW space
// Run headless with ALVRXR_DUMP and a scratch ALVRXR_CONFIG_DIR (docs/compositor.md).
//
// Build: clang -fobjc-arc -O2 -I $OPENXR/build/include -I $OPENXR/include tests/slots-check.m \
//            -framework Foundation -framework Metal -o build/slots-check

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <dlfcn.h>
#include <stdio.h>
#include <unistd.h>

#define XR_USE_GRAPHICS_API_METAL
#include <openxr/openxr.h>
#include <openxr/openxr_loader_negotiation.h>
#include <openxr/openxr_platform.h>

static PFN_xrGetInstanceProcAddr gipa;

#define XR(call)                                                                                   \
    do {                                                                                           \
        XrResult r_ = (call);                                                                      \
        if (XR_FAILED(r_)) { fprintf(stderr, "slots-check: %s failed: %d\n", #call, r_); exit(1); } \
    } while (0)
#define FN(name) PFN_##name name = NULL; XR(gipa(instance, #name, (PFN_xrVoidFunction *)&name))

// Gradients, a checkerboard and a different blue per eye, so a swapped, shifted, scaled or
// wrongly converted picture shows. Linear values out; an sRGB target encodes them.
static NSString *const kShaders =
    @"#include <metal_stdlib>\n"
     "using namespace metal;\n"
     "struct V { float4 pos [[position]]; };\n"
     "vertex V vs(uint vid [[vertex_id]]) {\n"
     "    float2 p = float2((vid << 1) & 2, vid & 2); V o; o.pos = float4(p * 2.0 - 1.0, 0, 1); return o;\n"
     "}\n"
     "fragment float4 eye(V in [[stage_in]], constant float4 &k [[buffer(0)]]) {\n"
     "    float2 uv = in.pos.xy / k.xy;\n"
     "    bool check = (uint(in.pos.x / 128) + uint(in.pos.y / 128)) & 1;\n"
     "    return float4(uv.x, uv.y * (check ? 1.0 : 0.6), k.z, 1);\n"
     "}\n"
     "fragment float4 quad_fs(V in [[stage_in]], constant float4 &k [[buffer(0)]]) {\n"
     "    float2 uv = in.pos.xy / k.xy;\n"
     "    return float4(0.5 * uv.y, 0.5 * (1 - uv.x), 0.25, 0.5);   // premultiplied, alpha 0.5\n"
     "}\n";

typedef struct {
    XrSwapchain chain;
    id<MTLTexture> images[8];
    uint32_t count, width, height;
} chain;

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc < 3) { fprintf(stderr, "usage: slots-check RUNTIME.dylib bgra|half|quad\n"); return 2; }
        const char *mode = argv[2];
        bool half = !strcmp(mode, "half"), with_quad = !strcmp(mode, "quad");
        void *lib = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
        if (!lib) { fprintf(stderr, "%s\n", dlerror()); return 1; }
        PFN_xrNegotiateLoaderRuntimeInterface negotiate = dlsym(lib, "xrNegotiateLoaderRuntimeInterface");
        XrNegotiateLoaderInfo li = {XR_LOADER_INTERFACE_STRUCT_LOADER_INFO, XR_LOADER_INFO_STRUCT_VERSION,
                                    sizeof li, 1, XR_CURRENT_LOADER_RUNTIME_VERSION, XR_MAKE_VERSION(1, 0, 0),
                                    XR_MAKE_VERSION(1, 0x3ff, 0xfff)};
        XrNegotiateRuntimeRequest rr = {XR_LOADER_INTERFACE_STRUCT_RUNTIME_REQUEST, XR_RUNTIME_INFO_STRUCT_VERSION,
                                        sizeof rr};
        if (!negotiate || XR_FAILED(negotiate(&li, &rr))) { fprintf(stderr, "no negotiation\n"); return 1; }
        gipa = rr.getInstanceProcAddr;
        XrInstance instance = XR_NULL_HANDLE;

        FN(xrCreateInstance);
        const char *exts[] = {XR_KHR_METAL_ENABLE_EXTENSION_NAME};
        XrInstanceCreateInfo ici = {XR_TYPE_INSTANCE_CREATE_INFO};
        strcpy(ici.applicationInfo.applicationName, "slots-check");
        ici.applicationInfo.apiVersion = XR_MAKE_VERSION(1, 0, 0);
        ici.enabledExtensionCount = 1;
        ici.enabledExtensionNames = exts;
        XR(xrCreateInstance(&ici, &instance));
        FN(xrGetSystem);
        FN(xrGetMetalGraphicsRequirementsKHR);
        FN(xrCreateSession);
        FN(xrDestroySession);
        FN(xrEnumerateViewConfigurationViews);
        FN(xrCreateSwapchain);
        FN(xrEnumerateSwapchainImages);
        FN(xrAcquireSwapchainImage);
        FN(xrWaitSwapchainImage);
        FN(xrReleaseSwapchainImage);
        FN(xrCreateReferenceSpace);
        FN(xrBeginSession);
        FN(xrWaitFrame);
        FN(xrBeginFrame);
        FN(xrEndFrame);
        FN(xrLocateViews);

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
        XrSessionBeginInfo sbi = {XR_TYPE_SESSION_BEGIN_INFO, NULL, XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO};
        XR(xrBeginSession(session, &sbi));

        NSError *err = nil;
        id<MTLLibrary> shaders = [dev newLibraryWithSource:kShaders options:nil error:&err];
        if (!shaders) { fprintf(stderr, "%s\n", err.localizedDescription.UTF8String); return 1; }
        MTLPixelFormat eye_format = half ? MTLPixelFormatRGBA16Float : MTLPixelFormatBGRA8Unorm_sRGB;
        id<MTLRenderPipelineState> (^pipeline)(NSString *, MTLPixelFormat) = ^(NSString *fs, MTLPixelFormat f) {
            MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new];
            d.vertexFunction = [shaders newFunctionWithName:@"vs"];
            d.fragmentFunction = [shaders newFunctionWithName:fs];
            d.colorAttachments[0].pixelFormat = f;
            NSError *e = nil;
            id<MTLRenderPipelineState> p = [dev newRenderPipelineStateWithDescriptor:d error:&e];
            if (!p) { fprintf(stderr, "%s\n", e.localizedDescription.UTF8String); exit(1); }
            return p;
        };
        id<MTLRenderPipelineState> eye_pso = pipeline(@"eye", eye_format);
        id<MTLRenderPipelineState> quad_pso = pipeline(@"quad_fs", MTLPixelFormatRGBA8Unorm_sRGB);

        chain (^make_chain)(MTLPixelFormat, uint32_t, uint32_t) = ^(MTLPixelFormat f, uint32_t w, uint32_t h) {
            chain c = {.width = w, .height = h};
            XrSwapchainCreateInfo ci = {XR_TYPE_SWAPCHAIN_CREATE_INFO};
            ci.usageFlags = XR_SWAPCHAIN_USAGE_COLOR_ATTACHMENT_BIT | XR_SWAPCHAIN_USAGE_SAMPLED_BIT;
            ci.format = f;
            ci.sampleCount = 1;
            ci.width = w;
            ci.height = h;
            ci.faceCount = ci.arraySize = ci.mipCount = 1;
            XR(xrCreateSwapchain(session, &ci, &c.chain));
            XrSwapchainImageMetalKHR imgs[8];
            for (int i = 0; i < 8; i++) imgs[i] = (XrSwapchainImageMetalKHR){XR_TYPE_SWAPCHAIN_IMAGE_METAL_KHR};
            XR(xrEnumerateSwapchainImages(c.chain, 8, &c.count, (XrSwapchainImageBaseHeader *)imgs));
            for (uint32_t i = 0; i < c.count; i++) c.images[i] = (__bridge id<MTLTexture>)imgs[i].texture;
            return c;
        };
        XrViewConfigurationView vcv[2] = {{XR_TYPE_VIEW_CONFIGURATION_VIEW}, {XR_TYPE_VIEW_CONFIGURATION_VIEW}};
        uint32_t nv = 0;
        XR(xrEnumerateViewConfigurationViews(instance, system, XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO, 2, &nv, vcv));
        chain eyes[2], q = {0};
        for (int e = 0; e < 2; e++)
            eyes[e] = make_chain(eye_format, vcv[e].recommendedImageRectWidth, vcv[e].recommendedImageRectHeight);
        if (with_quad) q = make_chain(MTLPixelFormatRGBA8Unorm_sRGB, 512, 512);
        printf("slots-check: %s, eyes %ux%u\n", mode, eyes[0].width, eyes[0].height);

        XrReferenceSpaceCreateInfo rci = {XR_TYPE_REFERENCE_SPACE_CREATE_INFO, NULL, XR_REFERENCE_SPACE_TYPE_STAGE,
                                          {{0, 0, 0, 1}, {0, 0, 0}}};
        XrSpace stage, view;
        XR(xrCreateReferenceSpace(session, &rci, &stage));
        rci.referenceSpaceType = XR_REFERENCE_SPACE_TYPE_VIEW;
        XR(xrCreateReferenceSpace(session, &rci, &view));

        // Draws a picture into the next image of c and releases it.
        void (^draw)(chain *, id<MTLRenderPipelineState>, float) = ^(chain *c, id<MTLRenderPipelineState> pso, float blue) {
            uint32_t i;
            XR(xrAcquireSwapchainImage(c->chain, NULL, &i));
            XrSwapchainImageWaitInfo wi = {XR_TYPE_SWAPCHAIN_IMAGE_WAIT_INFO, NULL, XR_INFINITE_DURATION};
            XR(xrWaitSwapchainImage(c->chain, &wi));
            MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
            pass.colorAttachments[0].texture = c->images[i];
            pass.colorAttachments[0].loadAction = MTLLoadActionDontCare;
            pass.colorAttachments[0].storeAction = MTLStoreActionStore;
            id<MTLCommandBuffer> cmd = [queue commandBuffer];
            id<MTLRenderCommandEncoder> enc = [cmd renderCommandEncoderWithDescriptor:pass];
            float k[4] = {c->width, c->height, blue, 0};
            [enc setRenderPipelineState:pso];
            [enc setFragmentBytes:k length:sizeof k atIndex:0];
            [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
            [enc endEncoding];
            [cmd commit];
            XR(xrReleaseSwapchainImage(c->chain, NULL));
        };

        for (int frame = 0; frame < 40; frame++) {
            XrFrameState fs = {XR_TYPE_FRAME_STATE};
            XR(xrWaitFrame(session, NULL, &fs));
            XR(xrBeginFrame(session, NULL));
            XrViewLocateInfo vli = {XR_TYPE_VIEW_LOCATE_INFO, NULL, XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO,
                                    fs.predictedDisplayTime, stage};
            XrViewState vs = {XR_TYPE_VIEW_STATE};
            XrView views[2] = {{XR_TYPE_VIEW}, {XR_TYPE_VIEW}};
            uint32_t n;
            XR(xrLocateViews(session, &vli, &vs, 2, &n, views));
            XrCompositionLayerProjectionView pv[2];
            for (int e = 0; e < 2; e++) {
                draw(&eyes[e], eye_pso, e ? 0.8f : 0.2f);
                pv[e] = (XrCompositionLayerProjectionView){XR_TYPE_COMPOSITION_LAYER_PROJECTION_VIEW, NULL, views[e].pose,
                                                           views[e].fov,
                                                           {eyes[e].chain, {{0, 0}, {(int32_t)eyes[e].width, (int32_t)eyes[e].height}}, 0}};
            }
            XrCompositionLayerProjection proj = {XR_TYPE_COMPOSITION_LAYER_PROJECTION, NULL, 0, stage, 2, pv};
            XrCompositionLayerQuad ql = {XR_TYPE_COMPOSITION_LAYER_QUAD, NULL, XR_COMPOSITION_LAYER_BLEND_TEXTURE_SOURCE_ALPHA_BIT,
                                         view, XR_EYE_VISIBILITY_BOTH, {q.chain, {{0, 0}, {512, 512}}, 0},
                                         {{0, 0, 0, 1}, {0.1f, 0.05f, -1}}, {0.6f, 0.6f}};
            if (with_quad) draw(&q, quad_pso, 0);
            const XrCompositionLayerBaseHeader *layers[2] = {(const XrCompositionLayerBaseHeader *)&proj,
                                                             (const XrCompositionLayerBaseHeader *)&ql};
            XrFrameEndInfo fei = {XR_TYPE_FRAME_END_INFO, NULL, fs.predictedDisplayTime, XR_ENVIRONMENT_BLEND_MODE_OPAQUE,
                                  with_quad ? 2 : 1, layers};
            XR(xrEndFrame(session, &fei));
        }
        usleep(500000);   // the last frames' encode
        XR(xrDestroySession(session));
        printf("slots-check: done\n");
    }
    return 0;
}
