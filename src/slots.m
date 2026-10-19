// The runtime side of the compositor's output slots (compositor.h), and the mode that decides
// whose they are. LEGACY: the slots are this process's own, and axr_slot_end hands each frame to
// axr_submit, which encodes it here as before. CLIENT: vapord's, from openSession over XPC
// (client.m). SERVER: vapord's own lounge, a local source of its compositor.

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <IOSurface/IOSurfaceObjC.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <unistd.h>

#include "alvrxr.h"
#include "compositor.h"
#include "tracking.h"
#include "transport.h"

// --------------------------------------------------------------------------------------- modes

bool axr_compositor_flag(void) {
    static bool flag;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *dir = NSProcessInfo.processInfo.environment[@"ALVRXR_CONFIG_DIR"];
        if (!dir.length) dir = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/alvrxr"];
        NSData *d = [NSData dataWithContentsOfFile:[dir stringByAppendingPathComponent:@"tune.json"]];
        NSDictionary *tune = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
        id v = [tune isKindOfClass:NSDictionary.class] ? tune[@"compositor"] : nil;
        flag = [v respondsToSelector:@selector(boolValue)] && [v boolValue];
    });
    return flag;
}

static _Atomic int g_mode = AXR_MODE_LEGACY;

axr_mode axr_mode_init(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        if (!axr_compositor_flag()) return;
        axr_mode m = AXR_MODE_LEGACY;
        if (getenv("ALVRXR_HOME")) m = AXR_MODE_SERVER;
        else if (axr_client_hello(1.5)) m = AXR_MODE_CLIENT;
        else axr_log("compositor: vapord didn't answer, so this game runs the headset itself");
        g_mode = m;
        axr_log("mode: %s", m == AXR_MODE_SERVER ? "server" : m == AXR_MODE_CLIENT ? "client" : "legacy");
    });
    return (axr_mode)g_mode;
}

axr_mode axr_mode_current(void) { return (axr_mode)g_mode; }

void axr_mode_force_legacy(void) {
    if (g_mode != AXR_MODE_CLIENT) return;
    g_mode = AXR_MODE_LEGACY;
    axr_client_shutdown();
    axr_log("mode: legacy after all (a Vulkan session)");
}

// --------------------------------------------------------------------------------------- slots

struct axr_slots {
    axr_mode mode;                      // whose slots: fixed when opened
    id<MTLDevice> device;
    id<MTLCommandQueue> queue;
    uint32_t eye_w, eye_h;
    IOSurface *surfaces[AXR_SLOTS];
    id<MTLTexture> textures[AXR_SLOTS];
    id<MTLSharedEvent> release_event;   // compositor: every frame with seq <= value is let go
    id<MTLSharedEvent> frame_event;     // runtime: frame seq is ready
    axr_shm_session *region;            // vapord's mapping in CLIENT; a local copy in LEGACY
    uint64_t seq;                       // of the frame begun last
    // CLIENT and SERVER
    axr_source *src;                    // SERVER: the lounge's source in our own compositor
    uint32_t config_gen;                // the global region's when opened
    uint32_t generation;                // CLIENT: the connection the session was opened on
};

// ALVRXR_SLOT_TIMING: logs the GPU time of the frames' composition, averaged over 450 frames.
static _Atomic uint64_t g_gpu_ns, g_gpu_frames;

// ------------------------------------------------------------------- CLIENT and SERVER: vapord's

// The global region's config_gen. In SERVER the compositor's own region, mapped once more
// read-only here so the slots need nothing else from it.
static uint32_t config_gen(axr_mode mode) {
    static const axr_shm_global *server_global;
    if (mode == AXR_MODE_CLIENT) return axr_client_config_gen();
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        int fd = axr_compositor_global_fd();
        void *p = fd >= 0 ? mmap(NULL, sizeof(axr_shm_global), PROT_READ, MAP_SHARED, fd, 0) : MAP_FAILED;
        server_global = p == MAP_FAILED ? NULL : p;
    });
    const axr_shm_global *g = server_global;
    if (!g) return 0;
    return axr_read_config_gen(g);
}

