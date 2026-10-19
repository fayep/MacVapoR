// Exercises the audio mixer (src/audio.m) with no helper, no ALVR and no headset: the test writes
// tones into the rings itself, as MacVapoR Audio would, and stubs ALVR's two audio calls to record
// what the mixer sends. Build and run:  tests/audio-mix-check.sh
//   audio-mix-check mix              sources mixed, cross-faded, added and removed mid-stream
//   audio-mix-check legacy OUT       axr_audio_start's one source; writes the stream sent to OUT,
//                                    for comparing with the same test linked to an older audio.m
#import <Foundation/Foundation.h>
#include <fcntl.h>
#include <math.h>
#include <pthread.h>
#include <stdatomic.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

#include "alvrxr.h"
#include "../helper/audio_ring.h"

// The stubs.
#define MAX_OUT (48000 * 20)
static int16_t g_out[MAX_OUT][2];
static _Atomic uint64_t g_out_frames;
static uint64_t g_first_ns;
static uint32_t g_blocks, g_partial_blocks, g_external_rate;

void alvr_set_external_game_audio(uint32_t rate) { g_external_rate = rate; }
void alvr_send_game_audio(const int16_t *samples, uint64_t n) {
    uint64_t at = atomic_load(&g_out_frames);
    if (!at) g_first_ns = clock_gettime_nsec_np(CLOCK_MONOTONIC);
    if (at + n > MAX_OUT) return;
    memcpy(g_out[at], samples, n * 4);
    g_blocks++;
    if (n != 480) g_partial_blocks++;
    atomic_store(&g_out_frames, at + n);
}
void axr_log(const char *fmt, ...) {
    va_list a;
    va_start(a, fmt);
    printf("  [log] ");
    vprintf(fmt, a);
    printf("\n");
    va_end(a);
}
// Only the old audio.m, which can't be told not to launch the helper, is built against this.
int test_spawn(pid_t *pid, const char *path, const void *fa, const void *at, char *const argv[], char *const env[]) {
    *pid = 0;
    return 0;
}

static uint64_t now_ns(void) { return clock_gettime_nsec_np(CLOCK_MONOTONIC); }
static void sleep_until(uint64_t t) {
    uint64_t n = now_ns();
    if (t > n) usleep((useconds_t)((t - n) / 1000));
}

