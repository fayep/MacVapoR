// vapord: MacVapoR's home scene. It holds the headset while no game does, drawing a scene (a
// folder: see SCENES.md) through the alvrxr runtime like any OpenXR app. When a game starts, its runtime posts a claim
// (see claim_headset in backend.m) and vapord exits at once, which frees the ALVR server it ran;
// launchd starts it again, and it waits for the claiming game to end before taking the headset back.
//
// Usage: vapord [RUNTIME]   (default ~/Library/Application Support/MacVapoR/runtime/libalvrxr.dylib)
//        vapord --preview SCENE_DIR OUT.png [YAW [PITCH]]   a scene as seen standing, turned YAW degrees
//                                                             left and PITCH up (default 0, -8)
//
// VAPORD_DASHBOARD_TEST=game|lounge (tests only, with ALVRXR_CONFIG_DIR and ALVRXR_DUMP): the
// dashboard open with made-up state and pointers, over a game (transparent) or the lounge, for
// VAPORD_DASHBOARD_TEST_FRAMES frames (120); frames 30 and 45 (hovering, then pressing Recenter)
// are read back from the left eye's swapchain image, alpha and all, into the config dir.

#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>
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

#include "dashboard.h"
#include "objects_metal.h"
#include "prelude_metal.h"

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

// As prelude.metal's Picture: its float3 takes 16 bytes, and its bool the first byte of flip.
typedef struct {
    float centre[3], pad0;
    float half_size[2];
    int texture;
    int flip;
} picture_gpu;

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

// A picture file, as a texture: premultiplied, as the scene's pictures are drawn over it.
static id<MTLTexture> load_image(NSString *path, id<MTLDevice> dev, id<MTLCommandQueue> q) {
    CGImageSourceRef src = CGImageSourceCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path], NULL);
    CGImageRef img = src ? CGImageSourceCreateImageAtIndex(src, 0, NULL) : NULL;
    if (src) CFRelease(src);
    if (!img) return nil;
    size_t w = CGImageGetWidth(img), h = CGImageGetHeight(img);
    if (w > 8192 || h > 8192) { CGImageRelease(img); return nil; }
    CGContextRef c = canvas(w, h);
    CGContextDrawImage(c, CGRectMake(0, 0, w, h), img);
    CGImageRelease(img);
    return texture_from(c, dev, q);
}

static id<MTLTexture> colour_texture(simd_float3 srgb, id<MTLDevice> dev, id<MTLCommandQueue> q) {
    CGContextRef c = canvas(1, 1);
    uint8_t *px = CGBitmapContextGetData(c);
    for (int i = 0; i < 3; i++) px[i] = (uint8_t)lroundf(fminf(fmaxf(srgb[i], 0), 1) * 255);
    px[3] = 255;
    return texture_from(c, dev, q);
}

// ---------------------------------------------------------------------------------------- scenes
//
// A scene is a folder: scene.json, backdrop.metal and the pictures it names (see SCENES.md). The
// one shown is named in MacVapoR's home.json, looked for among the user's scenes and then those
// installed with the runtime, and is reloaded whenever any of them changes.

// As objects.metal's Look.
typedef struct {
    simd_float4 light, tint, rim, ambient;
} look_gpu;

typedef struct {
    NSString *dir, *name;
    id<MTLRenderPipelineState> backdrop;
    picture_gpu pictures[16];
    int picture_count;
    id<MTLTexture> images[8];
    id<MTLTexture> ball, table;
    look_gpu look;
    simd_float4 bones, palm, tips;   // a bare hand's lines, linear
    simd_float3 touched, pressed;    // a control's glow, linear
} scene;

static NSString *support_dir(void) {
    return [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/MacVapoR"];
}

static float lin(float c) { return powf(c, 2.2f); }

static simd_float3 lin3(simd_float3 c) { return simd_make_float3(lin(c.x), lin(c.y), lin(c.z)); }

// A JSON array of three numbers, else the default.
static simd_float3 vec3_or(id a, simd_float3 dflt) {
    if (![a isKindOfClass:NSArray.class] || [a count] < 3) return dflt;
    for (int i = 0; i < 3; i++)
        if (![a[i] isKindOfClass:NSNumber.class]) return dflt;
    return simd_make_float3([a[0] floatValue], [a[1] floatValue], [a[2] floatValue]);
}

static float number_or(id n, float dflt) { return [n isKindOfClass:NSNumber.class] ? [n floatValue] : dflt; }

static NSDictionary *dict_or_empty(id d) { return [d isKindOfClass:NSDictionary.class] ? d : @{}; }

// When the scene was last changed: its folder's files, and the choice of it.
static NSDate *scene_stamp(NSString *dir) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSDate *newest = [fm attributesOfItemAtPath:[support_dir() stringByAppendingPathComponent:@"home.json"] error:nil].fileModificationDate
                         ?: NSDate.distantPast;
    for (NSString *f in dir ? [fm contentsOfDirectoryAtPath:dir error:nil] : @[]) {
        NSDate *d = [fm attributesOfItemAtPath:[dir stringByAppendingPathComponent:f] error:nil].fileModificationDate;
        if (d && [d compare:newest] == NSOrderedDescending) newest = d;
    }
    return newest;
}

// The chosen scene's folder: by name, the user's own before those installed, else Vaporwave.
static NSString *chosen_scene_dir(void) {
    NSData *json = [NSData dataWithContentsOfFile:[support_dir() stringByAppendingPathComponent:@"home.json"]];
    NSDictionary *home = json ? dict_or_empty([NSJSONSerialization JSONObjectWithData:json options:0 error:nil]) : @{};
    NSString *chosen = [home[@"scene"] isKindOfClass:NSString.class] ? home[@"scene"] : @"vaporwave";
    // A runtime variant (tools/runtime-switch.sh) carries its own scenes beside vapord.
    NSString *beside = [NSBundle.mainBundle.executablePath.stringByDeletingLastPathComponent
                           stringByAppendingPathComponent:@"scenes"];
    NSArray *roots = @[[support_dir() stringByAppendingPathComponent:@"scenes"],
                       [support_dir() stringByAppendingPathComponent:@"runtime/scenes"], beside];
    for (NSString *name in @[chosen, @"vaporwave"]) {
        if ([name containsString:@"/"] || [name hasPrefix:@"."]) continue;
        for (NSString *root in roots) {
            NSString *dir = [root stringByAppendingPathComponent:name];
            if ([NSFileManager.defaultManager fileExistsAtPath:[dir stringByAppendingPathComponent:@"scene.json"]]) return dir;
        }
    }
    return nil;
}

// What's left when no scene loads: a dark grey floor under a dark sky.
static const char fallback_backdrop[] =
    "float3 backdrop(float3 o, float3 d, constant Eye &eye, thread float &depth) {\n"
    "    if (d.y >= -1e-4) return float3(0.02, 0.02, 0.03);\n"
    "    depth = -o.y / d.y;\n"
    "    float2 g = abs(fract((o + d * depth).xz + 0.5) - 0.5);\n"
    "    return float3(0.04) + float3(0.10) * step(min(g.x, g.y), 0.01) * exp(-depth * 0.2);\n"
    "}\n";

// The scene in dir (nil: the fallback), into out; on failure out is left as it was and why says
// what went wrong.
static bool load_scene(NSString *dir, id<MTLDevice> dev, id<MTLCommandQueue> q, scene *out, NSString **why) {
    scene sc = {.dir = dir, .name = @"(none)"};
    NSDictionary *j = @{};
    NSString *source = @(fallback_backdrop);
    if (dir) {
        NSError *err = nil;
        NSData *data = [NSData dataWithContentsOfFile:[dir stringByAppendingPathComponent:@"scene.json"]];
        id parsed = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:&err] : nil;
        if (![parsed isKindOfClass:NSDictionary.class]) {
            *why = [NSString stringWithFormat:@"scene.json: %@", err.localizedDescription ?: @"not a JSON object"];
            return false;
        }
        j = parsed;
        NSString *file = [j[@"shader"] isKindOfClass:NSString.class] ? j[@"shader"] : @"backdrop.metal";
        source = [NSString stringWithContentsOfFile:[dir stringByAppendingPathComponent:file.lastPathComponent]
                                           encoding:NSUTF8StringEncoding error:&err];
        if (!source) {
            *why = [NSString stringWithFormat:@"%@: %@", file, err.localizedDescription];
            return false;
        }
        sc.name = [j[@"name"] isKindOfClass:NSString.class] ? j[@"name"] : dir.lastPathComponent;
    }

    NSError *err = nil;
    id<MTLLibrary> lib = [dev newLibraryWithSource:[@(prelude_metal) stringByAppendingString:source] options:nil error:&err];
    if (!lib) {
        *why = [NSString stringWithFormat:@"backdrop shader: %@", err.localizedDescription];
        return false;
    }
    MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
    pd.vertexFunction = [lib newFunctionWithName:@"vs"];
    pd.fragmentFunction = [lib newFunctionWithName:@"fs"];
    pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm_sRGB;
    pd.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
    sc.backdrop = [dev newRenderPipelineStateWithDescriptor:pd error:&err];
    if (!sc.backdrop) {
        *why = [NSString stringWithFormat:@"backdrop pipeline: %@", err.localizedDescription];
        return false;
    }

    // The pictures, each image loaded once.
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (id p in [j[@"pictures"] isKindOfClass:NSArray.class] ? j[@"pictures"] : @[]) {
        NSDictionary *pic = dict_or_empty(p);
        NSString *image = [pic[@"image"] isKindOfClass:NSString.class] ? [pic[@"image"] lastPathComponent] : nil;
        if (!image || sc.picture_count == 16) continue;
        NSUInteger k = [names indexOfObject:image];
        if (k == NSNotFound) {
            if (names.count == 8) { say(@"%@: only 8 images; %@ left out", sc.name, image); continue; }
            id<MTLTexture> t = load_image([dir stringByAppendingPathComponent:image], dev, q);
            if (!t) { say(@"%@: can't load %@", sc.name, image); continue; }
            k = names.count;
            [names addObject:image];
            sc.images[k] = t;
        }
        simd_float3 c = vec3_or(pic[@"centre"], 0);
        simd_float3 size = vec3_or([pic[@"size"] isKindOfClass:NSArray.class] && [pic[@"size"] count] == 2
                                       ? [pic[@"size"] arrayByAddingObject:@0] : nil, simd_make_float3(1, 1, 0));
        sc.pictures[sc.picture_count++] = (picture_gpu){{c.x, c.y, c.z}, 0, {size.x / 2, size.y / 2}, (int)k,
                                                        [pic[@"flip"] boolValue]};
    }
    id<MTLTexture> blank = colour_texture(0, dev, q);
    for (int i = (int)names.count; i < 8; i++) sc.images[i] = blank;

    // The ball and table: a picture each, or a colour.
    id<MTLTexture> (^surface)(id, simd_float3) = ^id<MTLTexture>(id v, simd_float3 dflt) {
        id<MTLTexture> t = [v isKindOfClass:NSString.class] ? load_image([dir stringByAppendingPathComponent:[v lastPathComponent]], dev, q) : nil;
        return t ?: colour_texture(vec3_or(v, dflt), dev, q);
    };
    sc.ball = surface(j[@"ball"], simd_make_float3(0.9f, 0.9f, 0.92f));
    sc.table = surface(j[@"table"], simd_make_float3(0.3f, 0.3f, 0.32f));

    NSDictionary *light = dict_or_empty(j[@"light"]), *rim = dict_or_empty(j[@"rim"]), *ambient = dict_or_empty(j[@"ambient"]);
    NSDictionary *hands = dict_or_empty(j[@"hands"]), *controls = dict_or_empty(j[@"controls"]);
    sc.look.light = simd_make_float4(simd_normalize(vec3_or(light[@"from"], simd_make_float3(0, 0.3f, -1))),
                                     number_or(light[@"shade"], 0.35f));
    sc.look.tint = simd_make_float4(lin3(vec3_or(light[@"colour"], 1)), 0);
    sc.look.rim = simd_make_float4(lin3(vec3_or(rim[@"colour"], 1)) * number_or(rim[@"strength"], 0.3f), 0);
    sc.look.ambient = simd_make_float4(lin3(vec3_or(ambient[@"colour"], 1)) * number_or(ambient[@"strength"], 0.0f), 0);
    sc.bones = simd_make_float4(lin3(vec3_or(hands[@"bones"], simd_make_float3(0, 0.92f, 1))), 1);
    sc.palm = simd_make_float4(lin3(vec3_or(hands[@"palm"], simd_make_float3(0.62f, 0.30f, 0.95f))), 1);
    sc.tips = simd_make_float4(lin3(vec3_or(hands[@"tips"], simd_make_float3(0.86f, 0.89f, 0.96f))), 1);
    sc.touched = lin3(vec3_or(controls[@"touched"], simd_make_float3(0, 0.60f, 0.65f)));
    sc.pressed = lin3(vec3_or(controls[@"pressed"], simd_make_float3(0.70f, 0.42f, 0.88f)));
    *out = sc;
    return true;
}

