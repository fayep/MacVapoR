// ALVR, the compositor and the encoder, and the publisher of tracking, timing and input into
// axr_shm_global for tracking.m to read. Ported from alvr-mac-spike, which has the background for
// most of what is here (README "Things that were not obvious").

#include <errno.h>
#include <fcntl.h>
#include <notify.h>
#include <os/os_sync_wait_on_address.h>
#include <signal.h>
#include <sys/mman.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <VideoToolbox/VideoToolbox.h>
#import <ImageIO/ImageIO.h>
#import <CoreGraphics/CoreGraphics.h>
#include <math.h>
#include <pthread.h>
#include <stdarg.h>
#include <time.h>

#include "alvr_capi.h"
#include "alvrxr.h"
#include "tracking.h"

// ------------------------------------------------------------------------------------- logging

static FILE *g_logfile;

void axr_log(const char *fmt, ...) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // A scratch config dir (tests) keeps its log there, out of the real one.
        NSString *dir = NSProcessInfo.processInfo.environment[@"ALVRXR_CONFIG_DIR"]
                            ?: [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Logs"];
        g_logfile = fopen([[dir stringByAppendingPathComponent:@"alvrxr.log"] fileSystemRepresentation], "a");
    });
    char msg[1024];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(msg, sizeof msg, fmt, ap);
    va_end(ap);
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    struct tm tm;
    localtime_r(&ts.tv_sec, &tm);
    char line[1100];
    snprintf(line, sizeof line, "%02d:%02d:%02d.%03ld [alvrxr %d] %s\n", tm.tm_hour, tm.tm_min, tm.tm_sec,
             ts.tv_nsec / 1000000, getpid(), msg);
    fputs(line, stderr);
    if (g_logfile) { fputs(line, g_logfile); fflush(g_logfile); }
}

int64_t axr_now_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000000000 + ts.tv_nsec;
}

// ------------------------------------------------------------------------------- session file

static NSString *g_config_dir;

static NSString *session_path(void) { return [g_config_dir stringByAppendingPathComponent:@"session.json"]; }

static NSMutableDictionary *read_session(void) {
    NSData *d = [NSData dataWithContentsOfFile:session_path()];
    if (!d) return nil;
    return [NSJSONSerialization JSONObjectWithData:d options:NSJSONReadingMutableContainers error:nil];
}

// The settings the runtime depends on, applied before server_core reads the file: HEVC, ALVR's
// fixed foveated encoding, and socket buffers Darwin accepts ("Maximum" asks for 4 GB and gets
// refused, which leaves 9 KB UDP buffers on both ends).
static void prepare_session(void) {
    NSFileManager *fm = NSFileManager.defaultManager;
    [fm createDirectoryAtPath:g_config_dir withIntermediateDirectories:YES attributes:nil error:nil];
    if (![fm fileExistsAtPath:session_path()]) {
        // Development convenience: start from the spike's session, which already trusts the headset.
        NSString *spike = [NSHomeDirectory() stringByAppendingPathComponent:
                                                 @"Library/Application Support/alvr-mac-spike/session.json"];
        if ([fm fileExistsAtPath:spike]) [fm copyItemAtPath:spike toPath:session_path() error:nil];
    }
    NSMutableDictionary *s = read_session();
    if (!s) return;   // first run: server_core writes defaults, the next start fixes them up
    NSMutableDictionary *video = s[@"session_settings"][@"video"];
    video[@"preferred_codec"][@"variant"] = @"Hevc";
    video[@"foveated_encoding"][@"enabled"] = @YES;
    // Game audio comes from MacVapoR Audio through audio.m, not a device ALVR records; without the
    // helper it is off, as ALVR would otherwise fail every handshake looking for a device.
    NSMutableDictionary *game_audio = s[@"session_settings"][@"audio"][@"game_audio"];
    game_audio[@"enabled"] = @(axr_audio_available());
    game_audio[@"content"][@"device"][@"set"] = @NO;
    NSMutableDictionary *conn = s[@"session_settings"][@"connection"];
    for (NSString *k in @[ @"server_send_buffer_bytes", @"server_recv_buffer_bytes", @"client_send_buffer_bytes",
                           @"client_recv_buffer_bytes" ]) {
        conn[k][@"variant"] = @"Custom";
        conn[k][@"Custom"] = @(4 * 1024 * 1024);
    }
    NSData *out = [NSJSONSerialization dataWithJSONObject:s options:NSJSONWritingPrettyPrinted error:nil];
    [out writeToFile:session_path() atomically:YES];
}

typedef struct {
    int codec;
    double refresh;
    bool foveated;
    float center_size[2], center_shift[2], edge_ratio[2];
    uint32_t target_w, target_h;
    // ALVR's controller offsets (its headset.controllers settings), for its SteamVR driver.
    bool controller_offsets;
    float controller_position_offset[3], controller_rotation_offset[3];   // left hand; metres, degrees
} stream_setup;

static stream_setup read_stream_setup(void) {
    stream_setup s = {.codec = ALVR_CODEC_HEVC, .refresh = 90, .edge_ratio = {1, 1}};
    NSDictionary *session = read_session();
    NSDictionary *controllers = session[@"session_settings"][@"headset"][@"controllers"];
    if ([controllers[@"enabled"] boolValue]) {
        NSArray *pos = controllers[@"content"][@"left_controller_position_offset"][@"content"];
        NSArray *rot = controllers[@"content"][@"left_controller_rotation_offset"][@"content"];
        s.controller_offsets = true;
        for (NSUInteger i = 0; i < 3; i++) {
            s.controller_position_offset[i] = i < pos.count ? [pos[i] floatValue] : 0;
            s.controller_rotation_offset[i] = i < rot.count ? [rot[i] floatValue] : 0;
        }
    }
    NSDictionary *cfg = session[@"openvr_config"];
    if (!cfg) return s;
    s.codec = [cfg[@"codec"] intValue];
    s.refresh = [cfg[@"refresh_rate"] doubleValue] ?: 90;
    s.foveated = [cfg[@"enable_foveated_encoding"] boolValue];
    s.center_size[0] = [cfg[@"foveation_center_size_x"] floatValue];
    s.center_size[1] = [cfg[@"foveation_center_size_y"] floatValue];
    s.center_shift[0] = [cfg[@"foveation_center_shift_x"] floatValue];
    s.center_shift[1] = [cfg[@"foveation_center_shift_y"] floatValue];
    s.edge_ratio[0] = [cfg[@"foveation_edge_ratio_x"] floatValue];
    s.edge_ratio[1] = [cfg[@"foveation_edge_ratio_y"] floatValue];
    s.target_w = [cfg[@"target_eye_resolution_width"] unsignedIntValue];
    s.target_h = [cfg[@"target_eye_resolution_height"] unsignedIntValue];
    return s;
}

static NSString *stream_setup_raw(void) {
    NSDictionary *cfg = read_session()[@"openvr_config"];
    if (!cfg) return @"";
    return [[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:cfg options:NSJSONWritingSortedKeys error:nil]
                                 encoding:NSUTF8StringEncoding];
}

// ------------------------------------------------------------------------------------- state

static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;
static bool g_started, g_connected, g_force_idr = true;
// The client sends placeholder views and a placeholder head pose until it has decoded a frame.
static bool g_tracking_real;
static unsigned g_samples_since_real;
static stream_setup g_setup;
static NSString *g_setup_raw;
static uint32_t g_eye_w, g_eye_h;          // stream size per eye, before foveation

// Foveation, as the client's FFR.calculateFoveationVars computes it.
typedef struct {
    float eye_size_ratio[2], center_size[2], center_shift[2], edge_ratio[2];
    uint32_t enabled;
    uint32_t pad;              // Metal rounds Ffr up to its float2 alignment
} ffr_uniform;
static ffr_uniform g_ffr;
static uint32_t g_out_w, g_out_h;          // per eye, as encoded

static uint64_t g_device_id[AXR_DEVICE_COUNT];
// ALVRXR_DUMP=file: compose and encode without a headset and write the stream there instead,
// to check the compositor with a desktop decoder.
static FILE *g_dump;
static axr_views g_views;

// Tracking samples are stamped with the client's predicted display time, in its own clock.
// g_clock_offset converts them to ours; tracking.m's frames remember which sample they took.
static uint64_t g_newest_ts;
static double g_clock_offset;
static bool g_have_offset;
static int64_t g_last_sample_ns;
// How the headset's tracking samples arrive, for the stats line: how many, the mean interval
// between their timestamps, and how many came on the heels of the one before (under a third of
// a frame) or late (over one and a half frames).
static unsigned g_stat_samples, g_stat_bunched, g_stat_late;
static bool g_velocity_check;   // see check_velocity
static bool g_pose_velocity = true;   // see record_hand_samples
static void undo_alvr_shaping(int device, AlvrDeviceMotion *am, const stream_setup *setup);
static void record_hand_samples(uint64_t ts);
static const char *input_name(uint64_t id);
static bool fit_velocity(int hand, uint64_t ts, float linear[3], float angular[3]);

