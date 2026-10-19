// compositor-check: the compositor core (src/compositor.m) and the SERVER encode path
// (axr_encode_composite) in one headless process, built straight from src/ with the real ALVR
// core, so sources can be driven through the real slot protocol (shared events, descriptors,
// releases) without the XPC transport. tests/compositor-check.sh builds and runs it with a
// scratch ALVRXR_CONFIG_DIR and ALVRXR_DUMP, then checks the decoded stream.
//
//   compositor-check server N        one local source, N frames through the compositor (parity)
//   compositor-check legacy N        the same picture, N frames through axr_submit (the reference)
//   compositor-check compare A B     decodes both dumps and prints how far apart their frames are
//   compositor-check handover [--watchdog]
//                                    a lounge (green) and a game (red, 20 empty frames first);
//                                    the game is removed (or just stops, --watchdog) after 3.2 s
//   compositor-check reproject       axr_encode_composite with the other source's head yawed
//   compositor-check stripe DUMP     per frame, the x of the white stripe in the left eye
//
// The sources draw as xrclient does (a fill and the frame number as a bar row), so dumpcheck
// reads the dump the same way.

#import <Foundation/Foundation.h>
#import <IOSurface/IOSurfaceObjC.h>
#import <Metal/Metal.h>
#include <math.h>
#include <pthread.h>
#include <stdio.h>
#include <sys/mman.h>
#include <unistd.h>

#include "alvrxr.h"
#include "compositor.h"
#include "tracking.h"

enum { CELL = 16, BAR_H = 64, BITS = 16 };

