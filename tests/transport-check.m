// transport-check: the compositor transport (client.m, transport.m) and the CLIENT and SERVER
// slots (slots.m) end to end, headless and without launchd. One process plays both sides: the
// server listens on an anonymous NSXPCListener and the client connects to its endpoint, so the
// IOSurfaces, shared event handles and fds still cross a real XPC connection. The compositor is
// tests/compositor-stub.m, which checks every frame's pixels on the CPU and releases it.
//
// Usage (tests/transport-check.sh builds it and sets the scratch config):
//   transport-check client   CLIENT: frames, haptics, focus, heartbeat, config_gen, reconnects, loss
//   transport-check server   SERVER (run with ALVRXR_HOME=1): the lounge as a local source

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <stdarg.h>
#include <stdio.h>
#include <time.h>
#include <unistd.h>

#include "alvrxr.h"
#include "compositor.h"
#include "compositor-stub.h"
#include "tracking.h"
#include "transport.h"

static int g_failures;
#define CHECK(cond, ...)                                                                           \
    do {                                                                                           \
        if (!(cond)) { g_failures++; fprintf(stderr, "FAIL %s:%d: ", __FILE__, __LINE__); fprintf(stderr, __VA_ARGS__); fputc('\n', stderr); } \
    } while (0)

// ------------------------------------------------------------------ what the runtime would provide

void axr_log(const char *fmt, ...) {
    va_list a;
    va_start(a, fmt);
    fprintf(stderr, "  alvrxr: ");
    vfprintf(stderr, fmt, a);
    fputc('\n', stderr);
    va_end(a);
}
int64_t axr_now_ns(void) { return (int64_t)clock_gettime_nsec_np(CLOCK_MONOTONIC); }
uint64_t stub_now_ns(void) { return (uint64_t)axr_now_ns(); }
void axr_recommended_eye_size(uint32_t *w, uint32_t *h) { *w = STUB_EYE_W, *h = STUB_EYE_H; }
void axr_submit(int64_t t, const axr_eye_image eyes[2], id<MTLCommandQueue> q) {
    (void)t, (void)eyes, (void)q;
    fprintf(stderr, "FAIL: axr_submit called outside LEGACY\n");
    exit(1);
}
static _Atomic int g_haptics;
static float g_haptic_args[4];
void axr_haptics(int hand, float d, float f, float a) {
    g_haptic_args[0] = hand, g_haptic_args[1] = d, g_haptic_args[2] = f, g_haptic_args[3] = a;
    g_haptics++;
}
static const axr_shm_global *_Atomic g_attached;
static _Atomic int g_attaches;
void axr_tracking_attach(const axr_shm_global *g) { g_attached = g, g_attaches++; }
uint64_t axr_client_ts_for(int64_t t) { return (uint64_t)t + 7; }
static _Atomic int64_t g_loss_ns;
void axr_session_loss_pending(void) { g_loss_ns = axr_now_ns(); }

// ------------------------------------------------------------------------------------- frames

void stub_expected_colours(uint64_t seq, uint32_t *left, uint32_t *right) {
    uint32_t r = seq & 1 ? 255 : 0, g = seq & 2 ? 255 : 0, b = seq & 4 ? 255 : 0;
    *left = b | g << 8 | r << 16 | 0xffu << 24;
    *right = ((seq * 37) & 0xff) | ((seq * 91) & 0xff) << 8 | 0x80u << 16 | 0xffu << 24;
}

static id<MTLDevice> g_device;
static id<MTLCommandQueue> g_queue;
static axr_slots *g_slots;
static uint64_t g_seq;   // of the slots open now
static id<MTLCommandBuffer> g_last;
static int g_reopens;   // slots re-opened in this phase: frames drawn just before may be lost with the old session

// Opens the slots if needed, as end_frame does; false if it couldn't within 3 s.
static bool ensure_slots(void) {
    if (g_slots && axr_slots_stale(g_slots)) {
        axr_slots_close(g_slots);
        g_slots = NULL;
        g_reopens++;
    }
    for (int64_t until = axr_now_ns() + 3000000000; !g_slots && axr_now_ns() < until; usleep(20000)) {
        g_slots = axr_slots_open(g_device, g_queue);
        g_seq = 0;
    }
    return g_slots != NULL;
}

