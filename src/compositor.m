// The compositor core (SERVER mode, vapord): its sources' output slots, the frames they hand over
// through shared events, which of them is in the foreground and drives the encoder, and the
// cross-fade between them. docs/compositor.md "Frames (compositor side)" and "Handover" are the
// spec; the transport (transport.m) and the lounge's slots (slots.m) call the functions in
// compositor.h's "vapord side", from any thread.

#import <Foundation/Foundation.h>
#import <IOSurface/IOSurfaceObjC.h>
#import <Metal/Metal.h>
#include <fcntl.h>
#include <libproc.h>
#include <math.h>
#include <pthread.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <sys/sysctl.h>
#include <unistd.h>

#include "alvrxr.h"
#include "compositor.h"
#include "tracking.h"

#define MAX_SOURCES 4
#define LOUNGE_IDLE_NS 2000000000LL    // after a fade to a game, the lounge idles this much later
#define FIRST_FRAMES 3                 // content frames in a row (each within 2 periods) before a game shows
// The dashboard (docs/compositor.md): the right controller's system button held this long opens it,
// and the game under the panel is dimmed to this.
#define DASHBOARD_HOLD_NS 500000000LL
#define DASHBOARD_DIM 0.35f
#define SYSTEM_BUTTON "/user/hand/right/input/system/click"

// A frame a source has handed over: its descriptor, held until it stops being current and no
// compose command buffer reads it.
typedef struct {
    axr_frame_desc d;
    bool valid;
} frame_ref;

struct axr_source {
    int id;                         // for the log: 1, 2, ...
    bool local;                     // the lounge, drawn in this process
    pid_t pid;
    char name[64];                  // the game's program name (axr_process_name), for the dashboard
    bool gone;                      // removed: no more frames are taken, its last one may be fading out
    bool dropped;                   // its GPU resources are gone too (the struct stays: late listeners)
    IOSurface *surfaces[AXR_SLOTS];
    id<MTLTexture> textures[AXR_SLOTS];
    id<MTLSharedEvent> frame_event, release_event;
    axr_shm_session *region;
    int fd;
    dispatch_source_t exit_source;
    axr_audio_source *audio;
    // Frames.
    uint64_t next_seq;              // the frameEvent value listened for
    uint64_t newest_seq;            // the newest seq seen signalled
    uint64_t released;              // releaseEvent's value as set here
    frame_ref current;
    uint64_t inflight_seq[AXR_FRAME_RING];   // frames compose command buffers read (seq % RING)
    unsigned inflight[AXR_FRAME_RING];
    // Handover.
    int streak;                     // content frames in a row, each within 2 refresh periods
    int64_t last_content_ns;
    bool passed;                    // has passed the first-frame check (once: a demoted game stays back)
    int64_t last_frame_ns;          // any frame, for the watchdog
    int64_t added_ns;
    // Stats, over the 5 s line.
    unsigned stat_frames, stat_content, stat_skipped, stat_unread;
};

static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;
static bool g_started;
static dispatch_queue_t g_q;                 // frame arrivals, timers, exit sources: one serial queue
static MTLSharedEventListener *g_listener;
static id<MTLDevice> g_device;
static int g_global_fd = -1;                 // read-only, handed to every client; ours for good
static axr_source *g_sources[MAX_SOURCES];   // live ones; gone sources leave once dropped
static int g_next_id;

// Who is shown: fg drives the encoder; other, if any, is blended under it at (1 - alpha) while
// the fade runs. The fade's clock starts at its first compose, so a lounge that has to wake up
// first (should_render was 0) still gets the full fade.
static axr_source *g_lounge, *g_fg, *g_other;
static int64_t g_fade_start_ns;
static unsigned g_fade_frames;
static int64_t g_lounge_idle_at_ns;          // when the lounge's should_render goes to 0; 0 = not scheduled
static uint64_t g_fade_ms = 400;
// No frame from the foreground game for this long: fade back to the lounge. Its last frame is held,
// reprojected, until then, so a game's loading hitch needn't bounce the player to the lounge.
static _Atomic int64_t g_watchdog_ns = 1500000000LL;
// The dashboard: while open over a game, the lounge drives the encoder with its panel and the
// game's held frame shows through, dimmed. The system button is watched in tick().
static bool g_dashboard;
static bool g_sys_down, g_sys_fired;         // the button's state, and whether this press has opened or closed
static int64_t g_sys_press_ns;

// Stats: composes, and the time from the frame's listener firing to its command buffer's commit.
static unsigned g_stat_composed, g_stat_dropped;
static int64_t g_stat_latency_sum, g_stat_latency_max;

