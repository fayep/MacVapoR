// vapord: MacVapoR's home scene. It holds the headset while no game does, drawing scene.metal
// through the alvrxr runtime like any OpenXR app. When a game starts, its runtime posts a claim
// (see claim_headset in backend.m) and vapord exits at once, which frees the ALVR server it ran;
// launchd starts it again, and it waits for the claiming game to end before taking the headset back.
//
// Usage: vapord [RUNTIME]   (default ~/Library/Application Support/MacVapoR/runtime/libalvrxr.dylib)

#import <CoreText/CoreText.h>
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <dlfcn.h>
#include <simd/simd.h>
#include <stdio.h>
#include <math.h>
#include <notify.h>
#include <signal.h>
#include <unistd.h>

#define XR_USE_GRAPHICS_API_METAL
#include <openxr/openxr.h>
#include <openxr/openxr_loader_negotiation.h>
#include <openxr/openxr_platform.h>

#include "scene_metal.h"

static PFN_xrGetInstanceProcAddr gipa;
static NSString *g_config_dir, *g_pid_path;

static void say(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
static void say(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *s = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    fprintf(stderr, "vapord: %s\n", s.UTF8String);
}

static pid_t pid_in(NSString *file) {
    return [NSString stringWithContentsOfFile:[g_config_dir stringByAppendingPathComponent:file]
                                     encoding:NSUTF8StringEncoding error:nil].intValue;
}

#define XR(call)                                                                                   \
    do {                                                                                           \
        XrResult r_ = (call);                                                                      \
        if (XR_FAILED(r_)) { say(@"%s failed: %d", #call, r_); exit(1); }                          \
    } while (0)
#define FN(name) PFN_##name name = NULL; XR(gipa(instance, #name, (PFN_xrVoidFunction *)&name))

// ------------------------------------------------------------------------------------- pictures

// As scene.metal's Board: its float3 takes 16 bytes, and its bool the first byte of flip.
typedef struct {
    float centre[3], pad0;
    float half_size[2];
    int texture;
    int flip;
} board_gpu;

static CGContextRef canvas(size_t w, size_t h) {
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef c = CGBitmapContextCreate(NULL, w, h, 8, w * 4, cs, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(cs);
    CGContextSetAllowsAntialiasing(c, true);
    CGContextSetShouldAntialias(c, true);
    return c;
}

static id<MTLTexture> texture_from(CGContextRef c, id<MTLDevice> dev, id<MTLCommandQueue> q) {
    size_t w = CGBitmapContextGetWidth(c), h = CGBitmapContextGetHeight(c);
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm_sRGB
                                                                                 width:w height:h mipmapped:YES];
    id<MTLTexture> t = [dev newTextureWithDescriptor:d];
    [t replaceRegion:MTLRegionMake2D(0, 0, w, h) mipmapLevel:0 withBytes:CGBitmapContextGetData(c) bytesPerRow:w * 4];
    id<MTLCommandBuffer> cmd = [q commandBuffer];
    id<MTLBlitCommandEncoder> blit = [cmd blitCommandEncoder];
    [blit generateMipmapsForTexture:t];
    [blit endEncoding];
    [cmd commit];
    [cmd waitUntilCompleted];
    CGContextRelease(c);
    return t;
}

static CGColorRef rgb(double r, double g, double b, double a) {
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGFloat comps[4] = {r, g, b, a};
    CGColorRef c = CGColorCreate(cs, comps);
    CGColorSpaceRelease(cs);
    return c;   // leaked: a handful, made once
}

static CGGradientRef gradient(int n, const CGFloat *colors, const CGFloat *stops) {
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGGradientRef g = CGGradientCreateWithColorComponents(cs, colors, stops, n);
    CGColorSpaceRelease(cs);
    return g;
}

// A line of text, sheared into an 80s italic, centred on (x, y).
static CTLineRef text_line(NSString *s, NSString *font_name, CGFloat size, CGFloat kern) {
    CGAffineTransform shear = CGAffineTransformMake(1, 0, 0.22, 1, 0, 0);
    CTFontRef font = CTFontCreateWithName((__bridge CFStringRef)font_name, size, &shear);
    NSAttributedString *a = [[NSAttributedString alloc]
        initWithString:s attributes:@{(id)kCTFontAttributeName : (__bridge id)font, (id)kCTKernAttributeName : @(kern)}];
    CFRelease(font);
    return CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)a);
}

static CGPoint centred(CGContextRef c, CTLineRef line, CGFloat x, CGFloat y) {
    CGRect b = CTLineGetImageBounds(line, c);
    return CGPointMake(x - b.size.width / 2 - b.origin.x, y - b.size.height / 2 - b.origin.y);
}

// "MACVAPOR" in chrome, with a neon glow, and a smaller line under it.
static CGContextRef draw_name(void) {
    CGContextRef c = canvas(2048, 768);
    CTLineRef title = text_line(@"MACVAPOR", @"Futura-CondensedExtraBold", 330, 10);
    CGPoint at = centred(c, title, 1024, 470);
    CGRect b = CTLineGetImageBounds(title, c);
    b.origin.x += at.x;
    b.origin.y += at.y;

    // Glow, then the chrome inside the letters, then a bright rim.
    CGContextSetLineJoin(c, kCGLineJoinRound);
    CGContextSetTextDrawingMode(c, kCGTextStroke);
    CGContextSetShadowWithColor(c, CGSizeZero, 40, rgb(0.0, 0.9, 1.0, 1.0));
    CGContextSetStrokeColorWithColor(c, rgb(0.0, 0.85, 1.0, 0.9));
    CGContextSetLineWidth(c, 14);
    CGContextSetTextPosition(c, at.x, at.y);
    CTLineDraw(title, c);
    CGContextSetShadowWithColor(c, CGSizeZero, 0, NULL);

    CGContextSaveGState(c);
    CGContextSetTextDrawingMode(c, kCGTextClip);
    CGContextSetTextPosition(c, at.x, at.y);
    CTLineDraw(title, c);
    // Chrome: a cyan floor, a sharp purple horizon, silver sky darkening to violet at the top.
    const CGFloat colors[] = {
        0.10, 0.75, 0.95, 1,   0.45, 0.95, 1.00, 1,   0.22, 0.05, 0.42, 1,   0.95, 0.96, 1.00, 1,
        0.80, 0.84, 0.95, 1,   0.42, 0.28, 0.80, 1,
    };
    const CGFloat stops[] = {0.0, 0.30, 0.47, 0.50, 0.70, 1.0};
    CGGradientRef g = gradient(6, colors, stops);
    CGContextDrawLinearGradient(c, g, CGPointMake(0, b.origin.y), CGPointMake(0, b.origin.y + b.size.height), 0);
    CGGradientRelease(g);
    CGContextRestoreGState(c);

    CGContextSetTextDrawingMode(c, kCGTextStroke);
    CGContextSetStrokeColorWithColor(c, rgb(0.92, 0.95, 1.0, 1.0));
    CGContextSetLineWidth(c, 3);
    CGContextSetTextPosition(c, at.x, at.y);
    CTLineDraw(title, c);
    CFRelease(title);

    CTLineRef sub = text_line(@"VISION PRO  ·  PC VR", @"AvenirNext-DemiBold", 92, 26);
    CGPoint sat = centred(c, sub, 1024, 150);
    CGContextSetTextDrawingMode(c, kCGTextFill);
    CGContextSetShadowWithColor(c, CGSizeZero, 24, rgb(0.62, 0.30, 0.95, 1.0));
    CGContextSetFillColorWithColor(c, rgb(0.0, 0.92, 1.0, 1.0));
    CGContextSetTextPosition(c, sat.x, sat.y);
    CTLineDraw(sub, c);
    CFRelease(sub);
    return c;
}

// A palm in silhouette against the sunset, edged in cyan.
static CGContextRef draw_palm(void) {
    CGContextRef c = canvas(512, 1024);
    CGColorRef dark = rgb(0.06, 0.01, 0.12, 1.0), rim = rgb(0.0, 0.9, 1.0, 0.55);
    CGPoint crown = CGPointMake(300, 800);

    CGMutablePathRef trunk = CGPathCreateMutable();
    CGPathMoveToPoint(trunk, NULL, 226, 0);
    CGPathAddQuadCurveToPoint(trunk, NULL, 200, 470, crown.x - 10, crown.y);
    CGPathAddLineToPoint(trunk, NULL, crown.x + 10, crown.y);
    CGPathAddQuadCurveToPoint(trunk, NULL, 236, 470, 282, 0);
    CGPathCloseSubpath(trunk);

    CGMutablePathRef fronds = CGPathCreateMutable();
    const CGFloat tips[][2] = {{40, 640}, {80, 820}, {190, 960}, {330, 990}, {470, 880}, {500, 700}, {420, 560},
                               {150, 560}};
    for (size_t i = 0; i < sizeof tips / sizeof tips[0]; i++) {
        CGPoint tip = CGPointMake(tips[i][0], tips[i][1]);
        // The leaf arches up out of the crown and droops to its tip.
        CGPoint ctrl = CGPointMake((crown.x + tip.x) / 2, MAX(crown.y, tip.y) + 70);
        CGFloat dx = tip.y - crown.y, dy = crown.x - tip.x, n = hypot(dx, dy);
        dx = dx / n * 26;
        dy = dy / n * 26;
        CGPathMoveToPoint(fronds, NULL, crown.x, crown.y);
        CGPathAddQuadCurveToPoint(fronds, NULL, ctrl.x + dx, ctrl.y + dy, tip.x, tip.y);
        CGPathAddQuadCurveToPoint(fronds, NULL, ctrl.x - dx, ctrl.y - dy, crown.x, crown.y);
        CGPathCloseSubpath(fronds);
    }
    for (int pass = 0; pass < 2; pass++) {
        CGContextAddPath(c, trunk);
        CGContextAddPath(c, fronds);
        if (pass == 0) {
            CGContextSetStrokeColorWithColor(c, rim);
            CGContextSetLineWidth(c, 6);
            CGContextStrokePath(c);
        } else {
            CGContextSetFillColorWithColor(c, dark);
            CGContextFillPath(c);
        }
    }
    CGPathRelease(trunk);
    CGPathRelease(fronds);
    return c;
}

// ---------------------------------------------------------------------------- hands, controllers

// The controllers: Sony's PS VR2 Sense models, as kept by tools/psvr2-models.py, part by part so
// the trigger, stick and buttons move as they do on the real ones; or failing those, the merged
// model it converts for OpenComposite. Either is in the model's own frame (SteamVR's, which lines
// up with the OpenXR grip as Quest controllers' does). The texture is the converted raw RGBA.
typedef struct {
    float pos[3], normal[3], uv[2];
} mesh_vertex;

typedef struct {
    id<MTLBuffer> vertices, indices;
    uint32_t index_count;
} mesh;

static bool load_mesh(NSString *path, bool flip_v, id<MTLDevice> dev, mesh *out) {
    FILE *f = fopen(path.fileSystemRepresentation, "r");
    if (!f) return false;
    NSMutableData *v = [NSMutableData data], *vt = [NSMutableData data], *vn = [NSMutableData data];
    NSMutableData *verts = [NSMutableData data], *idx = [NSMutableData data];
    NSMutableDictionary<NSString *, NSNumber *> *seen = [NSMutableDictionary dictionary];
    char line[1024];
    while (fgets(line, sizeof line, f)) {
        float a, b, c;
        if (!strncmp(line, "v ", 2) && sscanf(line + 2, "%f %f %f", &a, &b, &c) == 3) {
            float p[3] = {a, b, c};
            [v appendBytes:p length:sizeof p];
        } else if (!strncmp(line, "vt ", 3) && sscanf(line + 3, "%f %f", &a, &b) == 2) {
            float p[2] = {a, flip_v ? 1 - b : b};
            [vt appendBytes:p length:sizeof p];
        } else if (!strncmp(line, "vn ", 3) && sscanf(line + 3, "%f %f %f", &a, &b, &c) == 3) {
            float p[3] = {a, b, c};
            [vn appendBytes:p length:sizeof p];
        } else if (!strncmp(line, "f ", 2)) {
            uint32_t corner[16];
            int n = 0;
            char *save = NULL;
            for (char *tok = strtok_r(line + 2, " \r\n", &save); tok && n < 16; tok = strtok_r(NULL, " \r\n", &save)) {
                NSString *key = @(tok);
                NSNumber *known = seen[key];
                if (known) {
                    corner[n++] = known.unsignedIntValue;
                    continue;
                }
                int iv, it, in;
                if (sscanf(tok, "%d/%d/%d", &iv, &it, &in) != 3 || iv < 1 || it < 1 || in < 1 ||
                    (NSUInteger)iv > v.length / 12 || (NSUInteger)it > vt.length / 8 || (NSUInteger)in > vn.length / 12)
                    continue;
                mesh_vertex m;
                memcpy(m.pos, (const float *)v.bytes + 3 * (iv - 1), sizeof m.pos);
                memcpy(m.uv, (const float *)vt.bytes + 2 * (it - 1), sizeof m.uv);
                memcpy(m.normal, (const float *)vn.bytes + 3 * (in - 1), sizeof m.normal);
                uint32_t i = (uint32_t)(verts.length / sizeof m);
                [verts appendBytes:&m length:sizeof m];
                seen[key] = @(i);
                corner[n++] = i;
            }
            for (int k = 1; k + 1 < n; k++) {   // a fan, for any polygon
                uint32_t tri[3] = {corner[0], corner[k], corner[k + 1]};
                [idx appendBytes:tri length:sizeof tri];
            }
        }
    }
    fclose(f);
    if (!idx.length) return false;
    out->vertices = [dev newBufferWithBytes:verts.bytes length:verts.length options:MTLResourceStorageModeShared];
    out->indices = [dev newBufferWithBytes:idx.bytes length:idx.length options:MTLResourceStorageModeShared];
    out->index_count = (uint32_t)(idx.length / sizeof(uint32_t));
    return true;
}

static id<MTLTexture> load_rgba(NSString *path, id<MTLDevice> dev, id<MTLCommandQueue> q) {
    NSData *rgba = [NSData dataWithContentsOfFile:path];
    uint32_t w = 1, h = 1;
    const uint8_t *px = (const uint8_t[]){200, 205, 225, 255};   // silver, without a texture
    if (rgba.length > 8) {
        memcpy(&w, rgba.bytes, 4);
        memcpy(&h, (const uint8_t *)rgba.bytes + 4, 4);
        if (rgba.length >= 8 + (size_t)w * h * 4) px = (const uint8_t *)rgba.bytes + 8;
        else w = h = 1;
    }
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm_sRGB
                                                                                 width:w height:h mipmapped:YES];
    id<MTLTexture> t = [dev newTextureWithDescriptor:d];
    [t replaceRegion:MTLRegionMake2D(0, 0, w, h) mipmapLevel:0 withBytes:px bytesPerRow:w * 4];
    id<MTLCommandBuffer> cmd = [q commandBuffer];
    id<MTLBlitCommandEncoder> blit = [cmd blitCommandEncoder];
    [blit generateMipmapsForTexture:t];
    [blit endEncoding];
    [cmd commit];
    return t;
}

