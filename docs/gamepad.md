# Virtual gamepad (spec, not built yet)

Status: proposed 2026-10-19. Nothing here exists in code yet.

## Why

Some games read only gamepads, joysticks, keyboard and mouse, even in VR: Elite Dangerous is the
first we hit. The controllers paired with the Vision Pro (PS VR2 Sense, or a gamepad paired with
the headset) reach the game only as OpenXR/OpenVR controller input, which those games ignore. A
gamepad connected to the Mac over Bluetooth works, but a streaming Pro Controller congests the
Mac's radio (keyboard input ~30 s late, 2026-10-19).

So: optionally present the headset's controllers to the game as one ordinary Xbox 360 controller
inside Wine, switched on and off from the dashboard.

## Behaviour

- Dashboard: a **Gamepad** button (on/off), shown when a game is in front. The choice is kept per
  game, by executable name, in `gamepad.json` in the config dir (`{"EliteDangerous64.exe": true}`),
  so a game that needs it gets it on every launch.
- On: the game sees an Xbox 360 controller (USB 045e:028e) appear, as if plugged in. Off, or the
  game's session ends, or vapord stops: it is unplugged (the device is removed, not left idle).
- While the dashboard is open the pad reports neutral (nothing pressed, sticks centred), so
  pointing at the panel never steers the game. Closing the dashboard resumes it.
- The game's OpenXR controller input is unchanged; the pad is in addition to it.

## Mapping

From the published inputs (`axr_shm.h` global `buttons[]`, the same paths the runtime reads), the
two hands' Touch-style controls:

| Headset controllers | Xbox 360 |
|---|---|
| left / right thumbstick x, y | left / right stick |
| left / right thumbstick click | L3 / R3 |
| left / right trigger value | LT / RT (0..255) |
| left / right squeeze (grip) | LB / RB (pressed above 0.5) |
| right A, B | A, B |
| left X, Y | X, Y |
| left menu | Back |
| right menu (when it isn't the system button) | Start |
| D-pad | left thumbstick direction while the left stick is touched-and-clicked? To settle when building: the Sense controllers have no D-pad. Candidate: hold left grip + left stick direction. |

A gamepad paired with the headset already arrives mapped onto these Touch controls by the ALVR
client (WorldTracker.sendGamepadInputs), so it round-trips to an Xbox pad with its own layout
(sticks to sticks, ZL/ZR to triggers, L/R to bumpers).

Haptics: XInput rumble (left low-frequency, right high-frequency motors) goes back to the
controllers through the existing haptics path (`alvr_send_haptics`), left motor to the left hand.

## Design

Two pieces: vapord publishes the pad state; a Wine HID minidriver in the game's prefix presents it.

### State file (vapord)

vapord (the compositor, SERVER mode) writes the pad's state into a small memory-mapped file,
`$TMPDIR/macvapor-gamepad` (a regular file, so Windows code in Wine can map it through `Z:`):

```c
typedef struct {
    uint32_t magic;        // 'AXGP'
    uint32_t version;      // 1
    uint32_t seq;          // seqlock: odd while writing
    uint32_t connected;    // 1: present the pad; 0: unplug it
    uint32_t game_pid;     // the foreground game it's for (host pid), 0 none
    uint16_t buttons;      // XINPUT_GAMEPAD_* bits
    uint8_t  lt, rt;       // 0..255
    int16_t  lx, ly, rx, ry;   // -32768..32767
    uint32_t packet;       // bumped on every change (XInput dwPacketNumber)
    // written by the driver, read by vapord:
    uint32_t rumble_seq;
    uint16_t rumble_low, rumble_high;   // 0..65535
} axr_gamepad_state;
```

Updated from the tracking/input thread on every input sample (the same cadence the runtime sees,
~120 Hz), and set neutral while the dashboard is open. `connected` is 1 only while the toggle is
on for the foreground game's executable.

### HID minidriver (in the prefix)

`macvapor_pad.sys`, a PE kernel driver built with mingw like DXMT, modelled on Wine's own winebus
devices: it creates one HID child device with the standard Xbox 360 report descriptor (the one
Wine's winebus uses for its SDL/iohid Xbox pads, so Wine's xinput maps it the same way), maps the
state file read-only (rumble fields read-write), and:

- reports an input report whenever `packet` changes (polled at 250 Hz on a kernel timer; no
  host-side wakeups needed);
- adds the device when `connected` turns 1 and removes it (IoInvalidateDeviceRelations) when it
  turns 0 or the file goes away;
- turns output reports (rumble) into the rumble fields.

Because it sits under Wine's hidclass, every Windows input API sees the same pad: XInput,
DirectInput, Raw Input and Windows.Gaming.Input.

Installed per prefix by `tools/notproton-vr-setup.sh` (copy to `system32/drivers`, a service key,
and a root-enumerated device), next to wineopenxr; inert unless the state file says connected.
The cleanup feature learns to remove it.

### Alternative considered

Replacing `xinput1_x.dll` alone: smaller, enough for Elite (XInput), but DirectInput / Raw Input /
WGI games would miss the pad. Not chosen.

## Testing

- Headless: tune.json `fake_press` paths drive `buttons[]`; a test reads the state file and checks
  the mapping, the dashboard-open neutral state, and connected following the toggle.
- In a prefix: a small XInput test program (XInputGetState loop) and `joy.cpl` (DirectInput) see
  one Xbox 360 controller, buttons and axes moving; unplug on toggle off.
- In the headset: Elite Dangerous flown with the Sense controllers; rumble felt.

## Open questions

- The D-pad on controllers that have none (see Mapping).
- Whether the toggle should also suppress the game's own OpenXR controller input, for games that
  read both and double up (none seen yet).
- One pad, or one per hand for twin-stick HOTAS-style setups (Elite supports two joysticks).
