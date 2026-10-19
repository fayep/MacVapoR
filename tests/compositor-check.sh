#!/bin/sh
# Builds tests/compositor-check.m straight from src/ (with the real ALVR core from out/) and runs
# the compositor's scenarios headless, checking the decoded dumps:
#   tests/compositor-check.sh [parity|handover|watchdog|reproject|all] [--keep]
# Always a scratch ALVRXR_CONFIG_DIR and ALVRXR_DUMP (docs/compositor.md "Testing without a
# headset"); never the real config, never vapord, nothing installed.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/.." && pwd)
what=${1:-all}
[ $# -gt 0 ] && shift
keep=
[ "${1:-}" = --keep ] && keep=1
[ -f "$repo/out/libalvrxr.dylib" ] && [ -f "$repo/build/compose_metal.h" ] || "$repo/build.sh"
[ -x "$repo/build/tests/dumpcheck" ] || "$here/build.sh"
dumpcheck=$repo/build/tests/dumpcheck
bin=$repo/build/tests/compositor-check
mkdir -p "$repo/build/tests"
clang -mmacosx-version-min="${MIN_VER:-15.0}" -fobjc-arc -O1 -g -Wall -Wno-unused-function \
    -I "$repo/src" -I "$repo/build" -I /opt/homebrew/include \
    "$here/compositor-check.m" "$repo/src/compositor.m" "$repo/src/server.m" "$repo/src/tracking.m" "$repo/src/audio.m" \
    -framework Foundation -framework Metal -framework CoreVideo -framework CoreMedia -framework VideoToolbox -framework ImageIO \
    -framework CoreGraphics -framework CoreAudio -framework IOSurface \
    -L "$repo/out" -lalvr_server_core -Wl,-rpath,"$repo/out" -o "$bin"

scratch=$(mktemp -d "${TMPDIR:-/tmp}/alvrxr-compositor.XXXXXX")
cleanup() { if [ -n "$keep" ]; then echo "kept $scratch"; else rm -rf "$scratch"; fi; }
trap cleanup EXIT
sed 's/"web_server_port": 8082/"web_server_port": 18082/' "$repo/macvapor/session-template.json" > "$scratch/session.json"
export ALVRXR_CONFIG_DIR=$scratch
fails=0
fail() { echo "FAIL: $*"; fails=$((fails + 1)); }
pass() { echo "PASS: $*"; }

# The left eye's fill per frame, "r g b", from dumpcheck's output.
fills() { awk '/^frame /{split($5, c, ","); print c[1], c[2], c[3]}' "$1"; }

run_parity() {
    echo "== parity: 90 frames of one picture, SERVER (compositor) against LEGACY (axr_submit)"
    ALVRXR_DUMP=$scratch/server.hevc "$bin" server 90 > "$scratch/server.out" 2>&1 || { tail -5 "$scratch/server.out"; fail "server run"; return; }
    ALVRXR_DUMP=$scratch/legacy.hevc "$bin" legacy 90 > "$scratch/legacy.out" 2>&1 || { tail -5 "$scratch/legacy.out"; fail "legacy run"; return; }
    "$dumpcheck" "$scratch/server.hevc" > "$scratch/server.txt" || { fail "server dump didn't decode"; return; }
    "$dumpcheck" "$scratch/legacy.hevc" > "$scratch/legacy.txt" || { fail "legacy dump didn't decode"; return; }
    sf=$(fills "$scratch/server.txt" | sort | uniq -c | sort -rn | head -1); lf=$(fills "$scratch/legacy.txt" | sort | uniq -c | sort -rn | head -1)
    echo "   server: $(tail -1 "$scratch/server.txt"), commonest fill:$sf"
    echo "   legacy: $(tail -1 "$scratch/legacy.txt"), commonest fill:$lf"
    grep -q " 0 release violations" "$scratch/server.out" || fail "release violations in the server run"
    "$bin" compare "$scratch/server.hevc" "$scratch/legacy.hevc" | tee "$scratch/compare.txt"
    # The pictures are identical before encoding; the hardware encoder's rate control is not
    # deterministic frame for frame, so a few levels of difference are noise.
    awk '{max=$(NF-4) + 0; mean=$NF} END {exit !(max <= 24 && mean < 1.0)}' "$scratch/compare.txt" \
        && pass "SERVER output matches LEGACY within encoder noise" || fail "SERVER and LEGACY outputs differ"
    grep -q "listener-to-commit" "$scratch/alvrxr.log" && grep -h "compositor:.*composed" "$scratch/alvrxr.log" | tail -1 | sed 's/^/   stats: /' || true
}

# Checks the lounge->game->lounge sequence in a handover dump: green, a monotonic fade to red
# (red up, green down), red, then a fade back to green.
check_fade_sequence() {
    fills "$1" | awk -v hz=90 '
    function near(a, b) { return (a - b) <= 14 && (b - a) <= 14 }
    {
        r = $1; g = $2; b = $3; n++
        state = (near(r, 0) && near(g, 200)) ? "lounge" : (near(r, 200) && near(g, 40)) ? "game" : "mix"
        if (state != last) { runs[++k] = state; start[k] = n - 1; }
        stop[k] = n - 1; last = state
        if (state == "mix") { mixn[k]++; if (prevr != "" && prevstate == "mix" && ((dir[k] > 0 && r < prevr - 3) || (dir[k] < 0 && r > prevr + 3))) bad[k]++ }
        if (state == "mix" && prevstate != "mix") dir[k] = (prevstate == "lounge") ? 1 : -1
        prevr = r; prevstate = state
    }
    END {
        printf "   sequence:"
        for (i = 1; i <= k; i++) printf " %s[%d-%d]", runs[i], start[i], stop[i]
        printf "\n"
        ok = 1
        if (k < 5) { print "   expected lounge, mix, game, mix, lounge"; ok = 0 }
        else {
            if (runs[1] != "lounge" || runs[2] != "mix" || runs[3] != "game" || runs[4] != "mix" || runs[5] != "lounge") { print "   wrong order"; ok = 0 }
            f1 = stop[2] - start[2] + 1; f2 = stop[4] - start[4] + 1
            printf "   fade in: %d intermediate frames (%d non-monotonic), fade out: %d (%d non-monotonic); expected %d +-3 each at %d Hz over 400 ms\n", f1, bad[2], f2, bad[4], int(0.4 * hz) - 1, hz
            if (f1 < 32 || f1 > 40 || f2 < 32 || f2 > 40) ok = 0
            if (bad[2] > 1 || bad[4] > 1) ok = 0
        }
        exit !ok
    }'
}

run_handover() {
    echo "== handover: lounge (green), then a game (red) with 20 empty frames first; the game is removed after 3.2 s"
    ALVRXR_DUMP=$scratch/handover.hevc "$bin" handover > "$scratch/handover.out" 2> "$scratch/handover.err" || { tail -5 "$scratch/handover.err"; fail "handover run"; }
    grep -h "compositor:" "$scratch/alvrxr.log" | grep -v "composed" | sed 's/^/   log: /'
    grep -h "focus\|first content\|removed\|stopped" "$scratch/handover.out" | sed 's/^/   driver: /'
    "$dumpcheck" "$scratch/handover.hevc" > "$scratch/handover.txt" || { fail "handover dump didn't decode"; return; }
    check_fade_sequence "$scratch/handover.txt" && pass "handover: lounge, cross-fade to the game, game, cross-fade back" || fail "handover sequence"
    ! grep -q VIOLATION "$scratch/handover.out" && pass "release protocol: no slot reused before its release" || fail "release violations"
    grep -q "lounge: focus VISIBLE, should_render 1" "$scratch/handover.out" && grep -q "lounge: focus VISIBLE, should_render 0" "$scratch/handover.out" \
        && grep -q "lounge: focus FOCUSED, should_render 1" "$scratch/handover.out" && pass "lounge focus: FOCUSED -> VISIBLE -> idle -> FOCUSED" || fail "lounge focus sequence"
    grep -q "reused slot" "$scratch/alvrxr.log" && fail "the compositor saw a slot reused early" || true
}

run_watchdog() {
    echo "== watchdog: as handover, but the game just stops sending; the lounge comes back after 300 ms"
    : > "$scratch/alvrxr.log"
    printf '{"watchdog_ms": 300}' > "$scratch/tune.json"   # the default is 1500
    ALVRXR_DUMP=$scratch/watchdog.hevc "$bin" handover --watchdog > "$scratch/watchdog.out" 2> "$scratch/watchdog.err" || { tail -5 "$scratch/watchdog.err"; fail "watchdog run"; }
    grep -h "compositor:" "$scratch/alvrxr.log" | grep -v "composed" | sed 's/^/   log: /'
    "$dumpcheck" "$scratch/watchdog.hevc" > "$scratch/watchdog.txt" || { fail "watchdog dump didn't decode"; return; }
    check_fade_sequence "$scratch/watchdog.txt" && pass "watchdog: the game's last frame fades back to the lounge" || fail "watchdog sequence"
    ms=$(grep -h "watchdog: no frame" "$scratch/alvrxr.log" | sed 's/.*for \([0-9]*\) ms.*/\1/' | head -1)
    [ -n "$ms" ] && [ "$ms" -ge 300 ] && [ "$ms" -le 400 ] && pass "watchdog fired after $ms ms" || fail "watchdog fired after '${ms:-never}' ms"
}

run_reproject() {
    echo "== reprojection: the other source's stripe, with its head yawed 10 degrees, lands where the fov says"
    ALVRXR_DUMP=$scratch/reproject.hevc "$bin" reproject > "$scratch/reproject.out" 2>&1 || { tail -5 "$scratch/reproject.out"; fail "reproject run"; }
    grep expected "$scratch/reproject.out" | sed 's/^/   /'
    "$bin" stripe "$scratch/reproject.hevc" > "$scratch/stripe.txt" || { fail "reproject dump didn't decode"; return; }
    a=$(awk '$2 >= 2 && $2 <= 9 {print $4}' "$scratch/stripe.txt" | sort -n | awk '{v[NR]=$1} END {print v[int((NR+1)/2)]}')
    b=$(awk '$2 >= 14 && $2 <= 21 {print $4}' "$scratch/stripe.txt" | sort -n | awk '{v[NR]=$1} END {print v[int((NR+1)/2)]}')
    e0=$(grep expected "$scratch/reproject.out" | sed 's/.*stripe at \([0-9.]*\) px.*/\1/')
    e1=$(grep expected "$scratch/reproject.out" | sed 's/.*no turn, \([0-9.]*\) px.*/\1/')
    echo "   measured: stripe at $a px with no turn, $b px yawed (the encoded image is foveated: the centre band is 1:1, so compare the shifts)"
    awk -v a="$a" -v b="$b" -v e0="$e0" -v e1="$e1" 'BEGIN { s = b - a; e = e1 - e0; d = s - e; if (d < 0) d = -d; printf "   shift %.1f px, expected %.1f px (%.1f px/deg)\n", s, e, e / 10; exit !(d <= 6) }' \
        && pass "reprojection shifts by the fov's pixels per degree" || fail "reprojection shift"
}

case "$what" in
parity) run_parity ;;
handover) run_handover ;;
watchdog) run_watchdog ;;
reproject) run_reproject ;;
all) run_parity; run_handover; run_watchdog; run_reproject ;;
*) echo "usage: $0 [parity|handover|watchdog|reproject|all] [--keep]" >&2; exit 2 ;;
esac
[ $fails -eq 0 ] && echo "compositor-check: all passed" || echo "compositor-check: $fails failed"
[ $fails -eq 0 ]
