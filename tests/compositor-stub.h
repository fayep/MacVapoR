// TEST ONLY: what tests/compositor-stub.m shares with tests/transport-check.m.
#pragma once
#include "axr_shm.h"

#define STUB_EYE_W 256
#define STUB_EYE_H 128

typedef struct {
    uint64_t frames, mismatches, last_seq;
    int64_t latency_sum, latency_max;   // ns from the client's commit to the stub's check
    int added, removed;
    pid_t last_pid;
    bool last_local;
} stub_stats;
extern stub_stats g_stub;
// While set, frames are left unread and unreleased, as by a compositor that hung or died.
extern _Atomic bool g_stub_hold;

// The current (newest) source's session region, as the compositor writes it.
axr_shm_session *stub_current_region(void);
void stub_bump_config_gen(void);

// Provided by the driver.
uint64_t stub_now_ns(void);
// The BGRA pixels (as a little-endian uint32) frame seq has in each eye's middle.
void stub_expected_colours(uint64_t seq, uint32_t *left, uint32_t *right);