// tune.json "velocity_check": true compares the right controller's reported velocities with the
// ones its poses imply, sample to sample, while it moves fast (a throw): the direction each way,
// its elevation, and the angle between them.
static void check_velocity(uint64_t ts) {
    static AlvrDeviceMotion prev;
    static uint64_t prev_ts;
    AlvrDeviceMotion m;
    if (!alvr_get_device_motion(g_device_id[AXR_RIGHT], ts, &m)) return;
    pthread_mutex_lock(&g_lock);
    stream_setup setup = g_setup;
    pthread_mutex_unlock(&g_lock);
    undo_alvr_shaping(AXR_RIGHT, &m, &setup);
    if (g_pose_velocity) fit_velocity(1, ts, m.linear_velocity, m.angular_velocity);
    double dt = prev_ts ? (ts - prev_ts) / 1e9 : 0;
    if (dt > 0.004 && dt < 0.05) {
        float d[3], r[3];
        for (int i = 0; i < 3; i++) { d[i] = (m.pose.position[i] - prev.pose.position[i]) / dt; r[i] = m.linear_velocity[i]; }
        float dn = sqrtf(d[0] * d[0] + d[1] * d[1] + d[2] * d[2]), rn = sqrtf(r[0] * r[0] + r[1] * r[1] + r[2] * r[2]);
        if (dn > 1.5f && rn > 0.01f) {
            float cosang = (d[0] * r[0] + d[1] * r[1] + d[2] * r[2]) / (dn * rn);
            // The rotation from the last pose to this one, as an angular velocity in the world frame.
            AlvrQuat a = prev.pose.orientation, b = m.pose.orientation;
            float qx = b.w * -a.x + b.x * a.w + b.y * -a.z - b.z * -a.y;
            float qy = b.w * -a.y - b.x * -a.z + b.y * a.w + b.z * -a.x;
            float qz = b.w * -a.z + b.x * -a.y - b.y * -a.x + b.z * a.w;
            float qw = b.w * a.w - b.x * -a.x - b.y * -a.y - b.z * -a.z;
            if (qw < 0) { qx = -qx; qy = -qy; qz = -qz; qw = -qw; }
            float s = sqrtf(qx * qx + qy * qy + qz * qz), angle = 2 * atan2f(s, qw);
            float w[3] = {0, 0, 0};
            if (s > 1e-6f) { w[0] = qx / s * angle / dt; w[1] = qy / s * angle / dt; w[2] = qz / s * angle / dt; }
            const float *rw = m.angular_velocity;
            float wn = sqrtf(w[0] * w[0] + w[1] * w[1] + w[2] * w[2]), rwn = sqrtf(rw[0] * rw[0] + rw[1] * rw[1] + rw[2] * rw[2]);
            float wcos = wn > 0.5f && rwn > 0.01f ? (w[0] * rw[0] + w[1] * rw[1] + w[2] * rw[2]) / (wn * rwn) : 2;
            axr_log("velocity: poses %.2f m/s at %+.0f deg up, reported %.2f m/s at %+.0f deg up, %.0f deg apart"
                    " | spin: poses %.1f rad/s, reported %.1f rad/s, %s%.0f deg apart",
                    dn, asinf(d[1] / dn) * 180 / M_PI, rn, asinf(r[1] / rn) * 180 / M_PI,
                    acosf(fmaxf(-1, fminf(1, cosang))) * 180 / M_PI, wn, rwn, wcos > 1.5f ? "(slow) " : "",
                    wcos > 1.5f ? 0 : acosf(fmaxf(-1, fminf(1, wcos))) * 180 / M_PI);
        }
    }
    prev = m;
    prev_ts = ts;
}
static uint64_t g_stat_prev_ts, g_stat_ts_span;
extern unsigned axr_stat_reused;   // tracking.m's frames that took a sample again

// Every input ALVR has reported, by id, as the header publishes them.
static struct { uint64_t id; float value; } g_buttons[AXR_MAX_BUTTONS];
static unsigned g_nbuttons;
static uint64_t g_input_generation;

// The region tracking.m reads. Only the event thread writes it once that thread exists.
static axr_shm_global *g_shm;
static int g_shm_fd = -1, g_shm_ro_fd = -1;

// Seated play: <config>/height.json {"eye_height": 1.6}, written by MacVapoR, puts the eyes at
// that height above the floor. ALVR's own recentering only runs when the client syncs its
// playspace, which the visionOS client does not do, so the runtime moves every pose itself, by
// what the first head pose of each connection says.
static float g_eye_height;
static float g_height_offset;
static bool g_height_offset_set;

static void read_eye_height(void) {
    NSData *d = [NSData dataWithContentsOfFile:[g_config_dir stringByAppendingPathComponent:@"height.json"]];
    NSDictionary *h = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
    g_eye_height = [h isKindOfClass:NSDictionary.class] ? [h[@"eye_height"] floatValue] : 0;
    if (g_eye_height > 0) axr_log("seated: eye height %.2f m", g_eye_height);
}

static int g_snapshot_request, g_snapshot_done;   // tune.json "snapshot": n saves the next frame's eye images

// --------------------------------------------------------------------------------- foveation

static void compute_foveation(void) {
    g_ffr = (ffr_uniform){.eye_size_ratio = {1, 1}, .center_size = {1, 1}, .edge_ratio = {1, 1}};
    g_out_w = g_eye_w;
    g_out_h = g_eye_h;
    if (!g_setup.foveated || g_setup.edge_ratio[0] < 1 || g_setup.edge_ratio[1] < 1) return;
    float target[2] = {g_eye_w, g_eye_h};
    for (int i = 0; i < 2; i++) {
        float two = g_setup.edge_ratio[i] * 2;
        float edge = target[i] - g_setup.center_size[i] * target[i];
        float center_aligned = 1 - ceilf(edge / two) * two / target[i];
        float edge_aligned = target[i] - center_aligned * target[i];
        float shift_aligned = ceilf(g_setup.center_shift[i] * edge_aligned / two) * two / edge_aligned;
        float optimized = (center_aligned + (1 - center_aligned) / g_setup.edge_ratio[i]) * target[i];
        float aligned = ceilf(optimized / 32) * 32;
        g_ffr.eye_size_ratio[i] = optimized / aligned;
        g_ffr.center_size[i] = center_aligned;
        g_ffr.center_shift[i] = shift_aligned;
        g_ffr.edge_ratio[i] = g_setup.edge_ratio[i];
        if (i == 0) g_out_w = aligned; else g_out_h = aligned;
    }
    g_ffr.enabled = 1;
}

// ---------------------------------------------------------------------------------- compositor

// compose.metal, embedded by build.sh as a C string.
#include "compose_metal.h"


typedef struct {
    float rect[2][4];
    uint32_t slice[2];
    ffr_uniform ffr;           // offset 40, as Metal places it
} compose_uniform;

static id<MTLDevice> g_device;
static id<MTLRenderPipelineState> g_pipeline;
static CVMetalTextureCacheRef g_texture_cache;
static CVPixelBufferPoolRef g_pool;
static VTCompressionSessionRef g_encoder;
static dispatch_queue_t g_encode_queue;
static dispatch_semaphore_t g_in_flight;
static NSMapTable<id<MTLTexture>, id<MTLTexture>> *g_array_views;
static NSMutableData *g_last_config;
_Static_assert(sizeof(compose_uniform) == 80 && __builtin_offsetof(compose_uniform, ffr) == 40, "Compose layout");
static NSMutableDictionary<NSNumber *, NSNumber *> *g_pts_to_ts;
static float g_bitrate = 30e6f;
static unsigned g_stat_frames, g_stat_bytes, g_stat_submit_calls, g_stat_not_ready;
unsigned axr_stat_wait, axr_stat_end, axr_stat_projection;
unsigned axr_stat_syncs, axr_stat_unfocused_syncs, axr_stat_pressed;   // runtime.m's input
static unsigned g_stat_button_events;
static int64_t g_stat_since;

id<MTLDevice> axr_metal_device(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{ g_device = MTLCreateSystemDefaultDevice(); });
    return g_device;
}

