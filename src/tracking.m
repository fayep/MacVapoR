// The reader side of axr_shm_global: frame timing, poses, views and input for the runtime, from
// the region the compositor's event thread publishes (server.m). Reads nothing else, so it works
// the same in vapord and in a game's process. Behaviour follows backend.m at tag
// known-good-2026-10-19; the lookups mirror ALVR's TrackingManager (server_core/src/tracking).

#include <math.h>
#include <os/os_sync_wait_on_address.h>
#include <pthread.h>
#include <stdlib.h>
#include <time.h>

#include "alvr_capi.h"
#include <simd/simd.h>

#include "tracking.h"

static _Atomic(const axr_shm_global *) g_shm;

// Frame timing, per session (reset by axr_tracking_reset_session). Frames remember which sample
// they were made for, so poses asked for a display time get that sample.
static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;
enum { FRAME_RING = 32 };
static struct { int64_t xr_time; uint64_t client_ts; } g_frames[FRAME_RING];
static unsigned g_frame_next;
static int64_t g_last_wait, g_last_display;
static uint64_t g_last_frame_ts;
unsigned axr_stat_reused;   // frames that took a sample a frame had already taken; server.m's stats line

void axr_tracking_attach(const axr_shm_global *g) {
    atomic_store_explicit(&g_shm, g, memory_order_release);
}

void axr_tracking_reset_session(void) {
    pthread_mutex_lock(&g_lock);
    memset(g_frames, 0, sizeof g_frames);
    g_frame_next = 0;
    g_last_wait = g_last_display = 0;
    g_last_frame_ts = 0;
    pthread_mutex_unlock(&g_lock);
}

static const axr_shm_global *region(void) { return atomic_load_explicit(&g_shm, memory_order_acquire); }

// ------------------------------------------------------------------------------------ header

// What the readers need from the header, copied out in one seqlock read.
typedef struct {
    bool connected, tracking_real, have_offset, fake_tpose, pose_velocity, height_offset_set;
    uint64_t newest_ts;
    double clock_offset;
    int64_t last_sample_ns;
    double refresh_hz;
    uint32_t eye_w, eye_h, render_w, render_h, recenter_gen;
    axr_views views;
    axr_pose aim[2];
    axr_pose grip[2];
    float height_offset, eye_height;
    uint64_t input_gen;
} header;

// Until the compositor says otherwise: the Vision Pro's view as ALVR reported it in testing, and
// Touch's aim 45 degrees below the grip (server.m publishes the same before a headset connects).
static const axr_views k_default_views = {
    .eye_in_head = {{{0, 0, 0, 1}, {-0.032f, 0, 0}}, {{0, 0, 0, 1}, {0.032f, 0, 0}}},
    .fov = {{-1.06f, 0.80f, 0.88f, -0.80f}, {-0.80f, 1.06f, 0.88f, -0.80f}},
};

static bool read_header(header *h) {
    const axr_shm_global *g = region();
    if (!g) {
        memset(h, 0, sizeof *h);
        h->views = k_default_views;
        float d = (float)M_PI / 360;
        h->aim[0] = h->aim[1] = (axr_pose){{sinf(-45 * d), 0, 0, cosf(-45 * d)}, {0, 0, 0}};
        return false;
    }
    _Atomic uint32_t *seq = (_Atomic uint32_t *)&g->seq;
    uint32_t s;
    do {
        s = axr_seq_read_begin(seq);
        h->connected = g->connected;
        h->tracking_real = g->tracking_real;
        h->have_offset = g->have_offset;
        h->fake_tpose = g->fake_tpose;
        h->pose_velocity = g->pose_velocity;
        h->height_offset_set = g->height_offset_set;
        h->newest_ts = g->newest_ts;
        h->clock_offset = g->clock_offset;
        h->last_sample_ns = g->last_sample_ns;
        h->refresh_hz = g->refresh_hz;
        h->eye_w = g->eye_w;
        h->eye_h = g->eye_h;
        h->render_w = g->render_w;
        h->render_h = g->render_h;
        h->recenter_gen = g->recenter_gen;
        h->views = g->views;
        h->aim[0] = g->aim[0];
        h->aim[1] = g->aim[1];
        h->grip[0] = g->grip[0];
        h->grip[1] = g->grip[1];
        h->height_offset = g->height_offset;
        h->eye_height = g->eye_height;
        h->input_gen = g->input_gen;
    } while (!axr_seq_read_ok(seq, s));
    return true;
}

