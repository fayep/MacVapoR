# The compositor

vapord runs all the time and owns the one ALVR connection, the encoder, tracking, input and
headset audio. The lounge (vapord's own scene) and each game are **sources** that draw frames
for it; vapord blends them into the stream, so starting or quitting a game is a cross-fade and
the headset never disconnects. This replaces the handover where a game's runtime started its
own ALVR server and vapord exited (`claim_headset`, backend.m), which left the headset without a
stream for 5–25 s.

Until it is proven it is opt-in (`tune.json "compositor": true`), and the known-good runtime
stays installable: `tools/runtime-switch.sh legacy` (tag `known-good-2026-10-19`).

## Modes (compositor.h)

| Mode | Who | ALVR server | Frames go |
|---|---|---|---|
| LEGACY | everything, without the flag; Vulkan sessions; clients that can't reach vapord | in-process | encoded in-process, as at the tag |
| SERVER | vapord with the flag | in-process, never exits | compositor in-process |
| CLIENT | games with the flag | none | IOSurface slots → vapord |

Chosen at the first `xrGetSystem` (not `xrCreateInstance`: OpenComposite creates and destroys
instances to probe for a headset, and those must not hand anything over). A CLIENT still links
libalvr_server_core for LEGACY fallback but never calls `alvr_initialize`. It calls
`alvr_path_to_id` for input paths, which is a pure function: `alvr_common::hash_string`
(common/src/version.rs), the standard library's `DefaultHasher::new()` (SipHash-1-3 with fixed
keys) over the string, touching no server state, so it needs neither `alvr_initialize` nor
`alvr_initialize_environment`, and the same dylib gives every process the same ids. tracking.m
relies on this: the ids in the header (`buttons`, `fake_press`) are matched against it.

How it starts (runtime.m `start_for_mode`, slots.m `axr_mode_init`). Without the flag ALVR still
starts at `xrCreateInstance`, as at the tag. With it, `xrGetSystem` decides: SERVER starts ALVR,
then `axr_compositor_start` and the XPC listener (`axr_transport_start`); a CLIENT's `hello`
there maps the global region and attaches tracking, and its session is opened lazily, by
`axr_slots_open` at `xrCreateSession`. The graphics API isn't known at `xrGetSystem`, so a Vulkan
`xrCreateSession` in a CLIENT calls `axr_mode_force_legacy` (drops the connection, detaches
tracking) and starts ALVR then: the game runs LEGACY. vapord reads the same flag itself and,
with it, neither waits out claims nor exits on one. `ALVRXR_COMPOSITOR_SERVICE` overrides the
Mach service name, for tests.

## Shared memory (axr_shm.h)

Two kinds of region, created by vapord with `shm_open` + `shm_unlink` and passed as fds.

- **Global** (`axr_shm_global`): vapord's ALVR event thread is the only writer; everyone maps it
  read-only (vapord's lounge reads its own through the same code). Header under a seqlock;
  tracking samples in a 128-entry ring, each slot with its own seqlock.
- **Session** (`axr_shm_session`), one per source: focus/should_render/closing written by the
  compositor; heartbeat and frame descriptors written by the source's runtime.

Rules:
1. One writer per field, as marked in axr_shm.h.
2. Readers copy fields out between `axr_seq_read_begin` and `axr_seq_read_ok` and retry on
   failure. Never keep a pointer into a region across that, never follow pointers stored in it.
3. Sample ring: the writer fills `samples[head % RING]` under that slot's seqlock, then stores
   `sample_head = head + 1` (release), then increments `sample_word` and calls
   `os_sync_wake_by_address_all(&sample_word, 4, OS_SYNC_WAKE_BY_ADDRESS_SHARED)`. Readers wait
   with `os_sync_wait_on_address_with_timeout(..., OS_SYNC_WAIT_ON_ADDRESS_SHARED, ...)`. This
   replaces `g_sample_cond`.
4. Bump `config_gen` whenever eye size or the stream changes (ALVR restart in the event thread);
   sessions re-open their slots when `axr_slots_stale()`.

## Behaviour that must not change (tracking.m vs backend.m at the tag)

- `axr_wait_frame`: same steady cadence (`1e9/refresh` from the session's last wait, restart from
  now if behind), then wait up to `period/4` for a sample newer than the last frame's, then
  `display = newest_ts + clock_offset` (or `last_wait + 2*period` with no tracking), strictly
  rising; records `{display, ts}` in the session's 32-entry ring.
- `axr_device_motion(device, time)`: ts = the frame ring's nearest entry, else `time - offset`.
  Look the sample up as ALVR's `get_device_motion` does (exact ts, else the smallest later one).
  Hands: on an exact hit with `pose_velocity`, the fitted velocities replace the headset's.
  Seated height offset added to y (set by the server the first time a head sample has y > 0.3).
  Fallbacks: head (0, 1.6, 0) when not connected; T-pose with `fake_tpose` and no client.
- `axr_hand_joints`: exact ts of the frame, else the newest; plus the height offset.
- `axr_current_views`: with ipd/fov scale and eye swap applied (the server publishes them applied).
- `axr_input`: values by id, fake presses while not connected; `axr_input_generation` bumps on
  any change (and on fake input changes).
- The 5 s stats line keeps its fields; in SERVER mode it covers all sources, labelled.

## Frames (runtime side)

Each session composes every frame into one of `AXR_SLOTS` (3) output slots: one texture,
`2*eye_w × eye_h`, `MTLPixelFormatBGRA8Unorm_sRGB` (IOSurface `'BGRA'`), left eye in the left
half. `end_frame` (runtime.m) runs today's `compose_layers` into it for projection + quads (one
target, a viewport per eye), or a plain copy when there are no quads. Game swapchain textures
never leave the game's process, so formats, depth, DXMT shared images and wineopenxr's fences
(runtime.m) are unaffected.

