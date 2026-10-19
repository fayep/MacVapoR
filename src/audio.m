// Game audio for ALVR. Recording a tap from inside the game's process depends on which of the game's
// processes macOS holds responsible for the permission, so it came and went. MacVapoR Audio, a
// helper app with a permission of its own, taps the game instead and hands the samples over in
// shared memory; the runtime passes them to ALVR, which streams them with the video. The helper
// also keeps the game muted on the Mac.
//
// Each tapped process is a source with a ring of its own. One thread mixes the sources, each at
// the gain the compositor gives it as it cross-fades, into the one stream ALVR sends, so the
// headset hears no gap when a game starts or quits.

#import <Foundation/Foundation.h>
#include <fcntl.h>
#include <math.h>
#include <pthread.h>
#include <spawn.h>
#include <stdatomic.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

#include "alvr_capi.h"
#include "alvrxr.h"
#include "../helper/audio_ring.h"

extern char **environ;

#define STREAM_RATE 48000
#define BLOCK (STREAM_RATE / 100)
#define MAX_SOURCES 16
#define MAX_MIX (1 << 17)   // output frames in one pass, more than the ring holds before it falls behind
#define GAIN_SLEW (1.0f / (STREAM_RATE * 0.015f))   // per frame: silence to full in 15 ms, no clicks
#define LIVE_NS 50000000ull   // a ring that hasn't moved for this long has stopped
#define MAX_BACKLOG (STREAM_RATE / 10)   // output frames a playing source may get ahead of the mix

struct axr_audio_source {
    char name[64];
    axr_audio_ring *ring;
    _Atomic float target;
    _Atomic bool removing;
    // The mixer thread's own.
    float gain;
    bool started;   // has been mixed; until then a new gain applies at once, so a source can fade in
    double position;   // in source frames, for resampling
    uint64_t last_written, last_change_ns;
};

static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;
static axr_audio_source *g_sources[MAX_SOURCES];
static int g_count;
static float g_mix[MAX_MIX][2];
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

// Tests write the rings themselves, under names of their own.
static bool no_helper(void) {
    return getenv("ALVRXR_AUDIO_NO_HELPER") != NULL;
}

static int16_t to_i16(float x) {
    x = fmaxf(-1.0f, fminf(1.0f, x));
    return (int16_t)lrintf(x * 32767.0f);
}

// How many output frames the ring holds past the source's position, at most limit.
static uint32_t available(const axr_audio_source *s, uint64_t written, double step, uint32_t limit) {
    uint32_t n = 0;
    for (double p = s->position; n < limit && p + 1 < written; p += step) n++;
    return n;
}

// Resamples n frames of the source into the mix, its gain moving towards the target over all
// `total` frames of the pass. Returns the source's peak.
static float mix_in(axr_audio_source *s, double step, uint32_t n, uint32_t total) {
    float target = atomic_load(&s->target), g = s->gain, peak = 0;
    for (uint32_t k = 0; k < total; k++) {
        g += fmaxf(-GAIN_SLEW, fminf(GAIN_SLEW, target - g));
        if (k >= n) continue;
        uint64_t i = (uint64_t)s->position;
        float t = (float)(s->position - i);
        const float *a = s->ring->frames[i % AXR_AUDIO_RING_FRAMES];
        const float *b = s->ring->frames[(i + 1) % AXR_AUDIO_RING_FRAMES];
        for (int c = 0; c < 2; c++) {
            float x = a[c] + (b[c] - a[c]) * t;
            peak = fmaxf(peak, fabsf(x));
            g_mix[k][c] += x * g;
        }
        s->position += step;
    }
    s->gain = g;
    return peak;
}

static void free_source(axr_audio_source *s) {
    munmap(s->ring, sizeof *s->ring);
    shm_unlink(s->name);
    free(s);
}