bool axr_backend_connected(void) {
    header h;
    read_header(&h);
    return h.connected;
}

bool axr_backend_tracking(void) {
    header h;
    read_header(&h);
    return h.connected && h.tracking_real;
}

bool axr_fake_tracking(void) {
    header h;
    read_header(&h);
    return !h.connected && h.fake_tpose;
}

double axr_refresh_hz(void) {
    header h;
    read_header(&h);
    return h.refresh_hz > 0 ? h.refresh_hz : 90;
}

// The size games are asked to render each eye at: openvr_config's target size, else the stream's.
void axr_recommended_eye_size(uint32_t *w, uint32_t *h_) {
    header h;
    read_header(&h);
    *w = h.render_w ?: (h.eye_w ?: 2144);
    *h_ = h.render_h ?: (h.eye_h ?: 2048);
}

void axr_stream_eye_size(uint32_t *w, uint32_t *h_) {
    header h;
    read_header(&h);
    *w = h.eye_w ?: 2144;
    *h_ = h.eye_h ?: 2048;
}

uint32_t axr_recenter_generation(void) {
    header h;
    read_header(&h);
    return h.recenter_gen;
}

axr_views axr_current_views(void) {
    header h;
    read_header(&h);
    return h.views;
}

axr_pose axr_aim_offset(int hand) {
    header h;
    read_header(&h);
    return h.aim[hand == AXR_LEFT ? 0 : 1];
}

uint64_t axr_input_generation(void) {
    header h;
    read_header(&h);
    return h.input_gen;
}

// ------------------------------------------------------------------------------ sample ring

// Copies slot i out; false for an empty one.
static bool read_slot(const axr_shm_global *g, unsigned i, axr_shm_sample *out) {
    _Atomic uint32_t *seq = (_Atomic uint32_t *)&g->samples[i].seq;
    uint32_t s;
    do {
        s = axr_seq_read_begin(seq);
        *out = g->samples[i];
    } while (!axr_seq_read_ok(seq, s));
    return out->ts != 0;
}

// A slot's ts and one of its flags, without copying the rest.
static uint64_t slot_ts(const axr_shm_global *g, unsigned i, size_t flag_offset, bool *flag) {
    _Atomic uint32_t *seq = (_Atomic uint32_t *)&g->samples[i].seq;
    uint32_t s;
    uint64_t ts;
    do {
        s = axr_seq_read_begin(seq);
        ts = g->samples[i].ts;
        *flag = *((const uint8_t *)&g->samples[i] + flag_offset) != 0;
    } while (!axr_seq_read_ok(seq, s));
    return ts;
}

// The sample at ts with flag set, as ALVR's get_device_motion finds it: the exact ts, else the
// one with the smallest later ts. False when there is none. (get_hand_skeleton takes only the
// exact one: exact_only.)
static bool find_sample(uint64_t ts, size_t flag_offset, bool exact_only, axr_shm_sample *out) {
    const axr_shm_global *g = region();
    if (!g || !ts) return false;
    for (int attempt = 0; attempt < 4; attempt++) {
        int best = -1;
        uint64_t best_d = UINT64_MAX;
        for (unsigned i = 0; i < AXR_SAMPLE_RING; i++) {
            bool flag;
            uint64_t t = slot_ts(g, i, flag_offset, &flag);
            if (!t || !flag) continue;
            if (t == ts) { best = (int)i; best_d = 0; break; }
            if (!exact_only && t > ts && t - ts < best_d) { best = (int)i; best_d = t - ts; }
        }
        if (best < 0) return false;
        // The slot may have been reused since the scan; then it held the oldest sample, so look again.
        if (read_slot(g, (unsigned)best, out) && out->ts == ts + best_d) return true;
    }
    return false;
}

// ------------------------------------------------------------------------------ frame timing

