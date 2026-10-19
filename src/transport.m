// vapord's side of the XPC transport (SERVER mode): serves AXRCompositor (axr_ipc.h) on the Mach
// service its launchd agent registers, and turns each game's session into a compositor source.

#import <Foundation/Foundation.h>
#include <unistd.h>

#include "alvrxr.h"
#include "transport.h"

NSXPCInterface *axr_compositor_interface(void) {
    NSXPCInterface *i = [NSXPCInterface interfaceWithProtocol:@protocol(AXRCompositor)];
    SEL hello = @selector(helloWithVersion:reply:), open = @selector(openSessionWithReply:);
    [i setClasses:[NSSet setWithObject:NSFileHandle.class] forSelector:hello argumentIndex:1 ofReply:YES];
    [i setClasses:[NSSet setWithObject:NSError.class] forSelector:hello argumentIndex:2 ofReply:YES];
    [i setClasses:[NSSet setWithObjects:NSArray.class, IOSurface.class, nil] forSelector:open argumentIndex:0 ofReply:YES];
    [i setClasses:[NSSet setWithObject:MTLSharedEventHandle.class] forSelector:open argumentIndex:1 ofReply:YES];
    [i setClasses:[NSSet setWithObject:MTLSharedEventHandle.class] forSelector:open argumentIndex:2 ofReply:YES];
    [i setClasses:[NSSet setWithObject:NSFileHandle.class] forSelector:open argumentIndex:3 ofReply:YES];
    [i setClasses:[NSSet setWithObject:NSError.class] forSelector:open argumentIndex:4 ofReply:YES];
    return i;
}

static NSError *failure(NSString *why) {
    return [NSError errorWithDomain:@"alvrxr.compositor" code:1 userInfo:@{NSLocalizedDescriptionKey : why}];
}

// One per connection: a game, with at most one session at a time.
@interface AXRClient : NSObject <AXRCompositor>
@property pid_t pid;
@end

@implementation AXRClient {
    axr_source *_src;
}

- (void)helloWithVersion:(uint32_t)version
                   reply:(void (^)(uint32_t, NSFileHandle *, NSError *))reply {
    int fd = axr_compositor_global_fd();
    if (version != AXR_IPC_VERSION) reply(AXR_IPC_VERSION, nil, failure(@"another version of the runtime"));
    else if (fd < 0) reply(AXR_IPC_VERSION, nil, failure(@"the compositor isn't running"));
    // The compositor keeps its fd; XPC sends a copy.
    else reply(AXR_IPC_VERSION, [[NSFileHandle alloc] initWithFileDescriptor:fd closeOnDealloc:NO], nil);
}

- (void)openSessionWithReply:(void (^)(NSArray<IOSurface *> *, MTLSharedEventHandle *, MTLSharedEventHandle *,
                                       NSFileHandle *, NSError *))reply {
    axr_source *src;
    @synchronized(self) {
        if (_src) axr_compositor_remove_source(_src);
        src = _src = axr_compositor_add_source(false, _pid);
    }
    if (!src) { reply(nil, nil, nil, nil, failure(@"no room for another source")); return; }
    axr_log("compositor: session for pid %d", _pid);
    reply(axr_source_slot_surfaces(src), axr_source_frame_event(src), axr_source_release_event(src),
          [[NSFileHandle alloc] initWithFileDescriptor:axr_source_session_fd(src) closeOnDealloc:NO], nil);
}

- (void)closeSession {
    @synchronized(self) {
        if (!_src) return;
        axr_compositor_remove_source(_src);
        _src = NULL;
    }
    axr_log("compositor: pid %d's session ended", _pid);
}

- (void)hapticsForHand:(int32_t)hand duration:(float)seconds frequency:(float)hz amplitude:(float)amplitude {
    axr_haptics(hand, seconds, hz, amplitude);
}
@end

static NSHashTable<NSXPCConnection *> *g_connections;   // TEST ONLY use: axr_transport_test_drop
static bool g_refuse;

@interface AXRListener : NSObject <NSXPCListenerDelegate>
@end

@implementation AXRListener
- (BOOL)listener:(NSXPCListener *)listener shouldAcceptNewConnection:(NSXPCConnection *)c {
    (void)listener;
    if (g_refuse) return NO;
    AXRClient *client = [AXRClient new];
    client.pid = c.processIdentifier;
    c.exportedInterface = axr_compositor_interface();
    c.exportedObject = client;
    // A game that crashes or quits without xrDestroySession ends its session here.
    c.interruptionHandler = ^{ [client closeSession]; };
    c.invalidationHandler = ^{ [client closeSession]; };
    @synchronized(g_connections) { [g_connections addObject:c]; }
    [c resume];
    return YES;
}
@end

static NSXPCListener *g_listener;
static AXRListener *g_delegate;

void axr_transport_start_listener(NSXPCListener *listener) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        g_connections = [NSHashTable weakObjectsHashTable];
        g_delegate = [AXRListener new];
        g_listener = listener;
        g_listener.delegate = g_delegate;
        [g_listener resume];
    });
}

void axr_transport_start(void) {
    const char *name = getenv("ALVRXR_COMPOSITOR_SERVICE");
    NSString *service = @(name && *name ? name : AXR_COMPOSITOR_SERVICE);
    axr_transport_start_listener([[NSXPCListener alloc] initWithMachServiceName:service]);
    axr_log("compositor: serving %s", service.UTF8String);
}

// TEST ONLY: drops every connection, as if vapord had gone, and refuses new ones while refuse.
void axr_transport_test_drop(bool refuse) {
    g_refuse = refuse;
    NSArray *all;
    @synchronized(g_connections) { all = g_connections.allObjects; }
    for (NSXPCConnection *c in all) [c invalidate];
}
