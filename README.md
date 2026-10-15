# alvrxr

An OpenXR runtime for macOS that displays through ALVR: frames go to the ALVR visionOS client
on an Apple Vision Pro, and head, PS VR2 Sense controller and button input comes back. No
SteamVR and no PC. The streaming side is the one proven in ../alvr-mac-spike.

Status (2026-10-15): Khronos `hello_xr -g Metal` runs on it and shows correctly on the
headset, with controller input and haptics.

## Build and use

    ./build.sh                                  # needs ~/Source/ALVR-20.14.1 and a built OpenXR-SDK-Source
    XR_RUNTIME_JSON=$PWD/out/alvrxr.json some_openxr_app

The runtime starts ALVR's server_core inside the app's process, with its session and logs in
`~/Library/Application Support/alvrxr` (copied from the spike's on first run, so a headset
trusted there is trusted here). Runtime log: `~/Library/Logs/alvrxr.log`.

`ALVRXR_DUMP=file.h265` composes and encodes without a headset and writes the stream to the
file, for a look with a desktop decoder.

## What is there

- Instance and system, the session state machine, VIEW/LOCAL/STAGE spaces, paths.
- Metal swapchains (`XR_KHR_metal_enable`); the first stereo projection layer is composed
  straight into ALVR's foveated stream layout on the app's own queue, then HEVC-encoded.
- Each frame is tied to an ALVR tracking sample: its poses come from that sample and the
  encoded frame carries its timestamp, so the client reprojects correctly.
- Actions for the Touch (and simple) controller profiles: ALVR presents Sense controllers as
  Touch controllers and names inputs by their OpenXR paths, so bindings resolve directly.
  Pose action spaces and haptics.

## Not yet

- Vulkan swapchains (`XR_KHR_vulkan_enable`/`enable2`), which Proton's wineopenxr needs.
- The aim pose is the grip pose; the offset is not measured yet.
- Quad and other non-projection layers are ignored; depth is accepted and ignored.
- Velocities are not reported.
