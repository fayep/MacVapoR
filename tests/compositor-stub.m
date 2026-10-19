// TEST ONLY: a stand-in for vapord's compositor core (compositor.m, WP4), for
// tests/transport-check.m. It implements the vapord side of compositor.h just enough to exercise
// the transport and the slots: sources get real IOSurfaces, shared events and session regions;
// each frame is taken when its frameEvent fires, its descriptor read, the slot's pixels checked
// on the CPU (IOSurfaceLock) and the frame released at once. Never linked into the runtime.

#import <Foundation/Foundation.h>
#import <IOSurface/IOSurfaceObjC.h>
#import <Metal/Metal.h>
#include <fcntl.h>
#include <stdio.h>
#include <sys/mman.h>
#include <unistd.h>

#include "compositor.h"
#include "compositor-stub.h"

static id<MTLDevice> g_device;
static axr_shm_global *g_global;
static int g_global_ro = -1;
static MTLSharedEventListener *g_listener;
static dispatch_queue_t g_queue;
static NSMutableArray *g_sources;
stub_stats g_stub;
_Atomic bool g_stub_hold;

// A writable fd for a fresh shm region of size, already unlinked; *ro gets a read-only one.
static int shm_region(size_t size, int *ro) {
    char name[64];
    static int n;
    snprintf(name, sizeof name, "/axr-stub-%d-%d", getpid(), n++);
    int fd = shm_open(name, O_RDWR | O_CREAT | O_EXCL, 0600);
    if (fd < 0) { perror("shm_open"); exit(1); }
    if (ro) *ro = shm_open(name, O_RDONLY);
    shm_unlink(name);
    if (ftruncate(fd, (off_t)size) != 0) { perror("ftruncate"); exit(1); }
    return fd;
}

void axr_compositor_start(void) {
    if (g_global) return;
    g_device = MTLCreateSystemDefaultDevice();
    g_queue = dispatch_queue_create("stub.frames", DISPATCH_QUEUE_SERIAL);
    g_listener = [[MTLSharedEventListener alloc] initWithDispatchQueue:g_queue];
    g_sources = [NSMutableArray array];
    int fd = shm_region(sizeof(axr_shm_global), &g_global_ro);
    g_global = mmap(NULL, sizeof *g_global, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    close(fd);
    g_global->magic = AXR_SHM_MAGIC;
    g_global->version = AXR_SHM_VERSION;
    g_global->size = sizeof *g_global;
    axr_seq_write_begin(&g_global->seq);
    g_global->eye_w = STUB_EYE_W;
    g_global->eye_h = STUB_EYE_H;
    g_global->refresh_hz = 90;
    g_global->config_gen = 1;
    axr_seq_write_end(&g_global->seq);
}

int axr_compositor_global_fd(void) { return g_global_ro; }

void stub_bump_config_gen(void) {
    axr_seq_write_begin(&g_global->seq);
    g_global->config_gen++;
    axr_seq_write_end(&g_global->seq);
}

@interface StubSource : NSObject {
@public
    bool local, removed;
    pid_t pid;
    NSArray<IOSurface *> *surfaces;
    id<MTLSharedEvent> frame, release;
    int session_fd;
    axr_shm_session *region;
    uint64_t next;
}
@end
@implementation StubSource
@end

static StubSource *g_current;

axr_shm_session *stub_current_region(void) { return g_current ? g_current->region : NULL; }

static void take_frames(StubSource *s, uint64_t upto) {
    for (; s->next <= upto; s->next++) {
        uint64_t seq = s->next;
        uint64_t head = atomic_load_explicit(&s->region->frame_head, memory_order_acquire);
        axr_frame_desc f = s->region->frames[seq % AXR_FRAME_RING];
        int64_t latency = (int64_t)stub_now_ns() - f.display_time;
        bool ok = head >= seq && f.seq == seq && f.slot == seq % AXR_SLOTS && (f.flags & AXR_FRAME_HAS_CONTENT) &&
                  f.client_ts == (uint64_t)f.display_time + 7;
        IOSurface *surf = f.slot < AXR_SLOTS ? s->surfaces[f.slot] : nil;
        uint32_t left = 0, right = 0;
        if (surf) {
            [surf lockWithOptions:kIOSurfaceLockReadOnly seed:NULL];
            const uint8_t *base = surf.baseAddress;
            size_t row = surf.bytesPerRow, w = surf.width / 2, h = surf.height;
            memcpy(&left, base + (h / 2) * row + (w / 2) * 4, 4);
            memcpy(&right, base + (h / 2) * row + (w + w / 2) * 4, 4);
            [surf unlockWithOptions:kIOSurfaceLockReadOnly seed:NULL];
        }
        uint32_t want_left, want_right;
        stub_expected_colours(seq, &want_left, &want_right);
        if (!ok || left != want_left || right != want_right) {
            g_stub.mismatches++;
            if (g_stub.mismatches <= 5)
                fprintf(stderr, "stub: frame %llu: desc ok %d (seq %llu slot %u flags %u head %llu), left %08x want %08x, right %08x want %08x\n",
                        seq, ok, f.seq, f.slot, f.flags, head, left, want_left, right, want_right);
        }
        g_stub.frames++;
        g_stub.last_seq = seq;
        g_stub.latency_sum += latency;
        if (latency > g_stub.latency_max) g_stub.latency_max = latency;
        // Let it go at once: the slot can be drawn again.
        s->release.signaledValue = seq;
    }
}

static void listen(StubSource *s) {
    __weak StubSource *weak = s;
    [s->frame notifyListener:g_listener atValue:s->next block:^(id<MTLSharedEvent> e, uint64_t value) {
        (void)value;
        StubSource *src = weak;
        if (!src || src->removed) return;
        if (g_stub_hold) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 10000000), g_queue, ^{ listen(src); });
            return;
        }
        take_frames(src, e.signaledValue);
        listen(src);
    }];
}