static void on_frame(axr_source *src, uint64_t value, int64_t fired_ns);
static void listen_next(axr_source *src);
static void source_gone(axr_source *src, const char *reason);
static void dashboard_set(bool open, int64_t now, const char *why);

static const char *name_of(const axr_source *s) {
    static char buf[4][48];
    static unsigned n;
    char *b = buf[n++ % 4];
    if (!s) snprintf(b, sizeof buf[0], "nothing");
    else if (s->local) snprintf(b, sizeof buf[0], "#%d lounge", s->id);
    else snprintf(b, sizeof buf[0], "#%d game (pid %d)", s->id, s->pid);
    return b;
}

static NSString *config_dir(void) {
    NSString *dir = NSProcessInfo.processInfo.environment[@"ALVRXR_CONFIG_DIR"];
    return dir.length ? dir : [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/alvrxr"];
}

// tune.json "fade_ms" and "watchdog_ms", read as each fade starts and each source is added, so
// they can be tuned live.
static void read_tune(void) {
    NSData *d = [NSData dataWithContentsOfFile:[config_dir() stringByAppendingPathComponent:@"tune.json"]];
    NSDictionary *t = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
    id v = [t isKindOfClass:NSDictionary.class] ? t[@"fade_ms"] : nil;
    g_fade_ms = [v respondsToSelector:@selector(unsignedLongLongValue)] && [v unsignedLongLongValue] > 0 ? [v unsignedLongLongValue] : 400;
    v = [t isKindOfClass:NSDictionary.class] ? t[@"watchdog_ms"] : nil;
    long long w = [v respondsToSelector:@selector(longLongValue)] && [v longLongValue] > 0 ? [v longLongValue] : 1500;
    atomic_store(&g_watchdog_ns, w * 1000000LL);
}

// ------------------------------------------------------------------------------------- focus

static void set_focus(axr_source *s, uint32_t focus, bool render) {
    if (!s || !s->region) return;
    uint32_t had = atomic_load(&s->region->focus), rendered = atomic_load(&s->region->should_render);
    if (had == focus && (rendered != 0) == render) return;
    atomic_store(&s->region->focus, focus);
    atomic_store(&s->region->should_render, render);
    static const char *names[] = {"HIDDEN", "VISIBLE", "FOCUSED"};
    axr_log("compositor: %s %s, should_render %d", name_of(s), names[focus < 3 ? focus : 0], render);
}

// ------------------------------------------------------------------------------------- audio

// Equal-power gains following the fade: the foreground rises as sin, the other falls as cos, so
// the sum of powers stays 1 through the cross-fade. The mixer smooths each step itself.
static void apply_audio_fade(axr_source *fg, axr_source *other, float alpha) {
    if (fg) axr_audio_set_gain(fg->audio, other ? sinf(alpha * (float)M_PI_2) : 1);
    if (other) axr_audio_set_gain(other->audio, cosf(alpha * (float)M_PI_2));
}

// ------------------------------------------------------------------------------------ release

// Raises the source's release value to just below the oldest frame still held: its current one,
// or one a compose command buffer is reading. Nothing held: everything seen so far.
static void release_update(axr_source *s) {
    if (!s->release_event) return;
    uint64_t hold = UINT64_MAX;
    if (s->current.valid && s->current.d.seq < hold) hold = s->current.d.seq;
    for (int i = 0; i < AXR_FRAME_RING; i++)
        if (s->inflight[i] && s->inflight_seq[i] < hold) hold = s->inflight_seq[i];
    uint64_t r = hold == UINT64_MAX ? s->newest_seq : hold - 1;
    if (r <= s->released) return;
    s->released = r;
    s->release_event.signaledValue = r;
}

static void frame_ref_acquire(axr_source *s, uint64_t seq) {
    unsigned i = seq % AXR_FRAME_RING;
    if (s->inflight[i] && s->inflight_seq[i] != seq) axr_log("compositor: %s frame %llu still in flight at %llu", name_of(s), s->inflight_seq[i], seq);
    s->inflight_seq[i] = seq;
    s->inflight[i]++;
}

static void frame_ref_release(axr_source *s, uint64_t seq) {
    unsigned i = seq % AXR_FRAME_RING;
    if (s->inflight[i]) s->inflight[i]--;
    release_update(s);
}

static bool source_in_flight(const axr_source *s) {
    for (int i = 0; i < AXR_FRAME_RING; i++) if (s->inflight[i]) return true;
    return false;
}

// Lets a gone source's GPU side go once nothing reads it; the struct itself stays, as a late
// listener block or a second remove (transport.m removes on both interruption and invalidation)
// may still name it.
static void source_drop(axr_source *s) {
    if (!s->gone || s->dropped || source_in_flight(s) || s == g_fg || s == g_other) return;
    s->dropped = true;
    s->current.valid = false;
    release_update(s);   // whatever the client is still waiting for
    for (int i = 0; i < AXR_SLOTS; i++) s->textures[i] = nil, s->surfaces[i] = nil;
    if (s->region) munmap(s->region, sizeof *s->region);
    s->region = NULL;
    if (s->fd >= 0) close(s->fd);
    s->fd = -1;
    for (int i = 0; i < MAX_SOURCES; i++) if (g_sources[i] == s) g_sources[i] = NULL;
    axr_log("compositor: %s dropped", name_of(s));
}

// ------------------------------------------------------------------------------------- handover

static float fade_alpha(int64_t now) {
    if (!g_other) return 1;
    if (!g_fade_start_ns) return 0;
    double a = (double)(now - g_fade_start_ns) / (g_fade_ms * 1e6);
    return a >= 1 ? 1 : a <= 0 ? 0 : (float)a;
}

static void fade_end(int64_t now) {
    axr_source *was = g_other;
    axr_log("compositor: fade end: %s now alone after %.0f ms, %u frames%s", name_of(g_fg),
            g_fade_start_ns ? (now - g_fade_start_ns) / 1e6 : 0.0, g_fade_frames, was && was->gone ? " (the other is gone)" : "");
    g_other = NULL;
    g_fade_start_ns = 0;
    g_fade_frames = 0;
    apply_audio_fade(g_fg, NULL, 1);
    if (was && was->gone) {
        if (was->audio && !was->local) axr_audio_remove_source(was->audio);
        was->audio = NULL;
        source_drop(was);
    } else if (was && !was->local) {
        // Demoted: VISIBLE, silent, its frames go back unread from here.
        axr_audio_set_gain(was->audio, 0);
        was->current.valid = false;
        release_update(was);
    }
    if (g_fg && !g_fg->local && g_lounge && !g_dashboard) g_lounge_idle_at_ns = now + LOUNGE_IDLE_NS;
}

// Starts the fade to src, from whoever was in front (its frame fades out underneath). With a
// fade already running the other way, the new one starts where that one stood, so the picture
// doesn't jump.
static void make_foreground(axr_source *src, int64_t now, const char *why) {
    // The panel belongs to whoever was in front; a change of foreground closes it.
    if (g_dashboard) dashboard_set(false, now, why);
    axr_source *prev = g_fg;
    float had = fade_alpha(now);   // prev's weight was `had`; it is now the other, at 1 - alpha
    if (g_other && g_other != src && g_other != prev) {
        // Three-way: the one already fading out just goes.
        axr_source *third = g_other;
        if (third->audio) axr_audio_set_gain(third->audio, 0);
        g_other = NULL;
        if (third->gone) source_drop(third);
    }
    bool reversed = g_other == src && prev;
    g_other = prev;
    g_fg = src;
    g_fade_frames = 0;
    g_lounge_idle_at_ns = 0;
    read_tune();
    g_fade_start_ns = reversed && had < 1 ? now - (int64_t)((1 - had) * g_fade_ms * 1e6) : 0;
    if (prev == g_lounge) set_focus(g_lounge, AXR_FOCUS_VISIBLE, true);
    else if (prev && !prev->gone) set_focus(prev, AXR_FOCUS_VISIBLE, true);
    set_focus(src, AXR_FOCUS_FOCUSED, true);
    axr_log("compositor: foreground: %s (%s), from %s, fade %llu ms%s at +%.1f ms", name_of(src), why, name_of(prev),
            (unsigned long long)g_fade_ms, reversed ? " (reversed)" : "", src ? (now - src->added_ns) / 1e6 : 0.0);
    if (!prev) { g_other = NULL; g_fade_start_ns = 0; apply_audio_fade(src, NULL, 1); }
    else apply_audio_fade(g_fg, g_other, fade_alpha(now));
}

// ------------------------------------------------------------------------------------ dashboard

// Opens or closes it (docs/compositor.md "Dashboard"): every source's region says so; open, the
// lounge takes focus and draws (the panel), the game in front keeps drawing without input; closed,
// the game has focus again and the lounge idles as after a fade. A fade in progress runs on
// regardless: its focus changes are the same ones, and fade_end leaves the idling to this.
static void dashboard_set(bool open, int64_t now, const char *why) {
    if (open == g_dashboard) return;
    g_dashboard = open;
    for (int i = 0; i < MAX_SOURCES; i++)
        if (g_sources[i] && g_sources[i]->region) atomic_store(&g_sources[i]->region->dashboard, open);
    axr_source *game = g_fg && !g_fg->local && !g_fg->gone ? g_fg : NULL;
    axr_log("compositor: dashboard %s (%s) over %s", open ? "open" : "closed", why, name_of(g_fg));
    if (open) {
        g_lounge_idle_at_ns = 0;
        set_focus(g_lounge, AXR_FOCUS_FOCUSED, true);
        if (game) set_focus(game, AXR_FOCUS_VISIBLE, true);
        return;
    }
    if (!game) return;   // the lounge is in front, with focus already
    set_focus(game, AXR_FOCUS_FOCUSED, true);
    if (g_lounge && g_lounge != g_other) {
        set_focus(g_lounge, AXR_FOCUS_VISIBLE, true);
        g_lounge_idle_at_ns = now + LOUNGE_IDLE_NS;
    }
}

// Who drives the encoder: the lounge while the dashboard is open over a game (it must stay
// responsive whatever the game does), else the foreground.
static axr_source *driver(void) {
    return g_dashboard && g_fg && !g_fg->local && g_lounge ? g_lounge : g_fg;
}

// The system button, from the published inputs (fake presses count while no headset is connected):
// held DASHBOARD_HOLD_NS opens; a new press while open closes. Each press does at most one thing.
static void watch_system_button(int64_t now) {
    float v = 0;
    bool down = axr_input(SYSTEM_BUTTON, &v) && v > 0.5f;
    if (down && !g_sys_down) {
        g_sys_down = true;
        g_sys_press_ns = now;
        g_sys_fired = g_dashboard;
        if (g_dashboard) dashboard_set(false, now, "system button");
    } else if (!down) {
        g_sys_down = false;
    }
    if (down && !g_sys_fired && now - g_sys_press_ns >= DASHBOARD_HOLD_NS) {
        g_sys_fired = true;
        dashboard_set(true, now, "system button held");
    }
}

// A content frame arrived from a game: the first-frame check, then the handover.
static void handover(axr_source *src, int64_t now) {
    if (src->local || src == g_fg || src->passed) return;
    int64_t period = (int64_t)(1e9 / axr_refresh_hz());
    src->streak = src->last_content_ns && now - src->last_content_ns <= 2 * period ? src->streak + 1 : 1;
    src->last_content_ns = now;
    if (src->streak < FIRST_FRAMES) return;
    src->passed = true;
    make_foreground(src, now, "first frames");
}

// ------------------------------------------------------------------------------------- compose

static axr_compose_frame compose_frame(const axr_source *s) {
    const axr_frame_desc *d = &s->current.d;
    return (axr_compose_frame){.texture = s->textures[d->slot % AXR_SLOTS], .head = d->head, .client_ts = d->client_ts,
                               .display_time = d->display_time};
}

static bool has_content(const axr_source *s) {
    return s && s->current.valid && (s->current.d.flags & AXR_FRAME_HAS_CONTENT);
}

// The driver's new frame drives: blend it with the other's current frame at the fade's alpha and
// encode; or, with the dashboard open over a game, draw the lounge's panel over the game's held
// frame, dimmed (the fade, if one runs, keeps its clock and its audio but isn't shown until the
// panel closes). The frames read are held until the command buffer completes.
static void compose(int64_t now, int64_t fired_ns) {
    axr_source *fg = driver(), *other;
    if (!has_content(fg)) return;
    bool overlay = fg != g_fg;
    if (overlay) other = has_content(g_fg) ? g_fg : NULL;
    else other = has_content(g_other) ? g_other : NULL;
    if (g_other && !g_fade_start_ns) {
        g_fade_start_ns = now;
        axr_log("compositor: fade start: %s over %s, %llu ms", name_of(g_fg), name_of(g_other), (unsigned long long)g_fade_ms);
    }
    float alpha = fade_alpha(now);
    axr_compose_frame f = compose_frame(fg), o = other ? compose_frame(other) : (axr_compose_frame){0};
    uint64_t fseq = fg->current.d.seq, oseq = other ? other->current.d.seq : 0;
    frame_ref_acquire(fg, fseq);
    if (other) frame_ref_acquire(other, oseq);
    void (^done)(void) = ^{
        dispatch_async(g_q, ^{
            pthread_mutex_lock(&g_lock);
            frame_ref_release(fg, fseq);
            if (other) frame_ref_release(other, oseq);
            source_drop(fg);
            if (other) source_drop(other);
            pthread_mutex_unlock(&g_lock);
        });
    };
    bool ok = overlay ? axr_encode_overlay(&f, other ? &o : NULL, DASHBOARD_DIM, done)
                      : axr_encode_composite(&f, other ? &o : NULL, alpha, done);
    if (!ok) {
        frame_ref_release(fg, fseq);
        if (other) frame_ref_release(other, oseq);
        g_stat_dropped++;
    } else {
        int64_t latency = axr_now_ns() - fired_ns;
        g_stat_composed++;
        g_stat_latency_sum += latency;
        if (latency > g_stat_latency_max) g_stat_latency_max = latency;
        if (g_other) g_fade_frames++;
    }
    if (g_other) apply_audio_fade(g_fg, g_other, alpha);
    if (g_other && alpha >= 1) fade_end(now);
}

// ------------------------------------------------------------------------------------- frames

static void listen_next(axr_source *src) {
    if (src->gone || !src->frame_event) return;
    uint64_t seq = src->next_seq;
    [src->frame_event notifyListener:g_listener atValue:seq block:^(id<MTLSharedEvent> e, uint64_t value) {
        (void)e;
        on_frame(src, value, axr_now_ns());
    }];
}

// frameEvent reached value: the frames up to its signalled value are ready, their descriptors
// written before the GPU could signal (slots.m axr_slot_end). The newest becomes current; the
// ones skipped on the way are released by release_update, since nothing holds them.
static void on_frame(axr_source *src, uint64_t value, int64_t fired_ns) {
    pthread_mutex_lock(&g_lock);
    if (src->gone || !src->region) { pthread_mutex_unlock(&g_lock); return; }
    int64_t now = fired_ns;
    uint64_t sig = src->frame_event.signaledValue;
    if (sig < value) sig = value;
    uint64_t head = atomic_load_explicit(&src->region->frame_head, memory_order_acquire);
    if (sig > head) sig = head;   // can't happen with a runtime that writes the descriptor first
    if (sig < src->next_seq) { pthread_mutex_unlock(&g_lock); listen_next(src); return; }
    src->stat_skipped += (unsigned)(sig - src->next_seq);
    axr_frame_desc d = src->region->frames[sig % AXR_FRAME_RING];
    src->newest_seq = sig;
    src->next_seq = sig + 1;
    src->last_frame_ns = now;
    src->stat_frames++;
    if (d.seq != sig) {
        // The runtime ran ahead and reused the descriptor (bounded by its CPU wait): skip it.
        src->stat_skipped++;
        release_update(src);
        pthread_mutex_unlock(&g_lock);
        listen_next(src);
        return;
    }
    // The slot must not be one still held here; a runtime that reuses it early broke the protocol.
    bool held = src->current.valid && src->current.d.slot == d.slot;
    for (int i = 0; i < AXR_FRAME_RING && !held; i++)
        held = src->inflight[i] && src->inflight_seq[i] % AXR_SLOTS == d.slot && src->inflight_seq[i] != sig;
    if (held) axr_log("compositor: %s frame %llu reused slot %u before its release (released %llu)", name_of(src),
                      (unsigned long long)sig, d.slot, (unsigned long long)src->released);
    bool content = (d.flags & AXR_FRAME_HAS_CONTENT) != 0;
    if (content) {
        src->stat_content++;
        handover(src, now);
    }
    // Shown sources keep their newest frame, content or not: an older one can't stay held once
    // the runtime has moved on, or its slot never comes free. A VISIBLE game's go back unread.
    bool shown = src == g_fg || src == g_other || src == g_lounge;
    if (shown) src->current = (frame_ref){.d = d, .valid = true};
    else if (content) src->stat_unread++;
    release_update(src);
    if (content && src == driver()) compose(now, fired_ns);
    pthread_mutex_unlock(&g_lock);
    listen_next(src);
}

// ------------------------------------------------------------------------------------- timer

// Every 50 ms: the system button, the watchdog on the foreground game, the lounge's idling, and
// gone sources.
static void tick(void) {
    pthread_mutex_lock(&g_lock);
    int64_t now = axr_now_ns();
    watch_system_button(now);
    axr_source *fg = g_fg;
    if (fg && !fg->local && !fg->gone && fg->last_frame_ns && now - fg->last_frame_ns > atomic_load(&g_watchdog_ns) && g_lounge) {
        axr_log("compositor: watchdog: no frame from %s for %.0f ms", name_of(fg), (now - fg->last_frame_ns) / 1e6);
        fg->passed = false;   // it may come back, through the first-frame check again
        fg->streak = 0;
        make_foreground(g_lounge, now, "watchdog");
    }
    if (g_lounge_idle_at_ns && now >= g_lounge_idle_at_ns) {
        g_lounge_idle_at_ns = 0;
        if (g_lounge && g_fg != g_lounge && g_other != g_lounge && !g_dashboard) set_focus(g_lounge, AXR_FOCUS_VISIBLE, false);
    }
    for (int i = 0; i < MAX_SOURCES; i++)
        if (g_sources[i] && g_sources[i]->gone) source_drop(g_sources[i]);
    pthread_mutex_unlock(&g_lock);
}

// ------------------------------------------------------------------------------------- API

void axr_compositor_start(void) {
    pthread_mutex_lock(&g_lock);
    if (g_started) { pthread_mutex_unlock(&g_lock); return; }
    g_started = true;
    g_device = axr_metal_device();
    g_q = dispatch_queue_create("alvrxr.compositor", DISPATCH_QUEUE_SERIAL);
    g_listener = [[MTLSharedEventListener alloc] initWithDispatchQueue:g_q];
    g_global_fd = axr_shm_readonly_fd(axr_shm_global_fd());
    read_tune();
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, g_q);
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC), 50 * NSEC_PER_MSEC, 5 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(timer, ^{ tick(); });
    dispatch_resume(timer);
    static dispatch_source_t keep;   // the timer lives as long as the process
    keep = timer;
    (void)keep;
    pthread_mutex_unlock(&g_lock);
    axr_log("compositor: started (fade %llu ms, global region fd %d)", (unsigned long long)g_fade_ms, g_global_fd);
}