// A frame: the left eye cleared to one colour, the right eye blitted another, as a game's composition would.
static void draw_frame(void) {
    id<MTLCommandBuffer> cmd = [g_queue commandBuffer];
    uint32_t slot;
    id<MTLTexture> t = axr_slot_begin(g_slots, cmd, &slot);
    uint64_t seq = ++g_seq;
    CHECK(slot == seq % AXR_SLOTS, "slot %u for seq %llu", slot, seq);
    uint32_t left, right;
    stub_expected_colours(seq, &left, &right);
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture = t;
    rp.colorAttachments[0].loadAction = MTLLoadActionClear;
    rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    rp.colorAttachments[0].clearColor = MTLClearColorMake(seq & 1, seq & 2 ? 1 : 0, seq & 4 ? 1 : 0, 1);
    [[cmd renderCommandEncoderWithDescriptor:rp] endEncoding];
    uint32_t w = (uint32_t)t.width / 2, h = (uint32_t)t.height;
    id<MTLBuffer> buf = [g_device newBufferWithLength:w * h * 4 options:MTLResourceStorageModeShared];
    uint32_t *px = buf.contents;
    for (uint32_t i = 0; i < w * h; i++) px[i] = right;
    id<MTLBlitCommandEncoder> blit = [cmd blitCommandEncoder];
    [blit copyFromBuffer:buf sourceOffset:0 sourceBytesPerRow:w * 4 sourceBytesPerImage:w * h * 4 sourceSize:MTLSizeMake(w, h, 1)
               toTexture:t destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(w, 0, 0)];
    [blit endEncoding];
    axr_pose head = {{0, 0, 0, 1}, {0, 1.6f, 0}};
    axr_slot_end(g_slots, cmd, slot, axr_now_ns(), AXR_FRAME_HAS_CONTENT, head);
    [cmd commit];
    g_last = cmd;
}

// n frames at about 90 Hz (or as fast as the slots let them, unpaced), then waits for the stub to
// have taken them all.
static void run_frames_paced(const char *phase, int n, bool paced) {
    g_stub.frames = g_stub.mismatches = 0;
    g_reopens = 0;
    g_stub.latency_sum = g_stub.latency_max = 0;
    int drawn = 0;
    int64_t start = axr_now_ns();
    for (int i = 0; i < n; i++) {
        if (!ensure_slots()) { CHECK(0, "%s: no slots", phase); return; }
        draw_frame();
        drawn++;
        if (paced) usleep(11000);
    }
    for (int64_t until = axr_now_ns() + 2000000000; g_stub.last_seq != g_seq && axr_now_ns() < until;) usleep(1000);
    double secs = (axr_now_ns() - start) / 1e9;
    printf("%-28s %3d drawn, %3llu checked by the compositor, %llu wrong, %d reopen(s), seq up to %llu, "
           "commit->checked %.2f ms avg %.2f ms max, %.0f fps\n",
           phase, drawn, g_stub.frames, g_stub.mismatches, g_reopens, g_stub.last_seq,
           g_stub.frames ? g_stub.latency_sum / 1e6 / g_stub.frames : 0, g_stub.latency_max / 1e6, drawn / secs);
    CHECK(g_stub.frames + AXR_SLOTS * g_reopens >= (uint64_t)drawn && g_stub.mismatches == 0 && g_stub.last_seq == g_seq,
          "%s: %llu of %d frames checked, %llu wrong", phase, g_stub.frames, drawn, g_stub.mismatches);
}

static void run_frames(const char *phase, int n) { run_frames_paced(phase, n, true); }

static bool wait_for(_Atomic int *v, int want, double secs) {
    for (int64_t until = axr_now_ns() + (int64_t)(secs * 1e9); *v < want && axr_now_ns() < until;) usleep(1000);
    return *v >= want;
}

static void check_focus(void) {
    axr_shm_session *r = stub_current_region();
    CHECK(axr_slots_focus(g_slots) == AXR_FOCUS_FOCUSED && axr_slots_should_render(g_slots), "focused at first");
    atomic_store(&r->focus, AXR_FOCUS_VISIBLE);
    atomic_store(&r->should_render, 0);
    CHECK(axr_slots_focus(g_slots) == AXR_FOCUS_VISIBLE && !axr_slots_should_render(g_slots), "focus follows the compositor");
    atomic_store(&r->focus, AXR_FOCUS_FOCUSED);
    atomic_store(&r->should_render, 1);
    int64_t before = axr_now_ns();
    axr_slots_heartbeat(g_slots);
    uint64_t hb = atomic_load(&r->heartbeat_ns);
    CHECK(hb >= (uint64_t)before && hb <= (uint64_t)axr_now_ns(), "heartbeat written");
    printf("focus/should_render/heartbeat through the session region: ok\n");
}

static void check_config_gen(void) {
    int added = g_stub.added, removed = g_stub.removed;
    CHECK(!axr_slots_stale(g_slots), "fresh slots aren't stale");
    stub_bump_config_gen();
    CHECK(axr_slots_stale(g_slots), "config_gen bump makes the slots stale");
    run_frames("after config_gen bump", 30);
    usleep(100000);
    CHECK(g_stub.added == added + 1 && g_stub.removed == removed + 1, "reopened: %d added, %d removed",
          g_stub.added - added, g_stub.removed - removed);
}

