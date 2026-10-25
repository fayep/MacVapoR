// The runtime's private OpenXR functions for MacVapoR's home scene (vapord), got with
// xrGetInstanceProcAddr. They work only in vapord's own session in SERVER mode (the compositor);
// elsewhere they return XR_ERROR_FUNCTION_UNSUPPORTED. See docs/compositor.md, "Dashboard".
#pragma once
#include <stdint.h>
#include <openxr/openxr.h>

#define AXR_NAME_MAX 64

typedef struct {
    uint32_t open;                    // the dashboard is open: vapord draws the panel, not the scene
    uint32_t game_pid;                // the foreground game's process, 0 with none
    char game_name[AXR_NAME_MAX];     // its executable's name, "" with none
    float battery[3];                 // headset, left, right controller: 0..1, or -1 unknown
    uint32_t charging[3];
    float fps, mbps;                  // the stream, over the last stats period
    float eye_height;                 // the seated eye height in use, 0 when standing (no offset)
    float height_offset;              // metres added to tracked heights now
    uint32_t loading;                 // a game is loading behind the lounge: vapord shows "Loading"
    char loading_name[AXR_NAME_MAX];  // its executable's name
    uint32_t joycon[2];               // left, right: the client says that hand holds a Joy-Con
} XrDashboardStateALVRXR;

// The dashboard's state. vapord polls it each frame.
typedef XrResult (XRAPI_PTR *PFN_xrGetDashboardStateALVRXR)(XrSession session, XrDashboardStateALVRXR *state);
// Closes the dashboard (as pressing the system button again does).
typedef XrResult (XRAPI_PTR *PFN_xrCloseDashboardALVRXR)(XrSession session);
// Ends the foreground game's session (it gets STOPPING, as if it had asked to exit) and fades
// back to the lounge; closes the dashboard.
typedef XrResult (XRAPI_PTR *PFN_xrQuitGameALVRXR)(XrSession session);
// Recenters, as holding the Digital Crown does.
typedef XrResult (XRAPI_PTR *PFN_xrRecenterALVRXR)(XrSession session);
// Seated play: puts the eyes at eye_height metres from where the head is now, live, for every
// session, and saves it to height.json. 0 = standing: tracked heights as they are.
typedef XrResult (XRAPI_PTR *PFN_xrSetEyeHeightALVRXR)(XrSession session, float eye_height);
