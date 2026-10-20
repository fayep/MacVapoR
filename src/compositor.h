// The compositor: vapord owns ALVR and the encoder, and blends the frames of its sources (the
// lounge, drawn in-process, and games, drawn in theirs) into the one stream. See
// docs/compositor.md. Runtimes only see the slot API; the rest is vapord's.
#pragma once
#include "axr_shm.h"
#ifdef __OBJC__
#import <Metal/Metal.h>
#import <IOSurface/IOSurfaceObjC.h>
#endif

// How this process takes part, decided once at the first xrGetSystem (axr_mode_init).
typedef enum {
    AXR_MODE_LEGACY = 0,   // today's: own ALVR server in-process, claim/_exit handover
    AXR_MODE_SERVER = 1,   // vapord: owns ALVR and the compositor; its runtime is a local source
    AXR_MODE_CLIENT = 2,   // a game: thin client of vapord's compositor over XPC
} axr_mode;

// LEGACY unless tune.json "compositor": true. With it, vapord (ALVRXR_HOME) is SERVER; anything
// else tries hello() for ~1.5 s and is CLIENT if it succeeds, LEGACY if not. A Vulkan session
// in a CLIENT process falls back by calling axr_mode_force_legacy() before it is created.
axr_mode axr_mode_init(void);
axr_mode axr_mode_current(void);
void axr_mode_force_legacy(void);

#ifdef __OBJC__
// ------------------------------------------------------------------------------ runtime side
// Each session composes every frame (projection + quads) into one of AXR_SLOTS output slots:
// one texture, 2*eye_w x eye_h, MTLPixelFormatBGRA8Unorm_sRGB, left eye in the left half. The
// same calls work in every mode; in LEGACY the slots are local and axr_slot_end encodes as
// axr_submit did.

typedef struct axr_slots axr_slots;

// Opens the slots for a session drawing on queue. Re-open when axr_slots_stale() says so (the
// stream restarted or its eye size changed).
axr_slots *axr_slots_open(id<MTLDevice> device, id<MTLCommandQueue> queue);
void axr_slots_close(axr_slots *s);
bool axr_slots_stale(const axr_slots *s);
void axr_slots_eye_size(const axr_slots *s, uint32_t *eye_w, uint32_t *eye_h);

// Starts a frame: picks the next slot, encodes into cmd a GPU wait until the compositor has
// released it, and returns its texture to render into with cmd.
id<MTLTexture> axr_slot_begin(axr_slots *s, id<MTLCommandBuffer> cmd, uint32_t *slot);
// Ends it: writes the frame descriptor and encodes into cmd the signal that hands the slot to
// the compositor. The caller commits cmd afterwards. flags: AXR_FRAME_*.
void axr_slot_end(axr_slots *s, id<MTLCommandBuffer> cmd, uint32_t slot, int64_t display_time,
                  uint32_t flags, axr_pose head);

// The session's focus as the compositor sets it (AXR_FOCUS_*), and whether it wants frames;
// FOCUSED and true in LEGACY.
uint32_t axr_slots_focus(const axr_slots *s);
bool axr_slots_should_render(const axr_slots *s);
// The session region's dashboard and exit_request flags (docs/compositor.md "Dashboard"); 0 in LEGACY.
uint32_t axr_slots_dashboard(const axr_slots *s);
uint32_t axr_slots_exit_request(const axr_slots *s);

// Haptics go to the compositor in CLIENT mode, to ALVR otherwise (axr_haptics does this).

// The compositor went away and didn't come back: the session reports LOSS_PENDING (runtime.m).
void axr_session_loss_pending(void);

// ------------------------------------------------------------------------------ vapord side
// The core (compositor.m, WP4) and the transport (XPC, WP5) meet here.

typedef struct axr_source axr_source;

// Starts the compositor after axr_backend_start: creates the global region and the encode path.
void axr_compositor_start(void);
// The global region's read-only fd, for hello().
int axr_compositor_global_fd(void);

// A new source. local: vapord's own runtime (the lounge). pid: the game process, for audio and
// for exit tracking. Allocates its slots (IOSurfaces), shared events and session region.
axr_source *axr_compositor_add_source(bool local, pid_t pid);
// What openSession hands a client.
NSArray<IOSurface *> *axr_source_slot_surfaces(axr_source *src);
MTLSharedEventHandle *axr_source_frame_event(axr_source *src);     // client signals frame seq
MTLSharedEventHandle *axr_source_release_event(axr_source *src);   // compositor signals release
int axr_source_session_fd(axr_source *src);
// The source has gone (XPC invalidated, process exited, session ended): fade out and free.
void axr_compositor_remove_source(axr_source *src);

// Serves the XPC protocol (axr_ipc.h) on AXR_COMPOSITOR_SERVICE (transport.m). The runtime calls
// it after axr_compositor_start when it is SERVER.
void axr_transport_start(void);

// ---- the dashboard (docs/compositor.md "Dashboard"). The compositor opens and closes it from the
// system button itself; these are what the private functions in alvrxr_ext.h come down to.
// Whether it is open; the foreground game's pid and executable name (0 and "" with none).
bool axr_compositor_dashboard(pid_t *game_pid, char name[64]);
// Whether a game is loading behind the lounge (connected, not yet or no longer drawing steadily),
// and its program name.
bool axr_compositor_loading(char name[64]);
void axr_compositor_close_dashboard(void);
// Sets exit_request on the foreground game's session and fades to the lounge at once; false with no game.
bool axr_compositor_quit_game(void);
// A process's program name: argv[0]'s last path component (a Windows path for a Wine game),
// without ".exe"; the executable's otherwise. "" if the process can't be read.
void axr_process_name(pid_t pid, char out[64]);
// TEST ONLY: opens or closes it as the button would.
void axr_compositor_test_dashboard(bool open);
#endif
