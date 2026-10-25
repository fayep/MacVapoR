# Upstream changes

MacVapoR runs on other projects' code, and some of it needed fixing. This page lists every change
we've made outside this repository: where it is, what it fixes, whether it has been sent upstream,
and what else it needs to be seen working.

That last part matters to anyone reviewing one of these changes. Several bugs only appear with the
whole stack (Wine on Apple silicon, DXMT, MoltenVK, our runtime), so testing a change against
upstream versions of everything else may well fail first somewhere else. The
[preview release](#preview-release) has all of it built and installed together.

All commits are by Faye Salwin <faye@zippysoft.com>, written with Claude Code (each carries a
`Co-Authored-By` line), except where a change is credited to someone else.

## The stack

A Windows VR game runs under [NotProton](https://github.com/NotProtonNot/NotProton): Steam's
compatibility tool for macOS, which runs it on CrossOver's Wine (11.17, with FEX for x86-64 code, so
processes are ARM64EC). D3D11 is translated to Metal by [DXMT](https://github.com/3Shain/dxmt),
Vulkan by MoltenVK. OpenXR calls cross into macOS through wineopenxr, built by NotProton, and reach
this repository's runtime, which streams to the Vision Pro through ALVR's server core. OpenVR games
go through [OpenComposite](https://gitlab.com/znixian/OpenOVR); Rift games through
[RiftLift](https://github.com/Villagers654/RiftLift).

## Changes and where they are

| Project | Where our work is | Upstream status |
| --- | --- | --- |
| SPIRV-Cross | [fayep/SPIRV-Cross `vertex-block-output-thread`](https://github.com/fayep/SPIRV-Cross/tree/vertex-block-output-thread) | [PR #2719](https://github.com/KhronosGroup/SPIRV-Cross/pull/2719), open |
| MoltenVK | No source changes: 1.4.2 rebuilt with the SPIRV-Cross fix | – |
| OpenComposite | [gitlab.com/fayep/OpenOVR](https://gitlab.com/fayep/OpenOVR) MR branches; everything together on [github.com/fayep/OpenOVR `local-render-models`](https://github.com/fayep/OpenOVR/tree/local-render-models) | [!186](https://gitlab.com/znixian/OpenOVR/-/merge_requests/186), [!187](https://gitlab.com/znixian/OpenOVR/-/merge_requests/187), [!188](https://gitlab.com/znixian/OpenOVR/-/merge_requests/188), [!189](https://gitlab.com/znixian/OpenOVR/-/merge_requests/189), open; some commits held back (below) |
| RiftLift | [fayep/RiftLift `vtable-hooks`](https://github.com/fayep/RiftLift/tree/vtable-hooks) | Not yet proposed |
| DXMT | [fayep/dxmt `thread-stack`](https://github.com/fayep/dxmt/tree/thread-stack) | DXMT doesn't accept AI-assisted PRs; to be reported as issues |
| NotProton | [fayep/NotProton `vr-runtimes`](https://github.com/fayep/NotProton/tree/vr-runtimes) | Not yet proposed |
| ALVR visionOS client | [fayep/alvr-visionos `faye/fixes`](https://github.com/fayep/alvr-visionos/tree/faye/fixes) | Not yet proposed |
| ALVR server | [`patches/`](../patches) in this repository, against 20.14.1 | Not yet proposed; to be checked against ALVR's current code first |

### SPIRV-Cross

- **`vertex-block-output-thread`**: for tessellation MoltenVK runs the vertex shader as a compute
  pass that writes its outputs to a buffer. SPIRV-Cross lowers a vertex shader's output block to a
  thread-local copy there but still treated it as buffer storage, so a store to one component became
  a `device float*` cast of a thread variable, which Metal rejects. Includes a test
  (`shaders-msl/vert/block-io-component-store.for-tess.vert`).
- **Needs**: nothing else; the test shows the bug and the fix. Seen in No Man's Sky's terrain
  shaders (the ground near the player wasn't drawn with tessellation on).

### MoltenVK

Tag `v1.4.2`, with the SPIRV-Cross fix applied to the revision it pins (`6c09849`):
`./fetchDependencies --macos --spirv-cross-root <patched checkout>`, then `make macos`. CrossOver's
own MoltenVK (1.2.10) can't be used for No Man's Sky: with it, shaders using more than 16 samplers
don't compile.

### OpenComposite

| Commit | Change | Needs to be seen | Sent as |
| --- | --- | --- | --- |
| d82b01b | Dpad bindings get parent actions in every action set, not just the first one to bind the input | Any game whose dpads are in more than one action set (No Man's Sky: sticks on foot) | !186 |
| c83ccf4 | A double-click binding counts a press once however often the action is read | A game that reads an action more than once a frame (Vertigo Remastered) | !186 |
| 1498479 | The temporary Vulkan device asks for external memory only where the device has it | A Vulkan driver without it: Wine over MoltenVK | !187 |
| c12c897 | With one GPU, a mismatched `VkPhysicalDevice` handle is a warning, not an abort | A game that submits a physical device from another of its instances (No Man's Sky under Wine) | !187 |
| 039d29f | `#include <chrono>` in XrHMD.cpp | Building with clang-cl and the MS STL | !188 |
| 7579c41 | OpenVR 2.12 and 2.15 interfaces (`IVRSystem_026` and others) | A game built with OpenVR 2.15 (No Man's Sky) | !189 |
| 73dbe20 | `IVRNotifications_002`, accepting and dropping notifications | Batman: Arkham VR | !189 |
| 3d9093f, e553f66 | Cross-compiling for Windows with clang-cl and xwin, static C/C++ runtime | Building on macOS or Linux | Held back for now |
| a11b65e | Controller render models converted on this machine | MacVapoR's PS VR2 Sense models | Held back: specific to MacVapoR |
| c68a6bd | The log stream is constructed on first use | Games whose global constructors log early (BONEWORKS) | Not ours to send: HudsonMCox's [WineVision VR](https://github.com/HudsonMCox/WineVisionVR) patch 0005 |
| 65234f4 | The D3D11 compositor reuses the view of a flipped texture | Performance with games that submit flipped textures | Not ours to send: WineVision VR patch 0007 |

Hashes are those on `local-render-models`; the MR branches carry the same changes rebased onto
upstream's `openxr`.

### RiftLift

| Commit | Change | Needs to be seen |
| --- | --- | --- |
| 1711376 | D3D methods hooked by replacing their vtable entries, not by rewriting their code with Detours; builds with clang-cl | A game whose D3D11 is ARM64EC code: DXMT under NotProton on Apple silicon (Lone Echo) |
| b949983 | Detours built unoptimised under clang, which otherwise compiles `DetourRestoreAfterWith` to a trap | Building with clang-cl |
| 92cd114 | OpenXR functions looked up again for each instance | A runtime that unloads with the first instance and loads elsewhere (Asgard's Wrath, through NotProton's wineopenxr) |
| bfbcac9 | The launcher uses a shared `Support\oculus-runtime` beside it, `riftlift.env` defaults, and `/env NAME=VALUE` | Nothing: a smoother install, one shared runtime instead of copies in each prefix. Tested with Lone Echo; not in the preview (which uses 0.11.1.2's launcher), and to be proposed after the bridge fixes |

### DXMT

Branch `thread-stack` on DXMT `50102f9`:

- **415163a**: implements `ID3D11DeviceContext1::SwapDeviceContextState`, which Lone Echo needs.
- **49ba13b**: reserves 16 MB of stack for DXMT's threads. With CrossOver's DXMT, Elite Dangerous:
  Odyssey hit a GPU timeout while loading; with this build it runs at 82–90 fps. Which change made
  the difference isn't known yet.

### NotProton

Branch `vr-runtimes` on NotProton 1.2.0 builds Proton's wineopenxr for CrossOver and connects it to
an OpenXR runtime on macOS:

- **e38f475, 98763a8**: wineopenxr built for CrossOver; the OpenXR loader finds a macOS runtime
  through `~/.config/openxr/1/active_runtime.json`.
- **ea8f058, 2fa7b11**: D3D11 games on DXMT, through a Metal session (the swapchain images are
  DXMT shared textures with keyed mutexes).
- **6928dcb**: images RiftLift acquires before `xrEnumerateSwapchainImages` are tracked, and quad
  layers' images refreshed every frame (Asgard's Wrath's title and loading screens).
- **ead98ea, 9e1b66d, aa8d489**: wineopenxr staged into a game's prefix when an OpenXR runtime is
  registered; installing it into the bridge.
- **6ecb34e, 0ed175e, 7d959e5, f077b7a**: OpenVR games: a runtime's Windows `vrclient` linked into
  the prefix, `openvrpaths.vrpath` found under CrossOver, and Steam's VR key filled without SteamVR.

### ALVR visionOS client

Branch `faye/fixes` (9 commits). The main one, **508acd9** and its follow-ups (2dfcafd, f671d5b,
1ba3de6, bf88e61, 0f16821): visionOS never gives controller input back to a full-immersive ALVR once
another window (Siri, the Mac's screen) has had focus, so the client notices the lost input and
opens a small window that closes itself, which gives it back. Also **9038e0b** (a launch crash, a
race on the world anchors), **3696716** (controller velocities in the right frames) and
**3709c79** (the right Options button as System, hand skeletons through pinches). Needs only an
ALVR server and PS VR2 Sense controllers.

### ALVR server

Patches against ALVR 20.14.1's server core, which this repository's runtime links:

- `alvr-20.14.1-dial-ipv4.patch`: a trusted client is dialled at its last address, and over IPv4
  only (the client listens on IPv4; the IPv6 addresses it advertises are link-local and can't be
  dialled).
- `alvr-20.14.1-game-audio.patch`: game audio on macOS. The real-time callback no longer waits
  for the session lock, and the sender is released when recording stops so the next connection
  can bind its socket.
- `alvr-20.14.1-no-dialogs.patch`: no dialog windows on macOS, and no panic when the dashboard's
  port is taken.
- `alvr-20.14.1-unmapped-buttons.patch`: buttons the emulated controller profile lacks (the Sense
  controllers' grip touch and right Options) are passed on, not dropped.

`opencomposite-double-press.patch` is the same change as OpenComposite's c83ccf4.

## What each game needs

| Game | Beyond MacVapoR and NotProton's runner |
| --- | --- |
| Beat Saber, The Lab, The Last Clockwinder | NotProton `vr-runtimes`, the ALVR client fixes for controller focus |
| Vertigo Remastered | + OpenComposite c83ccf4 |
| Batman: Arkham VR | + OpenComposite 73dbe20 |
| No Man's Sky | + OpenComposite d82b01b, 1498479, c12c897, 7579c41; MoltenVK with the SPIRV-Cross fix; [vkfeatures](../compat/vkfeatures) ([steam-games.md](steam-games.md#no-mans-sky)) |
| Elite Dangerous: Odyssey | + DXMT `thread-stack` |
| Lone Echo | + RiftLift 1711376, b949983, 92cd114 (the bridge), DXMT `thread-stack` ([rift-games.md](rift-games.md)) |
| Asgard's Wrath | + RiftLift 92cd114, NotProton 6928dcb |

## Not included

- The CrossOver msync leak that makes The Lab's Secret Shop run at about 1 fps is fixed by
  [Highball](https://github.com/gauthierpiarrette/highball-engine)'s patch 0014. NotProton's
  runner doesn't have it, and it isn't ours to send.
- Meta's runtime DLLs and the games themselves are never part of a release: they come from your
  own Meta account and PC.

## Preview release

[MacVapoR 0.2.0 preview](https://github.com/fayep/MacVapoR/releases/tag/v0.2.0-preview) puts all of
the above together: the app (the runtime and home scene, wineopenxr from NotProton's
`vr-runtimes`), and a components archive with OpenComposite from `local-render-models` (including
HudsonMCox's two fixes, credited, and his to submit), MoltenVK with the SPIRV-Cross fix, DXMT from
`thread-stack`, and RiftLift's OpenXR bridge from `vtable-hooks` (with RiftLift 0.11.1.2's own
launcher). Each comes with its licence, and its source is at the branch above; the archive's README
says where each goes. Built from `compositor` at 670348b.
