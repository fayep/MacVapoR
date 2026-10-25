# MacVapoR

<img src="macvapor/icon-256.png" width="128" alt="MacVapoR icon" align="right">

Play Windows PC VR games from Steam on a Mac, shown on an Apple Vision Pro. The games run
under [NotProton](https://github.com/NotProtonNot/NotProton)'s CrossOver runner; MacVapoR
gives them an OpenXR runtime, alvrxr, that streams each frame to the
[ALVR](https://apps.apple.com/app/alvr/id6479728026) app on the Vision Pro and brings head,
PS VR2 Sense controller and button input back. No PC and no SteamVR.

Game audio streams to the headset with the video. OpenXR games (Beat Saber) run directly; OpenVR (SteamVR) games such as The Lab run through
[OpenComposite](https://gitlab.com/znixian/OpenOVR), which MacVapoR downloads for you.

## What you need

- An Apple silicon Mac with macOS 15 or later. Tested so far on macOS 27, M4 Max.
- NotProton with its CrossOver runner, and the games installed through Steam under it.
- An Apple Vision Pro with ALVR from the App Store, on the same network as the Mac, and
  PS VR2 Sense controllers paired to the Vision Pro.

Tested: Beat Saber and The Lab (D3D11) with the app alone. With the 0.2.0 preview's components
(below) also No Man's Sky (Vulkan), Elite Dangerous: Odyssey and Meta Rift games. Other D3D11
games are likely to work; D3D12 games are not supported yet.

## Install

**Install [NotProton](https://github.com/NotProtonNot/NotProton) first**, and play a game through it
once, so its CrossOver runner is in place. MacVapoR builds on NotProton and does nothing without it.

1. Download the DMG from the [releases](https://github.com/fayep/MacVapoR/releases), open
   it, and drag MacVapoR to Applications. It is signed and notarized.
2. Open MacVapoR and click **Install**: the runtime goes into
   `~/Library/Application Support/MacVapoR`.
3. macOS asks whether **MacVapoR Audio** may record audio: allow it. It sends each game's sound to
   the headset, and keeps the game quiet on the Mac. MacVapoR shows whether it is allowed.

The [0.2.0 preview](https://github.com/fayep/MacVapoR/releases) also has a components archive: our
builds of OpenComposite, MoltenVK, DXMT, RiftLift's bridge and a Vulkan wrapper, which some games
need. The app doesn't install them yet; the archive's README says where each goes and which games
it's for. What we changed in each project, and where that change stands upstream, is in
[docs/upstream.md](docs/upstream.md).

## Set a game up

1. Launch the game once through NotProton, so it has a Wine prefix, and quit it.
2. In NotProton, set the game's graphics to **DXMT**.
3. In MacVapoR, find the game under **Games**, check the executable, and click **Set Up**.
   For an OpenVR game, click **Download OpenComposite** first.
4. Wake the controllers, open ALVR on the Vision Pro, and launch the game.
5. The first time, the headset appears under **Headsets**: trust it, then restart the game.

Playing seated? Under **Headsets**, choose **Seated: fixed eye height**, so standing games put your eyes
at that height instead of your real one.

**Undo** puts a game back as it was. The runtime's log is at `~/Library/Logs/alvrxr.log`.

### Clean up old setups

A newer NotProton sets VR up by itself each time a game starts, and then a game needs no
**Set Up**; an old setup even gets in its way. **Clean up old setups**, under **Games**, looks
through every game and lists what Set Up left there, each with a reason and a tick box, and
changes nothing until you click **Clean up**.

- With a NotProton that still needs the setup, only leftovers are offered: spare copies of
  `openvr_api.dll` or OpenComposite, and an `opencomposite.ini` beside the game's own
  `openvr_api.dll`. The rest is kept, and offered once NotProton is updated.
- With one that sets VR up by itself, the rest can go too: the game's own `openvr_api.dll` is put
  back, and wineopenxr and the registry values Set Up wrote are taken out. An OpenComposite build
  other than MacVapoR's, an `opencomposite.ini` with settings of your own, and DXVK in a game not
  set to DXMT are listed but not ticked, or kept.

Quit a game first; a running one is shown but can't be cleaned. A copy of each file replaced or
edited is kept beside it, ending in `.before-macvapor-cleanup`, and what was done is logged to
`~/Library/Logs/macvapor-cleanup.log`.

Games from Meta's PC store for the Rift can be played too, brought over from the PC they're
installed on: see [Meta Rift games](docs/rift-games.md). That isn't ready for everyone yet.

## Home scene

While no game is running, the headset shows a home scene: somewhere to stand, with your hands or
controllers, and a ball on a table to throw. Choose it, or turn it off, under **Home Scene** in
MacVapoR. Two come with it, Vaporwave and Studio. A scene is a folder, so you can make your own:
see [home/SCENES.md](home/SCENES.md).

## Known issues

- If visionOS takes focus away (Siri, a screenshot, the Mac's screen), the controllers'
  buttons stop working until ALVR is reopened. A fix for the ALVR app is waiting upstream.
- The controllers must be awake when ALVR connects, or their buttons may not come through.
- Loading screens hold the game's last frame, unless the compositor is on: with `"compositor": true`
  in `~/Library/Application Support/alvrxr/tune.json`, the home scene stays up while a game loads and
  cross-fades into it. The compositor is new in 0.2.0 and off by default.
- With the compositor on, the home scene has twice stopped following head movement, looking like a
  flat screen fixed in the room, both times after the headset had disconnected and reconnected. The
  cause isn't known yet. `launchctl kickstart -k gui/$(id -u)/com.zippysoft.macvapor.home`, then
  reconnecting ALVR, fixes it.
- The Lab's Secret Shop runs at about 1 fps, because of a bug in CrossOver's MSync that NotProton's
  runner still has: some waits leave entries behind in the wineserver until its pool runs out, and
  from then on it stalls the game. Highball has a fix (its patch 0014); until the runner has it,
  `WINEMSYNC=0` in the game's launch options makes it about three times faster, which is still slow.
- ALVR's "Stream refresh rate" setting limits the frame rate; set it to 120 Hz.
- Westworld Awakening (Unreal Engine 4, OpenVR 1.0.10) quits about a second after the headset
  connects; under investigation.

# alvrxr, the runtime

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
- Depth layers are accepted and ignored; layers other than projection and quad are ignored.

## Releases

`macvapor/make-release.sh` builds the runtime, NotProton's wineopenxr and the MacVapoR app for
macOS 15, signs them with a Developer ID, notarizes and staples the app and the DMG.
To sign with your own Developer ID, copy `macvapor/release.env.example` to
`macvapor/release.env` (ignored by git) and fill it in, or set `IDENTITY` and `NOTARY_PROFILE`
in the environment. Without them the build is signed ad hoc and not notarized.
`tools/notproton-vr-setup.sh` is the per-game setup MacVapoR runs, usable on its own; its
`--scan` and `--clean` are the clean-up. `tests/cleanup-check.sh` checks them on a made-up library.

MIT licence; the bundled components keep their own, see `macvapor/LICENSES/NOTICE.txt`.
