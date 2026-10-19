// Tracking, timing and input shared through axr_shm_global (axr_shm.h). The compositor's ALVR
// event thread publishes (server.m); every runtime reads (tracking.m) through the functions
// declared in alvrxr.h, unchanged for runtime.m:
//   axr_wait_frame, axr_device_motion, axr_hand_joints, axr_current_views, axr_aim_offset,
//   axr_input, axr_input_generation, axr_recenter_generation, axr_refresh_hz,
//   axr_recommended_eye_size, axr_backend_connected, axr_backend_tracking, axr_fake_tracking.
// Their behaviour must match backend.m at tag known-good-2026-10-19 (see docs/compositor.md).
#pragma once
#include "axr_shm.h"

// ------------------------------------------------------------------------------ reader side

// Points the reader at a mapped global region: the compositor's own in vapord, or the one a
// runtime got from the compositor. Call before any reader function; can be called again (after
// a reconnect) with a new mapping. NULL detaches: readers then answer as with no headset.
void axr_tracking_attach(const axr_shm_global *g);

// Per-session frame timing state, so two sessions in one process (never in practice) or a
// session after a reconnect start clean. Called at xrCreateSession.
void axr_tracking_reset_session(void);

// The ALVR sample ts a frame for this display time was tied to by axr_wait_frame (0 if none);
// what client_ts_for() did in backend.m.
uint64_t axr_client_ts_for(int64_t display_time);

// ------------------------------------------------------------------------------ writer side
// Only the compositor's ALVR event thread calls these (server.m).

// Creates the global region (shm_open + shm_unlink, so only fds keep it); returns the writable
// mapping and its fd, which axr_shm_readonly_fd() reopens read-only for handing to clients.
axr_shm_global *axr_shm_create(int *fd);
int axr_shm_readonly_fd(int fd);

// Header fields, written under the header seqlock in one go.
void axr_publish_state(void);
// A tracking sample, after undo_alvr_shaping and the velocity fit; wakes axr_wait_frame.
void axr_publish_sample(const axr_shm_sample *s);