int axr_compositor_global_fd(void) { return g_global_fd; }

static int shm_region(size_t size) {
    char name[64];
    static _Atomic int n;
    snprintf(name, sizeof name, "/axr-s-%d-%d", getpid(), atomic_fetch_add(&n, 1));
    int fd = shm_open(name, O_RDWR | O_CREAT | O_EXCL, 0600);
    if (fd < 0) return -1;
    shm_unlink(name);
    if (ftruncate(fd, (off_t)size) != 0) { close(fd); return -1; }
    return fd;
}

static void source_free_failed(axr_source *s) {
    if (s->region) munmap(s->region, sizeof *s->region);
    if (s->fd >= 0) close(s->fd);
    free(s);
}

axr_source *axr_compositor_add_source(bool local, pid_t pid) {
    if (!g_started) { axr_log("compositor: add_source before start"); return NULL; }
    pthread_mutex_lock(&g_lock);
    int at = -1, live = 0;
    for (int i = 0; i < MAX_SOURCES; i++) {
        if (g_sources[i] && !g_sources[i]->gone) live++;
        if (!g_sources[i] && at < 0) at = i;
    }
    if (at < 0 || live >= MAX_SOURCES) {
        pthread_mutex_unlock(&g_lock);
        axr_log("compositor: no room for another source (%d live)", live);
        return NULL;
    }
    axr_source *s = calloc(1, sizeof *s);
    s->id = ++g_next_id;
    s->local = local;
    s->pid = pid;
    s->fd = -1;
    s->next_seq = 1;
    s->added_ns = axr_now_ns();
    uint32_t eye_w, eye_h;
    axr_stream_eye_size(&eye_w, &eye_h);
    for (int i = 0; i < AXR_SLOTS; i++) {
        s->surfaces[i] = [[IOSurface alloc] initWithProperties:@{
            IOSurfacePropertyKeyWidth : @(eye_w * 2),
            IOSurfacePropertyKeyHeight : @(eye_h),
            IOSurfacePropertyKeyBytesPerElement : @4,
            IOSurfacePropertyKeyPixelFormat : @((uint32_t)'BGRA'),
        }];
        MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm_sRGB
                                                                                     width:eye_w * 2 height:eye_h mipmapped:NO];
        d.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget;
        d.storageMode = MTLStorageModeShared;
        s->textures[i] = s->surfaces[i] ? [g_device newTextureWithDescriptor:d iosurface:(__bridge IOSurfaceRef)s->surfaces[i] plane:0] : nil;
        if (!s->textures[i]) {
            pthread_mutex_unlock(&g_lock);
            axr_log("compositor: no %ux%u IOSurface texture for a source", eye_w * 2, eye_h);
            source_free_failed(s);
            return NULL;
        }
    }
    s->frame_event = [g_device newSharedEvent];
    s->release_event = [g_device newSharedEvent];
    s->fd = shm_region(sizeof *s->region);
    void *region = s->fd >= 0 ? mmap(NULL, sizeof *s->region, PROT_READ | PROT_WRITE, MAP_SHARED, s->fd, 0) : MAP_FAILED;
    if (region == MAP_FAILED) {
        pthread_mutex_unlock(&g_lock);
        axr_log("compositor: no session region for a source");
        s->region = NULL;
        source_free_failed(s);
        return NULL;
    }
    s->region = region;
    s->region->magic = AXR_SHM_MAGIC;
    s->region->version = AXR_SHM_VERSION;
    s->region->size = sizeof *s->region;
    // Games are FOCUSED from the start (they wait for focus before drawing); so is a lounge that
    // has nothing in front of it.
    atomic_store(&s->region->focus, AXR_FOCUS_FOCUSED);
    atomic_store(&s->region->should_render, 1);
    atomic_store(&s->region->dashboard, g_dashboard);
    if (!local && pid > 0) axr_process_name(pid, s->name);
    g_sources[at] = s;
    if (!local && pid > 0) {
        s->exit_source = dispatch_source_create(DISPATCH_SOURCE_TYPE_PROC, (uintptr_t)pid, DISPATCH_PROC_EXIT, g_q);
        dispatch_source_set_event_handler(s->exit_source, ^{
            pthread_mutex_lock(&g_lock);
            source_gone(s, "process exited");
            pthread_mutex_unlock(&g_lock);
        });
        dispatch_resume(s->exit_source);
    }
    if (local) {
        s->audio = axr_audio_local_source();
        axr_source *old = g_lounge;
        g_lounge = s;
        // The lounge re-opening its slots (the stream changed) takes the old one's place.
        if (!g_fg || g_fg == old) { g_fg = s; g_fade_start_ns = 0; }
        else set_focus(s, AXR_FOCUS_VISIBLE, true);
        if (old && g_other == old) g_other = s;
        if (old && !old->gone) source_gone(old, "the lounge opened new slots");
    } else if (pid > 0) {
        // Silent until it is shown: the fade brings it up.
        s->audio = axr_audio_add_source(pid);
        axr_audio_set_gain(s->audio, 0);
    }
    axr_log("compositor: source added: %s, slots %ux%u, fd %d%s", name_of(s), eye_w * 2, eye_h, s->fd,
            s == g_fg ? ", foreground" : "");
    pthread_mutex_unlock(&g_lock);
    listen_next(s);
    return s;
}