static void handle_encoded(CMSampleBufferRef sample) {
    int64_t pts = CMSampleBufferGetPresentationTimeStamp(sample).value;
    uint64_t ts;
    @synchronized(g_pts_to_ts) {
        ts = [g_pts_to_ts[@(pts)] unsignedLongLongValue];
        [g_pts_to_ts removeObjectForKey:@(pts)];
    }
    bool key = true;
    CFArrayRef atts = CMSampleBufferGetSampleAttachmentsArray(sample, false);
    if (atts && CFArrayGetCount(atts) > 0) {
        CFDictionaryRef a = CFArrayGetValueAtIndex(atts, 0);
        CFBooleanRef notSync = CFDictionaryGetValue(a, kCMSampleAttachmentKey_NotSync);
        if (notSync && CFBooleanGetValue(notSync)) key = false;
    }
    bool hevc = g_setup.codec == ALVR_CODEC_HEVC;
    if (key) {
        CMFormatDescriptionRef fd = CMSampleBufferGetFormatDescription(sample);
        NSMutableData *config = [NSMutableData data];
        size_t count = 0;
        for (size_t i = 0;; i++) {
            const uint8_t *p = NULL;
            size_t n = 0;
            OSStatus st = hevc ? CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(fd, i, &p, &n, &count, NULL)
                               : CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fd, i, &p, &n, &count, NULL);
            if (st != noErr || !p) break;
            [config appendBytes:"\0\0\0\1" length:4];
            [config appendBytes:p length:n];
            if (i + 1 >= count) break;
        }
        if (![config isEqualToData:g_last_config]) {
            g_last_config = config;
            if (g_dump) fwrite(config.bytes, 1, config.length, g_dump);
            else alvr_set_video_config_nals(hevc ? ALVR_CODEC_HEVC : ALVR_CODEC_H264, config.bytes, (int32_t)config.length);
        }
    }
    CMBlockBufferRef block = CMSampleBufferGetDataBuffer(sample);
    size_t total = 0;
    char *raw = NULL;
    if (!block || CMBlockBufferGetDataPointer(block, 0, NULL, &total, &raw) != noErr) return;
    // VideoToolbox writes 4-byte lengths; ALVR wants Annex B start codes in their place.
    NSMutableData *out = [NSMutableData dataWithBytes:raw length:total];
    uint8_t *b = out.mutableBytes;
    for (size_t o = 0; o + 4 <= total;) {
        size_t n = (size_t)b[o] << 24 | (size_t)b[o + 1] << 16 | (size_t)b[o + 2] << 8 | b[o + 3];
        b[o] = b[o + 1] = b[o + 2] = 0;
        b[o + 3] = 1;
        o += 4 + n;
    }
    if (g_dump) { fwrite(out.bytes, 1, out.length, g_dump); fflush(g_dump); }
    else if (ts) alvr_send_video_nal(ts, out.mutableBytes, (int32_t)out.length, key);
    g_stat_frames++;
    g_stat_bytes += total;
}

static void set_prop(CFStringRef key, CFTypeRef value) {
    OSStatus s = VTSessionSetProperty(g_encoder, key, value);
    if (s != noErr) axr_log("encoder property %s refused: %d", CFStringGetCStringPtr(key, kCFStringEncodingUTF8), (int)s);
}

// (Re)creates the pool and encoder for the current stream size. Called with g_lock held.
static void make_encoder(void) {
    if (g_encoder) {
        VTCompressionSessionCompleteFrames(g_encoder, kCMTimeInvalid);
        VTCompressionSessionInvalidate(g_encoder);
        CFRelease(g_encoder);
        g_encoder = NULL;
    }
    if (g_pool) { CFRelease(g_pool); g_pool = NULL; }
    g_last_config = nil;
    NSDictionary *attrs = @{
        (id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA),
        (id)kCVPixelBufferWidthKey : @(g_out_w * 2),
        (id)kCVPixelBufferHeightKey : @(g_out_h),
        (id)kCVPixelBufferIOSurfacePropertiesKey : @{},
        (id)kCVPixelBufferMetalCompatibilityKey : @YES,
    };
    CVPixelBufferPoolCreate(NULL, NULL, (__bridge CFDictionaryRef)attrs, &g_pool);
    bool hevc = g_setup.codec == ALVR_CODEC_HEVC;
    NSDictionary *spec = @{
        (id)kVTVideoEncoderSpecification_EnableLowLatencyRateControl : @YES,
        (id)kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder : @YES,
    };
    OSStatus st = VTCompressionSessionCreate(NULL, (int32_t)g_out_w * 2, (int32_t)g_out_h,
                                             hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264,
                                             (__bridge CFDictionaryRef)spec, NULL, NULL, NULL, NULL, &g_encoder);
    if (st != noErr) { axr_log("VTCompressionSessionCreate failed: %d", (int)st); g_encoder = NULL; return; }
    set_prop(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue);
    set_prop(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse);
    set_prop(kVTCompressionPropertyKey_ProfileLevel,
             hevc ? kVTProfileLevel_HEVC_Main_AutoLevel : kVTProfileLevel_H264_High_AutoLevel);
    set_prop(kVTCompressionPropertyKey_AverageBitRate, (__bridge CFTypeRef) @(g_bitrate));
    set_prop(kVTCompressionPropertyKey_ExpectedFrameRate, (__bridge CFTypeRef) @(g_setup.refresh));
    set_prop(kVTCompressionPropertyKey_MaxKeyFrameInterval, (__bridge CFTypeRef) @100000);
    VTCompressionSessionPrepareToEncodeFrames(g_encoder);
    g_force_idr = true;
    axr_log("encoder: %ux%u per eye%s, %s, %.0f Hz", g_out_w, g_out_h,
            g_ffr.enabled ? " (foveated)" : "", hevc ? "HEVC" : "H264", g_setup.refresh);
}

static id<MTLTexture> array_view(id<MTLTexture> t);
id<MTLTexture> axr_array_view(id<MTLTexture> t) { return array_view(t); }

static id<MTLTexture> array_view(id<MTLTexture> t) {
    if (t.textureType == MTLTextureType2DArray) return t;
    id<MTLTexture> v;
    @synchronized(g_array_views) {
        v = [g_array_views objectForKey:t];
        if (!v) {
            v = [t newTextureViewWithPixelFormat:t.pixelFormat textureType:MTLTextureType2DArray
                                          levels:NSMakeRange(0, 1) slices:NSMakeRange(0, 1)];
            [g_array_views setObject:v forKey:t];
        }
    }
    return v;
}

// Copies each eye's layer as the app submitted it and writes it as a PNG, to see what the app
// actually rendered into each layer.
static void snapshot_eyes(const axr_eye_image eyes[2], id<MTLCommandQueue> queue, int n) {
    for (int e = 0; e < 2; e++) {
        id<MTLTexture> src = eyes[e].texture;
        axr_log("snapshot %d eye %d: type %lu, %lux%lu, %lu layers, format %lu, slice %u, rect %d,%d %dx%d", n, e,
                (unsigned long)src.textureType, (unsigned long)src.width, (unsigned long)src.height,
                (unsigned long)src.arrayLength, (unsigned long)src.pixelFormat, eyes[e].slice, eyes[e].x, eyes[e].y,
                eyes[e].width, eyes[e].height);
        MTLPixelFormat fmt = src.pixelFormat;
        bool bgra = fmt == MTLPixelFormatBGRA8Unorm || fmt == MTLPixelFormatBGRA8Unorm_sRGB;
        bool rgba = fmt == MTLPixelFormatRGBA8Unorm || fmt == MTLPixelFormatRGBA8Unorm_sRGB;
        bool half = fmt == MTLPixelFormatRGBA16Float;   // linear, as Ready At Dawn's games submit
        if (!bgra && !rgba && !half) { axr_log("snapshot: format %lu not handled", (unsigned long)fmt); continue; }
        MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:fmt width:eyes[e].width
                                                                                    height:eyes[e].height mipmapped:NO];
        d.storageMode = MTLStorageModeShared;
        id<MTLTexture> dst = [src.device newTextureWithDescriptor:d];
        id<MTLCommandBuffer> cmd = [queue commandBuffer];
        id<MTLBlitCommandEncoder> blit = [cmd blitCommandEncoder];
        [blit copyFromTexture:src sourceSlice:eyes[e].slice sourceLevel:0 sourceOrigin:MTLOriginMake(eyes[e].x, eyes[e].y, 0)
                   sourceSize:MTLSizeMake(eyes[e].width, eyes[e].height, 1) toTexture:dst destinationSlice:0
             destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)];
        [blit endEncoding];
        NSString *path = [g_config_dir stringByAppendingPathComponent:[NSString stringWithFormat:@"snapshot-%d-eye%d.png", n, e]];
        [cmd addCompletedHandler:^(id<MTLCommandBuffer> _) {
            size_t w = dst.width, h = dst.height, row = w * (half ? 8 : 4);
            NSMutableData *px = [NSMutableData dataWithLength:row * h];
            [dst getBytes:px.mutableBytes bytesPerRow:row fromRegion:MTLRegionMake2D(0, 0, w, h) mipmapLevel:0];
            CGColorSpaceRef cs = CGColorSpaceCreateWithName(half ? kCGColorSpaceExtendedLinearSRGB : kCGColorSpaceSRGB);
            CGBitmapInfo info = bgra ? (kCGBitmapByteOrder32Little | kCGImageAlphaNoneSkipFirst) : (CGBitmapInfo)kCGImageAlphaNoneSkipLast;
            if (half) {
                info = kCGImageAlphaNoneSkipLast | kCGBitmapFloatComponents | kCGBitmapByteOrder16Little;
                // The brightest colour value, so an all-black image shows in the log.
                const __fp16 *v = px.bytes;
                float hi = 0;
                for (size_t i = 0; i < w * h * 4; i += 4)
                    for (int c = 0; c < 3; c++) if ((float)v[i + c] > hi) hi = (float)v[i + c];
                axr_log("snapshot %d eye %d: brightest colour value %.4f", n, e, hi);
            }
            CGContextRef ctx = CGBitmapContextCreate(px.mutableBytes, w, h, half ? 16 : 8, row, cs, info);
            CGImageRef img = CGBitmapContextCreateImage(ctx);
            CGImageDestinationRef out = CGImageDestinationCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path],
                                                                        CFSTR("public.png"), 1, NULL);
            CGImageDestinationAddImage(out, img, NULL);
            CGImageDestinationFinalize(out);
            CFRelease(out); CGImageRelease(img); CGContextRelease(ctx); CGColorSpaceRelease(cs);
            axr_log("snapshot written: %s", path.UTF8String);
        }];
        [cmd commit];
    }
}

