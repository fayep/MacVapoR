// A game's side of the XPC transport to vapord's compositor (CLIENT mode): hello, openSession,
// closeSession and haptics, and getting back to vapord when it goes away. Frames never pass
// through here; they go through the slots (slots.m).

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <pthread.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

#include "alvrxr.h"
#include "tracking.h"
#include "transport.h"

static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;
static NSXPCConnection *g_conn;          // nil while not connected
static const axr_shm_global *g_global;   // the current connection's region
static _Atomic uint32_t g_generation;
static bool g_reconnecting, g_shutdown;
static id<MTLSharedEvent> g_release;
static NSXPCListenerEndpoint *g_test_endpoint;

void axr_client_use_endpoint(NSXPCListenerEndpoint *endpoint) { g_test_endpoint = endpoint; }

static void connection_gone(NSXPCConnection *c);

static NSXPCConnection *new_connection(void) {
    NSXPCConnection *c;
    if (g_test_endpoint) {
        c = [[NSXPCConnection alloc] initWithListenerEndpoint:g_test_endpoint];
    } else {
        const char *name = getenv("ALVRXR_COMPOSITOR_SERVICE");
        c = [[NSXPCConnection alloc] initWithMachServiceName:@(name && *name ? name : AXR_COMPOSITOR_SERVICE) options:0];
    }
    c.remoteObjectInterface = axr_compositor_interface();
    __weak NSXPCConnection *weak = c;
    c.interruptionHandler = ^{ connection_gone(weak); };
    c.invalidationHandler = ^{ connection_gone(weak); };
    [c resume];
    return c;
}

// A reply that may come after we stopped waiting for it.
@interface AXRReply : NSObject
@property bool abandoned, done;
@property int fd;
@property NSArray *objects;
@end
@implementation AXRReply
@end

static bool wait_reply(AXRReply *r, dispatch_semaphore_t sem, double timeout_s) {
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout_s * 1e9)));
    @synchronized(r) {
        r.abandoned = true;
        if (!r.done && r.fd >= 0) close(r.fd), r.fd = -1;
        return r.done;
    }
}

// Calls hello on c and maps the region it hands back; NULL if it didn't within timeout_s.
static const axr_shm_global *hello_on(NSXPCConnection *c, double timeout_s) {
    AXRReply *r = [AXRReply new];
    r.fd = -1;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    id<AXRCompositor> proxy = [c remoteObjectProxyWithErrorHandler:^(NSError *e) { (void)e; dispatch_semaphore_signal(sem); }];
    [proxy helloWithVersion:AXR_IPC_VERSION reply:^(uint32_t version, NSFileHandle *global, NSError *error) {
        @synchronized(r) {
            if (r.abandoned) return;
            if (version != AXR_IPC_VERSION || !global || error) {
                axr_log("compositor: hello refused (version %u, ours %u)%s%s", version, AXR_IPC_VERSION,
                        error ? ": " : "", error ? error.localizedDescription.UTF8String : "");
            } else {
                r.fd = dup(global.fileDescriptor);
                r.done = r.fd >= 0;
            }
        }
        dispatch_semaphore_signal(sem);
    }];
    if (!wait_reply(r, sem, timeout_s)) return NULL;
    struct stat st;
    void *p = MAP_FAILED;
    if (fstat(r.fd, &st) == 0 && st.st_size >= (off_t)sizeof(axr_shm_global))
        p = mmap(NULL, sizeof(axr_shm_global), PROT_READ, MAP_SHARED, r.fd, 0);
    close(r.fd);
    const axr_shm_global *g = p == MAP_FAILED ? NULL : p;
    if (g && (g->magic != AXR_SHM_MAGIC || g->version != AXR_SHM_VERSION || g->size != sizeof *g)) {
        axr_log("compositor: vapord's region doesn't fit this runtime");
        munmap(p, sizeof *g);
        g = NULL;
    }
    return g;
}

// Makes c the connection. Earlier regions stay mapped: a tracking reader may still be in one.
static void connected(NSXPCConnection *c, const axr_shm_global *g) {
    pthread_mutex_lock(&g_lock);
    g_conn = c;
    g_global = g;
    uint32_t gen = ++g_generation;
    pthread_mutex_unlock(&g_lock);
    axr_tracking_attach(g);
    axr_log("compositor: connected to vapord (connection %u)", gen);
}

bool axr_client_hello(double timeout_s) {
    NSXPCConnection *c = new_connection();
    const axr_shm_global *g = hello_on(c, timeout_s);
    if (!g) { [c invalidate]; return false; }
    connected(c, g);
    return true;
}

void axr_client_shutdown(void) {
    pthread_mutex_lock(&g_lock);
    g_shutdown = true;
    NSXPCConnection *c = g_conn;
    g_conn = nil;
    pthread_mutex_unlock(&g_lock);
    [c invalidate];
    axr_tracking_attach(NULL);
}