NSArray<IOSurface *> *axr_source_slot_surfaces(axr_source *src) {
    if (!src) return nil;
    pthread_mutex_lock(&g_lock);
    NSMutableArray *a = [NSMutableArray array];
    for (int i = 0; i < AXR_SLOTS; i++) if (src->surfaces[i]) [a addObject:src->surfaces[i]];
    pthread_mutex_unlock(&g_lock);
    return a.count == AXR_SLOTS ? a : nil;
}

MTLSharedEventHandle *axr_source_frame_event(axr_source *src) {
    if (!src) return nil;
    pthread_mutex_lock(&g_lock);
    MTLSharedEventHandle *h = [src->frame_event newSharedEventHandle];
    pthread_mutex_unlock(&g_lock);
    return h;
}

MTLSharedEventHandle *axr_source_release_event(axr_source *src) {
    if (!src) return nil;
    pthread_mutex_lock(&g_lock);
    MTLSharedEventHandle *h = [src->release_event newSharedEventHandle];
    pthread_mutex_unlock(&g_lock);
    return h;
}

int axr_source_session_fd(axr_source *src) {
    if (!src) return -1;
    pthread_mutex_lock(&g_lock);
    int fd = src->fd;
    pthread_mutex_unlock(&g_lock);
    return fd;
}