void axr_submit(int64_t display_time, const axr_eye_image eyes[2], id<MTLCommandQueue> queue) {
    pthread_mutex_lock(&g_lock);
    int snap = g_snapshot_request > g_snapshot_done ? (g_snapshot_done = g_snapshot_request) : 0;
    pthread_mutex_unlock(&g_lock);
    if (snap) snapshot_eyes(eyes, queue, snap);

    uint64_t ts = g_dump ? (uint64_t)display_time : axr_client_ts_for(display_time);
    pthread_mutex_lock(&g_lock);
    bool ready = (g_connected || g_dump) && g_encoder && g_pool;
    // The client often sends no tracking until it has decoded a frame, so without this the
    // first frames would have no sample to carry and it would never get one. It takes ours.
    if (!ts && g_connected) ts = (uint64_t)display_time;
    g_stat_submit_calls++;
    if (!ready) g_stat_not_ready++;
    compose_uniform u = {.ffr = g_ffr};
    bool idr = g_force_idr;
    uint32_t out_w = g_out_w, out_h = g_out_h;
    pthread_mutex_unlock(&g_lock);
    if (!ready || !ts) return;

    for (int e = 0; e < 2; e++) {
        float tw = eyes[e].texture.width, th = eyes[e].texture.height;
        u.rect[e][0] = eyes[e].x / tw;
        u.rect[e][1] = eyes[e].y / th;
        u.rect[e][2] = eyes[e].width / tw;
        u.rect[e][3] = eyes[e].height / th;
        u.slice[e] = eyes[e].slice;
    }
    if (dispatch_semaphore_wait(g_in_flight, dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC)) != 0) return;

    CVPixelBufferRef pb = NULL;
    CVPixelBufferPoolCreatePixelBuffer(NULL, g_pool, &pb);
    CVMetalTextureRef cvtex = NULL;
    if (pb) CVMetalTextureCacheCreateTextureFromImage(NULL, g_texture_cache, pb, NULL, MTLPixelFormatBGRA8Unorm_sRGB,
                                                      out_w * 2, out_h, 0, &cvtex);
    id<MTLTexture> target = cvtex ? CVMetalTextureGetTexture(cvtex) : nil;
    id<MTLCommandBuffer> cmd = target ? [queue commandBuffer] : nil;
    if (!cmd) {
        if (cvtex) CFRelease(cvtex);
        if (pb) CVPixelBufferRelease(pb);
        dispatch_semaphore_signal(g_in_flight);
        return;
    }
    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = target;
    pass.colorAttachments[0].loadAction = MTLLoadActionDontCare;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLRenderCommandEncoder> enc = [cmd renderCommandEncoderWithDescriptor:pass];
    [enc setRenderPipelineState:g_pipeline];
    [enc setFragmentTexture:array_view(eyes[0].texture) atIndex:0];
    [enc setFragmentTexture:array_view(eyes[1].texture) atIndex:1];
    [enc setFragmentBytes:&u length:sizeof u atIndex:0];
    [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [enc endEncoding];
    [cmd addCompletedHandler:^(id<MTLCommandBuffer> _) {
        dispatch_async(g_encode_queue, ^{
            pthread_mutex_lock(&g_lock);
            VTCompressionSessionRef encoder = g_encoder;
            if (encoder) CFRetain(encoder);
            pthread_mutex_unlock(&g_lock);
            if (encoder) {
                alvr_report_composed(ts, 0);
                CMTime pts = CMTimeMake(axr_now_ns(), 1000000000);
                @synchronized(g_pts_to_ts) { g_pts_to_ts[@(pts.value)] = @(ts); }
                NSDictionary *props = idr ? @{(id)kVTEncodeFrameOptionKey_ForceKeyFrame : @YES} : nil;
                VTCompressionSessionEncodeFrameWithOutputHandler(
                    encoder, pb, pts, kCMTimeInvalid, (__bridge CFDictionaryRef)props, NULL,
                    ^(OSStatus status, VTEncodeInfoFlags flags, CMSampleBufferRef sample) {
                        if (status == noErr && sample) handle_encoded(sample);
                    });
                alvr_report_present(ts, 0);
                CFRelease(encoder);
            }
            CFRelease(cvtex);
            CVPixelBufferRelease(pb);
            dispatch_semaphore_signal(g_in_flight);
        });
    }];
    [cmd commit];
    if (idr) {
        pthread_mutex_lock(&g_lock);
        g_force_idr = false;
        pthread_mutex_unlock(&g_lock);
    }
}

// ------------------------------------------------------------------------------ ALVR events

static void apply_setup(void) {
    g_setup = read_stream_setup();
    g_setup_raw = stream_setup_raw();
    compute_foveation();
    make_encoder();
}

static void start_core(void) {
    AlvrTargetConfig target = alvr_initialize();
    pthread_mutex_lock(&g_lock);
    g_eye_w = target.stream_width;
    g_eye_h = target.stream_height;
    apply_setup();
    pthread_mutex_unlock(&g_lock);
    // Headless (ALVRXR_DUMP) doesn't listen for a headset, so it can run beside vapord.
    if (!g_dump) alvr_start_connection();
}

static bool finite_fov(const AlvrFov *f) {
    float v[4] = {f->left, f->right, f->up, f->down};
    for (int i = 0; i < 4; i++)
        if (!isfinite(v[i]) || fabsf(v[i]) > 1.5f) return false;
    return true;
}

static void read_tune(void);
static axr_pose from_alvr(AlvrPose p);
static void clear_samples(void);

// Bumped when the user asks to recenter: the visionOS client syncs its playspace when the Digital
// Crown is held (with "keep SteamVR center" off, its default) and expects the server to recenter.
static uint32_t g_recenter_generation;
static uint32_t g_config_gen;   // bumped when ALVR restarts (the stream, and so the eye size, may change)

// The sample ALVR has at ts, as the header's readers want it: every device's motion with ALVR's
// shaping undone, the hands' fitted velocities, and their skeletons. Each device is looked up by
// this exact ts, so ALVR's "else the next later one" never applies here: the readers do that on
// the ring (tracking.m).
static void publish_tracking_sample(uint64_t ts) {
    pthread_mutex_lock(&g_lock);
    stream_setup setup = g_setup;
    pthread_mutex_unlock(&g_lock);
    axr_shm_sample s;
    memset(&s, 0, sizeof s);
    s.ts = ts;
    for (int d = 0; d < AXR_DEVICE_COUNT; d++) {
        AlvrDeviceMotion am;
        if (!alvr_get_device_motion(g_device_id[d], ts, &am)) continue;
        undo_alvr_shaping(d, &am, &setup);
        s.dev[d].pose = from_alvr(am.pose);
        memcpy(s.dev[d].linear_velocity, am.linear_velocity, sizeof s.dev[d].linear_velocity);
        memcpy(s.dev[d].angular_velocity, am.angular_velocity, sizeof s.dev[d].angular_velocity);
        s.dev[d].valid = true;
    }
    for (int h = 0; h < 2; h++) {
        s.fit_ok[h] = fit_velocity(h, ts, s.fit_v[h], s.fit_w[h]);
        AlvrPose sk[AXR_HAND_JOINTS];
        if (!alvr_get_hand_skeleton(h, ts, sk)) continue;
        for (int i = 0; i < AXR_HAND_JOINTS; i++) s.skel[h][i] = from_alvr(sk[i]);
        s.skel_ok[h] = true;
    }
    // Seated play (read_eye_height): the first head pose of a connection sets the raise.
    pthread_mutex_lock(&g_lock);
    if (g_eye_height > 0 && !g_height_offset_set && s.dev[AXR_HEAD].valid && s.dev[AXR_HEAD].pose.position[1] > 0.3f) {
        g_height_offset = g_eye_height - s.dev[AXR_HEAD].pose.position[1];
        g_height_offset_set = true;
        axr_log("seated: head at %.2f m, raised %.2f m", s.dev[AXR_HEAD].pose.position[1], g_height_offset);
    }
    pthread_mutex_unlock(&g_lock);
    // The header's newest_ts goes first, so a reader woken by the sample sees it.
    axr_publish_state();
    axr_publish_sample(&s);
}

