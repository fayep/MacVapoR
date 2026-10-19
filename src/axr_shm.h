// Shared memory between the compositor (vapord, which owns ALVR) and the runtimes that draw for
// it: the lounge inside vapord, and each game's. See docs/compositor.md for the rules; in short:
// one writer per field, readers copy out under a seqlock and never keep pointers into it.
#pragma once
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <string.h>
#include "alvrxr.h"

#define AXR_SHM_MAGIC 0x41585231u   // "AXR1"
#define AXR_SHM_VERSION 1
#define AXR_SAMPLE_RING 128         // tracking samples, ~1.4 s at 90 Hz
#define AXR_MAX_BUTTONS 256
#define AXR_MAX_FAKE_PRESS 16
#define AXR_HAND_JOINTS 26
#define AXR_SLOTS 3                 // output slots per session
#define AXR_FRAME_RING 8            // frame descriptors per session

// ---------------------------------------------------------------------------- global region
// Written only by the compositor's ALVR event thread; mapped read-only by every runtime.

typedef struct {
    _Atomic uint32_t seq;           // this slot's seqlock: odd while being written
    uint32_t _pad;
    uint64_t ts;                    // ALVR sample timestamp (client clock, ns); 0 = empty slot
    axr_motion dev[AXR_DEVICE_COUNT];   // as ALVR gave them, with undo_alvr_shaping applied; no height offset
    float fit_v[2][3], fit_w[2][3];  // fitted hand velocities (left, right), see record_hand_samples
    uint8_t fit_ok[2];               // the fit exists for that hand at this ts
    uint8_t skel_ok[2];              // a hand skeleton exists for that hand at this ts
    axr_pose skel[2][AXR_HAND_JOINTS];   // no height offset
} axr_shm_sample;

typedef struct {
    // Written once at creation, before the region is handed out.
    uint32_t magic, version, size;

    // ---- header, under seq (seqlock)
    _Atomic uint32_t seq;
    uint8_t connected;              // a headset is connected
    uint8_t tracking_real;          // past the client's placeholder poses
    uint8_t have_offset;            // clock_offset is valid
    uint8_t fake_tpose;             // tune.json fake_tpose (only applies while !connected)
    uint8_t pose_velocity;          // tune.json pose_velocity: use fit_* on an exact hit
    uint8_t height_offset_set;
    uint8_t swap_eyes;              // already applied to views; informational
    uint8_t _pad0;
    uint64_t newest_ts;             // newest sample timestamp seen
    double clock_offset;            // smoothed CLOCK_MONOTONIC - sample ts (ns)
    int64_t last_sample_ns;         // CLOCK_MONOTONIC arrival of the newest sample
    double refresh_hz;
    uint32_t eye_w, eye_h;          // the stream's eye size: output slots are 2*eye_w x eye_h
    uint32_t config_gen;            // bumps when the stream restarts or eye size changes
    uint32_t recenter_gen;          // as axr_recenter_generation()
    axr_views views;                // with tune.json ipd_scale, fov_scale, swap_eyes applied
    axr_pose aim[2];                // axr_aim_offset(AXR_LEFT), (AXR_RIGHT)
    float height_offset;            // seated raise in metres, valid when height_offset_set
    float eye_height;               // height.json; 0 = standing (no offset)
    uint64_t input_gen;             // bumps when any button value changes
    uint32_t nbuttons;
    uint32_t nfake_press;
    struct { uint64_t id; float value; uint32_t _pad; } buttons[AXR_MAX_BUTTONS];
    uint64_t fake_press[AXR_MAX_FAKE_PRESS];   // alvr_path_to_id of tune.json fake_press paths

    // ---- tracking ring (per-slot seqlocks)
    _Atomic uint32_t sample_word;   // bumped (and woken) on every sample: wait on this
    _Atomic uint64_t sample_head;   // count of samples written; newest is (head - 1) % RING
    axr_shm_sample samples[AXR_SAMPLE_RING];
} axr_shm_global;

// ---------------------------------------------------------------------------- per-session region
// One per game session (and one for the lounge). Each field has a single writer, marked.

enum { AXR_FOCUS_HIDDEN = 0, AXR_FOCUS_VISIBLE = 1, AXR_FOCUS_FOCUSED = 2 };
enum {
    AXR_FRAME_HAS_CONTENT = 1u << 0,   // the frame had a projection or quad layer
};

typedef struct {
    uint64_t seq;                   // the frameEvent value this descriptor goes with (1, 2, ...)
    uint32_t slot;                  // 0 .. AXR_SLOTS-1
    uint32_t flags;                 // AXR_FRAME_*
    int64_t display_time;           // XrTime the frame was rendered for
    uint64_t client_ts;             // ALVR sample ts the frame's poses came from (0 = none)
    axr_pose head;                  // head pose used for it (stage space, with height offset),
                                    // so the compositor can reproject it
} axr_frame_desc;

typedef struct {
    uint32_t magic, version, size;
    _Atomic uint32_t focus;         // compositor writes: AXR_FOCUS_*
    _Atomic uint32_t should_render; // compositor writes: 0 lets the session idle
    _Atomic uint32_t closing;       // compositor writes: 1 = the compositor is going away
    _Atomic uint64_t heartbeat_ns;  // runtime writes, each xrWaitFrame
    _Atomic uint64_t frame_head;    // runtime writes: seq of the newest descriptor
    axr_frame_desc frames[AXR_FRAME_RING];   // runtime writes frames[seq % RING] before seq
} axr_shm_session;

// ---------------------------------------------------------------------------- seqlock helpers
// Writer (single thread): axr_seq_write_begin; write the fields; axr_seq_write_end.
// Reader: do { s = axr_seq_read_begin(); copy the fields out; } while (!axr_seq_read_ok(s));

static inline void axr_seq_write_begin(_Atomic uint32_t *seq) {
    uint32_t s = atomic_load_explicit(seq, memory_order_relaxed);
    atomic_store_explicit(seq, s + 1, memory_order_relaxed);
    atomic_thread_fence(memory_order_release);
}
static inline void axr_seq_write_end(_Atomic uint32_t *seq) {
    uint32_t s = atomic_load_explicit(seq, memory_order_relaxed);
    atomic_store_explicit(seq, s + 1, memory_order_release);
}
static inline uint32_t axr_seq_read_begin(_Atomic uint32_t *seq) {
    uint32_t s;
    while ((s = atomic_load_explicit(seq, memory_order_acquire)) & 1) { }
    return s;
}
static inline bool axr_seq_read_ok(_Atomic uint32_t *seq, uint32_t begin) {
    atomic_thread_fence(memory_order_acquire);
    return atomic_load_explicit(seq, memory_order_relaxed) == begin;
}
