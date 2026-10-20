# Steam games: per-game notes

Most Steam VR games need nothing beyond MacVapoR and NotProton: OpenVR games go through the shared
OpenComposite, OpenXR games through wineopenxr. This page records the ones that need something
more, and what each setting is for. Tested on an M4 Max with CrossOver Preview 27.0.0.41069 (FEX).

| Game | Steam app | Status |
| --- | --- | --- |
| The Lab | 450390 | Works, hands included. Nothing needed. |
| Battlezone (2016) | 312650 | Works. `CX_GRAPHICS_BACKEND=dxmt %command% -windowed`. |
| Elite Dangerous (Odyssey) | 359320 | Works in VR, 82–90 fps. Needs our DXMT build and a vendor ID; see below. |
| No Man's Sky | 275850 | Works in VR, hands and sticks included, about 20 fps. Needs MoltenVK 1.4, a Vulkan wrapper and Terrain Tessellation off; see below. |

## Elite Dangerous

Frontier's launcher (`EDLaunch.exe`, .NET Framework, WPF) works under CrossOver: it signs in
through Steam. Start it with Steam's VR option; it passes `/VR` on.

**Pick Odyssey in the launcher**, not the Combat Tutorial. The tutorial is a separate 32-bit build
whose only VR support is LibOVR 0.4.3 (the 2014 Rift DK2 SDK), which nothing here speaks.

Launch options:

```
WINEMSYNC=1 CX_GRAPHICS_BACKEND=dxmt DXMT_CONFIG="dxgi.customVendorId=10de;dxgi.customDeviceId=2684" %command%
```

- `DXMT_CONFIG`: DXMT reports Apple's PCI vendor ID (0x106B); Elite stops with "no 3D graphics
  adapter" for a vendor it doesn't know. This makes the adapter description say NVIDIA (an RTX
  4090's IDs); rendering is unchanged.

**Our DXMT build, not CrossOver's.** With CrossOver's DXMT, Odyssey hit a GPU timeout at about
frame 609 (`kIOGPUCommandBufferCallbackErrorTimeout`, then every submission ignored), so it never
got past loading. Our build (DXMT `50102f9` plus `SwapDeviceContextState` and 16 MB thread stacks:
`~/Source/dxmt` branch `thread-stack`, `49ba13b`) gets through and runs at 82–90 fps. Which upstream
change made the difference isn't known yet; CrossOver's is older. Installed for
`EliteDangerous64.exe` alone, as Lone Echo's is ([rift-games.md](rift-games.md)): the three DLLs
from `install-arm64ec/aarch64-windows` with their "Wine builtin DLL" marker cleared, copied to the
prefix's `system32`, and `HKCU\Software\Wine\AppDefaults\EliteDangerous64.exe\DllOverrides`
`d3d11`, `dxgi`, `d3d10core` = `native`. CrossOver's originals are kept in the prefix's
`dxmt-builtin-backup` (`steamapps/compatdata/359320/` in the library Elite is installed in).

**Controls.** Elite reads no VR controllers, only HOTAS, gamepads, keyboard and mouse, as on a PC.
A gamepad has to be connected to the Mac (a USB cable is best). Over Bluetooth, turn it off after
playing: a Switch Pro Controller left connected kept streaming and congested the Mac's radio, and
the Magic Keyboard's input arrived about 30 seconds late. A way to use the headset's controllers as
a gamepad is specified in [gamepad.md](gamepad.md).

## No Man's Sky

NMS on Windows renders with Vulkan only, so it runs on MoltenVK (Vulkan on Metal), not DXMT.
Three things were needed (2026-10-19):

**MoltenVK 1.4, not CrossOver's 1.2.10.** With 1.2.10 shaders using more than 16 samplers fail to
compile ("'sampler' attribute parameter is out of bounds"): its texture-buffer alignment emulation
switches argument buffers off. MoltenVK 1.4.2 (Homebrew's) doesn't. NotProton has one runner for
every game, so NMS gets its own: the runner cloned (`cp -cR`, an APFS clone) to
`runners/crossover-27.0.0.41069-fex-mvk14` with Homebrew's `libMoltenVK.dylib` in
`CrossOver/lib/aarch64`, and its `share/wine/wine.inf` given the original's modification time
(`touch -r`, else NotProton takes the prefix for another Wine's). A line in NotProton's tool list
(`~/Library/Application Support/notproton/tools`):

```
notproton-mvk14	27.0.0.41069-fex-mvk14	fex	CrossOver 2026 10 06-ARM64 - FEX + MoltenVK 1.4
```

makes NotProton create that compatibility tool at Steam's start (it deletes unlisted
`notproton*` folders). NMS's Compatibility setting is that tool, and the prefix's record
(`compatdata/275850/notproton-build`, build and display name) names its build. Opening the
NotProton app may rewrite the tool list. Environment variables don't reach MoltenVK: NotProton
passes only its allowlist (no `MVK_`, no `DYLD_`), and the prefix's registry environment reaches
Windows code only.

**A Vulkan wrapper** ([compat/vkfeatures](../compat/vkfeatures)): a `vulkan-1.dll` in NMS's
`Binaries` folder (NMS's own Khronos loader kept as `vulkan-1.dll.khronos`), loaded with
`HKCU\Software\Wine\AppDefaults\NMS.exe\DllOverrides` `vulkan-1` = `native,builtin`. It reports
`wideLines` (NMS refuses to start without; Metal has only one-pixel lines, which it then draws),
drops requested features the device lacks, clamps line widths, hides `VK_KHR_push_descriptor`,
raises the reported sampler limits (MoltenVK says 16 a stage, Metal's fixed slots, though with
argument buffers NMS's shaders use more and run; the wrapper reports the sampled-image limits,
256 a stage and 1280 a set, so NMS's "not enough per-stage descriptor samplers" warning is gone),
and attaches a debug messenger (MoltenVK log level via `VK_EXT_layer_settings`) so MoltenVK's
errors appear in `notproton-wine.log` as `vkfeatures:` lines.

**Terrain Tessellation at its lowest** (Options, Graphics). With tessellation MoltenVK runs the
vertex shader as a compute pass, and its shader translator (SPIRV-Cross) then casts the stage
output to `device float*` ("C-style cast ... converts between mismatching address spaces"): about
6,000 terrain pipelines fail and the ground near the player isn't drawn. A SPIRV-Cross fix would
bring tessellation back.

**VR**: `GAMEDATA/opencomposite.ini` with `initUsingVulkan=true` (OpenComposite reads its ini
from the game's working directory, which for NMS is `GAMEDATA`, not `Binaries`), and OpenComposite
`local-render-models` from `d82b01b`: its temporary Vulkan device no longer needs Windows external
memory (`1498479`), a mismatched physical device on a one-GPU Mac isn't fatal (`c12c897`), and
dpad bindings work in every action set (`d82b01b`; before it the sticks' snap turning and
teleporting worked in menus only). The runtime's `3988cde` puts each hand on its own controller.