Per frame, seq = 1, 2, 3, …:
1. `axr_slot_begin`: slot = seq % 3; encode a GPU wait for `releaseEvent >= seq - 3` (the slot's
   previous frame has been let go); return its texture.
2. The runtime encodes its composition into it on the same command buffer.
3. `axr_slot_end`: write `frames[seq % 8]` (slot, flags, display time, client_ts from
   `axr_client_ts_for`, head pose), store `frame_head = seq` (release), encode
   `signalEvent:frameEvent value:seq`. The caller commits.

The descriptor is written on the CPU before the GPU can signal, so whoever sees the event
value can read it. The GPU wait in step 1 doesn't hold the CPU back, so a runtime running
ahead could overwrite `frames[seq % 8]` before it is read: `axr_slot_begin` also waits on the
CPU (`waitUntilSignaledValue: seq - 8`, bounded to 100 ms) before reusing a descriptor, and the
compositor checks `desc.seq == seq` and skips a frame whose descriptor has moved on.

## Frames (compositor side)

- vapord registers `notifyListener:atValue:` on each source's frameEvent for the next seq. When
  it fires it reads the descriptor; that frame becomes the source's **current** frame. vapord
  never encodes a GPU wait on a client's event: a hung game must not stall the lounge.
- `releaseEvent = R` means every frame with seq ≤ R is released. vapord raises R when a frame
  stops being current and no in-flight compose command buffer reads it (from their completion
  handlers), or straight away for a frame it skips.
- **The foreground source drives encoding**: when its frame arrives, vapord composes the
  foreground frame with the other source's current frame (`alpha` = the fade), applies FFR, and
  encodes exactly as `axr_submit` did (`alvr_report_composed`, VideoToolbox, `alvr_send_video_nal`
  with the driving frame's `client_ts`). At most 2 in flight, as now.
- The non-driving frame is older, so it is reprojected for rotation: its descriptor's head pose
  versus the driving frame's. Nothing is ever shown head-locked.

## Handover

- A game becomes foreground at its first frame with `AXR_FRAME_HAS_CONTENT`, after 2 in a row
  each within 2 refresh periods of the last. Optional: `tune.json "handover_luma"` waits for a
  frame that isn't black.
- Fade: alpha 0 → 1 over `tune.json "fade_ms"` (400), blended in linear light, FFR after.
- The lounge's focus goes FOCUSED → VISIBLE when the fade starts (it stops taking input), and
  `should_render = 0` 2 s after alpha reaches 1 (it idles). The game is FOCUSED from
  `xrBeginSession` as now (games wait for focus before drawing).
- Fade back to the lounge on: XPC connection invalidated, the game's process exiting
  (`DISPATCH_SOURCE_TYPE_PROC`), `closeSession`, or no frame for `tune.json "watchdog_ms"`
  (1500). The lounge's `should_render = 1` and focus FOCUSED at once; the game's last frame fades
  out, reprojected. After the watchdog the game stays FOCUSED and the lounge VISIBLE: a stalled game
  is usually loading, and told it lost focus Unreal's Oculus games drop to a few frames a second
  and never pass the first-frame check again. It comes back through that check.
- Loading: while a connected game is not in front and not (or, after the watchdog, no longer)
  through the first-frame check, a second after it connected, `XrDashboardStateALVRXR.loading`
  says so with its name, and vapord shows a "Loading…" panel (chrome Brush Script) ahead of the
  head, world-locked, until the game fades in or goes.
- Several games: the newest to pass the first-frame check is foreground; others are VISIBLE and
  their frames are released unread. At most 4 sources.

## Audio

vapord calls `alvr_set_external_game_audio` once. For each source it launches MacVapoR Audio
for that pid (from the XPC connection, `processIdentifier`) and reads its ring; the mixer sums
the rings with equal-power gains following the fade, in 10 ms blocks, into one
`alvr_send_game_audio` stream. The lounge's ring is vapord's own.

## XPC (axr_ipc.h)

Mach service `com.zippysoft.macvapor.compositor`, in vapord's launchd agent (`MachServices`;
tools/home-agent.sh and MacVapoR.swift both write the plist). NSXPC: `hello`, `openSession`,
`closeSession`, `haptics`. Calls happen off the render thread; `hello` gives up after ~1.5 s and
the runtime runs LEGACY. If vapord goes away mid-game, the session's `closing` is set (or the
connection invalidates): the runtime retries `hello` for 2 s after launchd restarts vapord and
re-opens its session, else reports `XR_SESSION_STATE_LOSS_PENDING`.