// What drives a part, and how it moves.
enum { IN_NONE, IN_TRIGGER, IN_SQUEEZE, IN_A, IN_B, IN_MENU, IN_SYSTEM, IN_STICK };
enum { MOVE_NONE, MOVE_ROTATE, MOVE_TRANSLATE, MOVE_JOYSTICK };

typedef struct {
    mesh m;
    int input, move;
    simd_float3 pivot, axis;   // rotate: about axis through pivot; translate: along axis
    float amount;              // degrees or metres, at full travel
    simd_float4x4 frame;       // joystick: its centre, turned as it sits
    float tilt;                // joystick: degrees at full deflection
    simd_float3 press;         // joystick: travel when clicked
} part;

typedef struct {
    part parts[16];
    int count;
    id<MTLTexture> texture;
} controller;

typedef struct {
    float trigger, squeeze, stick[2];
    bool trigger_touch, squeeze_touch, a, a_touch, b, b_touch, menu, menu_touch, system, system_touch, stick_click, stick_touch;
} hand_input;

static simd_float3 vec3(NSArray *a) {
    return a.count >= 3 ? simd_make_float3([a[0] floatValue], [a[1] floatValue], [a[2] floatValue]) : simd_make_float3(0, 0, 0);
}

static simd_float4x4 rotation(simd_float3 axis, float degrees) {
    return simd_matrix4x4(simd_quaternion(degrees * (float)M_PI / 180, simd_normalize(axis)));
}