// With g_lock held. The source sends no more frames; what it showed fades out.
static void source_gone(axr_source *src, const char *reason) {
    if (src->gone) return;
    src->gone = true;
    int64_t now = axr_now_ns();
    axr_log("compositor: source removed: %s, %s, after %.1f s%s", name_of(src), reason, (now - src->added_ns) / 1e9,
            src == g_fg ? " (was foreground)" : src == g_other ? " (was fading)" : "");
    if (src->exit_source) { dispatch_source_cancel(src->exit_source); src->exit_source = NULL; }
    if (src == g_lounge) g_lounge = NULL;
    if (src == g_fg) {
        if (g_lounge) make_foreground(g_lounge, now, reason);   // its last frame fades out underneath
        else { g_fg = NULL; g_other = NULL; g_fade_start_ns = 0; }
    }
    if (src->audio && src != g_other) {
        if (!src->local) axr_audio_remove_source(src->audio);
        src->audio = NULL;
    }
    if (src != g_other) {
        src->current.valid = false;
        release_update(src);
        source_drop(src);
    }
}

void axr_compositor_remove_source(axr_source *src) {
    if (!src) return;
    pthread_mutex_lock(&g_lock);
    source_gone(src, "removed");
    pthread_mutex_unlock(&g_lock);
}

