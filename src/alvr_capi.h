// C view of ALVR 20.14.1 alvr/server_core/src/c_api.rs.
// Layouts follow the Rust #[repr(C)] / #[repr(u8)] definitions there; keep in step with that file.
#pragma once
#include <stdbool.h>
#include <stdint.h>

typedef struct { float left, right, up, down; } AlvrFov;
typedef struct { float x, y, z, w; } AlvrQuat;
typedef struct { AlvrQuat orientation; float position[3]; } AlvrPose;

typedef struct {
    AlvrPose pose;
    float linear_velocity[3];
    float angular_velocity[3];
} AlvrDeviceMotion;

typedef struct { uint64_t device_id; float gauge_value; bool is_plugged; } AlvrBatteryInfo;

typedef union { bool scalar; float float_; } AlvrButtonValue;   // `scalar` is the binary value
typedef struct { uint64_t id; AlvrButtonValue value; } AlvrButtonEntry;

enum {
    ALVR_EVENT_CLIENT_CONNECTED = 0,
    ALVR_EVENT_CLIENT_DISCONNECTED,
    ALVR_EVENT_BATTERY,
    ALVR_EVENT_PLAYSPACE_SYNC,
    ALVR_EVENT_VIEWS_CONFIG,
    ALVR_EVENT_TRACKING_UPDATED,
    ALVR_EVENT_BUTTONS_UPDATED,
    ALVR_EVENT_REQUEST_IDR,
    ALVR_EVENT_CAPTURE_FRAME,
    ALVR_EVENT_RESTART_PENDING,
    ALVR_EVENT_SHUTDOWN_PENDING,
    ALVR_EVENT_INTERACTION_PROFILE,   // patches/alvr-20.14.1-which-controller.patch
};

// A #[repr(u8)] enum with fields is a union of #[repr(C)] structs that each start with the tag,
// so every payload sits at its own alignment after the tag (4 or 8), not at one common offset.
typedef union {
    uint8_t tag;
    struct { uint8_t tag; AlvrBatteryInfo info; } battery;
    struct { uint8_t tag; float bounds[2]; } playspace;
    struct { uint8_t tag; AlvrPose local_view_transform[2]; AlvrFov fov[2]; } views;
    struct { uint8_t tag; uint64_t sample_timestamp_ns; } tracking;
    struct { uint8_t tag; uint64_t device_id, profile_id; } interaction_profile;
} AlvrEvent;

typedef struct {
    uint32_t game_render_width;
    uint32_t game_render_height;
    uint32_t stream_width;
    uint32_t stream_height;
} AlvrTargetConfig;

typedef struct { float bitrate_bps; float framerate; } AlvrDynamicEncoderParams;

enum { ALVR_CODEC_H264 = 0, ALVR_CODEC_HEVC = 1, ALVR_CODEC_AV1 = 2 };
enum { ALVR_HAND_LEFT = 0, ALVR_HAND_RIGHT = 1 };

uint64_t alvr_get_time_ns(void);
uint64_t alvr_path_to_id(const char *path);
void alvr_error(const char *s);
void alvr_warn(const char *s);
void alvr_info(const char *s);
uint64_t alvr_get_settings_json(char *buffer);
void alvr_initialize_environment(const char *config_dir, const char *log_dir);
void alvr_initialize_logging(const char *session_log_path, const char *crash_log_path);
AlvrTargetConfig alvr_initialize(void);
void alvr_start_connection(void);
bool alvr_poll_event(AlvrEvent *out_event, uint64_t timeout_ns);
bool alvr_get_device_motion(uint64_t device_id, uint64_t sample_timestamp_ns, AlvrDeviceMotion *out_motion);
bool alvr_get_hand_skeleton(uint8_t hand_type, uint64_t sample_timestamp_ns, AlvrPose *out_skeleton);
uint64_t alvr_get_buttons(AlvrButtonEntry *out_entries);
void alvr_send_haptics(uint64_t device_id, float duration_s, float frequency, float amplitude);
void alvr_set_video_config_nals(uint8_t codec, const uint8_t *buffer, int32_t len);
void alvr_send_video_nal(uint64_t timestamp_ns, uint8_t *buffer, int32_t len, bool is_idr);
bool alvr_get_dynamic_encoder_params(AlvrDynamicEncoderParams *out_params);
void alvr_report_composed(uint64_t timestamp_ns, uint64_t offset_ns);
void alvr_report_present(uint64_t timestamp_ns, uint64_t offset_ns);
bool alvr_duration_until_next_vsync(uint64_t *out_ns);
void alvr_restart(void);
void alvr_shutdown(void);
// From alvrxr's ALVR patch (patches/alvr-20.14.1-game-audio.patch).
void alvr_set_external_game_audio(uint32_t sample_rate);
void alvr_send_game_audio(const int16_t *samples, uint64_t frame_count);
