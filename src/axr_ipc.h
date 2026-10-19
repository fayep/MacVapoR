// The XPC protocol between a game's runtime and vapord's compositor, over the Mach service
// AXR_COMPOSITOR_SERVICE (registered by vapord's launchd agent). Setup only: every frame goes
// through shared memory and shared events (docs/compositor.md).
#pragma once
#import <Foundation/Foundation.h>
#import <IOSurface/IOSurfaceObjC.h>
#import <Metal/Metal.h>

#define AXR_COMPOSITOR_SERVICE "com.zippysoft.macvapor.compositor"
#define AXR_IPC_VERSION 1

NS_ASSUME_NONNULL_BEGIN

// What vapord exports.
@protocol AXRCompositor
// First call. The reply's region is axr_shm_global, read-only. version must equal
// AXR_IPC_VERSION on both sides or the client falls back to LEGACY.
- (void)helloWithVersion:(uint32_t)version
                   reply:(void (^)(uint32_t version, NSFileHandle *_Nullable global, NSError *_Nullable error))reply;
// A session drawing Metal frames. Slots are AXR_SLOTS IOSurfaces, 'BGRA', 2*eye_w x eye_h
// (eye size from the global region). frameEvent: the client signals each frame's seq on it;
// releaseEvent: vapord signals a slot's last seq when it may be reused. session: axr_shm_session,
// read-write.
- (void)openSessionWithReply:(void (^)(NSArray<IOSurface *> *_Nullable slots,
                                       MTLSharedEventHandle *_Nullable frameEvent,
                                       MTLSharedEventHandle *_Nullable releaseEvent,
                                       NSFileHandle *_Nullable session, NSError *_Nullable error))reply;
// The session ended (xrDestroySession / xrRequestExitSession); vapord fades back to the lounge.
- (void)closeSession;
- (void)hapticsForHand:(int32_t)hand duration:(float)seconds frequency:(float)hz amplitude:(float)amplitude;
@end

NS_ASSUME_NONNULL_END