static axr_slots *open_remote(id<MTLDevice> device, id<MTLCommandQueue> queue, axr_mode mode) {
    NSArray<IOSurface *> *surfaces = nil;
    MTLSharedEventHandle *frame = nil, *release = nil;
    int fd = -1;
    uint32_t generation = 0;
    axr_source *src = NULL;
    uint32_t gen = config_gen(mode);
    if (mode == AXR_MODE_CLIENT) {
        if (!axr_client_open_session(&surfaces, &frame, &release, &fd, &generation)) return NULL;
    } else {
        src = axr_compositor_add_source(true, getpid());
        if (!src) { axr_log("slots: the compositor has no source for the lounge"); return NULL; }
        surfaces = axr_source_slot_surfaces(src);
        frame = axr_source_frame_event(src);
        release = axr_source_release_event(src);
        fd = axr_source_session_fd(src);   // the source's: not ours to close
    }
    axr_slots *s = calloc(1, sizeof *s);
    s->mode = mode;
    s->device = device;
    s->queue = queue;
    s->src = src;
    s->generation = generation;
    s->config_gen = gen;
    void *region = fd >= 0 ? mmap(NULL, sizeof(axr_shm_session), PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0) : MAP_FAILED;
    if (mode == AXR_MODE_CLIENT && fd >= 0) close(fd);
    s->region = region == MAP_FAILED ? NULL : region;
    if (!s->region || s->region->magic != AXR_SHM_MAGIC || s->region->version != AXR_SHM_VERSION ||
        s->region->size != sizeof(axr_shm_session)) {
        axr_log("slots: the compositor's session region doesn't fit this runtime");
        axr_slots_close(s);
        return NULL;
    }
    IOSurface *first = surfaces.firstObject;
    s->eye_w = (uint32_t)first.width / 2;
    s->eye_h = (uint32_t)first.height;
    for (int i = 0; i < AXR_SLOTS && surfaces.count == AXR_SLOTS; i++) {
        IOSurface *surf = surfaces[i];
        if (surf.width != first.width || surf.height != first.height) break;
        MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm_sRGB
                                                                                     width:s->eye_w * 2
                                                                                    height:s->eye_h
                                                                                 mipmapped:NO];
        d.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
        d.storageMode = MTLStorageModeShared;
        s->surfaces[i] = surf;
        s->textures[i] = [device newTextureWithDescriptor:d iosurface:(__bridge IOSurfaceRef)surf plane:0];
    }
    s->frame_event = frame ? [device newSharedEventWithHandle:frame] : nil;
    s->release_event = release ? [device newSharedEventWithHandle:release] : nil;
    for (int i = 0; i < AXR_SLOTS; i++)
        if (!s->textures[i] || !s->frame_event || !s->release_event) {
            axr_log("slots: can't use the compositor's slots (%lu surfaces)", (unsigned long)surfaces.count);
            axr_slots_close(s);
            return NULL;
        }
    if (mode == AXR_MODE_CLIENT) axr_client_watch_release(s->release_event);
    axr_log("slots: %d of %ux%u from the compositor", AXR_SLOTS, s->eye_w * 2, s->eye_h);
    return s;
}

static void close_remote(axr_slots *s) {
    // Frames already committed may be waiting for releases that will no longer come; let them
    // through, since nobody reads these slots after this.
    if (s->release_event && s->release_event.signaledValue < s->seq) s->release_event.signaledValue = s->seq;
    if (s->mode == AXR_MODE_CLIENT) {
        axr_client_watch_release(nil);
        axr_client_close_session(s->generation);
    } else if (s->src) {
        axr_compositor_remove_source(s->src);
    }
    if (s->region) munmap(s->region, sizeof *s->region);
    s->region = NULL;
}

void axr_slots_heartbeat(axr_slots *s) {
    if (s && s->mode != AXR_MODE_LEGACY) atomic_store(&s->region->heartbeat_ns, (uint64_t)axr_now_ns());
}

// ------------------------------------------------------------------------------- every mode

axr_slots *axr_slots_open(id<MTLDevice> device, id<MTLCommandQueue> queue) {
    axr_mode mode = axr_mode_current();
    if (mode != AXR_MODE_LEGACY) return open_remote(device, queue, mode);
    axr_slots *s = calloc(1, sizeof *s);
    s->device = device;
    s->queue = queue;
    axr_recommended_eye_size(&s->eye_w, &s->eye_h);
    for (int i = 0; i < AXR_SLOTS; i++) {
        s->surfaces[i] = [[IOSurface alloc] initWithProperties:@{
            IOSurfacePropertyKeyWidth : @(s->eye_w * 2),
            IOSurfacePropertyKeyHeight : @(s->eye_h),
            IOSurfacePropertyKeyBytesPerElement : @4,
            IOSurfacePropertyKeyPixelFormat : @((uint32_t)'BGRA'),
        }];
        MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm_sRGB
                                                                                     width:s->eye_w * 2
                                                                                    height:s->eye_h
                                                                                 mipmapped:NO];
        d.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
        d.storageMode = MTLStorageModeShared;
        s->textures[i] = s->surfaces[i] ? [device newTextureWithDescriptor:d iosurface:(__bridge IOSurfaceRef)s->surfaces[i]
                                                                      plane:0]
                                        : nil;
        if (!s->textures[i]) {
            axr_log("slots: no %ux%u IOSurface texture", s->eye_w * 2, s->eye_h);
            axr_slots_close(s);
            return NULL;
        }
    }
    s->release_event = [device newSharedEvent];
    s->frame_event = [device newSharedEvent];
    s->region = calloc(1, sizeof *s->region);
    s->region->magic = AXR_SHM_MAGIC;
    s->region->version = AXR_SHM_VERSION;
    s->region->size = sizeof *s->region;
    atomic_store(&s->region->focus, AXR_FOCUS_FOCUSED);
    atomic_store(&s->region->should_render, 1);
    axr_log("slots: %d of %ux%u", AXR_SLOTS, s->eye_w * 2, s->eye_h);
    return s;
}