static void *event_thread(void *arg) {
    (void)arg;
    AlvrEvent ev;
    int64_t last_setup_check = axr_now_ns();
    for (;;) {
        if (alvr_poll_event(&ev, 2000000)) {
            switch (ev.tag) {
            case ALVR_EVENT_CLIENT_CONNECTED:
                pthread_mutex_lock(&g_lock);
                g_connected = true;
                g_height_offset_set = false;
                g_height_offset = 0;
                g_force_idr = true;
                g_have_offset = false;
                g_tracking_real = false;
                g_samples_since_real = 0;
                pthread_mutex_unlock(&g_lock);
                // ALVR starts each connection with an empty history; so does the ring.
                clear_samples();
                axr_publish_state();
                axr_log("headset connected");
                break;
            case ALVR_EVENT_PLAYSPACE_SYNC:
                g_recenter_generation++;
                axr_publish_state();
                axr_log("recenter requested");
                break;
            case ALVR_EVENT_CLIENT_DISCONNECTED:
                pthread_mutex_lock(&g_lock);
                g_connected = false;
                pthread_mutex_unlock(&g_lock);
                axr_publish_state();
                axr_log("headset disconnected");
                break;
            case ALVR_EVENT_VIEWS_CONFIG: {
                // Before its first decoded frame the client sends placeholders (zero IPD, infinite fov).
                if (!finite_fov(&ev.views.fov[0]) || !finite_fov(&ev.views.fov[1])) break;
                pthread_mutex_lock(&g_lock);
                g_tracking_real = true;
                for (int e = 0; e < 2; e++) {
                    const AlvrPose *p = &ev.views.local_view_transform[e];
                    g_views.eye_in_head[e] = (axr_pose){{p->orientation.x, p->orientation.y, p->orientation.z, p->orientation.w},
                                                        {p->position[0], p->position[1], p->position[2]}};
                    const AlvrFov *f = &ev.views.fov[e];
                    g_views.fov[e][0] = f->left; g_views.fov[e][1] = f->right;
                    g_views.fov[e][2] = f->up; g_views.fov[e][3] = f->down;
                }
                pthread_mutex_unlock(&g_lock);
                axr_publish_state();
                break;
            }
            case ALVR_EVENT_TRACKING_UPDATED: {
                uint64_t ts = ev.tracking.sample_timestamp_ns;
                double offset = (double)axr_now_ns() - (double)ts;
                pthread_mutex_lock(&g_lock);
                if (ts > g_newest_ts) g_newest_ts = ts;
                int64_t arrived = axr_now_ns(), frame = (int64_t)(1e9 / (g_setup.refresh > 0 ? g_setup.refresh : 90));
                if (g_last_sample_ns && arrived - g_last_sample_ns < frame / 3) g_stat_bunched++;
                if (g_last_sample_ns && arrived - g_last_sample_ns > frame * 3 / 2) g_stat_late++;
                if (g_stat_prev_ts && ts > g_stat_prev_ts && ts - g_stat_prev_ts < 100000000) {
                    g_stat_samples++;
                    g_stat_ts_span += ts - g_stat_prev_ts;
                }
                g_stat_prev_ts = ts;
                g_last_sample_ns = arrived;
                bool check = g_velocity_check;
                if (g_tracking_real) g_samples_since_real++;
                // Smoothed, since each sample's arrival carries network jitter.
                g_clock_offset = g_have_offset ? g_clock_offset + (offset - g_clock_offset) * 0.05 : offset;
                g_have_offset = true;
                pthread_mutex_unlock(&g_lock);
                record_hand_samples(ts);
                if (check) check_velocity(ts);
                publish_tracking_sample(ts);
                break;
            }
            case ALVR_EVENT_BUTTONS_UPDATED: {
                uint64_t n = alvr_get_buttons(NULL);
                AlvrButtonEntry entries[256];
                memset(entries, 0, sizeof entries);
                if (n > 256) n = 256;
                uint64_t got = alvr_get_buttons(entries);
                pthread_mutex_lock(&g_lock);
                g_stat_button_events++;
                for (uint64_t i = 0; i < got && i < n; i++) {
                    // The id says nothing about binary or scalar, and a bool only sets the first byte.
                    float v = entries[i].value.float_;
                    uint32_t bits;
                    memcpy(&bits, &entries[i].value, 4);
                    if (bits <= 1) v = bits ? 1.0f : 0.0f;
                    unsigned k = 0;
                    while (k < g_nbuttons && g_buttons[k].id != entries[i].id) k++;
                    if (k == g_nbuttons) {
                        if (k == AXR_MAX_BUTTONS) {
                            static bool said;
                            if (!said) axr_log("input: more than %d inputs, dropping %s", AXR_MAX_BUTTONS, input_name(entries[i].id));
                            said = true;
                            continue;
                        }
                        g_buttons[k].id = entries[i].id;
                        g_buttons[k].value = v;
                        g_nbuttons++;
                        g_input_generation++;
                        axr_log("input: first %s", input_name(entries[i].id));
                    } else if (g_buttons[k].value != v) {
                        g_buttons[k].value = v;
                        g_input_generation++;
                    }
                }
                pthread_mutex_unlock(&g_lock);
                axr_publish_state();
                break;
            }
            case ALVR_EVENT_BATTERY: {
                // Every few seconds the client sends each device's charge, 0 to 1; its controllers
                // read more than 1 until visionOS has told it theirs. Logged when it changes.
                static int last_percent[AXR_DEVICE_COUNT] = {-1, -1, -1};
                static bool last_plugged[AXR_DEVICE_COUNT];
                static const char *names[AXR_DEVICE_COUNT] = {"headset", "left controller", "right controller"};
                AlvrBatteryInfo b = ev.battery.info;
                for (int d = 0; d < AXR_DEVICE_COUNT; d++) {
                    if (b.device_id != g_device_id[d] || b.gauge_value > 1.0f) continue;
                    int percent = (int)lroundf(b.gauge_value * 100);
                    if (percent == last_percent[d] && b.is_plugged == last_plugged[d]) break;
                    last_percent[d] = percent;
                    last_plugged[d] = b.is_plugged;
                    axr_log("battery: %s %d%%%s", names[d], percent, b.is_plugged ? ", charging" : "");
                }
                break;
            }
            case ALVR_EVENT_REQUEST_IDR:
                pthread_mutex_lock(&g_lock);
                g_force_idr = true;
                pthread_mutex_unlock(&g_lock);
                break;
            default:
                break;
            }
        }

        AlvrDynamicEncoderParams p;
        if (alvr_get_dynamic_encoder_params(&p) && p.bitrate_bps > 0 && fabsf(p.bitrate_bps - g_bitrate) > g_bitrate * 0.05f) {
            pthread_mutex_lock(&g_lock);
            g_bitrate = p.bitrate_bps;
            if (g_encoder) set_prop(kVTCompressionPropertyKey_AverageBitRate, (__bridge CFTypeRef) @(g_bitrate));
            pthread_mutex_unlock(&g_lock);
        }

        int64_t now = axr_now_ns();
        if (now - last_setup_check > 1000000000) {
            last_setup_check = now;
            read_tune();
            // server_core only asks its own dashboard to restart after renegotiating, so restart
            // in place when the stream settings it saved change.
            if (![stream_setup_raw() isEqualToString:g_setup_raw]) {
                axr_log("stream settings changed, restarting ALVR into them");
                alvr_shutdown();
                pthread_mutex_lock(&g_lock);
                g_connected = false;
                pthread_mutex_unlock(&g_lock);
                start_core();
                g_config_gen++;
            }
            axr_publish_state();   // after read_tune and any restart
            if (now - g_stat_since > 5000000000LL) {
                double dt = (now - g_stat_since) / 1e9;
                uint64_t audio_frames;
                float audio_peak;
                axr_audio_stats(&audio_frames, &audio_peak);
                if (g_stat_frames || axr_stat_wait)
                    axr_log("%.0f fps, %.1f Mbps | app: %u waits, %u ends, %u projection layers, %u submits (%u not ready), %u reused samples"
                            " | headset: %.0f samples/s, every %.1f ms, %u bunched, %u late"
                            " | input: %u button events, %lu buttons seen, %u syncs (%u unfocused), %u pressed reads"
                            " | audio: %llu frames tapped, peak %.3f",
                            g_stat_frames / dt, g_stat_bytes * 8 / dt / 1e6, axr_stat_wait, axr_stat_end,
                            axr_stat_projection, g_stat_submit_calls, g_stat_not_ready, axr_stat_reused,
                            g_stat_samples / dt, g_stat_samples ? g_stat_ts_span / 1e6 / g_stat_samples : 0.0,
                            g_stat_bunched, g_stat_late, g_stat_button_events, (unsigned long)g_nbuttons, axr_stat_syncs,
                            axr_stat_unfocused_syncs, axr_stat_pressed, (unsigned long long)audio_frames,
                            audio_peak);
                g_stat_button_events = axr_stat_syncs = axr_stat_unfocused_syncs = axr_stat_pressed = 0;
                g_stat_frames = g_stat_bytes = g_stat_submit_calls = g_stat_not_ready = 0;
                axr_stat_wait = axr_stat_end = axr_stat_projection = axr_stat_reused = 0;
                pthread_mutex_lock(&g_lock);
                g_stat_samples = g_stat_bunched = g_stat_late = 0;
                g_stat_ts_span = 0;
                pthread_mutex_unlock(&g_lock);
                g_stat_since = now;
            }
        }
    }
    return NULL;
}