static int64_t g_t0;
static void say(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void say(const char *fmt, ...) {
    va_list a;
    va_start(a, fmt);
    printf("t=%7.3f ", (axr_now_ns() - g_t0) / 1e9);
    vprintf(fmt, a);
    printf("\n");
    fflush(stdout);
    va_end(a);
}

static const char shader_src[] =
    "#include <metal_stdlib>\nusing namespace metal;\n"
    "vertex float4 vs(uint v [[vertex_id]]) { float2 p = float2((v << 1) & 2, v & 2); return float4(p * 2 - 1, 0, 1); }\n"
    "fragment float4 fs(constant float4 &c [[buffer(0)]]) { return c; }\n";

static id<MTLDevice> g_dev;
static id<MTLCommandQueue> g_queue;
static id<MTLRenderPipelineState> g_pso;

static float srgb_to_linear(float c) { return c <= 0.04045f ? c / 12.92f : powf((c + 0.055f) / 1.055f, 2.4f); }

static void fill(id<MTLRenderCommandEncoder> enc, NSUInteger x, NSUInteger y, NSUInteger w, NSUInteger h, const float rgb[3]) {
    float c[4] = {srgb_to_linear(rgb[0]), srgb_to_linear(rgb[1]), srgb_to_linear(rgb[2]), 1};
    [enc setScissorRect:(MTLScissorRect){x, y, w, h}];
    [enc setFragmentBytes:c length:sizeof c atIndex:0];
    [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
}

// Both eyes of a slot: the fill, and the frame number's bar row at each eye's centre (number < 0:
// none). stripe_x >= 0 draws a 16 px white stripe there in each eye instead of bars.
static void draw_slot(id<MTLCommandBuffer> cmd, id<MTLTexture> tex, const float rgb[3], int number, int stripe_x) {
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture = tex;
    rp.colorAttachments[0].loadAction = MTLLoadActionDontCare;
    rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLRenderCommandEncoder> enc = [cmd renderCommandEncoderWithDescriptor:rp];
    [enc setRenderPipelineState:g_pso];
    NSUInteger W = tex.width / 2, H = tex.height;
    const float white[3] = {1, 1, 1}, black[3] = {0, 0, 0};
    fill(enc, 0, 0, W * 2, H, rgb);
    for (int e = 0; e < 2; e++) {
        NSUInteger ex = e * W;
        if (stripe_x >= 0) { fill(enc, ex + stripe_x - 8, 0, 16, H, white); continue; }
        if (number < 0) continue;
        NSUInteger x0 = ex + W / 2 - (BITS + 2) * CELL / 2, y0 = H / 2 - BAR_H / 2;
        fill(enc, x0, y0, CELL, BAR_H, white);
        for (int b = 0; b < BITS; b++)
            fill(enc, x0 + (1 + b) * CELL, y0, CELL, BAR_H, (number >> (BITS - 1 - b)) & 1 ? white : black);
        fill(enc, x0 + (1 + BITS) * CELL, y0, CELL, BAR_H, black);
    }
    [enc endEncoding];
}

static void setup_metal(void) {
    g_dev = axr_metal_device();
    g_queue = [g_dev newCommandQueue];
    NSError *err = nil;
    id<MTLLibrary> lib = [g_dev newLibraryWithSource:@(shader_src) options:nil error:&err];
    MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
    pd.vertexFunction = [lib newFunctionWithName:@"vs"];
    pd.fragmentFunction = [lib newFunctionWithName:@"fs"];
    pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm_sRGB;
    g_pso = [g_dev newRenderPipelineStateWithDescriptor:pd error:&err];
    if (!g_pso) { fprintf(stderr, "pipeline: %s\n", err.localizedDescription.UTF8String); exit(1); }
}

static id<MTLTexture> slot_texture(uint32_t w2, uint32_t h) {
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm_sRGB width:w2
                                                                                height:h mipmapped:NO];
    d.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    d.storageMode = MTLStorageModeShared;
    return [g_dev newTextureWithDescriptor:d];
}

static void pace(int64_t *next) {
    int64_t period = (int64_t)(1e9 / axr_refresh_hz()), now = axr_now_ns();
    *next += period;
    if (*next < now - period) *next = now;
    if (*next > now) usleep((useconds_t)((*next - now) / 1000));
}

static axr_pose head_yaw(float deg) {
    float h = deg * (float)M_PI / 360;
    return (axr_pose){{0, sinf(h), 0, cosf(h)}, {0, 1.6f, 0}};
}

// ------------------------------------------------------------------------------- a source's driver
// What slots.m does in CLIENT mode, on the compositor's slots: the GPU waits for the release of
// the slot's last frame, the CPU checks it too (a release that never comes is a protocol
// failure), the descriptor goes in before the signal.

typedef struct {
    const char *label;
    axr_source *src;
    id<MTLTexture> tex[AXR_SLOTS];
    id<MTLSharedEvent> frame, release;
    axr_shm_session *region;
    uint64_t seq;
    float rgb[3];
    int black_first;          // frames without content first
    int frames;               // sent
    _Atomic int stop;
    int violations;           // slots not released in time
    uint32_t focus;
    bool render;
    pthread_t thread;
    int64_t last_sent_ns;
} driver;

static bool driver_open(driver *d, const char *label, axr_source *src, const float rgb[3], int black_first) {
    memset((void *)d, 0, sizeof *d);
    d->label = label;
    d->src = src;
    memcpy(d->rgb, rgb, sizeof d->rgb);
    d->black_first = black_first;
    NSArray<IOSurface *> *surfaces = axr_source_slot_surfaces(src);
    if (surfaces.count != AXR_SLOTS) { say("%s: no surfaces", label); return false; }
    for (int i = 0; i < AXR_SLOTS; i++) {
        IOSurface *s = surfaces[i];
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm_sRGB
                                                                                      width:s.width height:s.height mipmapped:NO];
        td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
        td.storageMode = MTLStorageModeShared;
        d->tex[i] = [g_dev newTextureWithDescriptor:td iosurface:(__bridge IOSurfaceRef)s plane:0];
    }
    d->frame = [g_dev newSharedEventWithHandle:axr_source_frame_event(src)];
    d->release = [g_dev newSharedEventWithHandle:axr_source_release_event(src)];
    void *r = mmap(NULL, sizeof(axr_shm_session), PROT_READ | PROT_WRITE, MAP_SHARED, axr_source_session_fd(src), 0);
    if (r == MAP_FAILED || !d->frame || !d->release) { say("%s: can't open the source", label); return false; }
    d->region = r;
    d->focus = atomic_load(&d->region->focus);
    d->render = atomic_load(&d->region->should_render) != 0;
    say("%s: opened, focus %u, should_render %d", label, d->focus, d->render);
    return true;
}

