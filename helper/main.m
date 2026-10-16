// MacVapoR Audio: taps a game's audio for the runtime inside it, so that the audio recording
// permission is this app's, asked once, rather than each game's. Launched through Launch Services,
// so macOS holds it responsible for itself.
//
//   MacVapoR Audio --check STATUS_FILE      tap briefly, which asks for the permission the first
//                                           time, and write "allowed" or "denied" to STATUS_FILE
//   MacVapoR Audio --pid PID                tap process PID into the shared ring until it exits;
//                                           the game is muted on the Mac meanwhile

#import <CoreAudio/AudioHardware.h>
#import <CoreAudio/AudioHardwareTapping.h>
#import <CoreAudio/CATapDescription.h>
#import <Foundation/Foundation.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <unistd.h>

#include "audio_ring.h"

static AudioObjectID process_object(pid_t pid) {
    AudioObjectPropertyAddress a = {kAudioHardwarePropertyTranslatePIDToProcessObject, kAudioObjectPropertyScopeGlobal,
                                    kAudioObjectPropertyElementMain};
    AudioObjectID object = kAudioObjectUnknown;
    UInt32 size = sizeof object;
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, sizeof pid, &pid, &size, &object) != noErr)
        return kAudioObjectUnknown;
    return object;
}

static NSString *default_output_uid(void) {
    AudioObjectPropertyAddress a = {kAudioHardwarePropertyDefaultSystemOutputDevice, kAudioObjectPropertyScopeGlobal,
                                    kAudioObjectPropertyElementMain};
    AudioObjectID device = kAudioObjectUnknown;
    UInt32 size = sizeof device;
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, 0, NULL, &size, &device) != noErr) return nil;
    a.mSelector = kAudioDevicePropertyDeviceUID;
    CFStringRef uid = NULL;
    size = sizeof uid;
    if (AudioObjectGetPropertyData(device, &a, 0, NULL, &size, &uid) != noErr) return nil;
    return (__bridge_transfer NSString *)uid;
}

// A tap in a private aggregate device, read by block. Returns the device, or 0.
static AudioObjectID start_tap(CATapDescription *tap, AudioDeviceIOProcID *proc, Float64 *rate,
                               AudioDeviceIOBlock block) {
    tap.UUID = [NSUUID UUID];
    tap.privateTap = YES;
    AudioObjectID tap_id = kAudioObjectUnknown;
    if (AudioHardwareCreateProcessTap(tap, &tap_id) != noErr) return 0;
    NSString *output = default_output_uid();
    NSMutableDictionary *agg = [@{
        @kAudioAggregateDeviceNameKey : @"MacVapoR Audio",
        @kAudioAggregateDeviceUIDKey : [NSUUID UUID].UUIDString,
        @kAudioAggregateDeviceIsPrivateKey : @YES,
        @kAudioAggregateDeviceTapAutoStartKey : @YES,
        @kAudioAggregateDeviceTapListKey :
            @[ @{@kAudioSubTapUIDKey : tap.UUID.UUIDString, @kAudioSubTapDriftCompensationKey : @YES} ],
    } mutableCopy];
    if (output) {
        agg[@kAudioAggregateDeviceMainSubDeviceKey] = output;
        agg[@kAudioAggregateDeviceSubDeviceListKey] = @[ @{@kAudioSubDeviceUIDKey : output} ];
    }
    AudioObjectID device = kAudioObjectUnknown;
    if (AudioHardwareCreateAggregateDevice((__bridge CFDictionaryRef)agg, &device) != noErr) return 0;
    AudioObjectPropertyAddress a = {kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal,
                                    kAudioObjectPropertyElementMain};
    UInt32 size = sizeof *rate;
    AudioObjectGetPropertyData(device, &a, 0, NULL, &size, rate);
    if (AudioDeviceCreateIOProcIDWithBlock(proc, device, NULL, block) != noErr) return 0;
    if (AudioDeviceStart(device, *proc) != noErr) return 0;
    return device;
}

