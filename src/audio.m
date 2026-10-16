// Game audio for ALVR. macOS cannot record an output device the way ALVR's loopback capture
// expects, so the runtime taps its own process, the game's, whose audio Wine plays from
// in-process, and puts the tap in a private aggregate device that ALVR records as its game
// audio device (see prepare_session). While the tap is read the Mac's own output is muted.

#import <CoreAudio/AudioHardware.h>
#import <CoreAudio/AudioHardwareTapping.h>
#import <CoreAudio/CATapDescription.h>
#import <Foundation/Foundation.h>
#include <unistd.h>

#include "alvrxr.h"

static AudioObjectID g_tap = kAudioObjectUnknown;
static AudioObjectID g_aggregate = kAudioObjectUnknown;
static dispatch_source_t g_retry;

static AudioObjectID own_process_object(void) {
    AudioObjectPropertyAddress a = {kAudioHardwarePropertyTranslatePIDToProcessObject, kAudioObjectPropertyScopeGlobal,
                                    kAudioObjectPropertyElementMain};
    pid_t pid = getpid();
    AudioObjectID object = kAudioObjectUnknown;
    UInt32 size = sizeof(object);
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, sizeof(pid), &pid, &size, &object) != noErr)
        return kAudioObjectUnknown;
    return object;
}

static NSString *default_output_uid(void) {
    AudioObjectPropertyAddress a = {kAudioHardwarePropertyDefaultSystemOutputDevice, kAudioObjectPropertyScopeGlobal,
                                    kAudioObjectPropertyElementMain};
    AudioObjectID device = kAudioObjectUnknown;
    UInt32 size = sizeof(device);
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, 0, NULL, &size, &device) != noErr) return nil;
    a.mSelector = kAudioDevicePropertyDeviceUID;
    CFStringRef uid = NULL;
    size = sizeof(uid);
    if (AudioObjectGetPropertyData(device, &a, 0, NULL, &size, &uid) != noErr) return nil;
    return (__bridge_transfer NSString *)uid;
}

// The game's process only exists for Core Audio once it has opened audio, which may be after
// the runtime starts.
static bool try_tap(void) {
    AudioObjectID process = own_process_object();
    if (process == kAudioObjectUnknown) return false;

    CATapDescription *tap = [[CATapDescription alloc] initStereoMixdownOfProcesses:@[ @(process) ]];
    tap.name = @AXR_GAME_AUDIO_DEVICE;
    tap.privateTap = YES;
    tap.muteBehavior = CATapMutedWhenTapped;
    OSStatus st = AudioHardwareCreateProcessTap(tap, &g_tap);
    if (st != noErr) {
        axr_log("audio: could not tap the game's audio (%d)", (int)st);
        return true;
    }

    NSString *output = default_output_uid();
    NSMutableDictionary *agg = [@{
        @kAudioAggregateDeviceNameKey : @AXR_GAME_AUDIO_DEVICE,
        @kAudioAggregateDeviceUIDKey : [NSUUID UUID].UUIDString,
        @kAudioAggregateDeviceIsPrivateKey : @YES,
        @kAudioAggregateDeviceTapAutoStartKey : @YES,
        @kAudioAggregateDeviceTapListKey : @[ @{
            @kAudioSubTapUIDKey : tap.UUID.UUIDString,
            @kAudioSubTapDriftCompensationKey : @YES,
        } ],
    } mutableCopy];
    // ALVR looks its device up among output devices, so the aggregate carries the Mac's output.
    if (output) {
        agg[@kAudioAggregateDeviceMainSubDeviceKey] = output;
        agg[@kAudioAggregateDeviceSubDeviceListKey] = @[ @{@kAudioSubDeviceUIDKey : output} ];
    }
    st = AudioHardwareCreateAggregateDevice((__bridge CFDictionaryRef)agg, &g_aggregate);
    if (st != noErr) {
        axr_log("audio: could not make the game audio device (%d)", (int)st);
        AudioHardwareDestroyProcessTap(g_tap);
        g_tap = kAudioObjectUnknown;
        return true;
    }
    axr_log("audio: game audio tapped for ALVR (process object %u)", process);
    return true;
}

void axr_audio_start(void) {
    if (try_tap()) return;
    g_retry = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    dispatch_source_set_timer(g_retry, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), 2 * NSEC_PER_SEC,
                              NSEC_PER_SEC / 2);
    dispatch_source_set_event_handler(g_retry, ^{
        if (try_tap()) dispatch_source_cancel(g_retry);
    });
    dispatch_resume(g_retry);
}