static void driver_frame(driver *d, bool content) {
    uint64_t seq = ++d->seq;
    uint32_t slot = (uint32_t)(seq % AXR_SLOTS);
    if (seq > AXR_SLOTS && ![d->release waitUntilSignaledValue:seq - AXR_SLOTS timeoutMS:2000]) {
        d->violations++;
        say("%s: VIOLATION: slot %u of frame %llu not released after 2 s (release at %llu)", d->label, slot,
            (unsigned long long)seq, (unsigned long long)d->release.signaledValue);
    }
    if (seq > AXR_FRAME_RING) [d->release waitUntilSignaledValue:seq - AXR_FRAME_RING timeoutMS:100];
    id<MTLCommandBuffer> cmd = [g_queue commandBuffer];
    if (seq > AXR_SLOTS) [cmd encodeWaitForEvent:d->release value:seq - AXR_SLOTS];
    draw_slot(cmd, d->tex[slot], d->rgb, content ? (int)seq : -1, -1);
    int64_t display = axr_now_ns() + 20000000;
    axr_frame_desc *f = &d->region->frames[seq % AXR_FRAME_RING];
    *f = (axr_frame_desc){.seq = seq, .slot = slot, .flags = content ? AXR_FRAME_HAS_CONTENT : 0, .display_time = display,
                          .client_ts = (uint64_t)display, .head = head_yaw(0)};
    atomic_store_explicit(&d->region->frame_head, seq, memory_order_release);
    [cmd encodeSignalEvent:d->frame value:seq];
    [cmd commit];
    d->frames++;
    d->last_sent_ns = axr_now_ns();
}

static void *driver_thread(void *arg) {
    driver *d = arg;
    int64_t next = axr_now_ns();
    while (!atomic_load(&d->stop)) {
        pace(&next);
        uint32_t focus = atomic_load(&d->region->focus);
        bool render = atomic_load(&d->region->should_render) != 0;
        if (focus != d->focus || render != d->render) {
            d->focus = focus;
            d->render = render;
            say("%s: focus %s, should_render %d (at frame %d)", d->label, focus == 2 ? "FOCUSED" : focus == 1 ? "VISIBLE" : "HIDDEN",
                render, d->frames);
        }
        atomic_store(&d->region->heartbeat_ns, (uint64_t)axr_now_ns());
        bool content = render && d->frames >= d->black_first;
        if (d->frames == d->black_first) say("%s: first content frame", d->label);
        driver_frame(d, content);
    }
    return NULL;
}

static void driver_start(driver *d) { pthread_create(&d->thread, NULL, driver_thread, d); }
static void driver_stop(driver *d) {
    atomic_store(&d->stop, 1);
    pthread_join(d->thread, NULL);
    say("%s: stopped after %d frames, %d release violations", d->label, d->frames, d->violations);
}

// ------------------------------------------------------------------------------------- scenarios

static const float kGreen[3] = {0, 200 / 255.f, 60 / 255.f}, kRed[3] = {200 / 255.f, 40 / 255.f, 40 / 255.f};

static int run_server(int n) {
    axr_compositor_start();
    axr_source *src = axr_compositor_add_source(true, getpid());
    driver d;
    if (!src || !driver_open(&d, "lounge", src, kGreen, 0)) return 1;
    int64_t next = axr_now_ns();
    for (int i = 0; i < n; i++) { pace(&next); driver_frame(&d, true); }
    usleep(500000);
    say("server: %d frames, %d release violations", d.frames, d.violations);
    axr_compositor_remove_source(src);
    return d.violations ? 1 : 0;
}

static int run_legacy(int n) {
    uint32_t w, h;
    axr_stream_eye_size(&w, &h);
    id<MTLTexture> tex[AXR_SLOTS];
    for (int i = 0; i < AXR_SLOTS; i++) tex[i] = slot_texture(w * 2, h);
    int64_t next = axr_now_ns();
    for (int i = 1; i <= n; i++) {
        pace(&next);
        id<MTLTexture> t = tex[i % AXR_SLOTS];
        id<MTLCommandBuffer> cmd = [g_queue commandBuffer];
        draw_slot(cmd, t, kGreen, i, -1);
        [cmd enqueue];
        axr_eye_image eyes[2] = {{t, 0, 0, 0, (int32_t)w, (int32_t)h}, {t, 0, (int32_t)w, 0, (int32_t)w, (int32_t)h}};
        axr_submit(axr_now_ns() + 20000000, eyes, g_queue);
        [cmd commit];
    }
    usleep(500000);
    say("legacy: %d frames", n);
    return 0;
}