void axr_compositor_stats(char *buf, size_t n) {
    buf[0] = 0;
    if (!g_started) return;
    pthread_mutex_lock(&g_lock);
    size_t at = 0;
    at += snprintf(buf + at, n - at, " | compositor: %u composed (%u dropped), listener-to-commit %.2f ms mean, %.2f max; fg %s%s%s",
                   g_stat_composed, g_stat_dropped, g_stat_composed ? g_stat_latency_sum / 1e6 / g_stat_composed : 0.0,
                   g_stat_latency_max / 1e6, name_of(g_fg), g_other ? " fading" : "", g_dashboard ? ", dashboard open" : "");
    for (int i = 0; i < MAX_SOURCES && at < n; i++) {
        axr_source *s = g_sources[i];
        if (!s) continue;
        at += snprintf(buf + at, n - at, "; %s: %u frames (%u content, %u skipped, %u unread), %s", name_of(s), s->stat_frames,
                       s->stat_content, s->stat_skipped, s->stat_unread,
                       s->region ? (atomic_load(&s->region->focus) == AXR_FOCUS_FOCUSED ? "FOCUSED" : "VISIBLE") : "gone");
        if (s->region && !atomic_load(&s->region->should_render)) at += snprintf(buf + at, n - at, " idle");
        s->stat_frames = s->stat_content = s->stat_skipped = s->stat_unread = 0;
    }
    g_stat_composed = g_stat_dropped = 0;
    g_stat_latency_sum = g_stat_latency_max = 0;
    pthread_mutex_unlock(&g_lock);
}