uint32_t axr_client_generation(void) { return g_generation; }

uint32_t axr_client_config_gen(void) {
    pthread_mutex_lock(&g_lock);
    const axr_shm_global *g = g_conn ? g_global : NULL;
    pthread_mutex_unlock(&g_lock);
    if (!g) return 0;
    return axr_read_config_gen(g);
}

static void connection_gone(NSXPCConnection *c) {
    pthread_mutex_lock(&g_lock);
    bool current = c && c == g_conn;
    pthread_mutex_unlock(&g_lock);
    if (current) axr_client_lost();
}

void axr_client_lost(void) {
    pthread_mutex_lock(&g_lock);
    if (g_shutdown || g_reconnecting) { pthread_mutex_unlock(&g_lock); return; }
    g_reconnecting = true;
    NSXPCConnection *old = g_conn;
    g_conn = nil;
    id<MTLSharedEvent> release = g_release;
    pthread_mutex_unlock(&g_lock);
    [old invalidate];
    // Frames queued behind a release vapord will never signal would hang the game's queue.
    if (release) release.signaledValue = 1ull << 62;
    axr_log("compositor: lost vapord, trying to get it back");
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        // launchd restarts vapord, and holds our messages until it is listening again.
        int64_t deadline = axr_now_ns() + 2000000000;
        for (int64_t now = axr_now_ns(); now < deadline && !g_shutdown; now = axr_now_ns()) {
            NSXPCConnection *c = new_connection();
            double left = (deadline - now) / 1e9;
            const axr_shm_global *g = hello_on(c, left < 0.25 ? 0.25 : left);
            if (g) {
                connected(c, g);
                pthread_mutex_lock(&g_lock);
                g_reconnecting = false;
                pthread_mutex_unlock(&g_lock);
                return;
            }
            [c invalidate];
            usleep(200000);
        }
        pthread_mutex_lock(&g_lock);
        g_reconnecting = false;
        pthread_mutex_unlock(&g_lock);
        if (g_shutdown) return;
        axr_log("compositor: vapord didn't come back");
        axr_session_loss_pending();
    });
}

bool axr_client_open_session(NSArray<IOSurface *> **slots, MTLSharedEventHandle **frame_event,
                             MTLSharedEventHandle **release_event, int *session_fd, uint32_t *generation) {
    pthread_mutex_lock(&g_lock);
    NSXPCConnection *c = g_conn;
    uint32_t gen = g_generation;
    pthread_mutex_unlock(&g_lock);
    if (!c) { axr_client_lost(); return false; }   // no-op while a reconnect is under way
    AXRReply *r = [AXRReply new];
    r.fd = -1;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    id<AXRCompositor> proxy = [c remoteObjectProxyWithErrorHandler:^(NSError *e) { (void)e; dispatch_semaphore_signal(sem); }];
    [proxy openSessionWithReply:^(NSArray<IOSurface *> *s, MTLSharedEventHandle *f, MTLSharedEventHandle *rel,
                                  NSFileHandle *session, NSError *error) {
        @synchronized(r) {
            if (r.abandoned) return;
            if (error || s.count != AXR_SLOTS || !f || !rel || !session) {
                axr_log("compositor: openSession failed%s%s", error ? ": " : "", error ? error.localizedDescription.UTF8String : "");
            } else {
                r.fd = dup(session.fileDescriptor);
                r.objects = @[ s, f, rel ];
                r.done = r.fd >= 0;
            }
        }
        dispatch_semaphore_signal(sem);
    }];
    if (!wait_reply(r, sem, 2.0)) return false;
    *slots = r.objects[0];
    *frame_event = r.objects[1];
    *release_event = r.objects[2];
    *session_fd = r.fd;
    *generation = gen;
    return true;
}

void axr_client_close_session(uint32_t generation) {
    pthread_mutex_lock(&g_lock);
    NSXPCConnection *c = generation == g_generation ? g_conn : nil;
    pthread_mutex_unlock(&g_lock);
    [[c remoteObjectProxyWithErrorHandler:^(NSError *e) { (void)e; }] closeSession];
}

void axr_client_watch_release(id<MTLSharedEvent> release_event) {
    pthread_mutex_lock(&g_lock);
    g_release = release_event;
    pthread_mutex_unlock(&g_lock);
}

void axr_client_haptics(int hand, float duration_s, float frequency, float amplitude) {
    pthread_mutex_lock(&g_lock);
    NSXPCConnection *c = g_conn;
    pthread_mutex_unlock(&g_lock);
    [[c remoteObjectProxyWithErrorHandler:^(NSError *e) { (void)e; }] hapticsForHand:hand duration:duration_s
                                                                             frequency:frequency amplitude:amplitude];
}