static simd_float4x4 translation(simd_float3 t) {
    simd_float4x4 m = matrix_identity_float4x4;
    m.columns[3] = simd_make_float4(t, 1);
    return m;
}

static bool load_controller(NSString *dir, bool left, id<MTLDevice> dev, id<MTLCommandQueue> q, controller *c) {
    NSString *side = left ? @"left" : @"right";
    NSString *name = [@"playstation_vr2_sense_" stringByAppendingString:side];
    NSString *sony = [[dir stringByAppendingPathComponent:@"sony-source"] stringByAppendingPathComponent:name];
    c->count = 0;
    NSData *json = [NSData dataWithContentsOfFile:[sony stringByAppendingPathComponent:[name stringByAppendingString:@".json"]]];
    NSDictionary *components = json ? [NSJSONSerialization JSONObjectWithData:json options:0 error:nil][@"components"] : nil;
    NSDictionary *inputs = @{@"trigger" : @(IN_TRIGGER), @"button_grip" : @(IN_SQUEEZE), @"button_a" : @(IN_A),
                             @"button_b" : @(IN_B), @"button_option" : @(IN_MENU), @"button_enter" : @(IN_SYSTEM),
                             @"thumbstick" : @(IN_STICK)};
    for (NSString *key in components) {
        NSDictionary *comp = components[key];
        if (![comp[@"filename"] isKindOfClass:NSString.class] || c->count == 16) continue;
        part p = {0};
        if (!load_mesh([sony stringByAppendingPathComponent:comp[@"filename"]], true, dev, &p.m)) continue;
        NSDictionary *motion = comp[@"motion"];
        NSString *type = motion[@"type"];
        p.input = [inputs[key] intValue];
        NSArray *range = motion[@"value_mapping"];
        float full = range.count == 2 ? [range[1] floatValue] - [range[0] floatValue] : 0;
        if ([type isEqualToString:@"rotate"]) {
            p.move = MOVE_ROTATE;
            p.pivot = vec3(motion[@"pivot"]);
            p.axis = vec3(motion[@"axis"]);
            p.amount = full;
        } else if ([type isEqualToString:@"translate"]) {
            p.move = MOVE_TRANSLATE;
            p.axis = vec3(motion[@"axis"]);
            p.amount = full * 2;   // a millimetre is too little to see
        } else if ([type isEqualToString:@"joystick"]) {
            p.move = MOVE_JOYSTICK;
            NSArray *rot = comp[@"component_local"][@"rotate_xyz"];
            simd_float3 r = vec3(rot);
            p.frame = simd_mul(translation(vec3(motion[@"center"])),
                               simd_mul(simd_mul(rotation(simd_make_float3(1, 0, 0), r.x), rotation(simd_make_float3(0, 1, 0), r.y)),
                                        rotation(simd_make_float3(0, 0, 1), r.z)));
            NSArray *tx = motion[@"joystick_rotation_x"];
            p.tilt = tx.count == 2 ? fabsf([tx[0] floatValue]) : 16;
            p.press = vec3(motion[@"press_translate"]) * 2;
        }
        c->parts[c->count++] = p;
    }
    if (!c->count) {   // only the merged model
        part p = {0};
        if (!load_mesh([dir stringByAppendingPathComponent:[@"controller_" stringByAppendingFormat:@"%@.obj", side]], false, dev, &p.m))
            return false;
        c->parts[c->count++] = p;
    }
    c->texture = load_rgba([dir stringByAppendingPathComponent:[@"controller_" stringByAppendingFormat:@"%@.rgba", side]], dev, q);
    say(@"%@ controller: %d parts", side, c->count);
    return true;
}