static int check(NSString *status_file) {
    // Any tap asks; the whole system's audio, unmuted, for a moment.
    __block _Atomic uint64_t frames = 0;
    AudioDeviceIOProcID proc;
    Float64 rate = 0;
    CATapDescription *tap = [[CATapDescription alloc] initStereoGlobalTapButExcludeProcesses:@[]];
    tap.muteBehavior = CATapUnmuted;
    AudioObjectID device = start_tap(tap, &proc, &rate,
                                     ^(const AudioTimeStamp *now, const AudioBufferList *in, const AudioTimeStamp *it,
                                       AudioBufferList *out, const AudioTimeStamp *ot) {
                                         if (in && in->mNumberBuffers) atomic_fetch_add(&frames, 1);
                                     });
    // The first time, macOS asks, and no audio comes until it is answered.
    for (int i = 0; device && i < 600 && atomic_load(&frames) == 0; i++) usleep(100000);
    BOOL allowed = atomic_load(&frames) > 0;
    [(allowed ? @"allowed" : @"denied") writeToFile:status_file atomically:YES encoding:NSUTF8StringEncoding error:nil];
    return allowed ? 0 : 3;
}

static int tap_game(pid_t pid) {
    char name[64];
    snprintf(name, sizeof name, AXR_AUDIO_RING_NAME_FORMAT, pid);
    int fd = shm_open(name, O_RDWR);
    if (fd < 0) return 4;
    axr_audio_ring *ring = mmap(NULL, sizeof *ring, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    close(fd);
    if (ring == MAP_FAILED) return 4;

    dispatch_source_t exit_watch =
        dispatch_source_create(DISPATCH_SOURCE_TYPE_PROC, pid, DISPATCH_PROC_EXIT, dispatch_get_main_queue());
    dispatch_source_set_event_handler(exit_watch, ^{ exit(0); });
    dispatch_resume(exit_watch);
    if (kill(pid, 0) != 0) return 0;

    // The game is only known to Core Audio once it has opened audio.
    __block AudioObjectID device = 0;
    __block AudioDeviceIOProcID proc;
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(timer, DISPATCH_TIME_NOW, NSEC_PER_SEC / 2, NSEC_PER_SEC / 10);
    dispatch_source_set_event_handler(timer, ^{
        atomic_fetch_add(&ring->helper_alive, 1);
        if (device) return;
        AudioObjectID process = process_object(pid);
        if (process == kAudioObjectUnknown) return;
        Float64 rate = 0;
        CATapDescription *tap = [[CATapDescription alloc] initStereoMixdownOfProcesses:@[ @(process) ]];
        tap.muteBehavior = CATapMutedWhenTapped;
        device = start_tap(tap, &proc, &rate,
                           ^(const AudioTimeStamp *now, const AudioBufferList *in, const AudioTimeStamp *it,
                             AudioBufferList *out, const AudioTimeStamp *ot) {
                               if (!in || !in->mNumberBuffers) return;
                               const AudioBuffer *b = &in->mBuffers[0];
                               const float *x = b->mData;
                               UInt32 channels = b->mNumberChannels ?: 1;
                               UInt32 n = b->mDataByteSize / sizeof(float) / channels;
                               uint64_t w = atomic_load_explicit(&ring->written, memory_order_relaxed);
                               for (UInt32 i = 0; x && i < n; i++) {
                                   float *f = ring->frames[(w + i) % AXR_AUDIO_RING_FRAMES];
                                   f[0] = x[i * channels];
                                   f[1] = x[i * channels + (channels > 1)];
                               }
                               atomic_store_explicit(&ring->written, w + n, memory_order_release);
                           });
        if (device) atomic_store(&ring->sample_rate, (uint32_t)rate);
    });
    dispatch_resume(timer);
    dispatch_main();
}

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc == 3 && !strcmp(argv[1], "--check")) return check(@(argv[2]));
        if (argc == 3 && !strcmp(argv[1], "--pid")) return tap_game(atoi(argv[2]));
        fprintf(stderr, "usage: MacVapoR Audio --check STATUS_FILE | --pid PID\n");
        return 2;
    }
}