// The chosen scene, or failing it the fallback.
static void load_chosen_scene(id<MTLDevice> dev, id<MTLCommandQueue> q, scene *out) {
    NSString *dir = chosen_scene_dir(), *why = nil;
    if (load_scene(dir, dev, q, out, &why)) {
        say(@"scene: %@ (%@)", out->name, dir ?: @"built in");
        return;
    }
    say(@"scene %@: %@", dir, why);
    if (!out->backdrop && !load_scene(nil, dev, q, out, &why)) { say(@"fallback scene: %@", why); exit(1); }
    out->dir = dir;   // watched still, so a fix is picked up
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
    id<MTLTexture> tex;        // its own colour, or nil for the controller's texture
    bool flip_x;               // joystick: tilts the other way for x (the Joy-Con's frame faces the other way)
    simd_float3 top;           // the middle of its top, where a thumb presses it (Joy-Cons)
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

// Where a part sits for these inputs, in the model's frame, and how it glows: in the scene's
// colours, one while touched, the other while pressed.
static simd_float4x4 part_pose(const part *p, const hand_input *in, const scene *sc, simd_float4 *glow) {
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
    simd_float3 g = touched ? sc->touched : simd_make_float3(0, 0, 0);
    g = simd_mix(g, sc->pressed, simd_make_float3(1, 1, 1) * fminf(fmaxf((value - 0.5f) * 2, 0), 1));
    *glow = simd_make_float4(g, 0);

    switch (p->move) {
    case MOVE_ROTATE:
        return simd_mul(translation(p->pivot), simd_mul(rotation(p->axis, value * p->amount), translation(-p->pivot)));
    case MOVE_TRANSLATE:
        return translation(p->axis * (value * p->amount));
    case MOVE_JOYSTICK: {
        // The stick stands along its own z axis: forward tilts it about x, sideways about y.
        simd_float4x4 tilt = simd_mul(rotation(simd_make_float3(1, 0, 0), -in->stick[1] * p->tilt),
                                      rotation(simd_make_float3(0, 1, 0), (p->flip_x ? 1 : -1) * in->stick[0] * p->tilt));
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

// The Joy-Con model's frame from the OpenXR grip (the client's, from the hand holding it): turned
// so its top end is up as held, rolled about its length, and moved along itself. tune.json
// "joycon_pitch" (degrees about the grip's x), "joycon_roll" (degrees about the model's length,
// clockwise looking down on its top end), "joycon_drop" (metres towards its bottom end) and
// "joycon_y" (metres up in the room, + up, returned in *y) and "joycon_yaw" (degrees about the
// room's vertical through the hand, + anticlockwise seen from the top, returned in *yaw), re-read
// once a second.
static simd_float3 g_nudge[2];   // joycon_left/right_offset, also for the finger-attached placement

// Set for the left hand; the right one's roll and yaw are mirrored, plus "joycon_yaw_right"
// (degrees, + anticlockwise from the top): the thumb rests on the stick, which is above the buttons
// on the left Joy-Con and below them on the right, so the right one sits a little differently.
static simd_float4x4 joycon_from_grip(bool left, float *y, float *yaw) {
    static float pitch = -70, roll = 10, drop = 0, up = -0.06f, turn = 0, turn_right = 5;
    // "joycon_left_offset" / "joycon_right_offset": [x, y, z] metres, as you see the Joy-Con held up
    // in front of you: + right, + up (towards its top end), + into the screen (behind its face).
    static simd_float3 nudge[2];
    g_nudge[0] = nudge[0];
    g_nudge[1] = nudge[1];
    static double checked;
    double now = CFAbsoluteTimeGetCurrent();
    if (now - checked >= 1) {
        checked = now;
        NSData *d = [NSData dataWithContentsOfFile:[g_config_dir stringByAppendingPathComponent:@"tune.json"]];
        NSDictionary *t = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
        if (![t isKindOfClass:NSDictionary.class]) t = nil;
        float p = [t[@"joycon_pitch"] respondsToSelector:@selector(floatValue)] ? [t[@"joycon_pitch"] floatValue] : -70;
        float r = [t[@"joycon_roll"] respondsToSelector:@selector(floatValue)] ? [t[@"joycon_roll"] floatValue] : 10;
        float m = [t[@"joycon_drop"] respondsToSelector:@selector(floatValue)] ? [t[@"joycon_drop"] floatValue] : 0;
        float u = [t[@"joycon_y"] respondsToSelector:@selector(floatValue)] ? [t[@"joycon_y"] floatValue] : -0.06f;
        float w = [t[@"joycon_yaw"] respondsToSelector:@selector(floatValue)] ? [t[@"joycon_yaw"] floatValue] : 0;
        float wr = [t[@"joycon_yaw_right"] respondsToSelector:@selector(floatValue)] ? [t[@"joycon_yaw_right"] floatValue] : 5;
        if (wr != turn_right) NSLog(@"vapord: right Joy-Con yawed %+.0f more", wr);
        turn_right = wr;
        for (int i = 0; i < 2; i++) {
            NSArray *o = t[i ? @"joycon_right_offset" : @"joycon_left_offset"];
            simd_float3 v = 0;
            if ([o isKindOfClass:NSArray.class] && o.count == 3)
                for (int k = 0; k < 3; k++) v[k] = [o[k] respondsToSelector:@selector(floatValue)] ? [o[k] floatValue] : 0;
            if (simd_any(v != nudge[i])) NSLog(@"vapord: %@ Joy-Con moved (%+.3f, %+.3f, %+.3f) m", i ? @"right" : @"left", v.x, v.y, v.z);
            nudge[i] = v;
        }
        if (p != pitch || r != roll || m != drop || u != up || w != turn)
            NSLog(@"vapord: Joy-Con models pitched %.0f degrees, rolled %.0f, yawed %.0f, %.3f m along, y %+.3f m", p, r, w, m, u);
        pitch = p;
        roll = r;
        drop = m;
        up = u;
        turn = w;
    }
    *y = up;
    float mirror = left ? 1 : -1;
    *yaw = turn * mirror + (left ? 0 : turn_right);
    // Looking down on the top end is looking along +Z: clockwise from there is a turn about +Z.
    // The model's own axes: x across, its top end along -z, its face along +y.
    simd_float3 n = nudge[left ? 0 : 1];
    return simd_mul(simd_mul(rotation(simd_make_float3(1, 0, 0), pitch), rotation(simd_make_float3(0, 0, 1), roll * mirror)),
                    translation(simd_make_float3(n.x, -n.z, drop - n.y)));
}

// A Joy-Con attached to the hand holding it by the palm: its bottom presses into the palm and the ring
// and little fingers close it against the rail, so it moves with the palm. The palm's frame from joint
// positions only, as the hand is drawn (joint orientations reach us through other conversions and needn't
// agree): the wrist and the index and little knuckles, rigid with the palm and on the back of the hand.
// Its origin among them; x from the little knuckle to the index one; y out of the palm; z = x * y. The two
// hands' frames are mirror images, both right-handed, so a pose in the left one's is the right one's with
// z reflected (and the model, mirrored across its x).
static bool finger_frame(const XrHandJointLocationEXT *j, bool left, simd_float4x4 *out) {
    const XrSpaceLocationFlags pos = XR_SPACE_LOCATION_POSITION_VALID_BIT;
    int need[] = {XR_HAND_JOINT_WRIST_EXT, XR_HAND_JOINT_INDEX_PROXIMAL_EXT, XR_HAND_JOINT_LITTLE_PROXIMAL_EXT};
    for (int i = 0; i < 3; i++)
        if (!(j[need[i]].locationFlags & pos)) return false;
#define P(n) simd_make_float3(j[n].pose.position.x, j[n].pose.position.y, j[n].pose.position.z)
    simd_float3 wrist = P(XR_HAND_JOINT_WRIST_EXT), index = P(XR_HAND_JOINT_INDEX_PROXIMAL_EXT), little = P(XR_HAND_JOINT_LITTLE_PROXIMAL_EXT);
#undef P
    if (simd_distance(index, little) < 0.02f) return false;
    simd_float3 x = simd_normalize(index - little);
    // index x little, from the wrist: out of the palm for a right hand, into it for a left.
    simd_float3 y = simd_cross(index - wrist, little - wrist) * (left ? -1 : 1);
    y = y - simd_dot(y, x) * x;
    if (simd_length(y) < 1e-6f) return false;
    y = simd_normalize(y);
    simd_float3 z = simd_cross(x, y);
    *out = (simd_float4x4){{simd_make_float4(x, 0), simd_make_float4(y, 0), simd_make_float4(z, 0),
                            simd_make_float4((wrist + index + little) / 3, 1)}};
    return true;
}

// tune.json "joycon_attach" and "joycon_attach_right": [x, y, z, qx, qy, qz, qw], each Joy-Con's pose in
// its hand's palm frame. The grips aren't mirror images (the stick and buttons sit differently), so each
// hand has its own; without the right one's, it's the left one's mirrored. "joycon_capture": true has
// vapord set the left one from where the left Joy-Con is drawn now (placed the old way, from the grip and
// the joycon_* turns), the right one to its mirror, and drop the flag. Re-read once a second.
static simd_float4x4 g_attach[2];
static bool g_have_attach, g_capture, g_record, g_show_hands;

static simd_float4x4 mirror_attach(simd_float4x4 a) {
    return simd_mul(simd_mul(simd_diagonal_matrix(simd_make_float4(1, 1, -1, 1)), a), simd_diagonal_matrix(simd_make_float4(-1, 1, 1, 1)));
}

static bool attach_from(id o, simd_float4x4 *out) {
    if (![o isKindOfClass:NSArray.class] || [o count] != 7) return false;
    float v[7];
    for (int i = 0; i < 7; i++) v[i] = [o[i] respondsToSelector:@selector(floatValue)] ? [o[i] floatValue] : 0;
    *out = simd_matrix4x4(simd_normalize(simd_quaternion(v[3], v[4], v[5], v[6])));
    out->columns[3] = simd_make_float4(v[0], v[1], v[2], 1);
    return true;
}

static void read_attach(void) {
    static double checked;
    double now = CFAbsoluteTimeGetCurrent();
    if (now - checked < 1) return;
    checked = now;
    NSData *d = [NSData dataWithContentsOfFile:[g_config_dir stringByAppendingPathComponent:@"tune.json"]];
    NSDictionary *t = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
    if (![t isKindOfClass:NSDictionary.class]) t = nil;
    g_capture = [t[@"joycon_capture"] respondsToSelector:@selector(boolValue)] && [t[@"joycon_capture"] boolValue];
    g_record = [t[@"joycon_record"] respondsToSelector:@selector(boolValue)] && [t[@"joycon_record"] boolValue];
    g_show_hands = [t[@"joycon_show_hands"] respondsToSelector:@selector(boolValue)] && [t[@"joycon_show_hands"] boolValue];
    g_have_attach = attach_from(t[@"joycon_attach"], &g_attach[0]);
    if (g_have_attach && !attach_from(t[@"joycon_attach_right"], &g_attach[1])) g_attach[1] = mirror_attach(g_attach[0]);
}

// Saves a hand's attachment; capturing the left one (capture) resets the right one to its mirror.
static void save_attach(int hand, simd_float4x4 a, bool capture) {
    NSString *path = [g_config_dir stringByAppendingPathComponent:@"tune.json"];
    NSData *d = [NSData dataWithContentsOfFile:path];
    NSMutableDictionary *t = [(d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil) mutableCopy];
    if (![t isKindOfClass:NSMutableDictionary.class]) t = [NSMutableDictionary dictionary];
    simd_quatf q = simd_quaternion((simd_float3x3){{simd_make_float3(a.columns[0]), simd_make_float3(a.columns[1]),
                                                    simd_make_float3(a.columns[2])}});
    t[hand ? @"joycon_attach_right" : @"joycon_attach"] = @[@(a.columns[3].x), @(a.columns[3].y), @(a.columns[3].z), @(q.vector.x),
                                                           @(q.vector.y), @(q.vector.z), @(q.vector.w)];
    g_attach[hand] = a;
    if (capture) {
        [t removeObjectForKey:@"joycon_attach_right"];
        [t removeObjectForKey:@"joycon_capture"];
        g_attach[1] = mirror_attach(a);
        g_have_attach = true;
        g_capture = false;
    }
    [[NSJSONSerialization dataWithJSONObject:t options:0 error:nil] writeToFile:path atomically:YES];
    NSLog(@"vapord: %@ Joy-Con attached to the palm at (%.3f, %.3f, %.3f) m", hand ? @"right" : @"left", a.columns[3].x, a.columns[3].y,
          a.columns[3].z);
}

// The model's frame from the OpenXR grip: Sony's openxr_grip component, undone.
// tune.json "model_scale": the controller models' size against the controllers in hand, scaled
// about the grip, re-read once a second (for matching them by eye).
static float model_scale(void) {
    static float scale = 1.01f;   // Sony's models read a hair small against the controllers
    static double checked;
    double now = CFAbsoluteTimeGetCurrent();
    if (now - checked < 1) return scale;
    checked = now;
    NSData *d = [NSData dataWithContentsOfFile:[g_config_dir stringByAppendingPathComponent:@"tune.json"]];
    NSDictionary *t = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
    id v = [t isKindOfClass:NSDictionary.class] ? t[@"model_scale"] : nil;
    float s = [v respondsToSelector:@selector(floatValue)] && [v floatValue] > 0.5f && [v floatValue] < 2 ? [v floatValue] : 1.01f;
    if (s != scale) NSLog(@"vapord: controller models at %.3fx", s);
    scale = s;
    return scale;
}

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
} segment;   // as objects.metal's Segment

// A hand: a line along each bone, a different colour across the back of the hand, and a dot on
// each fingertip, in the scene's colours.
static void hand_lines(const XrHandJointLocationEXT *j, const scene *sc, segment *out, int *n) {
    static const int parent[26] = {-1, -1, 1, 2, 3, 4, 1, 6, 7, 8, 9, 1, 11, 12, 13, 14, 1, 16, 17, 18, 19, 1, 21, 22, 23, 24};
    for (int i = 2; i < 26; i++) {
        XrVector3f a = j[parent[i]].pose.position, b = j[i].pose.position;
        bool metacarpal = parent[i] == XR_HAND_JOINT_WRIST_EXT;
        segment s = {{a.x, a.y, a.z, 0.0035f}, {b.x, b.y, b.z, 0}, {0}};
        simd_float4 c = metacarpal ? sc->palm : sc->bones;
        memcpy(s.colour, &c, sizeof s.colour);
        out[(*n)++] = s;
        if (i == 5 || i == 10 || i == 15 || i == 20 || i == 25) {
            segment tip = {{b.x, b.y, b.z, 0.0055f}, {b.x, b.y, b.z, 0}, {0}};
            memcpy(tip.colour, &sc->tips, sizeof tip.colour);
            out[(*n)++] = tip;
        }
    }
}

// ---------------------------------------------------------------------------- the ball and table
//
// A beach ball on a pedestal in front of you. Grab it by reaching in with a controller and squeezing the
// trigger or grip, or bare-handed by pinching it; let go and it flies with your hand's velocity
// and spin, bounces on the grid and the table, and rolls to a stop. Out of reach, it comes back.

static const float kBallRadius = 0.11f;
static const simd_float3 kTableCentre = {0.0f, 0.0f, -0.55f};   // on the floor, straight ahead
static const float kTableTop = 0.76f, kTableHalf = 0.22f, kTableThick = 0.035f, kColumnHalf = 0.045f;

static mesh mesh_from(NSData *verts, NSData *idx, id<MTLDevice> dev) {
    mesh m;
    m.vertices = [dev newBufferWithBytes:verts.bytes length:verts.length options:MTLResourceStorageModeShared];
    m.indices = [dev newBufferWithBytes:idx.bytes length:idx.length options:MTLResourceStorageModeShared];
    m.index_count = (uint32_t)(idx.length / sizeof(uint32_t));
    return m;
}

// A unit sphere, its texture wrapped round once: u around, v from the top.
static mesh sphere_mesh(id<MTLDevice> dev) {
    NSMutableData *verts = [NSMutableData data], *idx = [NSMutableData data];
    const int rings = 24, segs = 48;
    for (int r = 0; r <= rings; r++)
        for (int s = 0; s <= segs; s++) {
            float th = (float)M_PI * r / rings, ph = 2 * (float)M_PI * s / segs;
            float x = sinf(th) * cosf(ph), y = cosf(th), z = sinf(th) * sinf(ph);
            mesh_vertex m = {{x, y, z}, {x, y, z}, {(float)s / segs, (float)r / rings}};
            [verts appendBytes:&m length:sizeof m];
        }
    for (int r = 0; r < rings; r++)
        for (int s = 0; s < segs; s++) {
            uint32_t a = r * (segs + 1) + s, b = a + segs + 1;
            uint32_t tri[6] = {a, b, a + 1, a + 1, b, b + 1};
            [idx appendBytes:tri length:sizeof tri];
        }
    return mesh_from(verts, idx, dev);
}

// A box of the given half sizes, centred; each face shows the whole texture.
static mesh box_mesh_at(simd_float3 half, simd_float3 centre, id<MTLDevice> dev) {
    NSMutableData *verts = [NSMutableData data], *idx = [NSMutableData data];
    for (int axis = 0; axis < 3; axis++)
        for (int sign = -1; sign <= 1; sign += 2) {
            simd_float3 n = 0, u = 0, w = 0;
            n[axis] = sign;
            u[(axis + 1) % 3] = 1;
            w[(axis + 2) % 3] = 1;
            uint32_t base = (uint32_t)(verts.length / sizeof(mesh_vertex));
            for (int k = 0; k < 4; k++) {
                float a = (k & 1) ? 1 : -1, b = (k & 2) ? 1 : -1;
                simd_float3 p = (n + u * a + w * b) * half + centre;
                mesh_vertex m = {{p.x, p.y, p.z}, {n.x, n.y, n.z}, {(a + 1) / 2, (b + 1) / 2}};
                [verts appendBytes:&m length:sizeof m];
            }
            uint32_t tri[6] = {base, base + 1, base + 2, base + 1, base + 3, base + 2};
            [idx appendBytes:tri length:sizeof tri];
        }
    return mesh_from(verts, idx, dev);
}

static mesh box_mesh(simd_float3 half, id<MTLDevice> dev) { return box_mesh_at(half, 0, dev); }

// A Joy-Con's body, as its face's outline shows: straight along the rail (+X, or -X with rail < 0)
// and across the top (z0) and bottom (z1) ends, with the two corners away from the rail rounded with
// radius r, a D; flat face (+Y) and back, hy either side of the middle.
static mesh joycon_body_mesh(float hx, float hy, float z0, float z1, float rail, float r, id<MTLDevice> dev) {
    NSMutableData *verts = [NSMutableData data], *idx = [NSMutableData data];
    enum { ARC = 16 };
    simd_float2 pt[2 * ARC + 6];   // (x, z), the rail at +X; walked so the outward side is on the right
    int n = 0;
    pt[n++] = simd_make_float2(hx, z1);
    pt[n++] = simd_make_float2(hx, z0);
    for (int i = 0; i <= ARC; i++) {   // the top corner away from the rail
        float a = -(float)M_PI / 2 - (float)M_PI / 2 * i / ARC;
        pt[n++] = simd_make_float2(-hx + r + r * cosf(a), z0 + r + r * sinf(a));
    }
    for (int i = 0; i <= ARC; i++) {   // the bottom one
        float a = (float)M_PI + (float)M_PI / 2 * i / ARC;
        pt[n++] = simd_make_float2(-hx + r + r * cosf(a), z1 - r - r * sinf(a));
    }
    if (rail < 0)
        for (int i = 0; i < n; i++) pt[i].x = -pt[i].x;
    simd_float2 centre = 0;
    for (int i = 0; i < n; i++) centre += pt[i] / n;
    for (int i = 0; i < n; i++) {   // the edge all round: flat-shaded quads, facing away from the middle
        simd_float2 p0 = pt[i], p1 = pt[(i + 1) % n];
        if (simd_distance(p0, p1) < 1e-6f) continue;
        simd_float2 d = p1 - p0, nm = simd_normalize(simd_make_float2(d.y, -d.x));
        if (simd_dot(nm, (p0 + p1) / 2 - centre) < 0) nm = -nm;
        uint32_t base = (uint32_t)(verts.length / sizeof(mesh_vertex));
        mesh_vertex q[4] = {{{p0.x, -hy, p0.y}, {nm.x, 0, nm.y}, {0, 0}}, {{p1.x, -hy, p1.y}, {nm.x, 0, nm.y}, {1, 0}},
                            {{p0.x, hy, p0.y}, {nm.x, 0, nm.y}, {0, 1}}, {{p1.x, hy, p1.y}, {nm.x, 0, nm.y}, {1, 1}}};
        [verts appendBytes:q length:sizeof q];
        uint32_t tri[6] = {base, base + 1, base + 2, base + 1, base + 3, base + 2};
        [idx appendBytes:tri length:sizeof tri];
    }
    for (int side = -1; side <= 1; side += 2) {   // the face and the back: fans round the middle
        uint32_t base = (uint32_t)(verts.length / sizeof(mesh_vertex));
        mesh_vertex c = {{centre.x, side * hy, centre.y}, {0, (float)side, 0}, {0.5f, 0.5f}};
        [verts appendBytes:&c length:sizeof c];
        for (int i = 0; i < n; i++) {
            mesh_vertex v = {{pt[i].x, side * hy, pt[i].y}, {0, (float)side, 0}, {0.5f, 0.5f}};
            [verts appendBytes:&v length:sizeof v];
            uint32_t t[3] = {base, base + 1 + i, base + 1 + (i + 1) % n};
            [idx appendBytes:t length:sizeof t];
        }
    }
    return mesh_from(verts, idx, dev);
}

// A round button or stick: a cylinder standing along Y, with flat ends.
static mesh cylinder_mesh_at(float radius, float half_height, simd_float3 centre, id<MTLDevice> dev) {
    NSMutableData *verts = [NSMutableData data], *idx = [NSMutableData data];
    const int segs = 24;
    for (int end = -1; end <= 1; end += 2) {   // the ends: a fan round a centre vertex
        uint32_t base = (uint32_t)(verts.length / sizeof(mesh_vertex));
        mesh_vertex c = {{centre.x, centre.y + end * half_height, centre.z}, {0, (float)end, 0}, {0.5f, 0.5f}};
        [verts appendBytes:&c length:sizeof c];
        for (int i = 0; i < segs; i++) {
            float a = 2 * (float)M_PI * i / segs;
            mesh_vertex v = {{centre.x + radius * cosf(a), centre.y + end * half_height, centre.z + radius * sinf(a)},
                             {0, (float)end, 0}, {0.5f + 0.5f * cosf(a), 0.5f + 0.5f * sinf(a)}};
            [verts appendBytes:&v length:sizeof v];
            uint32_t a1 = base + 1 + i, a2 = base + 1 + (i + 1) % segs;
            uint32_t tri[3] = {base, end > 0 ? a2 : a1, end > 0 ? a1 : a2};
            [idx appendBytes:tri length:sizeof tri];
        }
    }
    uint32_t base = (uint32_t)(verts.length / sizeof(mesh_vertex));
    for (int i = 0; i <= segs; i++) {   // the side
        float a = 2 * (float)M_PI * i / segs;
        for (int end = -1; end <= 1; end += 2) {
            mesh_vertex v = {{centre.x + radius * cosf(a), centre.y + end * half_height, centre.z + radius * sinf(a)},
                             {cosf(a), 0, sinf(a)}, {(float)i / segs, (end + 1) / 2.0f}};
            [verts appendBytes:&v length:sizeof v];
        }
        if (i < segs) {
            uint32_t b = base + 2 * i;
            uint32_t tri[6] = {b, b + 1, b + 2, b + 1, b + 3, b + 2};
            [idx appendBytes:tri length:sizeof tri];
        }
    }
    return mesh_from(verts, idx, dev);
}

// A Joy-Con held upright, as the client maps a joined pair (see the ALVR client's WorldTracker):
// L/R the trigger, ZL/ZR the grip, Minus the left menu button, Plus the right one. Our own boxes,
// in the OpenXR grip's frame: the top end (stick end) along -Z, the face up (+Y), the rail
// towards the other hand. Not Nintendo's model.
static void joycon_controller(bool left, id<MTLDevice> dev, id<MTLCommandQueue> q, controller *c) {
    const float hx = 0.0175f, hy = 0.0068f, hz = 0.050f, cz = -0.012f;   // half sizes; the body's centre
    const float face = hy, top = cz - hz, side = left ? 1 : -1;          // side: towards the rail
    id<MTLTexture> body = colour_texture(left ? simd_make_float3(0.04f, 0.73f, 0.90f) : simd_make_float3(1.0f, 0.24f, 0.16f), dev, q);
    id<MTLTexture> dark = colour_texture(simd_make_float3(0.11f, 0.11f, 0.12f), dev, q);
    id<MTLTexture> rail = colour_texture(simd_make_float3(0.22f, 0.22f, 0.24f), dev, q);
    c->count = 0;
    c->texture = dark;
    // half.x == half.z with round: a cylinder of that radius; else a box.
    void (^add)(simd_float3, simd_float3, id<MTLTexture>, int, simd_float3, bool) =
        ^(simd_float3 half, simd_float3 at, id<MTLTexture> tex, int input, simd_float3 travel, bool round) {
            part p = {.m = round ? cylinder_mesh_at(half.x, half.y, at, dev) : box_mesh_at(half, at, dev), .input = input, .tex = tex,
                      .top = at + simd_make_float3(0, half.y, 0)};
            if (simd_length(travel) > 0) {
                p.move = MOVE_TRANSLATE;
                p.axis = simd_normalize(travel);
                p.amount = simd_length(travel);
            }
            c->parts[c->count++] = p;
        };
    c->parts[c->count++] = (part){.m = joycon_body_mesh(hx, hy, cz - hz, cz + hz, side, 0.020f, dev), .tex = body};
    add(simd_make_float3(0.0015f, hy * 0.6f, hz * 0.9f), simd_make_float3(side * (hx + 0.0015f), 0, cz), rail, IN_NONE, 0, false);
    // L/R on the top end, over the face: the trigger. ZL/ZR behind it: the grip.
    add(simd_make_float3(hx * 0.9f, 0.003f, 0.004f), simd_make_float3(0, face - 0.004f, top - 0.002f), dark, IN_TRIGGER,
        simd_make_float3(0, 0, 0.002f), false);
    add(simd_make_float3(hx * 0.85f, 0.006f, 0.006f), simd_make_float3(0, -face - 0.003f, top + 0.010f), dark, IN_SQUEEZE,
        simd_make_float3(0, 0.003f, 0), false);
    // The stick: near the top on the left Joy-Con, below the buttons on the right.
    float stick_z = left ? top + 0.022f : cz + 0.002f, buttons_z = left ? cz + 0.002f : top + 0.022f;
    part stick = {.m = cylinder_mesh_at(0.0068f, 0.005f, simd_make_float3(0, face + 0.006f, stick_z), dev),
                  .input = IN_STICK, .move = MOVE_JOYSTICK, .tilt = 16, .press = simd_make_float3(0, -0.002f, 0), .tex = dark,
                  .flip_x = true, .top = simd_make_float3(0, face + 0.0095f, stick_z)};
    // The stick stands along its frame's z: here the face's normal, forward towards the top end.
    stick.frame = simd_mul(translation(simd_make_float3(0, face, stick_z)), rotation(simd_make_float3(1, 0, 0), -90));
    c->parts[c->count++] = stick;
    // Four buttons in a diamond (x towards +X, z towards the bottom), each lit by what the client
    // sends for it: the left's arrows down and left are X, right is Y, up the grip; on the right,
    // where A is (east) is B and where B is (south) is A (the client swaps them), and Y (west) and X
    // (north), nearer the thumb, are A and B too.
    const float d = 0.0085f;
    simd_float3 button = simd_make_float3(0.0035f, 0.0015f, 0.0035f), press = simd_make_float3(0, -0.0015f, 0);
    struct { float x, z; int input; } diamond[2][4] = {
        {{0, -d, IN_SQUEEZE}, {0, d, IN_A}, {-d, 0, IN_A}, {d, 0, IN_B}},     // left: up, down, left, right
        {{0, -d, IN_B}, {0, d, IN_A}, {-d, 0, IN_A}, {d, 0, IN_B}},          // right: north, south, west, east
    };
    for (int i = 0; i < 4; i++) {
        const typeof(diamond[0][0]) *b = &diamond[left ? 0 : 1][i];
        add(button, simd_make_float3(b->x, face + 0.0015f, buttons_z + b->z), dark, b->input, press, true);
    }
    // Minus or Plus, by the top end towards the rail; Capture or Home below everything.
    add(simd_make_float3(0.0032f, 0.001f, 0.0012f), simd_make_float3(side * 0.010f, face + 0.001f, top + 0.006f), dark, IN_MENU, press, false);
    add(simd_make_float3(0.003f, 0.001f, 0.003f), simd_make_float3(side * 0.006f, face + 0.001f, cz + 0.024f), dark, IN_NONE, 0,
        !left);   // Home is round, Capture square
}

typedef struct {
    simd_float3 p, v, w;    // centre, velocity, angular velocity
    simd_quatf q;           // its turn
    int held;               // the hand holding it, or -1
    simd_float4x4 in_hand;  // held: its pose in the hand's
    double still;           // seconds at rest out of reach
} ball_state;

static void ball_reset(ball_state *b) {
    *b = (ball_state){.p = kTableCentre + simd_make_float3(0, kTableTop + kBallRadius, 0), .q = simd_quaternion(0.0f, 0.0f, 0.0f, 1.0f),
                      .held = -1};
}

// One step of the ball's flight, bounces and rolling.
static void ball_step(ball_state *b, float dt) {
    if (b->held >= 0) return;
    b->v.y -= 9.81f * dt;
    b->p += b->v * dt;
    float spin = simd_length(b->w);
    if (spin > 1e-4f) b->q = simd_normalize(simd_mul(simd_quaternion(spin * dt, b->w / spin), b->q));

    // The surface under it: the table top over the table, else the floor.
    simd_float3 rel = b->p - kTableCentre;
    bool over_table = fabsf(rel.x) < kTableHalf && fabsf(rel.z) < kTableHalf;
    float floor_y = over_table && b->p.y > kTableTop - kTableThick ? kTableTop : 0;
    if (b->p.y < floor_y + kBallRadius) {
        b->p.y = floor_y + kBallRadius;
        if (b->v.y < 0) b->v.y = -b->v.y * 0.6f;   // a beach ball's bounce
        if (b->v.y < 0.35f) b->v.y = 0;
        b->v.x *= 1 - fminf(2.0f * dt, 1);         // rolling friction
        b->v.z *= 1 - fminf(2.0f * dt, 1);
        // Rolling: it turns as it goes.
        b->w = simd_cross(simd_make_float3(0, 1, 0), b->v) / kBallRadius;
    }
    // The column and the table's edges push it out sideways.
    if (b->p.y < kTableTop + kBallRadius && b->p.y > 0) {
        float half = b->p.y < kTableTop - kTableThick ? kColumnHalf : kTableHalf;
        simd_float2 d = simd_make_float2(rel.x, rel.z);
        simd_float2 nearest = simd_clamp(d, -half, half);
        simd_float2 out = d - nearest;
        float len = simd_length(out);
        if (len < kBallRadius && !(over_table && b->p.y >= kTableTop)) {
            simd_float2 n = len > 1e-5f ? out / len : simd_make_float2(1, 0);
            simd_float2 pos = nearest + n * kBallRadius;
            b->p.x = kTableCentre.x + pos.x;
            b->p.z = kTableCentre.z + pos.y;
            simd_float2 vv = simd_make_float2(b->v.x, b->v.z);
            float into = simd_dot(vv, n);
            if (into < 0) vv -= n * into * 1.6f;
            b->v.x = vv.x;
            b->v.z = vv.y;
        }
    }
    // Back to the table once it's been at rest on the floor a few seconds (seated, the floor at
    // your feet is out of reach), or soon after it flies off over the sea.
    bool on_floor = b->p.y < kBallRadius + 0.01f && simd_length(b->v) < 0.08f;
    bool gone = b->p.z < -40 || fabsf(b->p.x) > 40 || b->p.z > 40;
    b->still = on_floor || gone ? b->still + dt : 0;
    if (b->still > 3.0) ball_reset(b);
}

// ------------------------------------------------------------------------------------- the app

typedef struct {
    float rot0[4], rot1[4], rot2[4];
    float pos[4];
    float tan[4];
    float time[4];
    float ball[4];
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

// What every scene has drawn in it: the pipelines for meshes and hands, and the table and ball.
typedef struct {
    id<MTLRenderPipelineState> mesh_pso, line_pso;
    id<MTLDepthStencilState> no_depth, depth_write, depth_test;
    mesh ball, table_top, table_column;
} world;

typedef struct {
    simd_float4x4 view, proj;
} camera_gpu;   // as objects.metal's Camera

static camera_gpu eye_camera(XrPosef pose, XrFovf fov) {
    return (camera_gpu){simd_inverse(pose_matrix(pose)), projection(fov, 0.05f, 200)};
}

static bool make_world(id<MTLDevice> dev, world *w) {
    NSError *err = nil;
    id<MTLLibrary> mlib = [dev newLibraryWithSource:@(objects_metal) options:nil error:&err];
    if (!mlib) { say(@"objects shader: %@", err); return false; }
    MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
    pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm_sRGB;
    pd.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
    pd.vertexFunction = [mlib newFunctionWithName:@"mesh_vs"];
    pd.fragmentFunction = [mlib newFunctionWithName:@"mesh_fs"];
    w->mesh_pso = [dev newRenderPipelineStateWithDescriptor:pd error:&err];
    if (!w->mesh_pso) { say(@"mesh pipeline: %@", err); return false; }
    pd.vertexFunction = [mlib newFunctionWithName:@"line_vs"];
    pd.fragmentFunction = [mlib newFunctionWithName:@"line_fs"];
    pd.colorAttachments[0].blendingEnabled = YES;
    pd.colorAttachments[0].sourceRGBBlendFactor = pd.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
    pd.colorAttachments[0].destinationRGBBlendFactor = pd.colorAttachments[0].destinationAlphaBlendFactor =
        MTLBlendFactorOneMinusSourceAlpha;
    w->line_pso = [dev newRenderPipelineStateWithDescriptor:pd error:&err];
    if (!w->line_pso) { say(@"hand pipeline: %@", err); return false; }
    MTLDepthStencilDescriptor *dsd = [MTLDepthStencilDescriptor new];
    w->no_depth = [dev newDepthStencilStateWithDescriptor:dsd];
    dsd.depthCompareFunction = MTLCompareFunctionLess;
    dsd.depthWriteEnabled = YES;
    w->depth_write = [dev newDepthStencilStateWithDescriptor:dsd];
    dsd.depthWriteEnabled = NO;
    w->depth_test = [dev newDepthStencilStateWithDescriptor:dsd];
    w->ball = sphere_mesh(dev);
    w->table_top = box_mesh(simd_make_float3(kTableHalf, kTableThick / 2, kTableHalf), dev);
    w->table_column = box_mesh(simd_make_float3(kColumnHalf, (kTableTop - kTableThick) / 2, kColumnHalf), dev);
    return true;
}

// One eye's backdrop, then the table and the ball on it; returns the eye's camera, for what's
// drawn after.
static camera_gpu draw_world(id<MTLRenderCommandEncoder> enc, const world *w, const scene *sc, XrPosef pose, XrFovf fov,
                             float time, const ball_state *ball) {
    eye_uniform u = {0};
    rotation_columns(pose.orientation, &u);
    u.pos[0] = pose.position.x;
    u.pos[1] = pose.position.y;
    u.pos[2] = pose.position.z;
    u.tan[0] = tanf(fov.angleLeft);
    u.tan[1] = tanf(fov.angleRight);
    u.tan[2] = tanf(fov.angleUp);
    u.tan[3] = tanf(fov.angleDown);
    u.time[0] = time;
    u.ball[0] = ball->p.x;
    u.ball[1] = ball->p.y;
    u.ball[2] = ball->p.z;
    u.ball[3] = kBallRadius;

    [enc setDepthStencilState:w->no_depth];
    [enc setRenderPipelineState:sc->backdrop];
    [enc setFragmentBytes:&u length:sizeof u atIndex:0];
    [enc setFragmentBytes:sc->pictures length:sizeof sc->pictures atIndex:1];
    [enc setFragmentBytes:&sc->picture_count length:sizeof sc->picture_count atIndex:2];
    [enc setFragmentTextures:sc->images withRange:NSMakeRange(0, 8)];
    [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];

    camera_gpu camera = eye_camera(pose, fov);
    // The table and the ball.
    {
        simd_float4 no_glow = 0;
        struct { const mesh *m; simd_float4x4 model; id<MTLTexture> tex; } things[3];
        things[0] = (typeof(things[0])){&w->table_top, translation(kTableCentre + simd_make_float3(0, kTableTop - kTableThick / 2, 0)), sc->table};
        things[1] = (typeof(things[0])){&w->table_column, translation(kTableCentre + simd_make_float3(0, (kTableTop - kTableThick) / 2, 0)), sc->table};
        simd_float4x4 bm = simd_mul(translation(ball->p), simd_mul(simd_matrix4x4(ball->q),
                                                                   simd_diagonal_matrix(simd_make_float4(kBallRadius, kBallRadius, kBallRadius, 1))));
        things[2] = (typeof(things[0])){&w->ball, bm, sc->ball};
        [enc setRenderPipelineState:w->mesh_pso];
        [enc setDepthStencilState:w->depth_write];
        [enc setVertexBytes:&camera length:sizeof camera atIndex:1];
        [enc setFragmentBytes:&no_glow length:sizeof no_glow atIndex:0];
        [enc setFragmentBytes:&sc->look length:sizeof sc->look atIndex:1];
        for (int i = 0; i < 3; i++) {
            [enc setVertexBuffer:things[i].m->vertices offset:0 atIndex:0];
            [enc setVertexBytes:&things[i].model length:sizeof things[i].model atIndex:2];
            [enc setFragmentTexture:things[i].tex atIndex:0];
            [enc drawIndexedPrimitives:MTLPrimitiveTypeTriangle indexCount:things[i].m->index_count
                             indexType:MTLIndexTypeUInt32 indexBuffer:things[i].m->indices indexBufferOffset:0];
        }
    }
    return camera;
}

// A controller's parts where they sit for this hand's input, in the mesh pipeline.
static void draw_controller(id<MTLRenderCommandEncoder> enc, const world *w, const camera_gpu *camera, const controller *c,
                            simd_float4x4 model, const hand_input *input, const scene *sc) {
    [enc setRenderPipelineState:w->mesh_pso];
    [enc setDepthStencilState:w->depth_write];
    [enc setVertexBytes:camera length:sizeof *camera atIndex:1];
    [enc setFragmentBytes:&sc->look length:sizeof sc->look atIndex:1];
    for (int i = 0; i < c->count; i++) {
        const part *p = &c->parts[i];
        simd_float4 glow;
        simd_float4x4 m = simd_mul(model, part_pose(p, input, sc, &glow));
        [enc setFragmentTexture:p->tex ?: c->texture atIndex:0];
        [enc setVertexBuffer:p->m.vertices offset:0 atIndex:0];
        [enc setVertexBytes:&m length:sizeof m atIndex:2];
        [enc setFragmentBytes:&glow length:sizeof glow atIndex:0];
        [enc drawIndexedPrimitives:MTLPrimitiveTypeTriangle indexCount:p->m.index_count indexType:MTLIndexTypeUInt32
                       indexBuffer:p->m.indices indexBufferOffset:0];
    }
}

// vapord --preview: the scene in a folder as you'd see it standing by the table, into a PNG,
// without a headset; for making scenes.
static int preview(NSString *dir, NSString *png, float yaw, float pitch) {
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
    id<MTLCommandQueue> q = [dev newCommandQueue];
    world w;
    scene sc = {0};
    NSString *why = nil;
    if (!make_world(dev, &w)) return 1;
    if (!load_scene(dir, dev, q, &sc, &why)) { say(@"%@", why); return 1; }
    const int width = 1920, height = 1080;
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm_sRGB
                                                                                  width:width height:height mipmapped:NO];
    td.usage = MTLTextureUsageRenderTarget;
    td.storageMode = MTLStorageModeShared;
    id<MTLTexture> colour = [dev newTextureWithDescriptor:td];
    td.pixelFormat = MTLPixelFormatDepth32Float;
    td.storageMode = MTLStorageModePrivate;
    id<MTLTexture> depth = [dev newTextureWithDescriptor:td];

    // Standing at the origin, eyes 1.6 m up; 100 degrees across.
    simd_quatf turn = simd_mul(simd_quaternion(yaw * (float)M_PI / 180, simd_make_float3(0, 1, 0)),
                               simd_quaternion(pitch * (float)M_PI / 180, simd_make_float3(1, 0, 0)));
    XrPosef pose = {{turn.vector.x, turn.vector.y, turn.vector.z, turn.vector.w}, {0, 1.6f, 0}};
    float across = 50 * (float)M_PI / 180, up = atanf(tanf(across) * height / width);
    XrFovf fov = {-across, across, up, -up};
    ball_state ball;
    ball_reset(&ball);

    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture = colour;
    rp.colorAttachments[0].loadAction = MTLLoadActionClear;
    rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    rp.depthAttachment.texture = depth;
    rp.depthAttachment.loadAction = MTLLoadActionClear;
    rp.depthAttachment.storeAction = MTLStoreActionDontCare;
    rp.depthAttachment.clearDepth = 1.0;
    id<MTLCommandBuffer> cmd = [q commandBuffer];
    id<MTLRenderCommandEncoder> enc = [cmd renderCommandEncoderWithDescriptor:rp];
    camera_gpu camera = draw_world(enc, &w, &sc, pose, fov, 10, &ball);
    // VAPORD_PREVIEW_JOYCONS=1: a pair held up in front, faces towards you, the left one's L and
    // the right one's A lit.
    if (getenv("VAPORD_PREVIEW_JOYCONS")) {
        for (int h = 0; h < 2; h++) {
            controller jc;
            joycon_controller(h == 0, dev, q, &jc);
            simd_float4x4 m = simd_mul(translation(simd_make_float3(h ? 0.07f : -0.07f, 1.45f, -0.30f)),
                                       rotation(simd_make_float3(1, 0, 0), 70));
            hand_input in = {.trigger = h == 0 ? 1.0f : 0, .a = h == 1, .stick = {h ? 0.0f : 1.0f, 0}};
            draw_controller(enc, &w, &camera, &jc, m, &in, &sc);
        }
    }
    [enc endEncoding];
    [cmd commit];
    [cmd waitUntilCompleted];

    NSMutableData *px = [NSMutableData dataWithLength:(NSUInteger)width * height * 4];
    [colour getBytes:px.mutableBytes bytesPerRow:width * 4 fromRegion:MTLRegionMake2D(0, 0, width, height) mipmapLevel:0];
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGDataProviderRef dp = CGDataProviderCreateWithCFData((__bridge CFDataRef)px);
    CGImageRef img = CGImageCreate(width, height, 8, 32, width * 4, cs,
                                   (CGBitmapInfo)kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little, dp, NULL, false,
                                   kCGRenderingIntentDefault);
    CGImageDestinationRef d = CGImageDestinationCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:png], CFSTR("public.png"), 1, NULL);
    bool ok = d != NULL;
    if (d) {
        CGImageDestinationAddImage(d, img, NULL);
        ok = CGImageDestinationFinalize(d);
        CFRelease(d);
    }
    CGImageRelease(img);
    CGDataProviderRelease(dp);
    CGColorSpaceRelease(cs);
    if (!ok) { say(@"can't write %@", png); return 1; }
    say(@"%@: %d pictures, into %@", sc.name, sc.picture_count, png);
    return 0;
}

// The dashboard test: a swapchain image as drawn, alpha and all, into a PNG, and how much of it
// is transparent, opaque and in between.
static void save_with_alpha(id<MTLTexture> image, id<MTLCommandQueue> q, NSString *png) {
    NSUInteger width = image.width, height = image.height;
    id<MTLBuffer> buf = [q.device newBufferWithLength:width * height * 4 options:MTLResourceStorageModeShared];
    id<MTLCommandBuffer> cmd = [q commandBuffer];
    id<MTLBlitCommandEncoder> blit = [cmd blitCommandEncoder];
    [blit copyFromTexture:image sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(width, height, 1)
                 toBuffer:buf destinationOffset:0 destinationBytesPerRow:width * 4 destinationBytesPerImage:width * height * 4];
    [blit endEncoding];
    [cmd commit];
    [cmd waitUntilCompleted];
    const uint8_t *px = buf.contents;
    size_t clear = 0, solid = 0, partial = 0;
    for (size_t i = 0; i < width * height; i++) {
        uint8_t a = px[i * 4 + 3];
        if (a == 0) clear++;
        else if (a == 255) solid++;
        else partial++;
    }
    say(@"dashboard test: %@: alpha 0 %.1f%%, 255 %.1f%%, between %.1f%%", png.lastPathComponent,
        100.0 * clear / (width * height), 100.0 * solid / (width * height), 100.0 * partial / (width * height));
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGDataProviderRef dp = CGDataProviderCreateWithData(NULL, buf.contents, width * height * 4, NULL);
    CGImageRef img = CGImageCreate(width, height, 8, 32, width * 4, cs,
                                   (CGBitmapInfo)kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little, dp, NULL, false,
                                   kCGRenderingIntentDefault);
    CGImageDestinationRef d = CGImageDestinationCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:png], CFSTR("public.png"), 1, NULL);
    if (d) {
        CGImageDestinationAddImage(d, img, NULL);
        CGImageDestinationFinalize(d);
        CFRelease(d);
    }
    CGImageRelease(img);
    CGDataProviderRelease(dp);
    CGColorSpaceRelease(cs);
}

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc >= 4 && !strcmp(argv[1], "--preview")) return preview(@(argv[2]), @(argv[3]), argc > 4 ? atof(argv[4]) : 0, argc > 5 ? atof(argv[5]) : -8);
        // Tests point ALVRXR_CONFIG_DIR at a scratch folder so a second vapord can't touch the live
        // home.pid or claim.pid (the runtime inside reads the same variable for everything else).
        const char *cfg_env = getenv("ALVRXR_CONFIG_DIR");
        g_config_dir = cfg_env && *cfg_env ? @(cfg_env)
                                           : [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/alvrxr"];
        [NSFileManager.defaultManager createDirectoryAtPath:g_config_dir withIntermediateDirectories:YES attributes:nil error:nil];
        g_pid_path = [g_config_dir stringByAppendingPathComponent:@"home.pid"];

        // A game that runs its own ALVR server (any game without the compositor, or a Vulkan one
        // with it) claims the headset and keeps it until it ends; games drawing through the
        // compositor never claim, so vapord honours claims either way.
        for (pid_t game; (game = pid_in(@"claim.pid")) > 0 && game != getpid() && kill(game, 0) == 0;) sleep(2);

        [[NSString stringWithFormat:@"%d\n", getpid()] writeToFile:g_pid_path atomically:YES
                                                         encoding:NSUTF8StringEncoding error:nil];
        int token;
        // A scratch run must not exit when a real game claims the real headset, and posts no claim itself.
        if (!(cfg_env && *cfg_env))
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
        FN(xrApplyHapticFeedback);
        // The dashboard's private functions (alvrxr_ext.h). They work only in SERVER mode, the
        // compositor; a LEGACY runtime doesn't have them, or fails them, and the dashboard never opens.
        PFN_xrGetDashboardStateALVRXR get_dashboard = NULL;
        PFN_xrCloseDashboardALVRXR close_dashboard = NULL;
        PFN_xrQuitGameALVRXR quit_game = NULL;
        PFN_xrRecenterALVRXR recenter = NULL;
        PFN_xrSetEyeHeightALVRXR set_eye_height = NULL;
        gipa(instance, "xrGetDashboardStateALVRXR", (PFN_xrVoidFunction *)&get_dashboard);
        gipa(instance, "xrCloseDashboardALVRXR", (PFN_xrVoidFunction *)&close_dashboard);
        gipa(instance, "xrQuitGameALVRXR", (PFN_xrVoidFunction *)&quit_game);
        gipa(instance, "xrRecenterALVRXR", (PFN_xrVoidFunction *)&recenter);
        gipa(instance, "xrSetEyeHeightALVRXR", (PFN_xrVoidFunction *)&set_eye_height);
        // Tests only, and only with a scratch config dir: 1 the lounge behind the panel, 2 a game,
        // 3 no panel but a game loading behind the lounge.
        const char *test_env = getenv("VAPORD_DASHBOARD_TEST");
        int dash_test = test_env && *test_env && cfg_env && *cfg_env
                            ? (!strcmp(test_env, "lounge") ? 1 : !strcmp(test_env, "loading") ? 3 : 2) : 0;
        int dash_test_frames = getenv("VAPORD_DASHBOARD_TEST_FRAMES") ? atoi(getenv("VAPORD_DASHBOARD_TEST_FRAMES")) : 120;

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
        // The aim pose, which the dashboard's lasers come from.
        strcpy(aci.actionName, "aim");
        strcpy(aci.localizedActionName, "Aim");
        XrAction aim;
        XR(xrCreateAction(set, &aci, &aim));
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
        XrAction haptic;
        {
            XrActionCreateInfo ci = {XR_TYPE_ACTION_CREATE_INFO};
            strcpy(ci.actionName, "haptic");
            strcpy(ci.localizedActionName, "Haptic");
            ci.actionType = XR_ACTION_TYPE_VIBRATION_OUTPUT;
            ci.countSubactionPaths = 2;
            ci.subactionPaths = hands;
            XR(xrCreateAction(set, &ci, &haptic));
        }
        XrActionSuggestedBinding sb[6 + 2 * A_COUNT] = {{grip}, {grip}, {haptic}, {haptic}, {aim}, {aim}};
        XR(xrStringToPath(instance, "/user/hand/left/input/grip/pose", &sb[0].binding));
        XR(xrStringToPath(instance, "/user/hand/right/input/grip/pose", &sb[1].binding));
        XR(xrStringToPath(instance, "/user/hand/left/output/haptic", &sb[2].binding));
        XR(xrStringToPath(instance, "/user/hand/right/output/haptic", &sb[3].binding));
        XR(xrStringToPath(instance, "/user/hand/left/input/aim/pose", &sb[4].binding));
        XR(xrStringToPath(instance, "/user/hand/right/input/aim/pose", &sb[5].binding));
        uint32_t nsb = 6;
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
        XrSpace grip_space[2], aim_space[2];
        XrHandTrackerEXT trackers[2];
        for (int h = 0; h < 2; h++) {
            XrActionSpaceCreateInfo asi = {XR_TYPE_ACTION_SPACE_CREATE_INFO, NULL, grip, hands[h], {{0, 0, 0, 1}, {0, 0, 0}}};
            XR(xrCreateActionSpace(session, &asi, &grip_space[h]));
            asi.action = aim;
            XR(xrCreateActionSpace(session, &asi, &aim_space[h]));
            XrHandTrackerCreateInfoEXT hci = {XR_TYPE_HAND_TRACKER_CREATE_INFO_EXT, NULL, h ? XR_HAND_RIGHT_EXT : XR_HAND_LEFT_EXT,
                                              XR_HAND_JOINT_SET_DEFAULT_EXT};
            XR(xrCreateHandTrackerEXT(session, &hci, &trackers[h]));
        }
        NSString *models_dir = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/MacVapoR/rendermodels"];
        controller controllers[2];
        bool have_model[2];
        for (int h = 0; h < 2; h++) have_model[h] = load_controller(models_dir, h == 0, dev, queue, &controllers[h]);
        // Drawn instead while the client says a hand holds a Joy-Con (or VAPORD_JOYCONS=1).
        controller joycons[2];
        for (int h = 0; h < 2; h++) joycon_controller(h == 0, dev, queue, &joycons[h]);
        bool force_joycons = getenv("VAPORD_JOYCONS") != NULL;
        ball_state ball;
        ball_reset(&ball);
        XrTime last_time = 0;
        // Bare hands: where each pinch is, and was, for a throw's speed.
        bool pinching[2] = {false, false};
        simd_float3 pinch_at[2][4];
        XrTime pinch_time[2][4];
        int pinch_n[2] = {0, 0};
        bool was_gripping[2] = {false, false};
        bool a_was_down = false;       // A's last state, for capturing the Joy-Con's attachment on a press
        bool thumb_moved[2] = {false, false};   // a hand's attachment moved to meet its thumb: saved now and then
        double attach_saved = 0;
        // The dashboard: whether it was open last frame, each hand's trigger as a press (with
        // hysteresis), a bare hand's pointing smoothed, and the seated eye height its Seated
        // button sets (the runtime's while seated, else the last one used).
        bool dash_was_open = false, trigger_down[2] = {false, false};
        // The "Loading" panel: shown since (seconds, the loop's clock), or not.
        bool load_was = false;
        double load_since = 0;
        simd_float3 hand_ray[2] = {0};
        float seated_height = 1.20f;
        int dash_frame = 0;

        world w;
        if (!make_world(dev, &w)) return 1;
        if (!dash_init(dev, queue)) return 1;
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
        scene sc = {0};
        load_chosen_scene(dev, queue, &sc);
        NSDate *scene_changed = scene_stamp(sc.dir);
        CFAbsoluteTime scene_checked = CFAbsoluteTimeGetCurrent();

        say(@"home scene up");
        bool running = false;
        // Only FOCUSED takes input; under a game (VISIBLE) the scene is still drawn but doesn't
        // react, and SYNCHRONIZED/VISIBLE/FOCUSED can come and go without the session ending.
        bool focused = false;
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
                            focused = false;
                        } else if (st == XR_SESSION_STATE_FOCUSED || st == XR_SESSION_STATE_VISIBLE ||
                                   st == XR_SESSION_STATE_SYNCHRONIZED) {
                            focused = st == XR_SESSION_STATE_FOCUSED;
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

                // A new scene chosen, or the scene's files changed: in with it.
                if (CFAbsoluteTimeGetCurrent() - scene_checked > 1) {
                    scene_checked = CFAbsoluteTimeGetCurrent();
                    NSString *dir = chosen_scene_dir();
                    NSDate *stamp = scene_stamp(dir);
                    if (!(dir == sc.dir || [dir isEqualToString:sc.dir]) || [stamp compare:scene_changed] == NSOrderedDescending) {
                        scene_changed = stamp;
                        load_chosen_scene(dev, queue, &sc);
                    }
                }

                XrFrameState fs = {XR_TYPE_FRAME_STATE};
                XR(xrWaitFrame(session, NULL, &fs));
                XR(xrBeginFrame(session, NULL));
                // The dashboard's state; with the test, made up: seated over a game, or standing in the
                // lounge, with one battery low and one charging.
                XrDashboardStateALVRXR dstate = {0};
                if (dash_test == 3) {
                    dstate = (XrDashboardStateALVRXR){.loading = 1, .battery = {-1, -1, -1}};
                    strcpy(dstate.loading_name, "RoboRecall-Win64-Shipping.exe");
                } else if (dash_test) {
                    dstate = (XrDashboardStateALVRXR){.open = 1, .game_pid = dash_test == 2 ? (uint32_t)getpid() : 0,
                                                      .battery = {0.82f, 0.55f, 0.12f}, .charging = {0, 1, 0},
                                                      .fps = 90, .mbps = 42.5f, .eye_height = dash_test == 2 ? 1.2f : 0};
                    if (dash_test == 2) strcpy(dstate.game_name, "Half-Life Alyx.exe");
                } else if (!get_dashboard || XR_FAILED(get_dashboard(session, &dstate))) {
                    dstate = (XrDashboardStateALVRXR){0};
                }
                bool dash_open = dstate.open != 0;
                if (dstate.eye_height > 0) seated_height = dstate.eye_height;
                // Headless (the test's ALVRXR_DUMP) the home scene isn't asked to render: it is anyway.
                if (!fs.shouldRender && !dash_test) {   // no headset: an empty frame keeps the session going
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
                simd_float3 head = simd_make_float3((views[0].pose.position.x + views[1].pose.position.x) / 2,
                                                    (views[0].pose.position.y + views[1].pose.position.y) / 2,
                                                    (views[0].pose.position.z + views[1].pose.position.z) / 2);
                XrQuaternionf hq = views[0].pose.orientation;
                simd_quatf head_turn = simd_quaternion(hq.x, hq.y, hq.z, hq.w);
                // Opening: the panel goes ahead of the head and stays there, world-locked, until it closes.
                if (dash_open && !dash_was_open) {
                    dash_place(head, simd_act(head_turn, simd_make_float3(0, 0, -1)));
                    if (ball.held >= 0) ball.held = -1;   // let go of the ball: the hands are pointing now
                }
                dash_was_open = dash_open;
                // A game loading behind the lounge: "Loading" ahead of the head, world-locked, until it
                // shows (the dashboard, opened meanwhile, takes its place).
                bool loading = dstate.loading && !dash_open;
                double clock = CFAbsoluteTimeGetCurrent();
                if (loading && !load_was) {
                    dash_loading_place(head, simd_act(head_turn, simd_make_float3(0, 0, -1)));
                    load_since = clock;
                }
                load_was = loading;
                // Fading in over a third of a second, then breathing gently.
                float load_opacity = (float)(fmin((clock - load_since) / 0.35, 1) * (0.85 + 0.15 * cos((clock - load_since) * 2.6)));
                if (dash_open) dash_set_state(&dstate, seated_height);
                // While the dashboard's open the hands point at it, and play nothing else.
                bool play = focused && !dash_open;
                dash_pointer pointers[2] = {0};

                // Each hand: a controller where one's held, its joints where it's bare.
                XrActiveActionSet active = {set, XR_NULL_PATH};
                XrActionsSyncInfo sync = {XR_TYPE_ACTIONS_SYNC_INFO, NULL, 1, &active};
                if (focused) xrSyncActions(session, &sync);
                bool show_controller[2] = {false, false};
                const controller *drawn[2] = {&controllers[0], &controllers[1]};
                simd_float4x4 controller_model[2];
                hand_input input[2] = {0};
                for (int h = 0; h < 2 && focused; h++) {
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
                    XrSpaceVelocity svel = {XR_TYPE_SPACE_VELOCITY};
                    XrSpaceLocation sl = {XR_TYPE_SPACE_LOCATION, &svel};
                    XrSpaceLocationFlags want = XR_SPACE_LOCATION_POSITION_TRACKED_BIT | XR_SPACE_LOCATION_ORIENTATION_TRACKED_BIT;
                    // A pinch the client sends as a controller sits on the gaze ray, at the eyes: not a
                    // controller in the hand, which can't be there.
                    bool joycon = force_joycons || dstate.joycon[h];
                    if ((have_model[h] || joycon) && XR_SUCCEEDED(xrLocateSpace(grip_space[h], stage, fs.predictedDisplayTime, &sl)) &&
                        (sl.locationFlags & want) == want &&
                        simd_distance(simd_make_float3(sl.pose.position.x, sl.pose.position.y, sl.pose.position.z), head) > 0.25f) {
                        show_controller[h] = true;
                        drawn[h] = joycon ? &joycons[h] : &controllers[h];
                        float ms = model_scale();
                        float y = 0, yaw = 0;
                        simd_float4x4 from_grip = joycon_from_grip(h == 0, &y, &yaw);
                        // Turned about the room's vertical through the hand, then raised.
                        simd_float4x4 held = pose_matrix(sl.pose);
                        simd_float4 held_at = held.columns[3];
                        held.columns[3] = simd_make_float4(0, 0, 0, 1);
                        held = simd_mul(rotation(simd_make_float3(0, 1, 0), yaw), held);
                        held.columns[3] = held_at + simd_make_float4(0, y, 0, 0);
                        controller_model[h] = joycon ? simd_mul(held, from_grip)
                                                     : simd_mul(simd_mul(pose_matrix(sl.pose), simd_diagonal_matrix(simd_make_float4(ms, ms, ms, 1))),
                                                                grip_to_model(h == 0));
                        // Attached to the fingers, once captured from the left hand (the right mirrored).
                        XrHandJointLocationEXT fj[XR_HAND_JOINT_COUNT_EXT];
                        XrHandJointLocationsEXT fjl = {XR_TYPE_HAND_JOINT_LOCATIONS_EXT, NULL, XR_FALSE, XR_HAND_JOINT_COUNT_EXT, fj};
                        XrHandJointsLocateInfoEXT fli = {XR_TYPE_HAND_JOINTS_LOCATE_INFO_EXT, NULL, stage, fs.predictedDisplayTime};
                        simd_float4x4 fingers;
                        if (joycon && XR_SUCCEEDED(xrLocateHandJointsEXT(trackers[h], &fli, &fjl)) && fjl.isActive &&
                            finger_frame(fj, h == 0, &fingers)) {
                            read_attach();
                            // Until there's one, pressing A (the right Joy-Con's bottom button) captures too: that's
                            // "in position".
                            bool a_pressed = input[1].a && !a_was_down;
                            if ((g_capture || (a_pressed && !g_have_attach)) && h == 0)
                                save_attach(0, simd_mul(simd_inverse(fingers), controller_model[h]), true);
                            if (g_have_attach) {
                                simd_float4x4 a = g_attach[h];
                                // The hand's nudge, in its own axes as seen held up in front: + right, + up (its top
                                // end, the model's -z), + into the screen (behind its face, the model's -y).
                                simd_float3 n = g_nudge[h];
                                controller_model[h] = simd_mul(simd_mul(fingers, a), translation(simd_make_float3(n.x, -n.z, -n.y)));
                                // tune.json "joycon_record": true: every joint, in this Joy-Con model's frame (mm), ten
                                // times a second into joycon-joints.csv, for checking how the hand fits round it.
                                static double recorded[2];
                                if (g_record && CFAbsoluteTimeGetCurrent() - recorded[h] > 0.1) {
                                    recorded[h] = CFAbsoluteTimeGetCurrent();
                                    static FILE *csv;
                                    if (!csv) csv = fopen([g_config_dir stringByAppendingPathComponent:@"joycon-joints.csv"].fileSystemRepresentation, "a");
                                    simd_float4x4 inv = simd_inverse(controller_model[h]);
                                    for (int jn = 0; csv && jn < XR_HAND_JOINT_COUNT_EXT; jn++) {
                                        if (!(fj[jn].locationFlags & XR_SPACE_LOCATION_POSITION_VALID_BIT)) continue;
                                        simd_float4 l = simd_mul(inv, simd_make_float4(fj[jn].pose.position.x, fj[jn].pose.position.y,
                                                                                        fj[jn].pose.position.z, 1));
                                        fprintf(csv, "%.2f,%d,%d,%.1f,%.1f,%.1f,%d,%d\n", recorded[h], h, jn, l.x * 1000, l.y * 1000, l.z * 1000,
                                                input[h].a || input[h].b, input[h].trigger > 0.5f);
                                    }
                                    if (csv) fflush(csv);
                                }
                                // While the thumb presses a button (or pushes the stick), its tip is about 8 mm over that
                                // part's top: move the attachment a little towards making it so. A and B each come from
                                // two buttons; the one nearer the thumb is taken.
                                // While the stick moves the thumb's on it, so a button pressed then wasn't the thumb.
                                int pressed[4], np = 0;
                                if (fabsf(input[h].stick[0]) > 0.3f || fabsf(input[h].stick[1]) > 0.3f || input[h].stick_click) {
                                    pressed[np++] = IN_STICK;
                                } else {
                                    if (input[h].a) pressed[np++] = IN_A;
                                    if (input[h].b) pressed[np++] = IN_B;
                                    if (input[h].menu) pressed[np++] = IN_MENU;
                                }
                                for (int k = 0; k < np; k++) {
                                    // The left thumb's tip rests on the stick and its knuckle presses the arrows; the right
                                    // one's tip presses the buttons and its knuckle works the stick.
                                    bool knuckle = h == 0 ? pressed[k] == IN_A || pressed[k] == IN_B : pressed[k] == IN_STICK;
                                    // Otherwise the pad a third of the way down the last bone from the tip, not the tip.
                                    const XrHandJointLocationEXT *tip = &fj[XR_HAND_JOINT_THUMB_TIP_EXT], *ip = &fj[XR_HAND_JOINT_THUMB_DISTAL_EXT];
                                    if (!(tip->locationFlags & ip->locationFlags & XR_SPACE_LOCATION_POSITION_VALID_BIT)) continue;
                                    simd_float3 t3 = simd_make_float3(tip->pose.position.x, tip->pose.position.y, tip->pose.position.z);
                                    simd_float3 i3 = simd_make_float3(ip->pose.position.x, ip->pose.position.y, ip->pose.position.z);
                                    simd_float3 thumb = knuckle ? i3 : t3 + (i3 - t3) / 3;
                                    {
                                        float best = 1e9f;
                                        simd_float3 want = 0;
                                        for (int i = 0; i < drawn[h]->count; i++) {
                                            const part *pp = &drawn[h]->parts[i];
                                            if (pp->input != pressed[k]) continue;
                                            simd_float3 at = simd_make_float3(simd_mul(controller_model[h],
                                                                                       simd_make_float4(pp->top + simd_make_float3(0, 0.008f, 0), 1)));
                                            if (simd_distance(at, thumb) < best) best = simd_distance(at, thumb), want = at;
                                        }
                                        if (best > 0.06f) continue;   // too far to be this one: tracking's off
                                        // Into the palm frame's axes (its columns are orthonormal).
                                        simd_float3 w = thumb - want;
                                        simd_float3 d = simd_make_float3(simd_dot(simd_make_float3(fingers.columns[0]), w),
                                                                         simd_dot(simd_make_float3(fingers.columns[1]), w),
                                                                         simd_dot(simd_make_float3(fingers.columns[2]), w));
                                        g_attach[h].columns[3] += simd_make_float4(d * 0.05f, 0);
                                        thumb_moved[h] = true;
                                    }
                                }

                            }
                        }
                        // The ball: squeeze the trigger or grip with the controller in it, taking it from the other
                        // hand if that has it.
                        simd_float4x4 hand = pose_matrix(sl.pose);
                        simd_float3 at = simd_make_float3(sl.pose.position.x, sl.pose.position.y, sl.pose.position.z);
                        // The dashboard's laser, from the aim pose; the trigger presses.
                        trigger_down[h] = focused && (trigger_down[h] ? input[h].trigger > 0.35f : input[h].trigger > 0.6f);
                        XrSpaceLocation al = {XR_TYPE_SPACE_LOCATION};
                        if (dash_open && XR_SUCCEEDED(xrLocateSpace(aim_space[h], stage, fs.predictedDisplayTime, &al)) &&
                            (al.locationFlags & want) == want) {
                            simd_float4x4 am = pose_matrix(al.pose);
                            pointers[h] = (dash_pointer){true, simd_make_float3(am.columns[3]),
                                                         simd_normalize(-simd_make_float3(am.columns[2])), trigger_down[h]};
                        }
                        bool gripping = play && (input[h].trigger > 0.6f || input[h].squeeze > 0.6f);
                        bool letting_go = input[h].trigger < 0.35f && input[h].squeeze < 0.35f;
                        if (gripping && !was_gripping[h] && ball.held != h && simd_distance(at, ball.p) < kBallRadius + 0.07f) {
                            ball.held = h;
                            simd_float4x4 bm = simd_matrix4x4(ball.q);
                            bm.columns[3] = simd_make_float4(ball.p, 1);
                            ball.in_hand = simd_mul(simd_inverse(hand), bm);
                            XrHapticVibration buzz = {XR_TYPE_HAPTIC_VIBRATION, NULL, 40000000, XR_FREQUENCY_UNSPECIFIED, 0.6f};
                            XrHapticActionInfo hai = {XR_TYPE_HAPTIC_ACTION_INFO, NULL, haptic, hands[h]};
                            xrApplyHapticFeedback(session, &hai, (const XrHapticBaseHeader *)&buzz);
                        }
                        if (ball.held == h) {
                            simd_float4x4 bm = simd_mul(hand, ball.in_hand);
                            ball.p = simd_make_float3(bm.columns[3]);
                            ball.q = simd_quaternion(simd_matrix(simd_make_float3(bm.columns[0]), simd_make_float3(bm.columns[1]),
                                                                    simd_make_float3(bm.columns[2])));
                            if (letting_go) {
                                // It leaves with the hand's motion at the ball: its velocity, and its spin.
                                simd_float3 lin = simd_make_float3(svel.linearVelocity.x, svel.linearVelocity.y, svel.linearVelocity.z);
                                simd_float3 ang = simd_make_float3(svel.angularVelocity.x, svel.angularVelocity.y, svel.angularVelocity.z);
                                if (!(svel.velocityFlags & XR_SPACE_VELOCITY_LINEAR_VALID_BIT)) lin = 0;
                                if (!(svel.velocityFlags & XR_SPACE_VELOCITY_ANGULAR_VALID_BIT)) ang = 0;
                                ball.v = lin + simd_cross(ang, ball.p - at);
                                ball.w = ang;
                                ball.held = -1;
                            }
                        }
                        was_gripping[h] = gripping;
                        // The hand too, round a Joy-Con, with tune.json "joycon_show_hands": its model is placed
                        // from the hand, so this shows how well it fits.
                        read_attach();
                        if (joycon && g_show_hands) {
                            XrHandJointLocationEXT joints[XR_HAND_JOINT_COUNT_EXT];
                            XrHandJointLocationsEXT jl = {XR_TYPE_HAND_JOINT_LOCATIONS_EXT, NULL, XR_FALSE, XR_HAND_JOINT_COUNT_EXT, joints};
                            XrHandJointsLocateInfoEXT hli = {XR_TYPE_HAND_JOINTS_LOCATE_INFO_EXT, NULL, stage, fs.predictedDisplayTime};
                            if (XR_SUCCEEDED(xrLocateHandJointsEXT(trackers[h], &hli, &jl)) && jl.isActive) hand_lines(joints, &sc, lines, &nlines);
                        }
                        continue;
                    }
                    was_gripping[h] = false;
                    XrHandJointLocationEXT joints[XR_HAND_JOINT_COUNT_EXT];
                    XrHandJointLocationsEXT jl = {XR_TYPE_HAND_JOINT_LOCATIONS_EXT, NULL, XR_FALSE, XR_HAND_JOINT_COUNT_EXT, joints};
                    XrHandJointsLocateInfoEXT hli = {XR_TYPE_HAND_JOINTS_LOCATE_INFO_EXT, NULL, stage, fs.predictedDisplayTime};
                    if (XR_SUCCEEDED(xrLocateHandJointsEXT(trackers[h], &hli, &jl)) && jl.isActive) {
                        hand_lines(joints, &sc, lines, &nlines);
                        // The ball, bare-handed: pinch it.
                        XrVector3f th = joints[XR_HAND_JOINT_THUMB_TIP_EXT].pose.position, ix = joints[XR_HAND_JOINT_INDEX_TIP_EXT].pose.position;
                        simd_float3 t3 = simd_make_float3(th.x, th.y, th.z), i3 = simd_make_float3(ix.x, ix.y, ix.z);
                        simd_float3 at = (t3 + i3) * 0.5f;
                        float gap = simd_distance(t3, i3);
                        bool now = focused && (pinching[h] ? gap < 0.045f : gap < 0.022f);
                        // The dashboard, bare-handed: a ray from about the shoulder through the hand,
                        // between the index and thumb knuckles, which hold still through a pinch;
                        // smoothed, as a hand trembles. A pinch presses.
                        if (dash_open) {
                            XrVector3f ik = joints[XR_HAND_JOINT_INDEX_PROXIMAL_EXT].pose.position,
                                       tk = joints[XR_HAND_JOINT_THUMB_PROXIMAL_EXT].pose.position;
                            simd_float3 knuckles = (simd_make_float3(ik.x, ik.y, ik.z) + simd_make_float3(tk.x, tk.y, tk.z)) * 0.5f;
                            simd_float3 fwd = simd_act(head_turn, simd_make_float3(0, 0, -1));
                            fwd.y = 0;
                            fwd = simd_length(fwd) > 1e-3f ? simd_normalize(fwd) : simd_make_float3(0, 0, -1);
                            simd_float3 side = simd_cross(fwd, simd_make_float3(0, 1, 0));
                            simd_float3 shoulder = head + side * (h ? 0.17f : -0.17f) - simd_make_float3(0, 0.18f, 0) - fwd * 0.05f;
                            simd_float3 dir = simd_normalize(knuckles - shoulder);
                            hand_ray[h] = simd_length(hand_ray[h]) > 0.5f ? simd_normalize(simd_mix(hand_ray[h], dir, 0.35f)) : dir;
                            pointers[h] = (dash_pointer){true, knuckles, hand_ray[h], now};
                        }
                        // The last few pinch points, for the throw.
                        int k = pinch_n[h] % 4;
                        pinch_at[h][k] = at;
                        pinch_time[h][k] = fs.predictedDisplayTime;
                        pinch_n[h]++;
                        if (play && now && !pinching[h] && ball.held != h && simd_distance(at, ball.p) < kBallRadius + 0.05f) {
                            ball.held = h;
                            simd_float4x4 bm = simd_matrix4x4(ball.q);
                            bm.columns[3] = simd_make_float4(ball.p, 1);
                            ball.in_hand = simd_mul(simd_inverse(translation(at)), bm);
                        }
                        if (ball.held == h) {
                            simd_float4x4 bm = simd_mul(translation(at), ball.in_hand);
                            ball.p = simd_make_float3(bm.columns[3]);
                            if (!now) {
                                int oldest = pinch_n[h] >= 4 ? pinch_n[h] % 4 : 0, newest = (pinch_n[h] - 1) % 4;
                                double span = (pinch_time[h][newest] - pinch_time[h][oldest]) / 1e9;
                                ball.v = span > 0.005 ? (pinch_at[h][newest] - pinch_at[h][oldest]) / (float)span : 0;
                                ball.w = 0;
                                ball.held = -1;
                            }
                        }
                        pinching[h] = now;
                    } else {
                        pinching[h] = false;
                        hand_ray[h] = 0;
                        if (ball.held == h) ball.held = -1;   // the hand's gone: drop it
                    }
                }
                a_was_down = input[1].a;
                if ((thumb_moved[0] || thumb_moved[1]) && CFAbsoluteTimeGetCurrent() - attach_saved > 10) {
                    attach_saved = CFAbsoluteTimeGetCurrent();
                    for (int k = 0; k < 2; k++)
                        if (thumb_moved[k]) save_attach(k, g_attach[k], false);
                    thumb_moved[0] = thumb_moved[1] = false;
                }

                // The dashboard's pointers hit-tested, and a press acted on.
                dash_beam beams[2] = {0};
                if (dash_open) {
                    if (dash_test) {
                        // Made-up pointers: the right hand at Recenter, pressing it on frames 40 to
                        // 51; the left beside the panel, at nothing.
                        simd_float3 fwd = simd_act(head_turn, simd_make_float3(0, 0, -1));
                        simd_float3 r_from = head + simd_make_float3(0.22f, -0.35f, 0) + fwd * 0.15f;
                        simd_float3 l_from = head + simd_make_float3(-0.22f, -0.35f, 0) + fwd * 0.15f;
                        simd_float3 off = dash_button_centre(DASH_STANDING) + simd_make_float3(-0.5f, 0, 0);
                        pointers[1] = (dash_pointer){true, r_from, simd_normalize(dash_button_centre(DASH_RECENTER) - r_from),
                                                     dash_frame >= 40 && dash_frame < 52};
                        pointers[0] = (dash_pointer){true, l_from, simd_normalize(off - l_from), false};
                    }
                    int hand = 0;
                    int pressed = dash_point(pointers, beams, &hand);
                    if (pressed != DASH_NONE) {
                        XrHapticVibration tick = {XR_TYPE_HAPTIC_VIBRATION, NULL, 15000000, XR_FREQUENCY_UNSPECIFIED, 0.5f};
                        XrHapticActionInfo hai = {XR_TYPE_HAPTIC_ACTION_INFO, NULL, haptic, hands[hand]};
                        if (focused) xrApplyHapticFeedback(session, &hai, (const XrHapticBaseHeader *)&tick);
                        // −5/+5 cm nudge the seated height and put it in force, from where the head is now.
                        if (pressed == DASH_LOWER) seated_height = fmaxf(seated_height - 0.05f, 0.5f);
                        if (pressed == DASH_HIGHER) seated_height = fminf(seated_height + 0.05f, 2.2f);
                        XrResult r = XR_ERROR_FUNCTION_UNSUPPORTED;
                        if (!dash_test) switch (pressed) {
                        case DASH_STANDING: if (set_eye_height) r = set_eye_height(session, 0); break;
                        case DASH_SEATED:
                        case DASH_LOWER:
                        case DASH_HIGHER: if (set_eye_height) r = set_eye_height(session, seated_height); break;
                        case DASH_RECENTER: if (recenter) r = recenter(session); break;
                        case DASH_QUIT: if (quit_game) r = quit_game(session); break;
                        case DASH_CLOSE: if (close_dashboard) r = close_dashboard(session); break;
                        }
                        say(@"dashboard: %s (%s hand)%s", dash_button_name(pressed), hand ? "right" : "left",
                            dash_test ? ", a test: nothing done" : XR_SUCCEEDED(r) ? "" : [NSString stringWithFormat:@" failed: %d", r].UTF8String);
                    }
                }
                // The ball's flight, in small steps.
                float dt = last_time ? fminf((float)((fs.predictedDisplayTime - last_time) / 1e9), 0.05f) : 0;
                last_time = fs.predictedDisplayTime;
                for (int s = 0; s < 4; s++) ball_step(&ball, dt / 4);

                // Over a game the dashboard is all the lounge draws, over transparency: the compositor
                // lays it on the dimmed game by its alpha (premultiplied).
                bool overlay = dash_open && dstate.game_pid != 0;
                segment beam_lines[4];
                int nbeams = 0;
                for (int h = 0; h < 2; h++) {
                    if (!beams[h].show) continue;
                    simd_float4 c = beams[h].hit ? sc.bones : sc.palm;   // cyan on the panel, purple off it
                    segment s = {{beams[h].from.x, beams[h].from.y, beams[h].from.z, 0.0022f}, {beams[h].to.x, beams[h].to.y, beams[h].to.z, 0}, {0}};
                    memcpy(s.colour, &c, sizeof s.colour);
                    beam_lines[nbeams++] = s;
                    if (beams[h].hit) {
                        segment dot = {{beams[h].to.x, beams[h].to.y, beams[h].to.z, 0.0065f}, {beams[h].to.x, beams[h].to.y, beams[h].to.z, 0}, {0}};
                        memcpy(dot.colour, &sc.tips, sizeof dot.colour);
                        beam_lines[nbeams++] = dot;
                    }
                }

                XrCompositionLayerProjectionView pv[2];
                id<MTLCommandBuffer> cmd = [queue commandBuffer];
                uint32_t acquired[2];
                for (int e = 0; e < 2; e++) {
                    uint32_t idx;
                    XR(xrAcquireSwapchainImage(chains[e], NULL, &idx));
                    acquired[e] = idx;
                    XrSwapchainImageWaitInfo wi = {XR_TYPE_SWAPCHAIN_IMAGE_WAIT_INFO, NULL, XR_INFINITE_DURATION};
                    XR(xrWaitSwapchainImage(chains[e], &wi));

                    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
                    rp.colorAttachments[0].texture = images[e][idx];
                    rp.colorAttachments[0].loadAction = overlay ? MTLLoadActionClear : MTLLoadActionDontCare;
                    rp.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);
                    rp.colorAttachments[0].storeAction = MTLStoreActionStore;
                    rp.depthAttachment.texture = depth[e];
                    rp.depthAttachment.loadAction = MTLLoadActionClear;
                    rp.depthAttachment.storeAction = MTLStoreActionDontCare;
                    rp.depthAttachment.clearDepth = 1.0;
                    id<MTLRenderCommandEncoder> enc = [cmd renderCommandEncoderWithDescriptor:rp];
                    camera_gpu camera = overlay ? eye_camera(views[e].pose, views[e].fov)
                                                : draw_world(enc, &w, &sc, views[e].pose, views[e].fov,
                                                             (float)(CFAbsoluteTimeGetCurrent() - start), &ball);
                    for (int h = 0; h < 2; h++) {
                        if (show_controller[h] && !overlay)
                            draw_controller(enc, &w, &camera, drawn[h], controller_model[h], &input[h], &sc);
                    }
                    // The panel goes in the depth buffer, so a hand behind it is hidden.
                    if (dash_open) dash_draw(enc, (simd_float4x4[2]){camera.view, camera.proj}, w.depth_write);
                    if (loading && !overlay)
                        dash_loading_draw(enc, (simd_float4x4[2]){camera.view, camera.proj}, w.depth_write, dstate.loading_name,
                                          load_opacity);
                    if (nlines && !overlay) {
                        [enc setRenderPipelineState:w.line_pso];
                        [enc setDepthStencilState:w.depth_test];
                        [enc setVertexBytes:lines length:sizeof(segment) * nlines atIndex:0];
                        [enc setVertexBytes:&camera length:sizeof camera atIndex:1];
                        [enc drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4 instanceCount:nlines];
                    }
                    if (nbeams) {   // over everything: the beam ends on the panel's face
                        [enc setRenderPipelineState:w.line_pso];
                        [enc setDepthStencilState:w.no_depth];
                        [enc setVertexBytes:beam_lines length:sizeof(segment) * nbeams atIndex:0];
                        [enc setVertexBytes:&camera length:sizeof camera atIndex:1];
                        [enc drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4 instanceCount:nbeams];
                    }
                    [enc endEncoding];

                    pv[e] = (XrCompositionLayerProjectionView){XR_TYPE_COMPOSITION_LAYER_PROJECTION_VIEW, NULL,
                                                               views[e].pose, views[e].fov,
                                                               {chains[e], {{0, 0}, {(int32_t)vcv[e].recommendedImageRectWidth,
                                                                                     (int32_t)vcv[e].recommendedImageRectHeight}}, 0}};
                }
                [cmd commit];
                [cmd waitUntilScheduled];
                if (dash_test && (dash_frame == 30 || dash_frame == 45)) {
                    [cmd waitUntilCompleted];
                    save_with_alpha(images[0][acquired[0]], queue,
                                    [g_config_dir stringByAppendingPathComponent:[NSString stringWithFormat:@"dashboard-%d.png", dash_frame]]);
                }
                for (int e = 0; e < 2; e++) XR(xrReleaseSwapchainImage(chains[e], NULL));

                XrCompositionLayerProjection layer = {XR_TYPE_COMPOSITION_LAYER_PROJECTION, NULL, 0, stage, 2, pv};
                const XrCompositionLayerBaseHeader *layers[] = {(const XrCompositionLayerBaseHeader *)&layer};
                XrFrameEndInfo fei = {XR_TYPE_FRAME_END_INFO, NULL, fs.predictedDisplayTime,
                                      XR_ENVIRONMENT_BLEND_MODE_OPAQUE, 1, layers};
                XR(xrEndFrame(session, &fei));
                if (dash_test && ++dash_frame >= dash_test_frames) {
                    say(@"dashboard test: %d frames", dash_frame);
                    unlink(g_pid_path.fileSystemRepresentation);
                    return 0;
                }
            }
        }
    }
}
