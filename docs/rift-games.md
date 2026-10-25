# Meta Rift (Oculus PC) games

Games bought from Meta's PC store for the Rift (the Oculus PC app) can be played on the Vision Pro
too. You bring them over from the Windows PC they're installed on: the game's own folder and a few
of Meta's runtime files. Nothing is downloaded from Meta, and nothing is installed for a game
until Meta confirms that your account owns it.

Under the hood, the game talks to the Rift's runtime (LibOVR) as it would on a PC.
[RiftLift](https://github.com/Villagers654/RiftLift), an Oculus-to-OpenXR bridge derived from
Revive, turns that into OpenXR, and alvrxr takes it from there, as for any other game. Each game
is added to Steam as a non-Steam game and runs through NotProton like the rest.

Two of the pieces aren't in MacVapoR's app yet: our builds of RiftLift's bridge and of DXMT, in the
[0.2.0 preview](https://github.com/fayep/MacVapoR/releases)'s components archive (step 4 below). The
rest of what's still rough is in [What's left](#whats-left) at the end.

## Tested games

| Game | Version | Notes |
| --- | --- | --- |
| Lone Echo | 3.17.4 | Plays through. The game runs at about 50 to 58 frames a second on an M4 Max; the headset fills the gaps at 90 Hz. |
| Asgard's Wrath | 1.6.0 | Title and loading screens, calibration, play. |
| Robo Recall | 1.6 | Plays through. Needs Epic's telemetry blocked (rift-add.sh does it): its uploads to the retired `datarouter.ol.epicgames.com` crashed the game's HTTP thread a few minutes in. |

Other Rift games built on the same engines (Unreal Engine 4, Unity, Ready At Dawn's) are likely
to work. Games that need Meta's online services for multiplayer won't (see [Offline](#offline)).

## What you need

- Everything from the main [README](../README.md): MacVapoR installed, NotProton with its runner,
  Steam, the Vision Pro with ALVR and the PS VR2 Sense controllers.
- The Windows PC the games are installed on through the Meta (Oculus) app, or a copy of its
  Meta library folder. The PC needn't run again afterwards.
- Your Meta account, signed in with [AVP-Play](https://github.com/myMartek/avp-play):
  `avpplay login`. MacVapoR uses that sign-in only to ask Meta whether the account owns each game.
- Room for the games: they're as big as on the PC (Asgard's Wrath is 133 GB). An external drive is
  fine.
- For now, a checkout of the MacVapoR source, for `tools/rift-add.sh`.
- The 0.2.0 preview's components archive (`MacVapoR-0.2.0-components.zip`), for its `riftlift`
  and `dxmt` folders.

## 1. Copy from the PC

Make one folder on the Mac for everything Rift, called the **Rift folder** below; for example
`/Volumes/Games/rift`.

### Meta's runtime files, once

From `C:\Program Files\Oculus\Support\oculus-runtime\` on the PC, copy these five files into
`oculus-platform` in the Rift folder:

| File | What it's for |
| --- | --- |
| `LibOVRRT64_1.dll`, `LibOVRRT32_1.dll` | The Rift runtime. Games check that it's there and signed by Meta before they start. RiftLift takes over from it, so it never runs. |
| `LibOVRPlatform64_1.dll`, `LibOVRPlatformImpl64_1.dll` | The Oculus Platform SDK, which games use for the user's name, entitlement, achievements and saves. |
| `LibOVRP2P64_1.dll` | The Platform SDK's peer-to-peer library, which it needs to load. |

### Each game

On the PC, find the game in its Meta library. The library is `C:\Program Files\Oculus` unless it
was moved; the Meta app lists its libraries under **Settings > Library**. In the library are two
folders:

- `Software\<name>\`: the game.
- `Manifests\<name>.json`: Meta's list of the game's files, with a checksum for each.

`<name>` is the game's short name, such as `ready-at-dawn-lone-echo` or
`sanzaru-games-inc-wrath`. Copy both into a folder of their own in the Rift folder, so that you
end up with:

```
rift/
  oculus-platform/
    LibOVRP2P64_1.dll  LibOVRPlatform64_1.dll  LibOVRPlatformImpl64_1.dll  LibOVRRT32_1.dll  LibOVRRT64_1.dll
  lone-echo/
    ready-at-dawn-lone-echo.json
    ready-at-dawn-lone-echo/
      ...the game's files...
```

The folder for each game can have any name. Copy any way you like: a USB drive, a network share,
or over SSH, below. Don't copy while the Meta app is updating the game. When the game is added,
every file is checked against Meta's manifest. If any differs or is missing, nothing is set up.

**Over SSH.** If the PC runs Windows' OpenSSH Server and you can `ssh` to it without a
password, `rift-add.sh --from-pc HOST` (in step 3) finds the game in the PC's Meta libraries and
copies it into the Rift folder itself. You still copy the five runtime files by hand, once.

## 2. Find the game's Meta app ID

Each Meta game has a number. It's in the game's store address
(`https://www.meta.com/experiences/pcvr/1368187813209608/` is Lone Echo) and in its manifest:

```sh
python3 -c 'import json, sys; print(json.load(open(sys.argv[1], encoding="utf-8-sig"))["appId"])' \
    /Volumes/Games/rift/lone-echo/ready-at-dawn-lone-echo.json
```

## 3. Add it

Sign in once, with the Meta account that bought the games:

```sh
avpplay login
```

Then, from the MacVapoR source folder, for each game:

```sh
RIFT_DIR=/Volumes/Games/rift tools/rift-add.sh 1368187813209608
```

It:

1. asks Meta whether your account owns the game, and stops if it doesn't;
2. checks the copied files against Meta's manifest;
3. makes the game a NotProton prefix, and sets it up for OpenXR with DXMT, as MacVapoR does for
   Steam games;
4. installs RiftLift and Meta's runtime files in the prefix, with the settings an installed Meta
   app would have;
5. fetches the game's artwork from its Meta store page;
6. adds the game to Steam as a non-Steam game, with that artwork. Steam has to be closed for this
   step: the script waits for you to quit it.

Running it again for the same game updates the same Steam entry. With more than one Meta account
in AVP-Play (`avpplay login --account NAME`), choose one with `--account NAME`.

## 4. Use our bridge, and our DXMT

`rift-add.sh` installs RiftLift 0.11.1.2. Its bridge patches D3D11's code with Detours, which corrupts
DXMT's ARM64EC code; ours hooks D3D11's vtables instead. In the game's
prefix (`rift-add.sh` prints its path), with Steam's copy of the game not running:

1. Replace `drive_c/Program Files/RiftLift/RiftLiftOpenXR64.dll` with the one from the archive's
   `riftlift` folder. RiftLift's own launcher stays as it is.
2. For Lone Echo, which needs `SwapDeviceContextState` that CrossOver's DXMT doesn't have: back up
   `d3d11.dll`, `dxgi.dll` and `d3d10core.dll` in the prefix's `drive_c/windows/system32`, and copy in
   the three from the archive's `dxmt` folder. The archive's README has the rest (the DllOverrides
   and launch option). Asgard's Wrath and Robo Recall were set up without it.

Running `rift-add.sh` again for the game puts RiftLift's own bridge back, so do this again after it.

## 5. Play

Open Steam: the game is in your library. Wake the controllers, open ALVR on the Vision Pro, and
launch the game from Steam.

- The first launch is slow, while the game's code is translated for Apple silicon. Later launches
  are quicker.
- The window on the Mac is a mirror of what you see in the headset.
- The controllers are presented to the game as Oculus Touch controllers.

## Offline

Meta's online services don't run here. RiftLift answers the game's questions about them locally:

- you're signed in, as a local user, and entitled to the game;
- achievements and cloud saves stay on the Mac;
- you have no friends online, and there's no multiplayer.

The game's own saves are in its prefix, as on a PC.

## When something goes wrong

| What happens | What to do |
| --- | --- |
| "Meta says account … does not own app …" | Sign in with the account that bought the game (`avpplay login --account NAME`, then `--account NAME`). |
| "the copy doesn't match Meta's manifest" | Copy the game again, with the Meta app on the PC closed. The output lists the files that differ. |
| "app … is not in …" | The game's folder and manifest aren't where `RIFT_DIR` points: see [Each game](#each-game). |
| The game doesn't start | NotProton's log for it is `compatdata/<shortcut ID>/notproton-run.log` in Steam's folder; `rift-add.sh` prints the shortcut ID. |
| It starts, but the headset shows nothing | The runtime's log is `~/Library/Logs/alvrxr.log`. |

## Removing a game

Remove the shortcut in Steam, then delete its prefix
(`~/Library/Application Support/Steam/steamapps/compatdata/<shortcut ID>`) and, if you like, its
folder in the Rift folder. The game's saves are in the prefix, so they go with it.

## What's left

What stands between this guide and someone else following it on their own Mac:

1. **RiftLift's bridge with vtable hooks.** RiftLift's released bridge patches D3D11's code with
   Detours, which corrupts DXMT's ARM64EC code; ours hooks the vtables instead. It's on
   [fayep/RiftLift `vtable-hooks`](https://github.com/fayep/RiftLift/tree/vtable-hooks) and in the
   0.2.0 preview's components archive, installed by hand (step 4). To do: install it with MacVapoR
   (RiftLift is MIT), and offer the change to RiftLift.
2. **DXMT with `SwapDeviceContextState`.** Lone Echo needs it, and CrossOver's DXMT lacks it. It's on
   [fayep/dxmt `thread-stack`](https://github.com/fayep/dxmt/tree/thread-stack) and in the components
   archive, installed by hand (step 4). To do: find which other games need it, install it with
   MacVapoR for those (DXMT is LGPL), and report it to DXMT, which takes issues rather than
   AI-assisted pull requests.
3. **The tools are in a source checkout, with this Mac's folders as their defaults.** To do: MacVapoR
   installs `rift-add.sh`, `rift-setup.sh`, their helpers and the builds above beside the
   runtime, and they default to those; the Rift folder has no default.
4. ~~**RiftLift's release is downloaded by hand.**~~ Done: the setup fetches RiftLift 0.11.1.2's
   `riftlift-compat.zip` itself and checks its SHA-256.
5. **The artwork tool is compiled on first use** with `swiftc`, which needs Xcode's command line
   tools. To do: ship it built.
6. **AVP-Play for the sign-in.** It has releases; check that `avpplay login` works from the
   released app, and say how to get it.
7. **Tested on one Mac and one CrossOver runner.** The DXMT build has to match the runner's
   `winemetal`. To do: try a clean prefix on NotProton's current runner, and a second Mac.
8. **Terminal only.** To do, once the rest is done: a Rift Games section in MacVapoR that does
   steps 2 and 3 for a folder you choose.
