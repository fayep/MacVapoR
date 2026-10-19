// The runtime side of the compositor's output slots (compositor.h). Only LEGACY so far: the
// slots are this process's own, and axr_slot_end hands each frame to axr_submit, which encodes
// it here as before. The release and frame events are local, so CLIENT only has to swap them for
// vapord's.

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <IOSurface/IOSurfaceObjC.h>
#include <stdlib.h>

#include "alvrxr.h"
#include "compositor.h"
#include "tracking.h"

// --------------------------------------------------------------------------------------- modes

axr_mode axr_mode_init(void) { return AXR_MODE_LEGACY; }
axr_mode axr_mode_current(void) { return AXR_MODE_LEGACY; }
void axr_mode_force_legacy(void) {}

// --------------------------------------------------------------------------------------- slots

struct axr_slots {
    id<MTLDevice> device;
    id<MTLCommandQueue> queue;
    uint32_t eye_w, eye_h;
    IOSurface *surfaces[AXR_SLOTS];
    id<MTLTexture> textures[AXR_SLOTS];
    id<MTLSharedEvent> release_event;   // compositor: every frame with seq <= value is let go
    id<MTLSharedEvent> frame_event;     // runtime: frame seq is ready
    axr_shm_session *region;            // vapord's mapping in CLIENT; a local copy in LEGACY
    uint64_t seq;                       // of the frame begun last
};

// ALVRXR_SLOT_TIMING: logs the GPU time of the frames' composition, averaged over 450 frames.
static _Atomic uint64_t g_gpu_ns, g_gpu_frames;

axr_slots *axr_slots_open(id<MTLDevice> device, id<MTLCommandQueue> queue) {
    axr_slots *s = calloc(1, sizeof *s);
    s->device = device;
    s->queue = queue;
    axr_stream_eye_size(&s->eye_w, &s->eye_h);
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
    // Command buffers in flight keep their own references to the textures and events.
    for (int i = 0; i < AXR_SLOTS; i++) s->textures[i] = nil, s->surfaces[i] = nil;
    s->release_event = s->frame_event = nil;
    s->device = nil;
    s->queue = nil;
    free(s->region);
    free(s);
}

bool axr_slots_stale(const axr_slots *s) {
    uint32_t w, h;
    axr_stream_eye_size(&w, &h);
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
    // the GPU gets here, since the release is signalled in queue order after that frame's encode.
    if (seq > AXR_SLOTS) [cmd encodeWaitForEvent:s->release_event value:seq - AXR_SLOTS];
    return s->textures[*slot];
}

void axr_slot_end(axr_slots *s, id<MTLCommandBuffer> cmd, uint32_t slot, int64_t display_time, uint32_t flags,
                  axr_pose head) {
    uint64_t seq = s->seq;
    axr_frame_desc *f = &s->region->frames[seq % AXR_FRAME_RING];
    *f = (axr_frame_desc){.seq = seq, .slot = slot, .flags = flags, .display_time = display_time, .head = head};
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