// ------------------------------------------------------------------------------------- dashboard API

bool axr_compositor_dashboard(pid_t *game_pid, char name[64]) {
    pthread_mutex_lock(&g_lock);
    axr_source *game = g_fg && !g_fg->local && !g_fg->gone ? g_fg : NULL;
    bool open = g_dashboard;
    *game_pid = game ? game->pid : 0;
    snprintf(name, 64, "%s", game ? game->name : "");
    pthread_mutex_unlock(&g_lock);
    return open;
}

void axr_compositor_close_dashboard(void) {
    pthread_mutex_lock(&g_lock);
    dashboard_set(false, axr_now_ns(), "the panel");
    pthread_mutex_unlock(&g_lock);
}

void axr_compositor_test_dashboard(bool open) {
    pthread_mutex_lock(&g_lock);
    dashboard_set(open, axr_now_ns(), "test");
    pthread_mutex_unlock(&g_lock);
}

// The game's runtime takes exit_request through xrRequestExitSession's states and ends the
// session, which removes the source; the lounge comes back now rather than then, so the player
// isn't left looking at a game that is winding down (or one that ignores the request: its frames
// go unread from here, as it stays `passed`).
bool axr_compositor_quit_game(void) {
    pthread_mutex_lock(&g_lock);
    axr_source *game = g_fg && !g_fg->local && !g_fg->gone ? g_fg : NULL;
    if (game) {
        int64_t now = axr_now_ns();
        if (game->region) atomic_store(&game->region->exit_request, 1);
        axr_log("compositor: quit %s (dashboard)", name_of(game));
        if (g_lounge) make_foreground(g_lounge, now, "quit");
        else dashboard_set(false, now, "quit");
    }
    pthread_mutex_unlock(&g_lock);
    return game != NULL;
}