static int run_handover(bool watchdog) {
    axr_compositor_start();
    axr_source *lounge_src = axr_compositor_add_source(true, getpid());
    driver lounge, game;
    if (!lounge_src || !driver_open(&lounge, "lounge", lounge_src, kGreen, 0)) return 1;
    driver_start(&lounge);
    usleep(600000);
    axr_source *game_src = axr_compositor_add_source(false, 0);
    if (!game_src || !driver_open(&game, "game", game_src, kRed, 20)) return 1;
    say("game: starting");
    driver_start(&game);
    // Long enough for the lounge to idle: the fade ends ~0.7 s in, and it idles 2 s after that.
    usleep(3200000);
    if (watchdog) {
        driver_stop(&game);
        say("game: stopped sending (no removal)");
    } else {
        driver_stop(&game);
        axr_compositor_remove_source(game_src);
        say("game: removed");
    }
    usleep(1500000);
    driver_stop(&lounge);
    usleep(300000);
    axr_compositor_remove_source(lounge_src);
    return lounge.violations || game.violations ? 1 : 0;
}

static int run_reproject(void) {
    uint32_t w, h;
    axr_stream_eye_size(&w, &h);
    id<MTLTexture> a = slot_texture(w * 2, h), b = slot_texture(w * 2, h);
    const float black[3] = {0, 0, 0};
    id<MTLCommandBuffer> cmd = [g_queue commandBuffer];
    draw_slot(cmd, a, black, -1, -1);
    draw_slot(cmd, b, black, -1, (int)w / 2);
    [cmd commit];
    [cmd waitUntilCompleted];
    axr_views v = axr_current_views();
    float tl = tanf(v.fov[0][0]), tr = tanf(v.fov[0][1]);
    float yaw = 10;
    // The stripe at the source's centre column looks along x0 in tan space; turned by the yaw,
    // in the target's frame it is at x1 (the target looks straight ahead).
    float x0 = (tl + tr) / 2, th = yaw * (float)M_PI / 180;
    float x1 = (x0 * cosf(th) - sinf(th)) / (x0 * sinf(th) + cosf(th));
    printf("expected: stripe at %.1f px with no turn, %.1f px with the source yawed %.0f deg (left eye, %u px wide, fov tan %.3f..%.3f)\n",
           w / 2.0, (x1 - tl) / (tr - tl) * w, yaw, w, tl, tr);
    int64_t next = axr_now_ns();
    for (int i = 0; i < 24; i++) {
        pace(&next);
        axr_compose_frame fg = {.texture = a, .head = head_yaw(0), .display_time = axr_now_ns() + 20000000};
        axr_compose_frame other = {.texture = b, .head = head_yaw(i < 12 ? 0 : yaw), .display_time = fg.display_time};
        fg.client_ts = other.client_ts = (uint64_t)fg.display_time;
        if (!axr_encode_composite(&fg, &other, 0, nil)) say("reproject: frame %d dropped", i);
    }
    usleep(500000);
    return 0;
}

// ------------------------------------------------------------------------------------- decoding

static FILE *decode(const char *file, int *W, int *H) {
    char cmd[1024];
    snprintf(cmd, sizeof cmd, "/opt/homebrew/bin/ffprobe -v error -f hevc -i '%s' -select_streams v:0 -show_entries stream=width,height -of csv=p=0:s=x 2>/dev/null", file);
    FILE *p = popen(cmd, "r");
    if (!p || fscanf(p, "%dx%d", W, H) != 2) { fprintf(stderr, "can't read %s\n", file); exit(1); }
    pclose(p);
    snprintf(cmd, sizeof cmd, "/opt/homebrew/bin/ffmpeg -v error -f hevc -i '%s' -fps_mode passthrough -vf scale=in_range=tv:in_color_matrix=bt709 -f rawvideo -pix_fmt rgb24 - 2>/dev/null", file);
    return popen(cmd, "r");
}

// The frame numbers dumpcheck read from each decoded frame's bars, in order.
static int read_bars(const char *txt, int out[], int max) {
    FILE *f = fopen(txt, "r");
    int n = 0, idx, bars;
    char line[512];
    while (f && n < max && fgets(line, sizeof line, f))
        if (sscanf(line, "frame %d", &idx) == 1 && strstr(line, "bars ") && sscanf(strstr(line, "bars ") + 5, "%d", &bars) == 1)
            out[n++] = bars;
    if (f) fclose(f);
    return n;
}