// MacVapoR's home scene (vapord) holds the headset between games, and a game takes it over: its
// runtime records its pid as the claim, tells vapord, and waits for vapord, and the ALVR server
// it runs, to be gone. vapord starts again, and waits out the claim, once the game has ended.
static void claim_headset(void) {
    if (getenv("ALVRXR_HOME")) return;   // vapord itself
    if (getenv("ALVRXR_DUMP")) return;   // headless: leaves the headset to whoever has it
    NSString *claim = [g_config_dir stringByAppendingPathComponent:@"claim.pid"];
    [[NSString stringWithFormat:@"%d\n", getpid()] writeToFile:claim atomically:YES encoding:NSUTF8StringEncoding error:nil];
    NSString *home = [NSString stringWithContentsOfFile:[g_config_dir stringByAppendingPathComponent:@"home.pid"]
                                               encoding:NSUTF8StringEncoding error:nil];
    pid_t pid = home.intValue;
    if (pid <= 0 || kill(pid, 0) != 0) return;
    notify_post("com.zippysoft.macvapor.claim");
    for (int i = 0; i < 60 && kill(pid, 0) == 0; i++) usleep(50000);
    axr_log("headset claimed from the home scene (pid %d)%s", pid, kill(pid, 0) == 0 ? ", which hasn't gone" : "");
}

// An input's path, for the log, from the ones a Touch controller has.
static const char *input_name(uint64_t id) {
    static const char *hands[] = {"left", "right"};
    static const char *inputs[] = {"a/click", "a/touch", "b/click", "b/touch", "x/click", "x/touch", "y/click", "y/touch",
                                   "menu/click", "system/click", "system/touch", "trigger/value", "trigger/click", "trigger/touch",
                                   "squeeze/value", "squeeze/click", "squeeze/force", "thumbstick/x", "thumbstick/y",
                                   "thumbstick/click", "thumbstick/touch", "thumbrest/touch"};
    static char name[96];
    for (int h = 0; h < 2; h++)
        for (size_t i = 0; i < sizeof inputs / sizeof inputs[0]; i++) {
            snprintf(name, sizeof name, "/user/hand/%s/input/%s", hands[h], inputs[i]);
            if (alvr_path_to_id(name) == id) return name;
        }
    snprintf(name, sizeof name, "id %#llx", (unsigned long long)id);
    return name;
}