uint64_t axr_client_ts_for(int64_t xr_time) {
    uint64_t best = 0;
    int64_t best_d = INT64_MAX;
    pthread_mutex_lock(&g_lock);
    for (int i = 0; i < FRAME_RING; i++) {
        if (!g_frames[i].client_ts) continue;
        int64_t d = llabs(g_frames[i].xr_time - xr_time);
        if (d < best_d) { best_d = d; best = g_frames[i].client_ts; }
    }
    pthread_mutex_unlock(&g_lock);
    return best;
}

// Paced by a steady clock at the headset's refresh rate. Each frame takes the newest tracking
// sample, waiting a little for one if none has come since the last frame's. Starting frames as
// samples arrived instead let Wi-Fi's bunching and gaps set the frame times, which stuttered.
int64_t axr_wait_frame(void) {
    int64_t period = (int64_t)(1e9 / axr_refresh_hz());
    int64_t now = axr_now_ns();
    pthread_mutex_lock(&g_lock);
    int64_t next = g_last_wait + period;
    if (next < now - period) next = now;   // fell behind: start again from now
    g_last_wait = next;
    uint64_t last_frame_ts = g_last_frame_ts;
    pthread_mutex_unlock(&g_lock);
    if (next > now) {
        struct timespec d = {(next - now) / 1000000000, (next - now) % 1000000000};
        nanosleep(&d, NULL);
    }

    const axr_shm_global *g = region();
    header h;
    read_header(&h);
    bool tracking = g && h.connected && h.have_offset && axr_now_ns() - h.last_sample_ns < 100000000;
    if (tracking) {
        int64_t deadline = axr_now_ns() + period / 4;
        for (;;) {
            // The word is read before the header: a sample published between the two makes the
            // wait return at once, so none is missed.
            uint32_t word = atomic_load_explicit(&g->sample_word, memory_order_acquire);
            read_header(&h);
            if (h.newest_ts > last_frame_ts) break;
            int64_t left = deadline - axr_now_ns();
            if (left <= 0) break;
            os_sync_wait_on_address_with_timeout((void *)&g->sample_word, word, 4, OS_SYNC_WAIT_ON_ADDRESS_SHARED,
                                                 OS_CLOCK_MACH_ABSOLUTE_TIME, (uint64_t)left);
        }
    }

    read_header(&h);
    pthread_mutex_lock(&g_lock);
    int64_t display;
    uint64_t ts = 0;
    if (h.connected && h.have_offset && h.newest_ts) {
        ts = h.newest_ts;
        if (ts == g_last_frame_ts) axr_stat_reused++;
        g_last_frame_ts = ts;
        display = (int64_t)((double)ts + h.clock_offset);
    } else {
        display = g_last_wait + 2 * period;
    }
    if (display <= g_last_display) display = g_last_display + 1;   // display times must rise
    g_last_display = display;
    g_frames[g_frame_next % FRAME_RING].xr_time = display;
    g_frames[g_frame_next % FRAME_RING].client_ts = ts;
    g_frame_next++;
    pthread_mutex_unlock(&g_lock);
    return display;
}

// ------------------------------------------------------------------------------------- poses

// The controller's own frame moved and turned by t (tune.json grip_*): position + q * t.position,
// orientation q * t. A zero quaternion (an older compositor that doesn't publish it) leaves it alone.
static void turn_grip(axr_pose *p, const axr_pose *t) {
    const float *a = p->orientation, *b = t->orientation;
    if (b[0] == 0 && b[1] == 0 && b[2] == 0 && b[3] == 0) return;
    simd_float3 moved = simd_act(simd_quaternion(a[0], a[1], a[2], a[3]),
                                 simd_make_float3(t->position[0], t->position[1], t->position[2]));
    for (int i = 0; i < 3; i++) p->position[i] += moved[i];
    float q[4] = {a[3] * b[0] + a[0] * b[3] + a[1] * b[2] - a[2] * b[1],
                  a[3] * b[1] - a[0] * b[2] + a[1] * b[3] + a[2] * b[0],
                  a[3] * b[2] + a[0] * b[1] - a[1] * b[0] + a[2] * b[3],
                  a[3] * b[3] - a[0] * b[0] - a[1] * b[1] - a[2] * b[2]};
    memcpy(p->orientation, q, sizeof q);
}