axr_source *axr_compositor_add_source(bool local, pid_t pid) {
    StubSource *s = [StubSource new];
    s->local = local;
    s->pid = pid;
    NSMutableArray *surfaces = [NSMutableArray array];
    for (int i = 0; i < AXR_SLOTS; i++)
        [surfaces addObject:[[IOSurface alloc] initWithProperties:@{
                      IOSurfacePropertyKeyWidth : @(STUB_EYE_W * 2),
                      IOSurfacePropertyKeyHeight : @(STUB_EYE_H),
                      IOSurfacePropertyKeyBytesPerElement : @4,
                      IOSurfacePropertyKeyPixelFormat : @((uint32_t)'BGRA'),
                  }]];
    s->surfaces = surfaces;
    s->frame = [g_device newSharedEvent];
    s->release = [g_device newSharedEvent];
    s->session_fd = shm_region(sizeof(axr_shm_session), NULL);
    s->region = mmap(NULL, sizeof *s->region, PROT_READ | PROT_WRITE, MAP_SHARED, s->session_fd, 0);
    s->region->magic = AXR_SHM_MAGIC;
    s->region->version = AXR_SHM_VERSION;
    s->region->size = sizeof *s->region;
    atomic_store(&s->region->focus, AXR_FOCUS_FOCUSED);
    atomic_store(&s->region->should_render, 1);
    s->next = 1;
    @synchronized(g_sources) { [g_sources addObject:s]; }
    g_current = s;
    g_stub.added++;
    g_stub.last_pid = pid;
    g_stub.last_local = local;
    listen(s);
    return (__bridge axr_source *)s;
}

NSArray<IOSurface *> *axr_source_slot_surfaces(axr_source *src) { return ((__bridge StubSource *)src)->surfaces; }
MTLSharedEventHandle *axr_source_frame_event(axr_source *src) { return [((__bridge StubSource *)src)->frame newSharedEventHandle]; }
MTLSharedEventHandle *axr_source_release_event(axr_source *src) { return [((__bridge StubSource *)src)->release newSharedEventHandle]; }
int axr_source_session_fd(axr_source *src) { return ((__bridge StubSource *)src)->session_fd; }

void axr_compositor_remove_source(axr_source *src) {
    StubSource *s = (__bridge StubSource *)src;
    s->removed = true;
    g_stub.removed++;
    // The region stays mapped (and the fd open): the stub never reuses them, and the runtime may
    // still hold its own mapping.
    @synchronized(g_sources) { [g_sources removeObject:s]; }
}
