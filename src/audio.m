// Game audio for ALVR. Recording a tap from inside the game's process depends on which of the game's
// processes macOS holds responsible for the permission, so it came and went. MacVapoR Audio, a
// helper app with a permission of its own, taps the game instead and hands the samples over in
// shared memory; the runtime passes them to ALVR, which streams them with the video. The helper
// also keeps the game muted on the Mac.

#import <Foundation/Foundation.h>
#include <fcntl.h>
#include <math.h>
#include <pthread.h>
#include <spawn.h>
#include <stdatomic.h>
#include <sys/mman.h>
#include <unistd.h>

#include "alvr_capi.h"
#include "alvrxr.h"
#include "../helper/audio_ring.h"

extern char **environ;

#define STREAM_RATE 48000

static axr_audio_ring *g_ring;
static _Atomic uint64_t g_stat_frames;
static _Atomic uint32_t g_stat_peak;   // x 1000

void axr_audio_stats(uint64_t *frames, float *peak) {
    *frames = atomic_exchange(&g_stat_frames, 0);
    *peak = atomic_exchange(&g_stat_peak, 0) / 1000.0f;
}

static NSString *helper_path(void) {
    NSString *env = NSProcessInfo.processInfo.environment[@"ALVRXR_AUDIO_HELPER"];
    return env ?: [NSHomeDirectory() stringByAppendingPathComponent:
                                         @"Library/Application Support/MacVapoR/MacVapoR Audio.app"];
}

bool axr_audio_available(void) {
    return [NSFileManager.defaultManager fileExistsAtPath:helper_path()];
}

static int16_t to_i16(float x) {
    x = fmaxf(-1.0f, fminf(1.0f, x));
    return (int16_t)lrintf(x * 32767.0f);
}

// Reads the ring into ALVR in 10 ms pieces, at the stream's rate.
static void *reader(void *arg) {
    int16_t out[STREAM_RATE / 100 * 2];
    double position = 0;   // in source frames, for resampling
    for (;;) {
        usleep(5000);
        uint32_t rate = atomic_load(&g_ring->sample_rate);
        if (!rate) continue;
        uint64_t written = atomic_load_explicit(&g_ring->written, memory_order_acquire);
        uint64_t read = atomic_load(&g_ring->read);
        if (written - read > AXR_AUDIO_RING_FRAMES / 2) read = written - AXR_AUDIO_RING_FRAMES / 4;   // fell behind
        if (position < read) position = read;
        double step = (double)rate / STREAM_RATE;
        float peak = 0;
        while (position + step + 1 < written) {
            uint32_t n = 0;
            while (n < STREAM_RATE / 100 && position + 1 < written) {
                uint64_t i = (uint64_t)position;
                float t = (float)(position - i);
                const float *a = g_ring->frames[i % AXR_AUDIO_RING_FRAMES];
                const float *b = g_ring->frames[(i + 1) % AXR_AUDIO_RING_FRAMES];
                for (int c = 0; c < 2; c++) {
                    float x = a[c] + (b[c] - a[c]) * t;
                    peak = fmaxf(peak, fabsf(x));
                    out[n * 2 + c] = to_i16(x);
                }
                n++;
                position += step;
            }
            alvr_send_game_audio(out, n);
            atomic_fetch_add(&g_stat_frames, n);
        }
        atomic_store(&g_ring->read, (uint64_t)position);
        uint32_t p = (uint32_t)(peak * 1000), old = atomic_load(&g_stat_peak);
        while (p > old && !atomic_compare_exchange_weak(&g_stat_peak, &old, p)) {}
    }
    return NULL;
}

void axr_audio_start(void) {
    if (!axr_audio_available()) {
        axr_log("audio: MacVapoR Audio is not installed; no game audio");
        return;
    }
    char name[64];
    snprintf(name, sizeof name, AXR_AUDIO_RING_NAME_FORMAT, getpid());
    shm_unlink(name);
    int fd = shm_open(name, O_CREAT | O_RDWR, 0600);
    if (fd < 0 || ftruncate(fd, sizeof *g_ring) != 0) {
        axr_log("audio: no shared memory for the game audio");
        if (fd >= 0) close(fd);
        return;
    }
    g_ring = mmap(NULL, sizeof *g_ring, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    close(fd);
    if (g_ring == MAP_FAILED) {
        g_ring = NULL;
        return;
    }
    alvr_set_external_game_audio(STREAM_RATE);

    // Through Launch Services, so the helper is responsible for itself and its permission is used.
    char pid[16];
    snprintf(pid, sizeof pid, "%d", getpid());
    const char *app = helper_path().fileSystemRepresentation;
    char *args[] = {"open", "-g", "-j", "-n", "-a", (char *)app, "--args", "--pid", pid, NULL};
    pid_t child;
    if (posix_spawn(&child, "/usr/bin/open", NULL, NULL, args, environ) != 0) {
        axr_log("audio: could not start MacVapoR Audio");
        return;
    }
    pthread_t t;
    pthread_create(&t, NULL, reader, NULL);
    pthread_detach(t);
    axr_log("audio: MacVapoR Audio taps the game");
}