// Where a part sits for these inputs, in the model's frame, and how it glows: cyan while touched,
// violet while pressed.
static simd_float4x4 part_pose(const part *p, const hand_input *in, simd_float4 *glow) {
    float value = 0;
    bool touched = false;
    switch (p->input) {
    case IN_TRIGGER: value = in->trigger; touched = in->trigger_touch || value > 0.02f; break;
    case IN_SQUEEZE: value = in->squeeze; touched = in->squeeze_touch || value > 0.02f; break;
    case IN_A: value = in->a; touched = in->a_touch; break;
    case IN_B: value = in->b; touched = in->b_touch; break;
    case IN_MENU: value = in->menu; touched = in->menu_touch; break;
    // Until visionOS lets the app have the PS button, the client sends Options as it too.
    case IN_SYSTEM: value = in->system && !in->menu; touched = in->system_touch && !in->menu_touch; break;
    case IN_STICK:
        value = in->stick_click;
        touched = in->stick_touch || fabsf(in->stick[0]) > 0.05f || fabsf(in->stick[1]) > 0.05f;
        break;
    }
    simd_float3 cyan = {0.0f, 0.55f, 0.65f}, violet = {0.45f, 0.15f, 0.75f};
    simd_float3 g = touched ? cyan * 0.6f : simd_make_float3(0, 0, 0);
    g = simd_mix(g, violet, simd_make_float3(1, 1, 1) * fminf(fmaxf((value - 0.5f) * 2, 0), 1));
    *glow = simd_make_float4(g, 0);

    switch (p->move) {
    case MOVE_ROTATE:
        return simd_mul(translation(p->pivot), simd_mul(rotation(p->axis, value * p->amount), translation(-p->pivot)));
    case MOVE_TRANSLATE:
        return translation(p->axis * (value * p->amount));
    case MOVE_JOYSTICK: {
        // The stick stands along its own z axis: forward tilts it about x, sideways about y.
        simd_float4x4 tilt = simd_mul(rotation(simd_make_float3(1, 0, 0), -in->stick[1] * p->tilt),
                                      rotation(simd_make_float3(0, 1, 0), -in->stick[0] * p->tilt));
        simd_float4x4 m = simd_mul(p->frame, simd_mul(tilt, simd_inverse(p->frame)));
        return simd_mul(translation(p->press * (in->stick_click ? 1.0f : 0.0f)), m);
    }
    default:
        return matrix_identity_float4x4;
    }
}

static simd_float4x4 pose_matrix(XrPosef p) {
    simd_float4x4 m = simd_matrix4x4(simd_quaternion(p.orientation.x, p.orientation.y, p.orientation.z, p.orientation.w));
    m.columns[3] = simd_make_float4(p.position.x, p.position.y, p.position.z, 1);
    return m;
}

static simd_float4x4 projection(XrFovf f, float n, float far) {
    float l = tanf(f.angleLeft), r = tanf(f.angleRight), u = tanf(f.angleUp), d = tanf(f.angleDown);
    simd_float4x4 m = {{
        {2 / (r - l), 0, 0, 0},
        {0, 2 / (u - d), 0, 0},
        {(r + l) / (r - l), (u + d) / (u - d), -far / (far - n), -1},
        {0, 0, -far * n / (far - n), 0},
    }};
    return m;
}

// The model's frame from the OpenXR grip: Sony's openxr_grip component, undone.
static simd_float4x4 grip_to_model(bool left) {
    float a = 20.6f * (float)M_PI / 180;
    simd_float4x4 c = simd_matrix4x4(simd_quaternion(a, simd_make_float3(1, 0, 0)));
    c.columns[3] = simd_make_float4(left ? 0.007f : -0.007f, -0.00182941f, 0.1019482f, 1);
    return simd_inverse(c);
}

typedef struct {
    float a_radius[4];
    float b[4];
    float colour[4];
} segment;   // as scene.metal's Segment

static float lin(float c) { return powf(c, 2.2f); }

// A hand in neon: a line along each bone, cyan, violet across the back of the hand, and a silver
// dot on each fingertip.
static void hand_lines(const XrHandJointLocationEXT *j, segment *out, int *n) {
    static const int parent[26] = {-1, -1, 1, 2, 3, 4, 1, 6, 7, 8, 9, 1, 11, 12, 13, 14, 1, 16, 17, 18, 19, 1, 21, 22, 23, 24};
    const float cyan[4] = {lin(0.0f), lin(0.92f), lin(1.0f), 1}, silver[4] = {lin(0.86f), lin(0.89f), lin(0.96f), 1},
                violet[4] = {lin(0.62f), lin(0.30f), lin(0.95f), 1};
    for (int i = 2; i < 26; i++) {
        XrVector3f a = j[parent[i]].pose.position, b = j[i].pose.position;
        bool metacarpal = parent[i] == XR_HAND_JOINT_WRIST_EXT;
        segment s = {{a.x, a.y, a.z, 0.0035f}, {b.x, b.y, b.z, 0}, {0}};
        memcpy(s.colour, metacarpal ? violet : cyan, sizeof s.colour);
        out[(*n)++] = s;
        if (i == 5 || i == 10 || i == 15 || i == 20 || i == 25) {
            segment tip = {{b.x, b.y, b.z, 0.0055f}, {b.x, b.y, b.z, 0}, {0}};
            memcpy(tip.colour, silver, sizeof tip.colour);
            out[(*n)++] = tip;
        }
    }
}

// ------------------------------------------------------------------------------------- the app

typedef struct {
    float rot0[4], rot1[4], rot2[4];
    float pos[4];
    float tan[4];
    float time[4];
} eye_uniform;

static void rotation_columns(XrQuaternionf q, eye_uniform *u) {
    float x = q.x, y = q.y, z = q.z, w = q.w;
    float c0[4] = {1 - 2 * (y * y + z * z), 2 * (x * y + z * w), 2 * (x * z - y * w), 0};
    float c1[4] = {2 * (x * y - z * w), 1 - 2 * (x * x + z * z), 2 * (y * z + x * w), 0};
    float c2[4] = {2 * (x * z + y * w), 2 * (y * z - x * w), 1 - 2 * (x * x + y * y), 0};
    memcpy(u->rot0, c0, sizeof c0);
    memcpy(u->rot1, c1, sizeof c1);
    memcpy(u->rot2, c2, sizeof c2);
}