// Pairs the frames by the number drawn into them: the compositor may take the newer of two
// frames that arrive together, so one stream can be missing a few.
static int run_compare(const char *fa, const char *fb, const char *ta, const char *tb) {
    int wa, ha, wb, hb;
    FILE *a = decode(fa, &wa, &ha), *b = decode(fb, &wb, &hb);
    if (wa != wb || ha != hb) { printf("sizes differ: %dx%d vs %dx%d\n", wa, ha, wb, hb); return 1; }
    static int bars_a[4096], bars_b[4096];
    int na = ta ? read_bars(ta, bars_a, 4096) : 0, nb = tb ? read_bars(tb, bars_b, 4096) : 0;
    size_t n = (size_t)wa * ha * 3;
    uint8_t *fa_ = malloc(n), *fb_ = malloc(n);
    int frames = 0, worst = 0, ia = 0, ib = 0;
    double mean_sum = 0;
    bool have_b = false;   // fb_ holds a frame of b not yet compared, numbered got
    int got = -1;
    while (fread(fa_, 1, n, a) == n) {
        int want = ia < na ? bars_a[ia] : -1;
        ia++;
        bool ended = false;
        while (!have_b || (want >= 0 && got < want)) {
            if (fread(fb_, 1, n, b) != n) { ended = true; break; }
            got = ib < nb ? bars_b[ib] : -1;
            ib++;
            have_b = true;
            if (want < 0) break;
        }
        if (ended) break;
        if (want >= 0 && got != want) continue;   // b lacks this one
        have_b = false;
        int max = 0;
        double sum = 0;
        for (size_t i = 0; i < n; i++) { int d = abs(fa_[i] - fb_[i]); sum += d; if (d > max) max = d; }
        if (max > worst) worst = max;
        mean_sum += sum / n;
        frames++;
    }
    pclose(a);
    pclose(b);
    printf("compared %d frames: max abs diff %d, mean abs diff %.3f\n", frames, worst, frames ? mean_sum / frames : 0);
    return frames ? 0 : 1;
}

static int run_stripe(const char *file) {
    int W, H;
    FILE *p = decode(file, &W, &H);
    size_t n = (size_t)W * H * 3;
    uint8_t *f = malloc(n);
    int index = 0;
    while (fread(f, 1, n, p) == n) {
        int ew = W / 2, y = H / 2, first = -1, last = -1;
        for (int x = 0; x < ew; x++) {
            const uint8_t *px = f + (y * W + x) * 3;
            if (px[0] > 180 && px[1] > 180 && px[2] > 180) { if (first < 0) first = x; last = x; }
        }
        printf("frame %d stripe %.1f width %d\n", index++, first < 0 ? -1.0 : (first + last) / 2.0, first < 0 ? 0 : last - first + 1);
    }
    pclose(p);
    return index ? 0 : 1;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc < 2) { fprintf(stderr, "usage: see the top of compositor-check.m\n"); return 2; }
        g_t0 = axr_now_ns();
        setvbuf(stdout, NULL, _IOLBF, 0);
        const char *mode = argv[1];
        if (!strcmp(mode, "compare") && argc > 3) return run_compare(argv[2], argv[3], argc > 5 ? argv[4] : NULL, argc > 5 ? argv[5] : NULL);
        if (!strcmp(mode, "stripe") && argc > 2) return run_stripe(argv[2]);
        if (!getenv("ALVRXR_CONFIG_DIR") || !getenv("ALVRXR_DUMP")) { fprintf(stderr, "set ALVRXR_CONFIG_DIR (scratch) and ALVRXR_DUMP\n"); return 2; }
        axr_backend_start();
        setup_metal();
        usleep(300000);   // the encoder is made at start; let the event thread settle
        int n = argc > 2 ? atoi(argv[2]) : 90;
        int r;
        if (!strcmp(mode, "server")) r = run_server(n);
        else if (!strcmp(mode, "legacy")) r = run_legacy(n);
        else if (!strcmp(mode, "handover")) r = run_handover(argc > 2 && !strcmp(argv[2], "--watchdog"));
        else if (!strcmp(mode, "reproject")) r = run_reproject();
        else { fprintf(stderr, "unknown mode %s\n", mode); return 2; }
        usleep(300000);   // the last encodes
        return r;
    }
}
