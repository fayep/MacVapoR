# alvrxr

An OpenXR runtime for macOS that displays through ALVR: frames go to the ALVR visionOS client
on an Apple Vision Pro, and head, PS VR2 Sense controller and button input comes back. No
SteamVR and no PC. The streaming side is the one proven in ../alvr-mac-spike.

Status (2026-10-15): Khronos `hello_xr` runs on it and shows correctly on the headset with
Metal and with Vulkan (both `XR_KHR_vulkan_enable` and `enable2`, through MoltenVK), with
controller input and haptics. The Windows build of hello_xr (D3D11) also runs on it under
NotProton's CrossOver runner, through Proton's wineopenxr (patched for CrossOver) and DXVK;
`tools/wine-hello.sh` sets that up in a test prefix of its own.

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
- Vulkan swapchains (`XR_KHR_vulkan_enable`, `enable2`): images are made on the app's own
  VkDevice and MoltenVK exports the MTLTexture behind each (`VK_EXT_metal_objects`), so the
  Metal compositor samples them, on the MTLCommandQueue behind the app's VkQueue. Vulkan is
  called through the library that owns the app's handles: the loader for a native app,
  MoltenVK itself under CrossOver, whose Wine loads it without a loader. There Wine only lets a
  Windows app enable extensions it can wrap, so VK_EXT_metal_objects is out of reach and the
  textures and queue come from MoltenVK's own exports (vkGetMTLTextureMVK and friends).
- Metal swapchains (`XR_KHR_metal_enable`); the first stereo projection layer is composed
  straight into ALVR's foveated stream layout on the app's own queue, then HEVC-encoded.
- Each frame is tied to an ALVR tracking sample: its poses come from that sample and the
  encoded frame carries its timestamp, so the client reprojects correctly.
- Actions for the Touch (and simple) controller profiles: ALVR presents Sense controllers as
  Touch controllers and names inputs by their OpenXR paths, so bindings resolve directly.
  Pose action spaces and haptics.

## Not yet

- `hello_xr -g Vulkan` behind the Homebrew loader needs `VK_DRIVER_FILES` pointing at a copy of
  MoltenVK's manifest without `is_portability_driver`, since that app does not ask for
  portability drivers. (`-g Vulkan2` is fine: the runtime creates the instance and asks.)
- The aim pose is the grip pose; the offset is not measured yet.
- Quad and other non-projection layers are ignored; depth is accepted and ignored.
- Velocities are not reported.
