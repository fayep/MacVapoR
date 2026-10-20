# Steam games: per-game notes

Most Steam VR games need nothing beyond MacVapoR and NotProton: OpenVR games go through the shared
OpenComposite, OpenXR games through wineopenxr. This page records the ones that need something
more, and what each setting is for. Tested on an M4 Max with CrossOver Preview 27.0.0.41069 (FEX).

| Game | Steam app | Status |
| --- | --- | --- |
| The Lab | 450390 | Works, hands included. Nothing needed. |
| Battlezone (2016) | 312650 | Works. `CX_GRAPHICS_BACKEND=dxmt %command% -windowed`. |
| Elite Dangerous (Odyssey) | 359320 | Works in VR, 82–90 fps. Needs our DXMT build and a vendor ID; see below. |
| No Man's Sky | 275850 | In progress: Vulkan only, so MoltenVK rather than DXMT. |

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