axr_motion axr_device_motion(int device, int64_t time) {
    axr_motion m = {0};
    header h;
    read_header(&h);
    uint64_t ts = axr_client_ts_for(time);
    if (!ts && h.have_offset) ts = (uint64_t)((double)time - h.clock_offset);
    axr_shm_sample s;
    if (h.connected && ts && find_sample(ts, offsetof(axr_shm_sample, dev) + device * sizeof(axr_motion) + offsetof(axr_motion, valid), false, &s)) {
        m = s.dev[device];
        // The fitted velocities stand in for the headset's on the hand's own sample.
        if (device != AXR_HEAD && h.pose_velocity && s.ts == ts && s.fit_ok[device == AXR_RIGHT]) {
            memcpy(m.linear_velocity, s.fit_v[device == AXR_RIGHT], sizeof m.linear_velocity);
            memcpy(m.angular_velocity, s.fit_w[device == AXR_RIGHT], sizeof m.angular_velocity);
        }
        if (device != AXR_HEAD) turn_grip(&m.pose, &h.grip[device == AXR_RIGHT]);
        if (h.eye_height > 0 && h.height_offset_set) m.pose.position[1] += h.height_offset;
        m.valid = true;
    } else if (device == AXR_HEAD) {
        m.pose = (axr_pose){{0, 0, 0, 1}, {0, 1.6f, 0}};
        m.valid = true;
    } else if (!h.connected && h.fake_tpose) {
        // Pointing out along the arms: the left controller yawed 90 degrees left, the right one right.
        float s = 0.70710678f;
        m.pose = device == AXR_LEFT ? (axr_pose){{0, s, 0, s}, {-0.75f, 1.45f, -0.1f}}
                                    : (axr_pose){{0, -s, 0, s}, {0.75f, 1.45f, -0.1f}};
        m.valid = true;
    }
    return m;
}

// A hand's 26 joints at time, in the tracking frame as device poses are, in the client's order:
// SteamVR's bones, which line up with OpenXR's hand joints one for one. False while the hand
// isn't seen, or is holding a controller and the client sends that instead.
bool axr_hand_joints(int hand, int64_t time, axr_pose out[26]) {
    header h;
    read_header(&h);
    uint64_t ts = axr_client_ts_for(time), newest = h.newest_ts;
    float raise = h.eye_height > 0 && h.height_offset_set ? h.height_offset : 0;
    uint8_t which = hand == AXR_LEFT ? 0 : 1;
    size_t flag = offsetof(axr_shm_sample, skel_ok) + which;
    axr_shm_sample s;
    // Skeletons are kept by their exact sample time: the frame's, or else the newest.
    if (!h.connected || !((ts && find_sample(ts, flag, true, &s)) || (newest && find_sample(newest, flag, true, &s))))
        return false;
    for (int i = 0; i < AXR_HAND_JOINTS; i++) {
        out[i] = s.skel[which][i];
        out[i].position[1] += raise;
    }
    return true;
}

// ------------------------------------------------------------------------------------- input

bool axr_input(const char *path, float *value) {
    uint64_t id = alvr_path_to_id(path);
    const axr_shm_global *g = region();
    if (!g) return false;
    _Atomic uint32_t *seq = (_Atomic uint32_t *)&g->seq;
    uint32_t s;
    bool connected, fake, found;
    float v;
    do {
        s = axr_seq_read_begin(seq);
        connected = g->connected;
        fake = found = false;
        v = 0;
        // The counts may be mid-write: keep them in range, and the retry sorts it out.
        uint32_t nfake = g->nfake_press, nbuttons = g->nbuttons;
        if (nfake > AXR_MAX_FAKE_PRESS) nfake = AXR_MAX_FAKE_PRESS;
        if (nbuttons > AXR_MAX_BUTTONS) nbuttons = AXR_MAX_BUTTONS;
        for (uint32_t i = 0; i < nfake && !fake; i++) fake = g->fake_press[i] == id;
        for (uint32_t i = 0; i < nbuttons && !found; i++)
            if (g->buttons[i].id == id) { found = true; v = g->buttons[i].value; }
    } while (!axr_seq_read_ok(seq, s));
    if (!connected && fake) {
        *value = 1;
        return true;
    }
    if (!found) return false;
    *value = v;
    return true;
}