int main(int argc, char **argv) {
    @autoreleasepool {
        g_config_dir = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/alvrxr"];
        g_pid_path = [g_config_dir stringByAppendingPathComponent:@"home.pid"];

        // A game holding the headset keeps it until it ends.
        for (pid_t game; (game = pid_in(@"claim.pid")) > 0 && game != getpid() && kill(game, 0) == 0;) sleep(2);

        [[NSString stringWithFormat:@"%d\n", getpid()] writeToFile:g_pid_path atomically:YES
                                                         encoding:NSUTF8StringEncoding error:nil];
        int token;
        notify_register_dispatch("com.zippysoft.macvapor.claim", &token, dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0),
                                 ^(int t) {
                                     (void)t;
                                     unlink(g_pid_path.fileSystemRepresentation);
                                     _exit(0);   // the ALVR server goes with the process
                                 });

        setenv("ALVRXR_HOME", "1", 1);
        NSString *runtime = argc > 1 ? @(argv[1])
                                     : [NSHomeDirectory() stringByAppendingPathComponent:
                                                              @"Library/Application Support/MacVapoR/runtime/libalvrxr.dylib"];
        void *lib = dlopen(runtime.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL);
        if (!lib) { say(@"%s", dlerror()); return 1; }
        PFN_xrNegotiateLoaderRuntimeInterface negotiate = dlsym(lib, "xrNegotiateLoaderRuntimeInterface");
        XrNegotiateLoaderInfo li = {XR_LOADER_INTERFACE_STRUCT_LOADER_INFO, XR_LOADER_INFO_STRUCT_VERSION,
                                    sizeof li, 1, XR_CURRENT_LOADER_RUNTIME_VERSION, XR_MAKE_VERSION(1, 0, 0),
                                    XR_MAKE_VERSION(1, 0x3ff, 0xfff)};
        XrNegotiateRuntimeRequest rr = {XR_LOADER_INTERFACE_STRUCT_RUNTIME_REQUEST, XR_RUNTIME_INFO_STRUCT_VERSION,
                                        sizeof rr};
        if (!negotiate || XR_FAILED(negotiate(&li, &rr))) { say(@"the runtime didn't negotiate"); return 1; }
        gipa = rr.getInstanceProcAddr;
        XrInstance instance = XR_NULL_HANDLE;

        FN(xrCreateInstance);
        const char *exts[] = {XR_KHR_METAL_ENABLE_EXTENSION_NAME, XR_EXT_HAND_TRACKING_EXTENSION_NAME};
        XrInstanceCreateInfo ici = {XR_TYPE_INSTANCE_CREATE_INFO};
        strcpy(ici.applicationInfo.applicationName, "MacVapoR Home");
        strcpy(ici.applicationInfo.engineName, "vapord");
        ici.applicationInfo.apiVersion = XR_MAKE_VERSION(1, 0, 0);
        ici.enabledExtensionCount = 2;
        ici.enabledExtensionNames = exts;
        XR(xrCreateInstance(&ici, &instance));
        FN(xrGetSystem);
        FN(xrGetMetalGraphicsRequirementsKHR);
        FN(xrCreateSession);
        FN(xrEnumerateViewConfigurationViews);
        FN(xrCreateSwapchain);
        FN(xrEnumerateSwapchainImages);
        FN(xrAcquireSwapchainImage);
        FN(xrWaitSwapchainImage);
        FN(xrReleaseSwapchainImage);
        FN(xrCreateReferenceSpace);
        FN(xrPollEvent);
        FN(xrBeginSession);
        FN(xrEndSession);
        FN(xrWaitFrame);
        FN(xrBeginFrame);
        FN(xrEndFrame);
        FN(xrLocateViews);
        FN(xrStringToPath);
        FN(xrCreateActionSet);
        FN(xrCreateAction);
        FN(xrSuggestInteractionProfileBindings);
        FN(xrAttachSessionActionSets);
        FN(xrCreateActionSpace);
        FN(xrSyncActions);
        FN(xrLocateSpace);
        FN(xrCreateHandTrackerEXT);
        FN(xrLocateHandJointsEXT);
        FN(xrGetActionStateBoolean);
        FN(xrGetActionStateFloat);
        FN(xrGetActionStateVector2f);

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

        XrViewConfigurationView vcv[2] = {{XR_TYPE_VIEW_CONFIGURATION_VIEW}, {XR_TYPE_VIEW_CONFIGURATION_VIEW}};
        uint32_t nv = 0;
        XR(xrEnumerateViewConfigurationViews(instance, system, XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO, 2, &nv, vcv));
        XrSwapchain chains[2];
        id<MTLTexture> images[2][4];
        uint32_t image_count[2];
        for (int e = 0; e < 2; e++) {
            XrSwapchainCreateInfo ci = {XR_TYPE_SWAPCHAIN_CREATE_INFO};
            ci.usageFlags = XR_SWAPCHAIN_USAGE_COLOR_ATTACHMENT_BIT | XR_SWAPCHAIN_USAGE_SAMPLED_BIT;
            ci.format = MTLPixelFormatBGRA8Unorm_sRGB;
            ci.sampleCount = 1;
            ci.width = vcv[e].recommendedImageRectWidth;
            ci.height = vcv[e].recommendedImageRectHeight;
            ci.faceCount = ci.arraySize = ci.mipCount = 1;
            XR(xrCreateSwapchain(session, &ci, &chains[e]));
            XrSwapchainImageMetalKHR imgs[4];
            for (int i = 0; i < 4; i++) imgs[i] = (XrSwapchainImageMetalKHR){XR_TYPE_SWAPCHAIN_IMAGE_METAL_KHR};
            XR(xrEnumerateSwapchainImages(chains[e], 4, &image_count[e], (XrSwapchainImageBaseHeader *)imgs));
            for (uint32_t i = 0; i < image_count[e]; i++) images[e][i] = (__bridge id<MTLTexture>)imgs[i].texture;
        }
        XrReferenceSpaceCreateInfo rci = {XR_TYPE_REFERENCE_SPACE_CREATE_INFO, NULL, XR_REFERENCE_SPACE_TYPE_STAGE,
                                          {{0, 0, 0, 1}, {0, 0, 0}}};
        XrSpace stage;
        XR(xrCreateReferenceSpace(session, &rci, &stage));

        // Each hand's grip, and its joints.
        XrPath hands[2], touch;
        XR(xrStringToPath(instance, "/user/hand/left", &hands[0]));
        XR(xrStringToPath(instance, "/user/hand/right", &hands[1]));
        XR(xrStringToPath(instance, "/interaction_profiles/oculus/touch_controller", &touch));
        XrActionSetCreateInfo asci = {XR_TYPE_ACTION_SET_CREATE_INFO};
        strcpy(asci.actionSetName, "home");
        strcpy(asci.localizedActionSetName, "Home");
        XrActionSet set;
        XR(xrCreateActionSet(instance, &asci, &set));
        XrActionCreateInfo aci = {XR_TYPE_ACTION_CREATE_INFO};
        strcpy(aci.actionName, "grip");
        strcpy(aci.localizedActionName, "Grip");
        aci.actionType = XR_ACTION_TYPE_POSE_INPUT;
        aci.countSubactionPaths = 2;
        aci.subactionPaths = hands;
        XrAction grip;
        XR(xrCreateAction(set, &aci, &grip));
        // The controls the models show, each bound on both hands (Touch's x and y are the left's a and b).
        // Grip touch, Options touch, the right Options button and PS aren't Touch's, but ALVR passes them on.
        enum { A_TRIGGER, A_TRIGGER_TOUCH, A_SQUEEZE, A_SQUEEZE_TOUCH, A_A, A_A_TOUCH, A_B, A_B_TOUCH, A_MENU, A_MENU_TOUCH,
               A_SYSTEM, A_SYSTEM_TOUCH, A_STICK, A_STICK_CLICK, A_STICK_TOUCH, A_COUNT };
        const struct { const char *name; XrActionType type; const char *left, *right; } controls[A_COUNT] = {
            {"trigger", XR_ACTION_TYPE_FLOAT_INPUT, "trigger/value", "trigger/value"},
            {"trigger_touch", XR_ACTION_TYPE_BOOLEAN_INPUT, "trigger/touch", "trigger/touch"},
            {"squeeze", XR_ACTION_TYPE_FLOAT_INPUT, "squeeze/value", "squeeze/value"},
            {"squeeze_touch", XR_ACTION_TYPE_BOOLEAN_INPUT, "squeeze/touch", "squeeze/touch"},
            {"a", XR_ACTION_TYPE_BOOLEAN_INPUT, "x/click", "a/click"},
            {"a_touch", XR_ACTION_TYPE_BOOLEAN_INPUT, "x/touch", "a/touch"},
            {"b", XR_ACTION_TYPE_BOOLEAN_INPUT, "y/click", "b/click"},
            {"b_touch", XR_ACTION_TYPE_BOOLEAN_INPUT, "y/touch", "b/touch"},
            {"menu", XR_ACTION_TYPE_BOOLEAN_INPUT, "menu/click", "menu/click"},
            {"menu_touch", XR_ACTION_TYPE_BOOLEAN_INPUT, "menu/touch", "menu/touch"},
            {"system", XR_ACTION_TYPE_BOOLEAN_INPUT, "system/click", "system/click"},
            {"system_touch", XR_ACTION_TYPE_BOOLEAN_INPUT, "system/touch", "system/touch"},
            {"stick", XR_ACTION_TYPE_VECTOR2F_INPUT, "thumbstick", "thumbstick"},
            {"stick_click", XR_ACTION_TYPE_BOOLEAN_INPUT, "thumbstick/click", "thumbstick/click"},
            {"stick_touch", XR_ACTION_TYPE_BOOLEAN_INPUT, "thumbstick/touch", "thumbstick/touch"},
        };
        XrAction control[A_COUNT];
        XrActionSuggestedBinding sb[2 + 2 * A_COUNT] = {{grip}, {grip}};
        XR(xrStringToPath(instance, "/user/hand/left/input/grip/pose", &sb[0].binding));
        XR(xrStringToPath(instance, "/user/hand/right/input/grip/pose", &sb[1].binding));
        uint32_t nsb = 2;
        for (int i = 0; i < A_COUNT; i++) {
            XrActionCreateInfo ci = {XR_TYPE_ACTION_CREATE_INFO};
            strcpy(ci.actionName, controls[i].name);
            strcpy(ci.localizedActionName, controls[i].name);
            ci.actionType = controls[i].type;
            ci.countSubactionPaths = 2;
            ci.subactionPaths = hands;
            XR(xrCreateAction(set, &ci, &control[i]));
            for (int h = 0; h < 2; h++) {
                const char *path = h ? controls[i].right : controls[i].left;
                if (!path) continue;
                char full[128];
                snprintf(full, sizeof full, "/user/hand/%s/input/%s", h ? "right" : "left", path);
                sb[nsb].action = control[i];
                XR(xrStringToPath(instance, full, &sb[nsb++].binding));
            }
        }
        XrInteractionProfileSuggestedBinding ipsb = {XR_TYPE_INTERACTION_PROFILE_SUGGESTED_BINDING, NULL, touch, nsb, sb};
        XR(xrSuggestInteractionProfileBindings(instance, &ipsb));
        XrSessionActionSetsAttachInfo attach = {XR_TYPE_SESSION_ACTION_SETS_ATTACH_INFO, NULL, 1, &set};
        XR(xrAttachSessionActionSets(session, &attach));
        XrSpace grip_space[2];
        XrHandTrackerEXT trackers[2];
        for (int h = 0; h < 2; h++) {
            XrActionSpaceCreateInfo asi = {XR_TYPE_ACTION_SPACE_CREATE_INFO, NULL, grip, hands[h], {{0, 0, 0, 1}, {0, 0, 0}}};
            XR(xrCreateActionSpace(session, &asi, &grip_space[h]));
            XrHandTrackerCreateInfoEXT hci = {XR_TYPE_HAND_TRACKER_CREATE_INFO_EXT, NULL, h ? XR_HAND_RIGHT_EXT : XR_HAND_LEFT_EXT,
                                              XR_HAND_JOINT_SET_DEFAULT_EXT};
            XR(xrCreateHandTrackerEXT(session, &hci, &trackers[h]));
        }
        NSString *models_dir = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/MacVapoR/rendermodels"];
        controller controllers[2];
        bool have_model[2];
        for (int h = 0; h < 2; h++) have_model[h] = load_controller(models_dir, h == 0, dev, queue, &controllers[h]);

        NSError *err = nil;
        id<MTLLibrary> mlib = [dev newLibraryWithSource:@(scene_metal) options:nil error:&err];
        if (!mlib) { say(@"scene shader: %@", err); return 1; }
        MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
        pd.vertexFunction = [mlib newFunctionWithName:@"vs"];
        pd.fragmentFunction = [mlib newFunctionWithName:@"fs"];
        pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm_sRGB;
        pd.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
        id<MTLRenderPipelineState> pso = [dev newRenderPipelineStateWithDescriptor:pd error:&err];
        if (!pso) { say(@"scene pipeline: %@", err); return 1; }
        pd.vertexFunction = [mlib newFunctionWithName:@"mesh_vs"];
        pd.fragmentFunction = [mlib newFunctionWithName:@"mesh_fs"];
        id<MTLRenderPipelineState> mesh_pso = [dev newRenderPipelineStateWithDescriptor:pd error:&err];
        if (!mesh_pso) { say(@"controller pipeline: %@", err); return 1; }
        pd.vertexFunction = [mlib newFunctionWithName:@"line_vs"];
        pd.fragmentFunction = [mlib newFunctionWithName:@"line_fs"];
        pd.colorAttachments[0].blendingEnabled = YES;
        pd.colorAttachments[0].sourceRGBBlendFactor = pd.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
        pd.colorAttachments[0].destinationRGBBlendFactor = pd.colorAttachments[0].destinationAlphaBlendFactor =
            MTLBlendFactorOneMinusSourceAlpha;
        id<MTLRenderPipelineState> line_pso = [dev newRenderPipelineStateWithDescriptor:pd error:&err];
        if (!line_pso) { say(@"hand pipeline: %@", err); return 1; }
        MTLDepthStencilDescriptor *dsd = [MTLDepthStencilDescriptor new];
        id<MTLDepthStencilState> no_depth = [dev newDepthStencilStateWithDescriptor:dsd];
        dsd.depthCompareFunction = MTLCompareFunctionLess;
        dsd.depthWriteEnabled = YES;
        id<MTLDepthStencilState> depth_write = [dev newDepthStencilStateWithDescriptor:dsd];
        dsd.depthWriteEnabled = NO;
        id<MTLDepthStencilState> depth_test = [dev newDepthStencilStateWithDescriptor:dsd];
        id<MTLTexture> depth[2];
        for (int e = 0; e < 2; e++) {
            MTLTextureDescriptor *dd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float
                                                                                          width:vcv[e].recommendedImageRectWidth
                                                                                         height:vcv[e].recommendedImageRectHeight
                                                                                      mipmapped:NO];
            dd.usage = MTLTextureUsageRenderTarget;
            dd.storageMode = MTLStorageModeMemoryless;
            depth[e] = [dev newTextureWithDescriptor:dd];
        }
        id<MTLTexture> tex_name = texture_from(draw_name(), dev, queue);
        id<MTLTexture> tex_palm = texture_from(draw_palm(), dev, queue);

        // Furthest first: the name over the sea, then palms along the beach.
        const struct { float x, h; bool flip; } palms[] = {
            {-15, 8, true}, {-10.5, 6.5, false}, {-6.8, 8.8, true}, {6.8, 7.2, false}, {10.8, 9, true}, {15.5, 6.8, false},
        };
        board_gpu boards[16];
        int nb = 0;
        boards[nb++] = (board_gpu){{0, 6.6f, -18}, 0, {9.5f, 9.5f * 768 / 2048}, 0, 0};
        for (size_t i = 0; i < sizeof palms / sizeof palms[0]; i++)
            boards[nb++] = (board_gpu){{palms[i].x, palms[i].h / 2, -14.2f}, 0, {palms[i].h / 4, palms[i].h / 2}, 1, palms[i].flip};

        say(@"home scene up");
        bool running = false;
        CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
        for (;;) {
            @autoreleasepool {
                XrEventDataBuffer ev = {XR_TYPE_EVENT_DATA_BUFFER};
                while (xrPollEvent(instance, &ev) == XR_SUCCESS) {
                    if (ev.type == XR_TYPE_EVENT_DATA_SESSION_STATE_CHANGED) {
                        XrSessionState st = ((XrEventDataSessionStateChanged *)&ev)->state;
                        if (st == XR_SESSION_STATE_READY) {
                            XrSessionBeginInfo bi = {XR_TYPE_SESSION_BEGIN_INFO, NULL,
                                                     XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO};
                            XR(xrBeginSession(session, &bi));
                            running = true;
                        } else if (st == XR_SESSION_STATE_STOPPING) {
                            xrEndSession(session);
                            running = false;
                        } else if (st == XR_SESSION_STATE_EXITING || st == XR_SESSION_STATE_LOSS_PENDING) {
                            unlink(g_pid_path.fileSystemRepresentation);
                            return 0;
                        }
                    }
                    ev = (XrEventDataBuffer){XR_TYPE_EVENT_DATA_BUFFER};
                }
                if (!running) {
                    usleep(20000);
                    continue;
                }

                XrFrameState fs = {XR_TYPE_FRAME_STATE};
                XR(xrWaitFrame(session, NULL, &fs));
                XR(xrBeginFrame(session, NULL));
                if (!fs.shouldRender) {   // no headset: an empty frame keeps the session going
                    XrFrameEndInfo idle = {XR_TYPE_FRAME_END_INFO, NULL, fs.predictedDisplayTime,
                                           XR_ENVIRONMENT_BLEND_MODE_OPAQUE, 0, NULL};
                    XR(xrEndFrame(session, &idle));
                    continue;
                }
                XrViewLocateInfo vli = {XR_TYPE_VIEW_LOCATE_INFO, NULL, XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO,
                                        fs.predictedDisplayTime, stage};
                XrViewState vs = {XR_TYPE_VIEW_STATE};
                XrView views[2] = {{XR_TYPE_VIEW}, {XR_TYPE_VIEW}};
                uint32_t n = 0;
                XR(xrLocateViews(session, &vli, &vs, 2, &n, views));

                // Each hand: a controller where one's held, its joints where it's bare.
                XrActiveActionSet active = {set, XR_NULL_PATH};
                XrActionsSyncInfo sync = {XR_TYPE_ACTIONS_SYNC_INFO, NULL, 1, &active};
                xrSyncActions(session, &sync);
                bool show_controller[2] = {false, false};
                simd_float4x4 controller_model[2];
                hand_input input[2] = {0};
                for (int h = 0; h < 2; h++) {
                    for (int i = 0; i < A_COUNT; i++) {
                        XrActionStateGetInfo gi = {XR_TYPE_ACTION_STATE_GET_INFO, NULL, control[i], hands[h]};
                        if (controls[i].type == XR_ACTION_TYPE_FLOAT_INPUT) {
                            XrActionStateFloat f = {XR_TYPE_ACTION_STATE_FLOAT};
                            xrGetActionStateFloat(session, &gi, &f);
                            if (i == A_TRIGGER) input[h].trigger = f.currentState;
                            else input[h].squeeze = f.currentState;
                        } else if (controls[i].type == XR_ACTION_TYPE_VECTOR2F_INPUT) {
                            XrActionStateVector2f v2 = {XR_TYPE_ACTION_STATE_VECTOR2F};
                            xrGetActionStateVector2f(session, &gi, &v2);
                            input[h].stick[0] = v2.currentState.x;
                            input[h].stick[1] = v2.currentState.y;
                        } else {
                            XrActionStateBoolean b = {XR_TYPE_ACTION_STATE_BOOLEAN};
                            xrGetActionStateBoolean(session, &gi, &b);
                            bool on = b.currentState;
                            switch (i) {
                            case A_TRIGGER_TOUCH: input[h].trigger_touch = on; break;
                            case A_A: input[h].a = on; break;
                            case A_A_TOUCH: input[h].a_touch = on; break;
                            case A_B: input[h].b = on; break;
                            case A_B_TOUCH: input[h].b_touch = on; break;
                            case A_SQUEEZE_TOUCH: input[h].squeeze_touch = on; break;
                            case A_MENU: input[h].menu = on; break;
                            case A_MENU_TOUCH: input[h].menu_touch = on; break;
                            case A_SYSTEM: input[h].system = on; break;
                            case A_SYSTEM_TOUCH: input[h].system_touch = on; break;
                            case A_STICK_CLICK: input[h].stick_click = on; break;
                            case A_STICK_TOUCH: input[h].stick_touch = on; break;
                            }
                        }
                    }
                }
                segment lines[2 * 29];
                int nlines = 0;
                for (int h = 0; h < 2; h++) {
                    XrSpaceLocation sl = {XR_TYPE_SPACE_LOCATION};
                    XrSpaceLocationFlags want = XR_SPACE_LOCATION_POSITION_TRACKED_BIT | XR_SPACE_LOCATION_ORIENTATION_TRACKED_BIT;
                    if (have_model[h] && XR_SUCCEEDED(xrLocateSpace(grip_space[h], stage, fs.predictedDisplayTime, &sl)) &&
                        (sl.locationFlags & want) == want) {
                        show_controller[h] = true;
                        controller_model[h] = simd_mul(pose_matrix(sl.pose), grip_to_model(h == 0));
                        continue;
                    }
                    XrHandJointLocationEXT joints[XR_HAND_JOINT_COUNT_EXT];
                    XrHandJointLocationsEXT jl = {XR_TYPE_HAND_JOINT_LOCATIONS_EXT, NULL, XR_FALSE, XR_HAND_JOINT_COUNT_EXT, joints};
                    XrHandJointsLocateInfoEXT hli = {XR_TYPE_HAND_JOINTS_LOCATE_INFO_EXT, NULL, stage, fs.predictedDisplayTime};
                    if (XR_SUCCEEDED(xrLocateHandJointsEXT(trackers[h], &hli, &jl)) && jl.isActive) hand_lines(joints, lines, &nlines);
                }

                XrCompositionLayerProjectionView pv[2];
                id<MTLCommandBuffer> cmd = [queue commandBuffer];
                for (int e = 0; e < 2; e++) {
                    uint32_t idx;
                    XR(xrAcquireSwapchainImage(chains[e], NULL, &idx));
                    XrSwapchainImageWaitInfo wi = {XR_TYPE_SWAPCHAIN_IMAGE_WAIT_INFO, NULL, XR_INFINITE_DURATION};
                    XR(xrWaitSwapchainImage(chains[e], &wi));

                    eye_uniform u = {0};
                    rotation_columns(views[e].pose.orientation, &u);
                    u.pos[0] = views[e].pose.position.x;
                    u.pos[1] = views[e].pose.position.y;
                    u.pos[2] = views[e].pose.position.z;
                    u.tan[0] = tanf(views[e].fov.angleLeft);
                    u.tan[1] = tanf(views[e].fov.angleRight);
                    u.tan[2] = tanf(views[e].fov.angleUp);
                    u.tan[3] = tanf(views[e].fov.angleDown);
                    u.time[0] = (float)(CFAbsoluteTimeGetCurrent() - start);

                    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
                    rp.colorAttachments[0].texture = images[e][idx];
                    rp.colorAttachments[0].loadAction = MTLLoadActionDontCare;
                    rp.colorAttachments[0].storeAction = MTLStoreActionStore;
                    rp.depthAttachment.texture = depth[e];
                    rp.depthAttachment.loadAction = MTLLoadActionClear;
                    rp.depthAttachment.storeAction = MTLStoreActionDontCare;
                    rp.depthAttachment.clearDepth = 1.0;
                    id<MTLRenderCommandEncoder> enc = [cmd renderCommandEncoderWithDescriptor:rp];
                    [enc setDepthStencilState:no_depth];
                    [enc setRenderPipelineState:pso];
                    [enc setFragmentBytes:&u length:sizeof u atIndex:0];
                    [enc setFragmentBytes:boards length:sizeof(board_gpu) * nb atIndex:1];
                    [enc setFragmentBytes:&nb length:sizeof nb atIndex:2];
                    [enc setFragmentTexture:tex_name atIndex:0];
                    [enc setFragmentTexture:tex_palm atIndex:1];
                    [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];

                    struct { simd_float4x4 view, proj; } camera = {simd_inverse(pose_matrix(views[e].pose)),
                                                                   projection(views[e].fov, 0.05f, 200)};
                    for (int h = 0; h < 2; h++) {
                        if (!show_controller[h]) continue;
                        [enc setRenderPipelineState:mesh_pso];
                        [enc setDepthStencilState:depth_write];
                        [enc setVertexBytes:&camera length:sizeof camera atIndex:1];
                        [enc setFragmentTexture:controllers[h].texture atIndex:0];
                        for (int i = 0; i < controllers[h].count; i++) {
                            const part *p = &controllers[h].parts[i];
                            simd_float4 glow;
                            simd_float4x4 m = simd_mul(controller_model[h], part_pose(p, &input[h], &glow));
                            [enc setVertexBuffer:p->m.vertices offset:0 atIndex:0];
                            [enc setVertexBytes:&m length:sizeof m atIndex:2];
                            [enc setFragmentBytes:&glow length:sizeof glow atIndex:0];
                            [enc drawIndexedPrimitives:MTLPrimitiveTypeTriangle indexCount:p->m.index_count
                                             indexType:MTLIndexTypeUInt32 indexBuffer:p->m.indices indexBufferOffset:0];
                        }
                    }
                    if (nlines) {
                        [enc setRenderPipelineState:line_pso];
                        [enc setDepthStencilState:depth_test];
                        [enc setVertexBytes:lines length:sizeof(segment) * nlines atIndex:0];
                        [enc setVertexBytes:&camera length:sizeof camera atIndex:1];
                        [enc drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4 instanceCount:nlines];
                    }
                    [enc endEncoding];

                    pv[e] = (XrCompositionLayerProjectionView){XR_TYPE_COMPOSITION_LAYER_PROJECTION_VIEW, NULL,
                                                               views[e].pose, views[e].fov,
                                                               {chains[e], {{0, 0}, {(int32_t)vcv[e].recommendedImageRectWidth,
                                                                                     (int32_t)vcv[e].recommendedImageRectHeight}}, 0}};
                }
                [cmd commit];
                [cmd waitUntilScheduled];
                for (int e = 0; e < 2; e++) XR(xrReleaseSwapchainImage(chains[e], NULL));

                XrCompositionLayerProjection layer = {XR_TYPE_COMPOSITION_LAYER_PROJECTION, NULL, 0, stage, 2, pv};
                const XrCompositionLayerBaseHeader *layers[] = {(const XrCompositionLayerBaseHeader *)&layer};
                XrFrameEndInfo fei = {XR_TYPE_FRAME_END_INFO, NULL, fs.predictedDisplayTime,
                                      XR_ENVIRONMENT_BLEND_MODE_OPAQUE, 1, layers};
                XR(xrEndFrame(session, &fei));
            }
        }
    }
}