static axr_audio_ring *open_ring(int pid) {
    char name[64];
    const char *prefix = getenv("ALVRXR_AUDIO_RING_PREFIX");
    if (prefix) snprintf(name, sizeof name, "%s%d", prefix, pid);
    else snprintf(name, sizeof name, AXR_AUDIO_RING_NAME_FORMAT, pid);
    int fd = shm_open(name, O_RDWR);
    if (fd < 0) {
        printf("FAIL: no ring %s\n", name);
        exit(1);
    }
    axr_audio_ring *r = mmap(NULL, sizeof *r, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    close(fd);
    return r;
}

// A helper stand-in: writes a sine into a ring in device-sized pieces, in real time.
typedef struct {
    axr_audio_ring *ring;
    uint32_t rate, chunk;
    double freq, amp;
    uint64_t start_ns, stop_ns;   // relative to the test's start
    bool jitter;
} writer;
static uint64_t g_t0;

static void *write_tone(void *arg) {
    writer *w = arg;
    sleep_until(g_t0 + w->start_ns);
    atomic_store(&w->ring->sample_rate, w->rate);
    uint64_t frames = 0, base = now_ns();
    unsigned seed = 7;
    // A set number of frames, so that runs compare.
    uint64_t total = (w->stop_ns - w->start_ns) * w->rate / 1000000000;
    while (frames < total) {
        uint64_t wpos = atomic_load(&w->ring->written);
        uint32_t n = w->chunk;
        if (w->jitter) n = w->chunk / 2 + rand_r(&seed) % w->chunk;
        n = (uint32_t)MIN(n, total - frames);
        for (uint32_t i = 0; i < n; i++) {
            float x = (float)(w->amp * sin(2 * M_PI * w->freq * (frames + i) / w->rate));
            w->ring->frames[(wpos + i) % AXR_AUDIO_RING_FRAMES][0] = x;
            w->ring->frames[(wpos + i) % AXR_AUDIO_RING_FRAMES][1] = -x;
        }
        atomic_store_explicit(&w->ring->written, wpos + n, memory_order_release);
        frames += n;
        sleep_until(base + frames * 1000000000ull / w->rate);
    }
    return NULL;
}

static pthread_t start_writer(writer *w) {
    pthread_t t;
    pthread_create(&t, NULL, write_tone, w);
    return t;
}

static int legacy(const char *path) {
    axr_audio_start();
    axr_audio_ring *ring = open_ring(getpid());
    g_t0 = now_ns();
    // A helper that starts after a while, at 44.1 kHz, in uneven pieces.
    writer w = {ring, 44100, 441, 440, 0.5, 300000000, 3300000000, true};
    pthread_join(start_writer(&w), NULL);
    usleep(200000);
    uint64_t n = atomic_load(&g_out_frames);
    uint64_t frames;
    float peak;
    axr_audio_stats(&frames, &peak);
    FILE *f = fopen(path, "wb");
    fwrite(g_out, 4, n, f);
    fclose(f);
    printf("legacy: rate %u, %llu frames sent in %u blocks (%u partial); stats %llu frames, peak %.3f\n",
           g_external_rate, n, g_blocks, g_partial_blocks, frames, peak);
    return 0;
}

// Amplitude of a frequency over [from, to) of channel 0, by correlation.
static double tone_amp(uint64_t from, uint64_t to, double freq) {
    double re = 0, im = 0;
    for (uint64_t i = from; i < to; i++) {
        double x = g_out[i][0] / 32767.0;
        re += x * cos(2 * M_PI * freq * i / 48000);
        im += x * sin(2 * M_PI * freq * i / 48000);
    }
    return 2 * sqrt(re * re + im * im) / (to - from);
}
static int max_jump(uint64_t from, uint64_t to) {
    int m = 0;
    for (uint64_t i = from + 1; i < to; i++)
        for (int c = 0; c < 2; c++) m = MAX(m, abs(g_out[i][c] - g_out[i - 1][c]));
    return m;
}
static double rms(uint64_t from, uint64_t to) {
    double s = 0;
    for (uint64_t i = from; i < to; i++) s += pow(g_out[i][0] / 32767.0, 2);
    return sqrt(s / (to - from));
}
// A pure tone's largest step from one sample to the next, in int16 units.
static double tone_jump(double amp, double freq) { return 2 * amp * sin(M_PI * freq / 48000) * 32767; }

static int failures;
#define EXPECT(c, ...) do { if (!(c)) { failures++; printf("FAIL: "); printf(__VA_ARGS__); printf("\n"); } } while (0)

static int mix(void) {
    g_t0 = now_ns();
    axr_audio_source *a = axr_audio_add_source(1), *b = axr_audio_add_source(2), *c = NULL;
    EXPECT(a && b, "sources not added");
    writer wa = {open_ring(1), 48000, 512, 440, 0.3, 0, 5200000000, true};
    writer wb = {open_ring(2), 48000, 512, 660, 0.3, 200000000, 5200000000, true};
    writer wc = {NULL, 48000, 512, 880, 0.2, 3300000000, 5200000000, true};
    pthread_t ta = start_writer(&wa), tb = start_writer(&wb), tc = 0;

    // Measured at, in seconds of output: both at 1 (0.3-0.9); B cut to 0 by set_gain at 1.0;
    // A 1->0 and B 0->1 over 400 ms from 1.5; back from 2.5; C added at 3.0 (its helper starting at
    // 3.3) at gain 1; C removed at 4.0; B removed at 4.5, still playing; A's writer stops at 5.2.
    sleep_until(g_t0 + 1000000000);
    axr_audio_set_gain(b, 0);
    for (int dir = 0; dir < 2; dir++) {
        uint64_t start = g_t0 + (dir ? 2500000000ull : 1500000000ull);
        sleep_until(start);
        for (;;) {
            double f = (now_ns() - start) / 400e6;
            if (f > 1) f = 1;
            double th = (dir ? 1 - f : f) * M_PI / 2;
            axr_audio_set_gain(a, (float)cos(th));
            axr_audio_set_gain(b, (float)sin(th));
            if (f >= 1) break;
            usleep(11111);   // a 90 Hz compositor
        }
    }
    sleep_until(g_t0 + 3000000000ull);
    c = axr_audio_add_source(3);
    wc.ring = open_ring(3);
    tc = start_writer(&wc);
    sleep_until(g_t0 + 4000000000ull);
    axr_audio_remove_source(c);
    sleep_until(g_t0 + 4500000000ull);
    axr_audio_remove_source(b);
    pthread_join(ta, NULL);
    pthread_join(tb, NULL);
    pthread_join(tc, NULL);
    usleep(300000);
    axr_audio_remove_source(a);
    usleep(100000);

    uint64_t n = atomic_load(&g_out_frames);
    double latency = (g_first_ns - g_t0) / 1e9;
    // Output frame for a test time, given the first frame went out at `latency`.
    #define AT(t) ((uint64_t)(((t) - latency) * 48000))
    printf("mix: %llu frames in %u blocks (%u partial), first after %.1f ms; %.3f s of audio for %.3f s of writing\n",
           n, g_blocks, g_partial_blocks, latency * 1000, n / 48000.0, 5.2 - latency);
    EXPECT(fabs(n / 48000.0 - (5.2 - latency)) < 0.05, "output is not continuous in time");

    double jA = tone_jump(0.3, 440), jB = tone_jump(0.3, 660), jC = tone_jump(0.2, 880);
    struct { const char *what; double from, to, ampA, ampB, ampC, bound; } seg[] = {
        {"A alone, before B's helper starts", 0.05, 0.19, 0.3, 0, 0, jA},
        {"A + B at gain 1", 0.3, 0.9, 0.3, 0.3, 0, jA + jB},
        {"B cut to 0 by one set_gain (15 ms ramp)", 0.95, 1.1, -1, -1, 0, jA + jB},
        {"B at 0", 1.1, 1.45, 0.3, 0, 0, jA},
        {"cross-fade A 1->0, B 0->1, 400 ms", 1.45, 1.95, -1, -1, 0, jA + jB},
        {"B alone", 2.0, 2.45, 0, 0.3, 0, jB},
        {"cross-fade back", 2.45, 2.95, -1, -1, 0, jA + jB},
        {"C added at gain 1; its helper not started", 3.0, 3.25, 0.3, 0, 0, jA},
        {"C playing", 3.35, 3.9, 0.3, 0, 0.2, jA + jC},
        {"C removed while playing (fade out)", 3.95, 4.1, -1, -1, -1, jA + jC},
        {"B (at 0) removed while playing", 4.4, 4.6, 0.3, 0, 0, jA},
        {"A alone to its end", 4.6, 5.15, 0.3, 0, 0, jA},
    };
    printf("  %-44s %9s %9s %9s %10s %10s\n", "segment", "440 Hz", "660 Hz", "880 Hz", "max jump", "tone(s)");
    for (size_t i = 0; i < sizeof seg / sizeof seg[0]; i++) {
        uint64_t from = AT(seg[i].from), to = AT(seg[i].to);
        double a440 = tone_amp(from, to, 440), a660 = tone_amp(from, to, 660), a880 = tone_amp(from, to, 880);
        int j = max_jump(from, to);
        printf("  %-44s %9.4f %9.4f %9.4f %10d %10.0f\n", seg[i].what, a440, a660, a880, j, seg[i].bound);
        if (seg[i].ampA >= 0) EXPECT(fabs(a440 - seg[i].ampA) < 0.01, "%s: 440 Hz at %.4f", seg[i].what, a440);
        if (seg[i].ampB >= 0) EXPECT(fabs(a660 - seg[i].ampB) < 0.01, "%s: 660 Hz at %.4f", seg[i].what, a660);
        if (seg[i].ampC >= 0) EXPECT(fabs(a880 - seg[i].ampC) < 0.01, "%s: 880 Hz at %.4f", seg[i].what, a880);
        EXPECT(j <= seg[i].bound * 1.05 + 2, "%s: a jump of %d", seg[i].what, j);
    }
    // The equal-power fades keep the level of the two (uncorrelated) tones constant: 5 ms windows.
    double lo = 1, hi = 0;
    for (uint64_t i = AT(1.45); i + 240 < AT(2.95); i += 240) {
        double r = rms(i, i + 240);
        lo = MIN(lo, r), hi = MAX(hi, r);
    }
    double steady_lo = 1, steady_hi = 0;
    for (uint64_t i = AT(1.1); i + 240 < AT(1.45); i += 240) {
        double r = rms(i, i + 240);
        steady_lo = MIN(steady_lo, r), steady_hi = MAX(steady_hi, r);
    }
    printf("  level through both fades, 5 ms windows: rms %.4f..%.4f (A alone, same windows: %.4f..%.4f)\n", lo, hi,
           steady_lo, steady_hi);
    int whole = max_jump(AT(0.05), AT(5.15));
    uint64_t run = 0, longest = 0;
    for (uint64_t i = AT(0.05); i < AT(5.15); i++) {
        run = g_out[i][0] == 0 && g_out[i][1] == 0 ? run + 1 : 0;
        longest = MAX(longest, run);
    }
    printf("  whole stream: max jump %d (bound, all three tones at once %.0f); longest run of silence %llu frames\n",
           whole, jA + jB + jC, longest);
    EXPECT(longest < 4, "a gap of %llu frames", longest);
    uint64_t frames;
    float peak;
    axr_audio_stats(&frames, &peak);
    // Removed sources' rings are gone (the test's own mappings keep the memory, as a helper's would).
    for (int pid = 1; pid <= 3; pid++) {
        char name[64];
        snprintf(name, sizeof name, "%s%d", getenv("ALVRXR_AUDIO_RING_PREFIX"), pid);
        int fd = shm_open(name, O_RDWR);
        EXPECT(fd < 0, "ring %s is still there after its source was removed", name);
        if (fd >= 0) close(fd), shm_unlink(name);
    }
    printf("  stats: %llu frames tapped, peak %.3f\n", frames, peak);
    printf(failures ? "FAILED (%d)\n" : "ok\n", failures);
    return failures != 0;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc == 3 && !strcmp(argv[1], "legacy")) return legacy(argv[2]);
        if (argc == 2 && !strcmp(argv[1], "mix")) return mix();
        fprintf(stderr, "usage: audio-mix-check mix | legacy OUT\n");
        return 2;
    }
}