## Testing without a headset

`ALVRXR_DUMP=file` composes and encodes with no headset (backend.m) and is headless: it doesn't
claim the headset, listen for one, or tap audio, so it can run beside the real vapord.
`tune.json fake_tpose` fakes tracking.

Rules for test runs, because Faye's real lounge is running on this machine:
- Always set `ALVRXR_CONFIG_DIR` to a scratch directory (with its own session.json/tune.json),
  never the real `~/Library/Application Support/alvrxr`.
- Never run vapord against the real config dir: until WP6 makes it honour `ALVRXR_CONFIG_DIR`
  (vapord.m:873) it writes the live home.pid. Never call runtime-switch.sh, never install a
  variant, never touch launchd, the OpenXR manifest or MacVapoR's folders: the lead does that.
- ALVR's web server may start on session.json's `web_server_port` (8082), which the real vapord
  holds: give a scratch config dir's session.json another port (e.g. 18082). headless.sh copies
  macvapor/session-template.json, so prepare_session doesn't borrow the real one.

tests/ drives sources and checks the decoded frames' colours and fade (ffmpeg decodes):
`tests/build.sh` builds `xrclient` (a Metal client: `--color`, `--quad`, `--black-first`,
`--stall-after`, `--exit-after`, `--crash-after`, `--format`) and `dumpcheck` (decodes an
ALVRXR_DUMP stream, prints per-frame colours and the frame number read from xrclient's bar row);
`tests/headless.sh single` runs one client end to end with a scratch config dir. The handover,
crash and two-clients scenarios are stubs until the compositor exists. `tests/compositor-check.sh
dashboard` drives the dashboard in the compositor (a tune.json fake press of the system button,
the overlay compose, quit, eye height, recenter); `tests/dashboard-check.sh` the runtime side (a
game never sees the system button and follows exit_request; vapord's session, in SERVER mode on
a test service name, uses the private functions). Anything about feel is checked in the headset.

## Dashboard

Holding the right controller's system button (the PS VR2 right Options button, which the
visionOS client sends as system) for 0.5 s opens a panel over whatever is running, like SteamVR's
dashboard; pressing it again closes it. The system button never reaches games.

- The compositor watches the button itself (server side, from the published buttons), since the
  lounge has no input focus while a game runs. Open: `dashboard = 1` in every source's session
  region; the lounge becomes FOCUSED with `should_render = 1`, the foreground game VISIBLE (it
  keeps drawing, gets no input).
- Composing while open: the game dimmed (to ~35%) with the lounge's slot drawn over it with its
  alpha (premultiplied). The lounge, with `dashboard` set, draws only the panel and its pointer,
  over transparency (alpha 0 elsewhere). With no game, the lounge draws its scene behind the panel
  as usual (alpha 1).
- The panel is world-locked: placed ~1 m ahead at eye height, facing the user, when it opens; it
  doesn't follow the head. A laser from either controller's aim pose, or a hand's pinch ray,
  points at it; trigger or pinch presses.
- Contents: height (standing / seated at an eye height, set from where the head is now, nudged
  ±5 cm), recenter, quit the game (when one is foreground), and a status line (game name,
  battery, stream fps/bitrate).
- vapord drives it through the private functions in alvrxr_ext.h. Quit sets the game's
  `exit_request`; its runtime goes VISIBLE → SYNCHRONIZED → STOPPING as for
  xrRequestExitSession, and the compositor fades back to the lounge as the session ends.
