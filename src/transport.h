// The XPC transport between a game's runtime (client.m) and vapord's compositor (transport.m),
// and what the slots and the runtime need from it. Internal to the runtime: compositor.h and
// axr_ipc.h are the contract, this is plumbing.
#pragma once
#include "axr_shm.h"
#include "compositor.h"
#ifdef __OBJC__
#import "axr_ipc.h"
#endif

// tune.json "compositor": true in the config dir (ALVRXR_CONFIG_DIR, else
// ~/Library/Application Support/alvrxr). Cheap: read once.
bool axr_compositor_flag(void);

// The region's config_gen.
static inline uint32_t axr_read_config_gen(const axr_shm_global *g) {
    _Atomic uint32_t *seq = (_Atomic uint32_t *)&g->seq;
    uint32_t begin, gen;
    do {
        begin = axr_seq_read_begin(seq);
        gen = g->config_gen;
    } while (!axr_seq_read_ok(seq, begin));
    return gen;
}

// ------------------------------------------------------------------------------ client (games)

// Connects to vapord and maps its global region; false if it didn't answer within timeout_s or
// speaks another version. On success the tracking readers are attached to the region.
bool axr_client_hello(double timeout_s);
// Drops the connection for good (a Vulkan session falling back to LEGACY).
void axr_client_shutdown(void);
// Bumps on every successful hello, so slots opened on an older connection know they're stale.
uint32_t axr_client_generation(void);
// The global region's config_gen (0 when not connected).
uint32_t axr_client_config_gen(void);
// vapord is gone or going (closing set, connection lost): reconnect in the background, or
// report XR_SESSION_STATE_LOSS_PENDING after 2 s. Idempotent.
void axr_client_lost(void);
void axr_client_haptics(int hand, float duration_s, float frequency, float amplitude);

#ifdef __OBJC__
// openSession, synchronously (off the render thread's hot path: once per session). Fails at once
// while not connected.
bool axr_client_open_session(NSArray<IOSurface *> **slots, MTLSharedEventHandle **frame_event,
                             MTLSharedEventHandle **release_event, int *session_fd, uint32_t *generation);
// closeSession, if the session is from the current connection.
void axr_client_close_session(uint32_t generation);
// The release event of the open session, which the client signals itself when vapord goes away
// so frames waiting on it don't hang the game's queue. nil to forget it.
void axr_client_watch_release(id<MTLSharedEvent> release_event);

// The protocol with the classes its replies carry, for both ends.
NSXPCInterface *axr_compositor_interface(void);

// TEST ONLY: talk to this endpoint (an anonymous listener in the same process) instead of the
// Mach service, so the transport can be exercised without launchd.
void axr_client_use_endpoint(NSXPCListenerEndpoint *endpoint);
// TEST ONLY: serve on this listener instead of the Mach service.
void axr_transport_start_listener(NSXPCListener *listener);
// TEST ONLY: drops every client connection, as if vapord had gone, and refuses new ones while
// refuse is set.
void axr_transport_test_drop(bool refuse);
#endif

// Called once per xrWaitFrame: the session's heartbeat for the compositor (CLIENT and SERVER).
typedef struct axr_slots axr_slots;
void axr_slots_heartbeat(axr_slots *s);