// Trims a path, Windows or POSIX, to its last component without ".exe".
static void program_name(const char *path, char out[64]) {
    const char *last = path;
    for (const char *p = path; *p; p++)
        if (*p == '/' || *p == '\\') last = p + 1;
    snprintf(out, 64, "%s", last);
    size_t n = strlen(out);
    if (n > 4 && !strcasecmp(out + n - 4, ".exe")) out[n - 4] = 0;
}

void axr_process_name(pid_t pid, char out[64]) {
    out[0] = 0;
    // argv[0] (KERN_PROCARGS2): a Wine process puts the Windows program's path there, which is what
    // the player knows the game as; the Mach-O path would say wine64-preloader.
    int mib[3] = {CTL_KERN, KERN_PROCARGS2, pid};
    size_t len = 0;
    char *buf = NULL;
    if (sysctl(mib, 3, NULL, &len, NULL, 0) == 0 && len > sizeof(int) && (buf = malloc(len + 1)) &&
        sysctl(mib, 3, buf, &len, NULL, 0) == 0 && len > sizeof(int)) {
        buf[len] = 0;
        int argc;
        memcpy(&argc, buf, sizeof argc);
        // argc, the executable path, NUL padding, then argv[0].
        const char *p = buf + sizeof(int), *end = buf + len;
        while (p < end && *p) p++;
        while (p < end && !*p) p++;
        if (argc > 0 && p < end && *p) program_name(p, out);
    }
    free(buf);
    if (!out[0]) {
        char path[PROC_PIDPATHINFO_MAXSIZE];
        if (proc_pidpath(pid, path, sizeof path) > 0) program_name(path, out);
    }
}
