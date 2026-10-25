// alvrxr: an OpenXR runtime for macOS that displays through ALVR's server_core, so the ALVR
// visionOS client shows the frames and supplies head, controller and button input.
//
// runtime.m is the OpenXR surface; server.m owns ALVR, the compositor and the encoder, and
// publishes tracking and input into shared memory, which tracking.m reads.
#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __OBJC__
#import <Metal/Metal.h>
#endif

// Devices, in the order ALVR's /user/head, /user/hand/left, /user/hand/right.
enum { AXR_HEAD = 0, AXR_LEFT = 1, AXR_RIGHT = 2, AXR_DEVICE_COUNT = 3 };

typedef struct {
    float orientation[4];      // x, y, z, w
    float position[3];
} axr_pose;

typedef struct {
    axr_pose pose;
    float linear_velocity[3];
    float angular_velocity[3];
    bool valid;
} axr_motion;

typedef struct {
    axr_pose eye_in_head[2];   // left, right
    float fov[2][4];           // left, right, up, down (radians, left/down negative)
} axr_views;

void axr_log(const char *fmt, ...) __attribute__((format(printf, 1, 2)));

int64_t axr_now_ns(void);              // XrTime: CLOCK_MONOTONIC nanoseconds

// Starts ALVR (idempotent). The runtime works with no headset connected: frames are composed
// and dropped, and poses fall back to a standing default.
void axr_backend_start(void);

// The game's audio, tapped by MacVapoR Audio and handed to ALVR (audio.m).
bool axr_audio_available(void);
void axr_audio_start(void);
void axr_audio_stats(uint64_t *frames, float *peak);   // since the last call, over all sources
// The mixer: each source is a process MacVapoR Audio taps into a ring of its own, mixed into the
// one stream ALVR sends. A source starts at gain 1, or at the first gain set before it plays; the
// mixer moves smoothly to a new gain (linear amplitude, 0..1) within 15 ms. Removing fades it out
// first. Any thread. axr_audio_start is axr_audio_add_source(getpid()).
#include <sys/types.h>
typedef struct axr_audio_source axr_audio_source;
axr_audio_source *axr_audio_add_source(pid_t pid);   // NULL if there's no helper or no room
void axr_audio_set_gain(axr_audio_source *src, float gain);
void axr_audio_remove_source(axr_audio_source *src);   // src is gone after this
axr_audio_source *axr_audio_local_source(void);        // the one axr_audio_start added (NULL if none)
bool axr_backend_connected(void);
bool axr_fake_tracking(void);       // tune.json fake_tpose, with no client: report the head as tracked
// The aim pose in the controller's (grip) frame: tune.json "aim_yaw", "aim_pitch" and "aim_roll"
// degrees about its Y, X and Z axes (pitch -45 unless set), and "aim_offset" [x, y, z] metres; the
// left hand mirrors yaw, roll and x.
axr_pose axr_aim_offset(int hand);
bool axr_hand_joints(int hand, int64_t time, axr_pose out[26]);   // see tracking.m
bool axr_backend_tracking(void);     // connected and past the client's placeholder poses
uint32_t axr_recenter_generation(void);   // changes when the user asks to recenter (Digital Crown)
double axr_refresh_hz(void);
void axr_recommended_eye_size(uint32_t *w, uint32_t *h);

// Blocks until the next frame is due and returns its predicted display time. Each frame is
// tied to the newest ALVR tracking sample, so poses and the encoded frame agree on the time.
int64_t axr_wait_frame(void);

// Motion of a device at an XrTime, in ALVR's stage space (floor origin, -Z forward).
axr_motion axr_device_motion(int device, int64_t time);
axr_views axr_current_views(void);

// Current value of an ALVR input path (e.g. "/user/hand/left/input/trigger/value").
bool axr_input(const char *path, float *value);
uint64_t axr_input_generation(void);   // bumps whenever any input changes
void axr_haptics(int hand, float duration_s, float frequency, float amplitude);

#ifdef __OBJC__
id<MTLDevice> axr_metal_device(void);

typedef struct {
    id<MTLTexture> texture;    // 2D or 2D array
    uint32_t slice;
    int32_t x, y, width, height;
} axr_eye_image;

// Composes the two eye images into ALVR's (foveated) stream layout on the app's queue, after
// the app's own rendering, and encodes and sends the result for that frame's display time.
void axr_submit(int64_t display_time, const axr_eye_image eyes[2], id<MTLCommandQueue> queue);

// A 2D texture as a one-slice 2D array view (cached), so shaders can take either.
id<MTLTexture> axr_array_view(id<MTLTexture> t);

// SERVER mode (compositor.m): a source's frame as its descriptor gives it, in its output slot.
typedef struct {
    id<MTLTexture> texture;    // the slot: both eyes, left in the left half
    axr_pose head;             // the head pose it was drawn for
    uint64_t client_ts;
    int64_t display_time;
} axr_compose_frame;
// Blends fg over other (reprojected for the turn between their head poses; none if NULL) at alpha
// (fg's weight) on vapord's own queue, applies FFR and encodes the result for fg's time exactly as
// axr_submit does. done runs when the GPU has finished reading the textures; false (and no done)
// when the frame was dropped: not ready, or 2 already in flight.
bool axr_encode_composite(const axr_compose_frame *fg, const axr_compose_frame *other, float alpha, void (^done)(void));
// The dashboard: fg (the lounge's panel, premultiplied alpha) over under (the game, reprojected to
// fg's head pose) dimmed to dim; otherwise as axr_encode_composite. under may be NULL.
bool axr_encode_overlay(const axr_compose_frame *fg, const axr_compose_frame *under, float dim, void (^done)(void));
#endif
// The dashboard's calls into the server (compositor.m and runtime.m's private functions; SERVER only).
void axr_server_recenter(void);                      // as ALVR_EVENT_PLAYSPACE_SYNC: bumps the recenter generation
void axr_server_set_eye_height(float eye_height);    // seated at eye_height from where the head is now; 0 = standing. Saves height.json
void axr_server_dashboard_stats(float battery[3], uint32_t charging[3], uint32_t joycon[3], float *fps, float *mbps, float *eye_height,
                                float *height_offset);
// The global region's writable fd (-1 before axr_backend_start); axr_shm_readonly_fd takes it.
int axr_shm_global_fd(void);
// The compositor's part of the 5 s stats line, " | compositor: ..." or "" when it isn't running.
void axr_compositor_stats(char *buf, size_t n);
#ifdef __OBJC__
#endif
