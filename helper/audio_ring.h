// The game audio ring shared between MacVapoR Audio, which taps the game's process, and the runtime
// inside the game, which hands the samples to ALVR. One writer, one reader, in shared memory named
// by AXR_AUDIO_RING_NAME_FORMAT with the game's process ID.
#pragma once
#include <stdatomic.h>
#include <stdint.h>

#define AXR_AUDIO_RING_NAME_FORMAT "/alvrxr-audio-%d"
#define AXR_AUDIO_RING_FRAMES (48000 * 2)   // two seconds of stereo at 48 kHz

typedef struct {
    _Atomic uint64_t written;   // frames written since the start, by the helper
    _Atomic uint64_t read;      // frames read, by the runtime
    _Atomic uint32_t sample_rate;   // of the tapped audio; 0 until the tap runs
    _Atomic uint32_t helper_alive;  // a heartbeat the helper bumps every second
    float frames[AXR_AUDIO_RING_FRAMES][2];   // interleaved stereo
} axr_audio_ring;
