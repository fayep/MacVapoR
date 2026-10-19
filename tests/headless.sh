#!/bin/sh
# Runs scenarios against the runtime with no headset, checking what ends up in the encoded stream.
#   tests/headless.sh single|handover|crash|two-clients [--runtime PATH] [--keep]
# Always runs with a scratch ALVRXR_CONFIG_DIR and ALVRXR_DUMP (see docs/compositor.md, "Testing
# without a headset"); never uses the real config, never installs, never starts vapord.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/.." && pwd)
scenario=${1:-single}
[ $# -gt 0 ] && shift
runtime=$repo/out/libalvrxr.dylib
keep=
while [ $# -gt 0 ]; do
    case "$1" in
        --runtime) runtime=${2:?}; shift 2 ;;
        --keep) keep=1; shift ;;
        *) echo "unknown option $1" >&2; exit 2 ;;
    esac
done
[ -f "$repo/out/libalvrxr.dylib" ] || "$repo/build.sh"
[ -x "$repo/build/tests/xrclient" ] && [ -x "$repo/build/tests/dumpcheck" ] || "$here/build.sh"
xrclient=$repo/build/tests/xrclient
dumpcheck=$repo/build/tests/dumpcheck

scratch=$(mktemp -d "${TMPDIR:-/tmp}/alvrxr-headless.XXXXXX")
# The runtime's logs grow by hundreds of MB a minute, so the scratch dir goes unless --keep.
cleanup() { if [ -n "$keep" ]; then echo "kept $scratch"; else rm -rf "$scratch"; fi; }
trap cleanup EXIT
# prepare_session (backend.m) otherwise borrows the spike's session from the real home directory.
# On its own web server port: 8082 belongs to the real vapord, and ALVR panics in a loop (filling
# session_log.txt by hundreds of MB a second) when it can't bind.
sed 's/"web_server_port": 8082/"web_server_port": 18082/' "$repo/macvapor/session-template.json" > "$scratch/session.json"
export ALVRXR_CONFIG_DIR=$scratch

# summarize DUMPCHECK_OUTPUT: frames, the colours in order with their frame ranges, and gaps in the numbers.
summarize() {
    awk '
    /^frame / {
        n++
        fill = $5; other = $7; bars = $9
        key = fill
        if (key != last) { runs[++r] = key; start[r] = $2; last = key }
        stop[r] = $2
        if (bars != "-") { seen++; if (prev != "" && bars != prev + 1) { gaps = gaps sprintf(" %d->%d(at stream frame %d)", prev, bars, $2) } prev = bars; if (first == "") first = bars; lastbar = bars }
        if (other != "-1,-1,-1") quads++
    }
    END {
        printf "frames encoded: %d\n", n
        printf "colours in order (fill r,g,b):"
        for (i = 1; i <= r; i++) printf " [%s x frames %d-%d]", runs[i], start[i], stop[i]
        printf "\n"
        printf "frame numbers read: %d (first %s, last %s)\n", seen, first, lastbar
        printf "gaps in frame numbers:%s\n", (gaps == "" ? " none" : gaps)
        printf "frames with a second colour (quad): %d\n", quads
    }'
}

# near R,G,B TOL "r,g,b": is the colour within TOL of R,G,B?
near() { echo "$5" | awk -F, -v r=$1 -v g=$2 -v b=$3 -v t=$4 'function d(x){return x<0?-x:x} {exit !(d($1-r)<=t && d($2-g)<=t && d($3-b)<=t)}'; }

case "$scenario" in
single)
    echo "== single: one client, fill 0,200,60, quad 40,80,230, 4 seconds"
    export ALVRXR_DUMP=$scratch/dump.hevc
    "$xrclient" --runtime "$runtime" --frames 0 --seconds 4 --color 0,200,60 --quad > "$scratch/client.log" 2>&1 &
    cpid=$!
    ( sleep 90; kill -9 $cpid 2>/dev/null ) &
    dog=$!
    sleep 2
    # alvr_initialize might open a port the real vapord also uses; report what the client holds.
    echo "-- network sockets of the client while it runs (lsof -nP -i -a -p $cpid):"
    lsof -nP -i -a -p "$cpid" 2>&1 | sed 's/^/   /'
    [ -n "$(lsof -nP -i -a -p "$cpid" 2>/dev/null)" ] || echo "   (none)"
    echo "-- files it has open for writing outside the scratch dir:"
    lsof -nP -p "$cpid" 2>/dev/null | awk '$4 ~ /^[0-9]+[wu]$/ && $5 == "REG" {print "   " $NF}' | grep -v "$scratch\|com.apple.metal" || true
    status=0
    wait $cpid || status=$?
    kill $dog 2>/dev/null || true
    wait $dog 2>/dev/null || true
    tail -4 "$scratch/client.log" | sed 's/^/client: /'
    [ $status -eq 0 ] || { echo "FAIL: xrclient exited $status"; exit 1; }
    "$dumpcheck" "$scratch/dump.hevc" > "$scratch/decoded.txt" || { echo "FAIL: nothing decoded"; exit 1; }
    head -4 "$scratch/decoded.txt"
    echo "..."
    tail -3 "$scratch/decoded.txt"
    summarize < "$scratch/decoded.txt" | tee "$scratch/summary.txt"
    # The colours must be the client's, within encoding noise, and the frame numbers must count up.
    fill=$(awk '/^frame /{print $5}' "$scratch/decoded.txt" | sort | uniq -c | sort -rn | head -1 | awk '{print $2}')
    other=$(awk '/^frame /{print $7}' "$scratch/decoded.txt" | sort | uniq -c | sort -rn | head -1 | awk '{print $2}')
    ok=1
    near 0 200 60 12 "$fill" || { echo "FAIL: fill $fill is not 0,200,60"; ok=0; }
    near 40 80 230 12 "$other" || { echo "FAIL: quad $other is not 40,80,230"; ok=0; }
    grep -q "gaps in frame numbers: none" "$scratch/summary.txt" || { echo "FAIL: gaps in the frame numbers"; ok=0; }
    [ $ok -eq 1 ] && echo "PASS: decoded fill $fill and quad $other match what the client drew"
    [ $ok -eq 1 ]
    ;;
handover|crash|two-clients)
    # STUB. Needs the compositor (vapord honouring ALVRXR_CONFIG_DIR, other packages):
    #   handover:    start out/vapord against the scratch dir, then a client with --exit-after, checking the
    #                dump shows home, the client's colour fading in, then home again fading out.
    #   crash:       a client with --crash-after, checking the stream falls back to home with no black frames.
    #   two-clients: two clients with different --color, checking only the focused one's colour is encoded.
    echo "scenario '$scenario' is not implemented yet: it needs the compositor and vapord's ALVRXR_CONFIG_DIR" >&2
    exit 3
    ;;
*) echo "usage: $0 single|handover|crash|two-clients [--runtime PATH] [--keep]" >&2; exit 2 ;;
esac
