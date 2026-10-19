#!/bin/sh
# Renders vapord's dashboard headless and leaves pictures of it to look at.
#   tests/dashboard-ui-check.sh [game|lounge ...] [--keep DIR]
# For each mode, runs out/vapord with VAPORD_DASHBOARD_TEST (the panel open with made-up state and
# pointers: the right hand on Recenter, pressing it on frames 40-51, the left beside the panel)
# against a scratch ALVRXR_CONFIG_DIR and ALVRXR_DUMP, LEGACY (no "compositor" in tune.json), so it
# runs beside the real vapord. Leaves in DIR/MODE:
#   dashboard-30.png, dashboard-45.png  the left eye's swapchain image read back, alpha and all
#                                       (hovering Recenter, then pressing it)
#   stream-*.png                        frames decoded from the encoded stream (alpha is gone there)
# and checks: over a game, most of the image is alpha 0; in the lounge, none of it is; the press
# was seen; the real home.pid didn't change.
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
modes=
keep=
while [ $# -gt 0 ]; do
    case "$1" in
        game | lounge) modes="$modes $1"; shift ;;
        --keep) keep=${2:?}; shift 2 ;;
        *) echo "unknown argument $1" >&2; exit 2 ;;
    esac
done
modes=${modes:-game lounge}
[ -x "$here/out/vapord" ] || "$here/build.sh"
real_pid="$HOME/Library/Application Support/alvrxr/home.pid"
before=$(stat -f '%m %z' "$real_pid" 2>/dev/null; cat "$real_pid" 2>/dev/null || true)
top=${keep:-$(mktemp -d "${TMPDIR:-/tmp}/vapord-dashboard.XXXXXX")}
fail=0
for mode in $modes; do
    scratch=$top/$mode
    rm -rf "$scratch"
    mkdir -p "$scratch"
    # Its own web server port: 8082 is the real vapord's, and 18082 other tests' (docs/compositor.md, "Testing
    # without a headset").
    sed "s/\"web_server_port\": 8082/\"web_server_port\": ${PORT:-18093}/" "$here/macvapor/session-template.json" > "$scratch/session.json"
    echo '{"fake_tpose": true}' > "$scratch/tune.json"
    ALVRXR_CONFIG_DIR=$scratch ALVRXR_DUMP=$scratch/dump.hevc VAPORD_DASHBOARD_TEST=$mode \
        "$here/out/vapord" "$here/out/libalvrxr.dylib" > "$scratch/vapord.log" 2>&1 &
    pid=$!
    ( sleep 60; kill "$pid" 2>/dev/null ) &
    watchdog=$!
    wait "$pid" || { echo "$mode: vapord failed"; fail=1; }
    kill "$watchdog" 2>/dev/null || true
    grep 'vapord: dashboard' "$scratch/vapord.log" | sed "s/^/$mode: /"
    grep -q 'dashboard: recenter (right hand)' "$scratch/vapord.log" || { echo "$mode: no press of Recenter"; fail=1; }
    /opt/homebrew/bin/ffmpeg -v error -f hevc -i "$scratch/dump.hevc" -vf "select=not(mod(n\,30))" -fps_mode passthrough \
        "$scratch/stream-%02d.png" || echo "$mode: couldn't decode the stream"
    # Over a game: transparent round the panel. In the lounge: the scene is opaque everywhere.
    clear=$(sed -n 's/.*dashboard-30.png: alpha 0 \([0-9.]*\)%.*/\1/p' "$scratch/vapord.log")
    case "$mode" in
        game) awk -v c="${clear:-0}" 'BEGIN { exit !(c > 50) }' || { echo "$mode: only ${clear:-?}% transparent"; fail=1; } ;;
        lounge) [ "${clear:-x}" = 0.0 ] || { echo "$mode: ${clear:-?}% transparent, should be none"; fail=1; } ;;
    esac
done
after=$(stat -f '%m %z' "$real_pid" 2>/dev/null; cat "$real_pid" 2>/dev/null || true)
[ "$before" = "$after" ] || { echo "the real home.pid changed!"; fail=1; }
echo "pictures in $top"
[ $fail = 0 ] && echo "dashboard-check: ok"
exit $fail