void axr_backend_start(void) {
    pthread_mutex_lock(&g_lock);
    if (g_started) { pthread_mutex_unlock(&g_lock); return; }
    g_started = true;
    pthread_mutex_unlock(&g_lock);

    NSString *env = NSProcessInfo.processInfo.environment[@"ALVRXR_CONFIG_DIR"];
    g_config_dir = env ?: [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/alvrxr"];
    claim_headset();
    prepare_session();
    read_eye_height();
    NSString *dump = NSProcessInfo.processInfo.environment[@"ALVRXR_DUMP"];
    if (dump) g_dump = fopen(dump.fileSystemRepresentation, "wb");
    alvr_initialize_environment(g_config_dir.fileSystemRepresentation, g_config_dir.fileSystemRepresentation);
    // server_core appends forever; keep one launch back.
    NSString *session_log = [g_config_dir stringByAppendingPathComponent:@"session_log.txt"];
    NSString *old_log = [g_config_dir stringByAppendingPathComponent:@"session_log.old.txt"];
    [NSFileManager.defaultManager removeItemAtPath:old_log error:nil];
    [NSFileManager.defaultManager moveItemAtPath:session_log toPath:old_log error:nil];
    alvr_initialize_logging([[g_config_dir stringByAppendingPathComponent:@"session_log.txt"] fileSystemRepresentation],
                            [[g_config_dir stringByAppendingPathComponent:@"crash_log.txt"] fileSystemRepresentation]);

    g_device_id[AXR_HEAD] = alvr_path_to_id("/user/head");
    g_device_id[AXR_LEFT] = alvr_path_to_id("/user/hand/left");
    g_device_id[AXR_RIGHT] = alvr_path_to_id("/user/hand/right");
    g_pts_to_ts = [NSMutableDictionary dictionary];
    g_array_views = [NSMapTable weakToStrongObjectsMapTable];
    g_encode_queue = dispatch_queue_create("alvrxr.encode", DISPATCH_QUEUE_SERIAL);
    g_in_flight = dispatch_semaphore_create(2);
    // Until the headset says otherwise: the Vision Pro's view as ALVR reported it in testing.
    g_views = (axr_views){
        .eye_in_head = {{{0, 0, 0, 1}, {-0.032f, 0, 0}}, {{0, 0, 0, 1}, {0.032f, 0, 0}}},
        .fov = {{-1.06f, 0.80f, 0.88f, -0.80f}, {-0.80f, 1.06f, 0.88f, -0.80f}},
    };

    id<MTLDevice> dev = axr_metal_device();
    NSError *err = nil;
    id<MTLLibrary> lib = [dev newLibraryWithSource:@(compose_metal) options:nil error:&err];
    if (!lib) axr_log("compositor shader: %s", err.localizedDescription.UTF8String);
    MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
    pd.vertexFunction = [lib newFunctionWithName:@"vs"];
    pd.fragmentFunction = [lib newFunctionWithName:@"fs"];
    pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm_sRGB;
    g_pipeline = [dev newRenderPipelineStateWithDescriptor:pd error:&err];
    if (!g_pipeline) axr_log("compositor pipeline: %s", err.localizedDescription.UTF8String);
    CVMetalTextureCacheCreate(NULL, NULL, dev, NULL, &g_texture_cache);

    // The region the runtime's readers (tracking.m) take everything from; in-process for now, so
    // the readers get the writable mapping itself.
    axr_tracking_attach(axr_shm_create(&g_shm_fd));

    start_core();
    axr_publish_state();
    if (!g_dump) axr_audio_start();
    pthread_t t;
    pthread_create(&t, NULL, event_thread, NULL);
    pthread_detach(t);
    axr_log("started (config %s)", g_config_dir.UTF8String);
}

// ------------------------------------------------------------------------------ shared region

axr_shm_global *axr_shm_create(int *fd) {
    char name[64];
    snprintf(name, sizeof name, "/axr-%d-%llx", getpid(), (unsigned long long)axr_now_ns());
    int rw = shm_open(name, O_RDWR | O_CREAT | O_EXCL, 0600);
    if (rw < 0) { axr_log("shm_open: %s", strerror(errno)); return NULL; }
    // The read-only fd must be opened by name, so it is taken now, before the name goes.
    int ro = shm_open(name, O_RDONLY, 0);
    shm_unlink(name);
    axr_shm_global *g = NULL;
    if (ftruncate(rw, sizeof *g) == 0)
        g = mmap(NULL, sizeof *g, PROT_READ | PROT_WRITE, MAP_SHARED, rw, 0);
    if (g == MAP_FAILED || !g) {
        axr_log("shared region: %s", strerror(errno));
        close(rw);
        if (ro >= 0) close(ro);
        return NULL;
    }
    memset(g, 0, sizeof *g);
    g->magic = AXR_SHM_MAGIC;
    g->version = AXR_SHM_VERSION;
    g->size = sizeof *g;
    g_shm = g;
    g_shm_fd = rw;
    g_shm_ro_fd = ro;
    *fd = rw;
    return g;
}

int axr_shm_readonly_fd(int fd) {
    return fd == g_shm_fd && g_shm_ro_fd >= 0 ? dup(g_shm_ro_fd) : -1;
}

static void clear_samples(void) {
    if (!g_shm) return;
    for (unsigned i = 0; i < AXR_SAMPLE_RING; i++) {
        axr_seq_write_begin(&g_shm->samples[i].seq);
        g_shm->samples[i].ts = 0;
        axr_seq_write_end(&g_shm->samples[i].seq);
    }
}

void axr_publish_sample(const axr_shm_sample *s) {
    if (!g_shm) return;
    uint64_t head = atomic_load_explicit(&g_shm->sample_head, memory_order_relaxed);
    axr_shm_sample *slot = &g_shm->samples[head % AXR_SAMPLE_RING];
    axr_seq_write_begin(&slot->seq);
    // Everything after the seqlock word, which must stay odd throughout.
    size_t body = offsetof(axr_shm_sample, ts);
    memcpy((char *)slot + body, (const char *)s + body, sizeof *s - body);
    axr_seq_write_end(&slot->seq);
    atomic_store_explicit(&g_shm->sample_head, head + 1, memory_order_release);
    atomic_fetch_add_explicit(&g_shm->sample_word, 1, memory_order_release);
    os_sync_wake_by_address_all(&g_shm->sample_word, 4, OS_SYNC_WAKE_BY_ADDRESS_SHARED);
}

static axr_pose from_alvr(AlvrPose p) {
    return (axr_pose){{p.orientation.x, p.orientation.y, p.orientation.z, p.orientation.w},
                      {p.position[0], p.position[1], p.position[2]}};
}

// Testing without a headset: tune.json "fake_tpose": true holds both controllers out at shoulder
// height, and "fake_press": [paths] reads those inputs as pressed. Only while no client is connected.
static bool g_fake_tpose;
static NSSet<NSString *> *g_fake_press;
static uint64_t g_fake_press_id[AXR_MAX_FAKE_PRESS];
static unsigned g_nfake_press;

typedef struct { float x, y, z, w; } quat;
static quat qmul(quat a, quat b) {
    return (quat){a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y, a.w * b.y - a.x * b.z + a.y * b.w + a.z * b.x,
                  a.w * b.z + a.x * b.y - a.y * b.x + a.z * b.w, a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z};
}
static void qrot3(quat q, const float v[3], float out[3]) {
    quat r = qmul(qmul(q, (quat){v[0], v[1], v[2], 0}), (quat){-q.x, -q.y, -q.z, q.w});
    out[0] = r.x; out[1] = r.y; out[2] = r.z;
}

// ALVR shapes each motion for SteamVR before handing it over: a controller is moved and turned by
// its offset settings, and every angular velocity is turned into the device's own frame. This
// takes that back off, leaving the motion the headset sent: poses as tracked, velocities in the
// tracking frame.
static void undo_alvr_shaping(int device, AlvrDeviceMotion *am, const stream_setup *setup) {
    quat q = {am->pose.orientation.x, am->pose.orientation.y, am->pose.orientation.z, am->pose.orientation.w};
    float w[3];
    qrot3(q, am->angular_velocity, w);
    memcpy(am->angular_velocity, w, sizeof w);
    if (device == AXR_HEAD || !setup->controller_offsets) return;
    float sign = device == AXR_RIGHT ? -1 : 1;
    const float *r = setup->controller_rotation_offset;
    float t[3] = {sign * setup->controller_position_offset[0], setup->controller_position_offset[1],
                  setup->controller_position_offset[2]};
    float d = (float)M_PI / 360;   // half a degree in radians: half-angles
    quat rx = {sinf(r[0] * d), 0, 0, cosf(r[0] * d)}, ry = {0, sinf(sign * r[1] * d), 0, cosf(sign * r[1] * d)},
         rz = {0, 0, sinf(sign * r[2] * d), cosf(sign * r[2] * d)};
    quat rot = qmul(qmul(rx, ry), rz);
    float arm[3];
    qrot3(q, t, arm);
    for (int i = 0; i < 3; i++) am->pose.position[i] -= arm[i];
    am->linear_velocity[0] -= w[1] * arm[2] - w[2] * arm[1];
    am->linear_velocity[1] -= w[2] * arm[0] - w[0] * arm[2];
    am->linear_velocity[2] -= w[0] * arm[1] - w[1] * arm[0];
    quat orig = qmul(q, (quat){-rot.x, -rot.y, -rot.z, rot.w});
    am->pose.orientation = (AlvrQuat){orig.x, orig.y, orig.z, orig.w};
}

// Controller velocities from the tracked poses. The headset's own are damped to a third or less
// of the real speed (visionOS's, for PS VR2 Sense), which threw everything short, so each hand
// keeps its last poses and its velocities are fitted over the newest VELOCITY_WINDOW: linear by
// least squares through the positions, angular from the turn between the first and last.
// tune.json "pose_velocity": false hands on the headset's instead.
#define VELOCITY_RING 16
#define VELOCITY_WINDOW 40000000   // ns
typedef struct {
    uint64_t ts;
    float p[3];
    quat q;
    float v[3], w[3];
} hand_sample;
static hand_sample g_hand_samples[2][VELOCITY_RING];
static unsigned g_hand_next[2];

static void record_hand_samples(uint64_t ts) {
    pthread_mutex_lock(&g_lock);
    stream_setup setup = g_setup;
    pthread_mutex_unlock(&g_lock);
    for (int h = 0; h < 2; h++) {
        int device = h ? AXR_RIGHT : AXR_LEFT;
        AlvrDeviceMotion am;
        if (!alvr_get_device_motion(g_device_id[device], ts, &am)) continue;
        undo_alvr_shaping(device, &am, &setup);
        hand_sample s = {.ts = ts, .q = {am.pose.orientation.x, am.pose.orientation.y, am.pose.orientation.z,
                                         am.pose.orientation.w}};
        memcpy(s.p, am.pose.position, sizeof s.p);

        pthread_mutex_lock(&g_lock);
        hand_sample *ring = g_hand_samples[h];
        const hand_sample *prev = &ring[(g_hand_next[h] + VELOCITY_RING - 1) % VELOCITY_RING];
        if (prev->ts >= ts) { pthread_mutex_unlock(&g_lock); continue; }
        // The window: this sample and those before it within VELOCITY_WINDOW.
        const hand_sample *win[VELOCITY_RING];
        int n = 0;
        win[n++] = &s;
        for (unsigned k = 1; k < VELOCITY_RING; k++) {
            const hand_sample *o = &ring[(g_hand_next[h] + VELOCITY_RING - k) % VELOCITY_RING];
            if (!o->ts || ts - o->ts > VELOCITY_WINDOW) break;
            win[n++] = o;
        }
        if (n >= 2) {
            double tm = 0;
            for (int i = 0; i < n; i++) tm += (double)(int64_t)(win[i]->ts - ts) / 1e9;
            tm /= n;
            for (int a = 0; a < 3; a++) {
                double pm = 0, num = 0, den = 0;
                for (int i = 0; i < n; i++) pm += win[i]->p[a];
                pm /= n;
                for (int i = 0; i < n; i++) {
                    double dt = (double)(int64_t)(win[i]->ts - ts) / 1e9 - tm;
                    num += dt * (win[i]->p[a] - pm);
                    den += dt * dt;
                }
                s.v[a] = den > 0 ? (float)(num / den) : 0;
            }
            const hand_sample *first = win[n - 1];
            quat a = first->q, d = qmul(s.q, (quat){-a.x, -a.y, -a.z, a.w});
            if (d.w < 0) d = (quat){-d.x, -d.y, -d.z, -d.w};
            float sn = sqrtf(d.x * d.x + d.y * d.y + d.z * d.z), span = (float)((ts - first->ts) / 1e9);
            float rate = sn > 1e-6f && span > 0 ? 2 * atan2f(sn, d.w) / span / sn : 0;
            s.w[0] = d.x * rate; s.w[1] = d.y * rate; s.w[2] = d.z * rate;
        }
        ring[g_hand_next[h] % VELOCITY_RING] = s;
        g_hand_next[h] = (g_hand_next[h] + 1) % VELOCITY_RING;
        pthread_mutex_unlock(&g_lock);
    }
}

// The fitted velocities for a hand's sample at ts; false (leaving them) for a sample not
// recorded. tune.json "pose_velocity" is the readers' to apply (axr_shm_global.pose_velocity).
static bool fit_velocity(int hand, uint64_t ts, float linear[3], float angular[3]) {
    bool found = false;
    pthread_mutex_lock(&g_lock);
    for (unsigned k = 0; k < VELOCITY_RING && !found; k++) {
        const hand_sample *s = &g_hand_samples[hand][k];
        if (s->ts != ts) continue;
        memcpy(linear, s->v, sizeof s->v);
        memcpy(angular, s->w, sizeof s->w);
        found = true;
    }
    pthread_mutex_unlock(&g_lock);
    return found;
}

// Stereo tuning, read from <config>/tune.json while running: {"ipd_scale":1, "fov_scale":1,
// "swap_eyes":false}. For finding which of the client's view numbers the picture disagrees with.
static float g_ipd_scale = 1, g_fov_scale = 1;
static float g_aim_rotation[3] = {-45, 0, 0}, g_aim_offset[3];   // pitch, yaw, roll in degrees; metres

// The aim pose in the controller's (grip) frame (alvrxr.h axr_aim_offset). With g_lock held.
static axr_pose aim_offset(int hand) {
    float d = (float)M_PI / 360, m = hand == AXR_LEFT ? -1 : 1;   // the left hand mirrors yaw, roll and x
    quat rx = {sinf(g_aim_rotation[0] * d), 0, 0, cosf(g_aim_rotation[0] * d)};
    quat ry = {0, sinf(m * g_aim_rotation[1] * d), 0, cosf(m * g_aim_rotation[1] * d)};
    quat rz = {0, 0, sinf(m * g_aim_rotation[2] * d), cosf(m * g_aim_rotation[2] * d)};
    quat q = qmul(qmul(ry, rx), rz);
    return (axr_pose){{q.x, q.y, q.z, q.w}, {m * g_aim_offset[0], g_aim_offset[1], g_aim_offset[2]}};
}
static bool g_swap_eyes;

static void read_tune(void) {
    NSData *d = [NSData dataWithContentsOfFile:[g_config_dir stringByAppendingPathComponent:@"tune.json"]];
    NSDictionary *t = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
    float ipd = t[@"ipd_scale"] ? [t[@"ipd_scale"] floatValue] : 1, fov = t[@"fov_scale"] ? [t[@"fov_scale"] floatValue] : 1;
    bool swap = [t[@"swap_eyes"] boolValue];
    int snap = [t[@"snapshot"] intValue];
    bool tpose = [t[@"fake_tpose"] boolValue];
    // Touch's aim points 45 degrees below the PS VR2 Sense grip ALVR reports: measured by hand, in
    // Asgard's Wrath.
    float aim_rotation[3] = {t[@"aim_pitch"] ? [t[@"aim_pitch"] floatValue] : -45, [t[@"aim_yaw"] floatValue],
                             [t[@"aim_roll"] floatValue]};
    float aim_offset[3] = {0, 0, 0};
    NSArray *ao = [t[@"aim_offset"] isKindOfClass:NSArray.class] ? t[@"aim_offset"] : nil;
    for (NSUInteger i = 0; i < 3 && i < ao.count; i++) aim_offset[i] = [ao[i] floatValue];
    pthread_mutex_lock(&g_lock);
    if (memcmp(aim_rotation, g_aim_rotation, sizeof aim_rotation) || memcmp(aim_offset, g_aim_offset, sizeof aim_offset)) {
        memcpy(g_aim_rotation, aim_rotation, sizeof aim_rotation);
        memcpy(g_aim_offset, aim_offset, sizeof aim_offset);
        axr_log("aim: pitch %.1f, yaw %.1f, roll %.1f deg, offset (%.3f, %.3f, %.3f) m from the grip (right hand)",
                aim_rotation[0], aim_rotation[1], aim_rotation[2], aim_offset[0], aim_offset[1], aim_offset[2]);
    }
    pthread_mutex_unlock(&g_lock);
    bool velocity_check = [t[@"velocity_check"] boolValue];
    bool pose_vel = t[@"pose_velocity"] ? [t[@"pose_velocity"] boolValue] : true;
    pthread_mutex_lock(&g_lock);
    if (pose_vel != g_pose_velocity) axr_log("controller velocities from %s", pose_vel ? "the poses" : "the headset");
    g_pose_velocity = pose_vel;
    pthread_mutex_unlock(&g_lock);
    if (velocity_check != g_velocity_check) axr_log("velocity check %s", velocity_check ? "on" : "off");
    g_velocity_check = velocity_check;
    NSArray *press = [t[@"fake_press"] isKindOfClass:NSArray.class] ? t[@"fake_press"] : @[];
    pthread_mutex_lock(&g_lock);
    NSSet *pressed = [NSSet setWithArray:press];
    if (tpose != g_fake_tpose || ![pressed isEqualToSet:g_fake_press ?: [NSSet set]]) {
        g_fake_tpose = tpose;
        g_fake_press = pressed;
        g_nfake_press = 0;
        for (NSString *path in pressed) {
            if (g_nfake_press == AXR_MAX_FAKE_PRESS) break;
            if ([path isKindOfClass:NSString.class]) g_fake_press_id[g_nfake_press++] = alvr_path_to_id(path.UTF8String);
        }
        g_input_generation++;
        axr_log("fake input: tpose %d, pressed %s", tpose, [[press componentsJoinedByString:@" "] UTF8String]);
    }
    g_snapshot_request = snap;
    bool changed = ipd != g_ipd_scale || fov != g_fov_scale || swap != g_swap_eyes;
    g_ipd_scale = ipd; g_fov_scale = fov; g_swap_eyes = swap;
    pthread_mutex_unlock(&g_lock);
    if (changed) axr_log("tune: ipd x%.3f, fov x%.3f%s", ipd, fov, swap ? ", eyes swapped" : "");
}

// The client's views with the stereo tuning applied. With g_lock held.
static axr_views current_views(void) {
    axr_views v = g_views;
    float ipd = g_ipd_scale, fov = g_fov_scale;
    bool swap = g_swap_eyes;
    for (int e = 0; e < 2; e++) {
        for (int k = 0; k < 3; k++) v.eye_in_head[e].position[k] *= ipd;
        for (int k = 0; k < 4; k++) v.fov[e][k] = atanf(tanf(v.fov[e][k]) * fov);
    }
    if (swap) {
        axr_pose p = v.eye_in_head[0]; v.eye_in_head[0] = v.eye_in_head[1]; v.eye_in_head[1] = p;
        float f[4]; memcpy(f, v.fov[0], sizeof f); memcpy(v.fov[0], v.fov[1], sizeof f); memcpy(v.fov[1], f, sizeof f);
    }
    return v;
}

// ------------------------------------------------------------------------------- publishing

// Everything in the header, from the server's state in one go, so readers see a consistent set.
void axr_publish_state(void) {
    axr_shm_global *g = g_shm;
    if (!g) return;
    pthread_mutex_lock(&g_lock);
    axr_seq_write_begin(&g->seq);
    g->connected = g_connected;
    // Samples queued before the first decoded frame still carry the placeholder pose.
    g->tracking_real = g_tracking_real && g_samples_since_real > 45;
    g->have_offset = g_have_offset;
    g->fake_tpose = g_fake_tpose;
    g->pose_velocity = g_pose_velocity;
    g->height_offset_set = g_height_offset_set;
    g->swap_eyes = g_swap_eyes;
    g->newest_ts = g_newest_ts;
    g->clock_offset = g_clock_offset;
    g->last_sample_ns = g_last_sample_ns;
    g->refresh_hz = g_setup.refresh > 0 ? g_setup.refresh : 90;
    // The stream's size, as the field says; the size games should render at (openvr_config's
    // target, which axr_recommended_eye_size used to prefer) has no field of its own yet.
    g->eye_w = g_eye_w;
    g->render_w = g_setup.target_w;
    g->render_h = g_setup.target_h;
    g->eye_h = g_eye_h;
    g->config_gen = g_config_gen;
    g->recenter_gen = g_recenter_generation;
    g->views = current_views();
    g->aim[0] = aim_offset(AXR_LEFT);
    g->aim[1] = aim_offset(AXR_RIGHT);
    g->height_offset = g_height_offset;
    g->eye_height = g_eye_height;
    g->input_gen = g_input_generation;
    g->nbuttons = g_nbuttons;
    for (unsigned i = 0; i < g_nbuttons; i++) {
        g->buttons[i].id = g_buttons[i].id;
        g->buttons[i].value = g_buttons[i].value;
    }
    g->nfake_press = g_nfake_press;
    memcpy(g->fake_press, g_fake_press_id, sizeof g->fake_press);
    axr_seq_write_end(&g->seq);
    pthread_mutex_unlock(&g_lock);
}

void axr_haptics(int hand, float duration_s, float frequency, float amplitude) {
    if (hand != AXR_LEFT && hand != AXR_RIGHT) return;
    alvr_send_haptics(g_device_id[hand], duration_s, frequency, amplitude);
}