static int client(void) {
    NSXPCListener *listener = [NSXPCListener anonymousListener];
    axr_transport_start_listener(listener);
    axr_client_use_endpoint(listener.endpoint);

    int64_t t0 = axr_now_ns();
    axr_mode m = axr_mode_init();
    printf("mode: %d (CLIENT is 2), hello took %.2f ms\n", m, (axr_now_ns() - t0) / 1e6);
    CHECK(m == AXR_MODE_CLIENT, "mode %d", m);
    const axr_shm_global *g = g_attached;
    CHECK(g && g->magic == AXR_SHM_MAGIC && g->eye_w == STUB_EYE_W, "tracking attached to the global region");

    CHECK(ensure_slots(), "openSession");
    uint32_t w, h;
    axr_slots_eye_size(g_slots, &w, &h);
    CHECK(w == STUB_EYE_W && h == STUB_EYE_H, "eye size %ux%u", w, h);
    CHECK(g_stub.last_pid == getpid() && !g_stub.last_local, "source for pid %d local %d", g_stub.last_pid, g_stub.last_local);
    run_frames("client", 180);
    run_frames_paced("client, unpaced", 600, false);

    axr_client_haptics(AXR_RIGHT, 0.1f, 160, 0.5f);
    CHECK(wait_for(&g_haptics, 1, 1) && g_haptic_args[0] == AXR_RIGHT && g_haptic_args[3] == 0.5f, "haptics forwarded");
    printf("haptics forwarded: hand %.0f %.2f s %.0f Hz amplitude %.2f\n", g_haptic_args[0], g_haptic_args[1],
           g_haptic_args[2], g_haptic_args[3]);

    check_focus();
    check_config_gen();

    // vapord's connection drops (as when it restarts): reconnect, re-open, carry on.
    uint32_t gen = axr_client_generation();
    int attaches = g_attaches;
    int64_t t = axr_now_ns();
    axr_transport_test_drop(false);
    run_frames("after the connection drops", 60);
    printf("  reconnected: connection %u -> %u, tracking re-attached %d time(s), phase took %.0f ms\n",
           gen, axr_client_generation(), g_attaches - attaches, (axr_now_ns() - t) / 1e6);
    CHECK(axr_client_generation() == gen + 1, "reconnected once");

    // vapord says it's going (closing): same.
    gen = axr_client_generation();
    atomic_store(&stub_current_region()->closing, 1);
    run_frames("after closing is set", 30);
    CHECK(axr_client_generation() == gen + 1, "reconnected after closing");

    // vapord goes and doesn't come back, while the game's frames wait on releases: they must not
    // hang its queue, and the session is lost after ~2 s.
    g_stub_hold = true;
    for (int i = 0; i < 6; i++) draw_frame();
    usleep(100000);
    CHECK(g_last.status != MTLCommandBufferStatusCompleted, "frames wait for releases while the compositor holds them");
    t = axr_now_ns();
    axr_transport_test_drop(true);
    [g_last waitUntilCompleted];
    printf("vapord gone with frames queued: the queue drained after %.1f ms\n", (axr_now_ns() - t) / 1e6);
    while (!g_loss_ns && axr_now_ns() - t < 5000000000) usleep(10000);
    CHECK(g_loss_ns, "loss pending reported");
    printf("vapord gone for good: LOSS_PENDING after %.2f s\n", (g_loss_ns - t) / 1e9);
    CHECK(axr_slots_stale(g_slots), "stale while disconnected");
    axr_slots_close(g_slots);
    g_slots = NULL;
    CHECK(axr_slots_open(g_device, g_queue) == NULL, "no slots while vapord is gone");

    // A Vulkan session in a CLIENT process.
    axr_mode_force_legacy();
    CHECK(axr_mode_current() == AXR_MODE_LEGACY && g_attached == NULL, "forced LEGACY");
    printf("force_legacy: mode %d, tracking detached\n", axr_mode_current());
    return 0;
}

static int server(void) {
    axr_mode m = axr_mode_init();
    printf("mode: %d (SERVER is 1)\n", m);
    CHECK(m == AXR_MODE_SERVER, "mode %d", m);
    CHECK(ensure_slots(), "local source");
    CHECK(g_stub.last_pid == getpid() && g_stub.last_local, "local source for our pid");
    run_frames("server (lounge)", 180);
    run_frames_paced("server, unpaced", 600, false);
    check_focus();
    check_config_gen();
    int removed = g_stub.removed;
    axr_slots_close(g_slots);
    CHECK(g_stub.removed == removed + 1, "closing the slots removes the source");
    return 0;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc < 2) { fprintf(stderr, "usage: transport-check client|server\n"); return 2; }
        g_device = MTLCreateSystemDefaultDevice();
        g_queue = [g_device newCommandQueue];
        axr_compositor_start();   // the stub's global region
        if (!strcmp(argv[1], "client")) client();
        else server();
        printf("%s: %s\n", argv[1], g_failures ? "FAILED" : "passed");
        return g_failures ? 1 : 0;
    }
}