// Every 5 ms, mixes what the sources have into ALVR in 10 ms pieces, at the stream's rate. The
// sources still playing set the pace together: a pass takes what the one with least has, so none
// runs dry mid-block (their taps share the output device's clock). One that has stopped, its game
// gone or its helper not started, holds no one back and plays out what it has.
static void *mixer(void *arg) {
    int16_t out[BLOCK * 2];
    for (;;) {
        usleep(5000);
        axr_audio_source *src[MAX_SOURCES];
        pthread_mutex_lock(&g_lock);
        int count = g_count;
        memcpy(src, g_sources, sizeof src);
        pthread_mutex_unlock(&g_lock);

        uint64_t now = clock_gettime_nsec_np(CLOCK_MONOTONIC);
        double step[MAX_SOURCES];
        uint32_t avail[MAX_SOURCES];
        bool live[MAX_SOURCES];
        uint32_t live_min = UINT32_MAX, stopped_max = 0;
        for (int i = 0; i < count; i++) {
            axr_audio_source *s = src[i];
            uint32_t rate = atomic_load(&s->ring->sample_rate);
            step[i] = (double)rate / STREAM_RATE;
            avail[i] = 0;
            live[i] = false;
            if (!rate) continue;
            uint64_t written = atomic_load_explicit(&s->ring->written, memory_order_acquire);
            uint64_t read = atomic_load(&s->ring->read);
            if (written - read > AXR_AUDIO_RING_FRAMES / 2) read = written - AXR_AUDIO_RING_FRAMES / 4;   // fell behind
            if (s->position < read) s->position = read;
            if (written != s->last_written || !s->last_change_ns) {
                s->last_written = written;
                s->last_change_ns = now;
            }
            live[i] = now - s->last_change_ns < LIVE_NS;
            avail[i] = available(s, written, step[i], MAX_MIX);
            if (live[i]) live_min = MIN(live_min, avail[i]);
            else stopped_max = MAX(stopped_max, avail[i]);
        }
        uint32_t total = live_min != UINT32_MAX ? live_min : stopped_max;
        if (total % BLOCK == 1) total--;   // never a block of one frame; it waits for the next pass

        float peak = 0;
        memset(g_mix, 0, total * sizeof g_mix[0]);
        for (int i = 0; i < count; i++) {
            axr_audio_source *s = src[i];
            if (!s->started) {
                s->gain = atomic_load(&s->target);
                s->started = avail[i] && total;
            }
            if (!step[i]) continue;   // the helper hasn't started: silence
            uint32_t n = MIN(avail[i], total);
            if (total) peak = fmaxf(peak, mix_in(s, step[i], n, total));
            atomic_fetch_add(&g_stat_frames, n);
            // Only clocks gone astray get a source this far ahead; skip, so its delay stays short.
            if (live[i] && avail[i] - n > MAX_BACKLOG) s->position += (avail[i] - n - BLOCK) * step[i];
            atomic_store(&s->ring->read, (uint64_t)s->position);
        }
        for (uint32_t done = 0; done < total;) {
            uint32_t n = MIN(BLOCK, total - done);
            for (uint32_t k = 0; k < n; k++)
                for (int c = 0; c < 2; c++) out[k * 2 + c] = to_i16(g_mix[done + k][c]);
            alvr_send_game_audio(out, n);
            done += n;
        }
        uint32_t p = (uint32_t)(peak * 1000), old = atomic_load(&g_stat_peak);
        while (p > old && !atomic_compare_exchange_weak(&g_stat_peak, &old, p)) {}

        // A removed source goes once it has faded out, or has nothing more to play.
        axr_audio_source *gone[MAX_SOURCES];
        int ngone = 0;
        pthread_mutex_lock(&g_lock);
        for (int i = 0; i < g_count;) {
            axr_audio_source *s = g_sources[i];
            int j = 0;
            while (j < count && src[j] != s) j++;
            bool quiet = j == count || !s->started || s->gain == 0 || (!live[j] && avail[j] <= total);
            if (atomic_load(&s->removing) && quiet) {
                gone[ngone++] = s;
                g_sources[i] = g_sources[--g_count];
            } else {
                i++;
            }
        }
        pthread_mutex_unlock(&g_lock);
        for (int i = 0; i < ngone; i++) free_source(gone[i]);
    }
    return NULL;
}

static void start_mixer(void) {
    alvr_set_external_game_audio(STREAM_RATE);
    pthread_t t;
    pthread_create(&t, NULL, mixer, NULL);
    pthread_detach(t);
}

axr_audio_source *axr_audio_add_source(pid_t pid) {
    if (!no_helper() && !axr_audio_available()) return NULL;
    axr_audio_source *s = calloc(1, sizeof *s);
    const char *prefix = getenv("ALVRXR_AUDIO_RING_PREFIX");
    if (prefix) snprintf(s->name, sizeof s->name, "%s%d", prefix, pid);
    else snprintf(s->name, sizeof s->name, AXR_AUDIO_RING_NAME_FORMAT, pid);
    s->gain = 1;
    atomic_store(&s->target, 1.0f);
    shm_unlink(s->name);
    int fd = shm_open(s->name, O_CREAT | O_RDWR, 0600);
    if (fd < 0 || ftruncate(fd, sizeof *s->ring) != 0) {
        axr_log("audio: no shared memory for the game audio");
        if (fd >= 0) close(fd);
        shm_unlink(s->name);
        free(s);
        return NULL;
    }
    s->ring = mmap(NULL, sizeof *s->ring, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    close(fd);
    if (s->ring == MAP_FAILED) {
        shm_unlink(s->name);
        free(s);
        return NULL;
    }
    pthread_mutex_lock(&g_lock);
    bool room = g_count < MAX_SOURCES;
    if (room) g_sources[g_count++] = s;
    pthread_mutex_unlock(&g_lock);
    if (!room) {
        axr_log("audio: too many sources; no audio for process %d", pid);
        free_source(s);
        return NULL;
    }
    static pthread_once_t once = PTHREAD_ONCE_INIT;
    pthread_once(&once, start_mixer);

    // Through Launch Services, so the helper is responsible for itself and its permission is used.
    // It taps until the process exits.
    if (!no_helper()) {
        char arg[16];
        snprintf(arg, sizeof arg, "%d", pid);
        const char *app = helper_path().fileSystemRepresentation;
        char *args[] = {"open", "-g", "-j", "-n", "-a", (char *)app, "--args", "--pid", arg, NULL};
        pid_t child;
        if (posix_spawn(&child, "/usr/bin/open", NULL, NULL, args, environ) != 0) {
            axr_log("audio: could not start MacVapoR Audio");
            axr_audio_remove_source(s);   // silent, so the mixer lets it go at once
            return NULL;
        }
    }
    return s;
}

void axr_audio_set_gain(axr_audio_source *src, float gain) {
    if (src) atomic_store(&src->target, fmaxf(0.0f, fminf(1.0f, gain)));
}

// The mixer fades it out and lets it go. The helper exits with its process; while that lives on,
// the helper keeps tapping into the ring it has mapped, unheard, and the process stays muted.
void axr_audio_remove_source(axr_audio_source *src) {
    if (!src) return;
    atomic_store(&src->target, 0.0f);
    atomic_store(&src->removing, true);
}

static axr_audio_source *g_local;   // this process's own: the lounge's, which the compositor fades

void axr_audio_start(void) {
    if (!axr_audio_available()) {
        axr_log("audio: MacVapoR Audio is not installed; no game audio");
        return;
    }
    if ((g_local = axr_audio_add_source(getpid()))) axr_log("audio: MacVapoR Audio taps the game");
}

axr_audio_source *axr_audio_local_source(void) { return g_local; }