void axr_slots_close(axr_slots *s) {
    if (!s) return;
    if (s->mode != AXR_MODE_LEGACY) close_remote(s);
    // Command buffers in flight keep their own references to the textures and events.
    for (int i = 0; i < AXR_SLOTS; i++) s->textures[i] = nil, s->surfaces[i] = nil;
    s->release_event = s->frame_event = nil;
    s->device = nil;
    s->queue = nil;
    if (s->mode == AXR_MODE_LEGACY) free(s->region);
    free(s);
}

bool axr_slots_stale(const axr_slots *s) {
    if (s->mode == AXR_MODE_CLIENT) {
        // vapord is going: reconnect, and open again on the new connection.
        if (atomic_load(&s->region->closing)) {
            axr_client_lost();
            return true;
        }
        if (axr_client_generation() != s->generation) return true;
    }
    if (s->mode != AXR_MODE_LEGACY) return config_gen(s->mode) != s->config_gen;
    uint32_t w, h;
    axr_recommended_eye_size(&w, &h);
    return w != s->eye_w || h != s->eye_h;
}

void axr_slots_eye_size(const axr_slots *s, uint32_t *eye_w, uint32_t *eye_h) {
    *eye_w = s->eye_w;
    *eye_h = s->eye_h;
}

id<MTLTexture> axr_slot_begin(axr_slots *s, id<MTLCommandBuffer> cmd, uint32_t *slot) {
    uint64_t seq = ++s->seq;
    *slot = (uint32_t)(seq % AXR_SLOTS);
    // The slot's previous frame was seq - AXR_SLOTS. In LEGACY this is already true by the time
    // the GPU gets here, since the release is signalled in queue order after that frame's encode;
    // otherwise the compositor signals it once it has let that frame go.
    if (seq > AXR_SLOTS) [cmd encodeWaitForEvent:s->release_event value:seq - AXR_SLOTS];
    // The GPU wait doesn't hold the CPU back, and axr_slot_end is about to reuse frames[seq % RING]:
    // its last frame must have been read (released) first, or a game that runs ahead overwrites
    // descriptors the compositor hasn't seen. Bounded, so a hung vapord can't hang the game; the
    // compositor checks each descriptor's seq anyway.
    if (s->mode != AXR_MODE_LEGACY && seq > AXR_FRAME_RING)
        [s->release_event waitUntilSignaledValue:seq - AXR_FRAME_RING timeoutMS:100];
    return s->textures[*slot];
}

void axr_slot_end(axr_slots *s, id<MTLCommandBuffer> cmd, uint32_t slot, int64_t display_time, uint32_t flags,
                  axr_pose head) {
    uint64_t seq = s->seq;
    axr_frame_desc *f = &s->region->frames[seq % AXR_FRAME_RING];
    *f = (axr_frame_desc){.seq = seq, .slot = slot, .flags = flags, .display_time = display_time, .head = head};
    if (s->mode != AXR_MODE_LEGACY) f->client_ts = axr_client_ts_for(display_time);
    atomic_store_explicit(&s->region->frame_head, seq, memory_order_release);
    [cmd encodeSignalEvent:s->frame_event value:seq];

    static int timing = -1;
    if (timing < 0) timing = getenv("ALVRXR_SLOT_TIMING") != NULL;
    if (timing) {
        [cmd addCompletedHandler:^(id<MTLCommandBuffer> c) {
            uint64_t ns = (uint64_t)((c.GPUEndTime - c.GPUStartTime) * 1e9);
            uint64_t sum = atomic_fetch_add(&g_gpu_ns, ns) + ns, n = atomic_fetch_add(&g_gpu_frames, 1) + 1;
            if (n % 450 == 0) {
                axr_log("slots: composition %.3f ms GPU per frame", (double)sum / n / 1e6);
                atomic_store(&g_gpu_ns, 0);
                atomic_store(&g_gpu_frames, 0);
            }
        }];
    }

    if (s->mode != AXR_MODE_LEGACY) return;   // the compositor takes it from here

    // axr_submit makes its own command buffer on the same queue and the caller commits cmd only
    // after this returns, so cmd takes its place in the queue first.
    [cmd enqueue];
    if (flags & AXR_FRAME_HAS_CONTENT) {
        uint32_t w = s->eye_w, h = s->eye_h;
        id<MTLTexture> t = s->textures[slot];
        axr_eye_image eyes[2] = {{t, 0, 0, 0, (int32_t)w, (int32_t)h}, {t, 0, (int32_t)w, 0, (int32_t)w, (int32_t)h}};
        axr_submit(display_time, eyes, s->queue);
    }
    // Anything axr_submit encoded is ahead of this in the queue, so the slot is free after it.
    id<MTLCommandBuffer> release = [s->queue commandBuffer];
    [release encodeSignalEvent:s->release_event value:seq];
    [release commit];
}

uint32_t axr_slots_focus(const axr_slots *s) { return atomic_load(&s->region->focus); }
bool axr_slots_should_render(const axr_slots *s) { return atomic_load(&s->region->should_render) != 0; }
