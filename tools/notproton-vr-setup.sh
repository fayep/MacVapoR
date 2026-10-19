#!/bin/sh
# Sets up one NotProton game prefix for OpenXR through wineopenxr and alvrxr, without touching
# NotProton or its CrossOver runner. Run it with the game closed, after the game has been
# launched once so its prefix exists.
#
#   tools/notproton-vr-setup.sh APPID 'Game.exe'      e.g. 620980 'Beat Saber.exe'
#       (the executable's path inside the game folder, e.g. 450390 TheLab/win64/TheLab.exe)
#   tools/notproton-vr-setup.sh --undo APPID 'Game.exe'
#   GFX=dxmt tools/notproton-vr-setup.sh APPID 'Game.exe'   D3D11 games on CrossOver's DXMT,
#       chosen with the game's graphics option in NotProton; no DXVK is put in place
#   GAME_DIR=/path/to/game tools/notproton-vr-setup.sh SHORTCUT_ID 'bin/Game.exe'
#       a non-Steam game added as a shortcut: its folder is given, as it has no app manifest
#   OC=/path/to/openvr_api.dll tools/notproton-vr-setup.sh APPID 'Game.exe'
#       an OpenVR game: OpenComposite's 64-bit openvr_api.dll replaces the game's own, which is
#       kept as openvr_api.dll.orig and put back by --undo
#   tools/notproton-vr-setup.sh --scan APPID
#       lists what an older per-game setup left behind, changing nothing (see "Cleaning up" below)
#   tools/notproton-vr-setup.sh --clean APPID KIND[:TARGET]...
#       takes out the listed items of those kinds, or just the one with that target
#
# What goes where, and why (NotProton 1.0.3's run script):
#   - wineopenxr goes into aarch64-windows/ and aarch64-unix/ under the prefix's Steam staging
#     directory. The run script puts that directory first on WINEDLLPATH and prunes stray
#     files in it, but not subdirectories; Wine's ARM64EC loader looks in those two.
#   - HKCU\Software\Wine\VR is written as a persistent key. The Steam shim creates it volatile
#     on every launch and leaves it alone when it already exists; without SteamVR it would
#     mark VR unavailable.
#   - Unless GFX=dxmt, DXVK's d3d11 goes beside the game with its builtin marker cleared, and
#     an AppDefaults override makes the game load it: on the FEX runner CrossOver's own DXVK
#     switch never reaches an ARM64EC process. DXMT's switch does, as it is ARM64 itself.
#   - OpenComposite gets initUsingVulkan=false, so its session before the game's first frame is
#     a D3D11 one like the game's, rather than Windows Vulkan through wineopenxr.
#   - The native OpenXR loader inside wineopenxr finds alvrxr through the per-user
#     ~/.config/openxr/1/active_runtime.json, since the run script passes no XR_* variables.
#
# Cleaning up. A NotProton whose run script links C:\vrclient to the registered OpenVR runtime
# and stages wineopenxr itself, and whose steam.exe fills the VR key, needs no per-game setup,
# and an old one then gets in its way: the persistent VR key stops steam.exe filling its own,
# and OpenComposite in the game folder bypasses the shared one. --scan prints one line per
# finding, tab-separated:
#   status  notproton|running|prefix|game|openvr-runtime  value
#   item    KIND  TARGET (a path, or a registry value)  REASON  DEFAULT (1 ticked, 0 not)  MODE
# MODE is "any" (junk with any NotProton), "zero-setup" (only once NotProton does the setup
# itself; --clean skips these otherwise) or "kept" (listed, never taken out). Registry edits
# are made to user.reg and system.reg as text, with the prefix stopped: running Wine's reg would
# start the prefix, and wineserver rewrites those files when it exits. A copy of each edited or
# replaced file is kept beside it, as NAME.before-macvapor-cleanup.
#
# Overridable: RUNNER, WOX (wineopenxr build output), ALVRXR_LIB (the runtime), STEAM, GAME_DIR,
# and for --scan/--clean: NOTPROTON_RUN (its run script), NP_BRIDGE (its bridge folder),
# VRPATHS (openvrpaths.vrpath), MACVAPOR_OC (MacVapoR's OpenComposite), GFX (the game's graphics)
#
# Only tools a Mac has without the Command Line Tools, except python3 for DXVK mode.
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
undo=0
mode=setup
case "${1:-}" in
    --undo) undo=1; mode=undo; shift ;;
    --scan) mode=scan; shift ;;
    --clean) mode=clean; shift ;;
esac
usage() { sed -n 2,20p "$0" >&2; exit 2; }
case $mode in
    setup|undo) [ $# -eq 2 ] || usage ;;
    scan) [ $# -eq 1 ] || usage ;;
    clean) [ $# -ge 2 ] || usage ;;
esac
appid=$1
exe=${2:-}
case "$appid" in ''|*[!0-9]*) echo "not an app id: $appid" >&2; exit 2 ;; esac

RUNNER=${RUNNER:-$HOME/Library/Application Support/notproton/runners/current}
WOX=${WOX:-$HOME/Source/NotProton/build/wineopenxr-out}
ALVRXR_LIB=${ALVRXR_LIB:-$here/out/libalvrxr.dylib}
STEAM=${STEAM:-$HOME/Library/Application Support/Steam}

# --scan and --clean also look at a game folder whose prefix is gone.
no_prefix() {
    case $mode in
        scan|clean) prefix= ;;
        *) echo "no prefix for $appid; launch the game once first" >&2; exit 1 ;;
    esac
}

# The game may be in any Steam library; its prefix is in that library's compatdata or the main one's.
# A shortcut's prefix is always in the main one's.
if [ -n "${GAME_DIR:-}" ]; then
    game=$GAME_DIR
    prefix="$STEAM/steamapps/compatdata/$appid/pfx"
    [ -f "$prefix/system.reg" ] || no_prefix
else
library=
for lib in "$STEAM" $(sed -n 's/.*"path"[[:space:]]*"\(.*\)".*/\1/p' "$STEAM/steamapps/libraryfolders.vdf" | tr ' ' '\001'); do
    lib=$(printf '%s' "$lib" | tr '\001' ' ')
    [ -f "$lib/steamapps/appmanifest_$appid.acf" ] && { library=$lib; break; }
done
[ -n "$library" ] || { echo "app $appid is not installed in any Steam library" >&2; exit 1; }
prefix="$library/steamapps/compatdata/$appid/pfx"
[ -f "$prefix/system.reg" ] || prefix="$STEAM/steamapps/compatdata/$appid/pfx"
[ -f "$prefix/system.reg" ] || no_prefix
game_dir=$(sed -n 's/.*"installdir"[[:space:]]*"\(.*\)".*/\1/p' "$library/steamapps/appmanifest_$appid.acf")
game="$library/steamapps/common/$game_dir"
fi
case $mode in
    setup|undo) [ -f "$game/$exe" ] || { echo "no $exe in $game" >&2; exit 1; } ;;
    *) [ -d "$game" ] || { echo "no folder $game" >&2; exit 1; } ;;
esac
# The executable may be in a subfolder, as The Lab's TheLab/win64/TheLab.exe; Wine's per-app
# settings go by its name, and DXVK's d3d11 goes beside it.
exe_name=$(basename "$exe")
exe_dir=$(dirname "$game/$exe")
staging="$prefix/drive_c/Program Files (x86)/Steam"
sys32="$prefix/drive_c/windows/system32"

if [ "$mode" = scan ] || [ "$mode" = clean ]; then
NOTPROTON_RUN=${NOTPROTON_RUN:-$STEAM/compatibilitytools.d/notproton/run}
NP_BRIDGE=${NP_BRIDGE:-$HOME/Library/Application Support/notproton/bridge}
VRPATHS=${VRPATHS:-$HOME/.config/openvr/openvrpaths.vrpath}
MACVAPOR_OC=${MACVAPOR_OC:-$HOME/Library/Application Support/MacVapoR/opencomposite/openvr_api.dll}
tab=$(printf '\t')

# Whether the installed NotProton sets VR up by itself at each launch: its run script links
# C:\vrclient and stages wineopenxr (NotProton's vr-runtimes work). These are the names it has
# now; if upstream renames them, this is the one place to follow.
notproton_zero_setup() {
    [ -f "$NOTPROTON_RUN" ] &&
        grep -q '^link_vrclient()' "$NOTPROTON_RUN" &&
        grep -q '^stage_wineopenxr()' "$NOTPROTON_RUN"
}

# The prefix's wineserver: Wine names its socket folder after the prefix's device and inode,
# and the running server holds the lock file in it open. The game's own process is not enough,
# as the server stays a few seconds after it and writes user.reg when it exits.
prefix_running() {
    [ -n "$prefix" ] || return 1
    server=$(stat -f '%d %i' "$prefix" | awk '{ printf "server-%x-%x", $1, $2 }')
    for wtmp in "/tmp/.wine-$(id -u)" "${TMPDIR:-/tmp}/.wine-$(id -u)"; do
        [ -e "$wtmp/$server/lock" ] && [ -n "$(lsof -t "$wtmp/$server/lock" 2>/dev/null)" ] && return 0
    done
    return 1
}

is_oc() { grep -aq -e OpenOVR -e OpenComposite "$1"; }
# What Set Up writes; anything else in an opencomposite.ini was put there by hand.
setup_ini() { [ "$(cat "$1")" = "initUsingVulkan=false" ]; }
item() { printf 'item\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5"; }

# The OpenVR runtime NotProton links as C:\vrclient, if one is registered.
vr_runtime=
if [ -f "$VRPATHS" ]; then
    vr_runtime=$(plutil -extract runtime.0 raw -o - "$VRPATHS" 2>/dev/null) || vr_runtime=
    [ -f "$vr_runtime/bin/win64/vrclient_x64.dll" ] || vr_runtime=
fi

# Section names as user.reg and system.reg write them, lower-cased.
vr_key='software\\wine\\vr'
khronos_key='software\\khronos\\openxr\\1'
khronos_value='"ActiveRuntime"="C:\\windows\\system32\\wineopenxr64.json"'
wox_files="aarch64-windows/wineopenxr.dll:x86_64-windows/wineopenxr.dll
aarch64-unix/wineopenxr.so:aarch64-unix/wineopenxr.so
aarch64-unix/libopenxr_loader.dylib:aarch64-unix/libopenxr_loader.dylib
system32/wineopenxr.dll:x86_64-windows/wineopenxr.dll
system32/wineopenxr64.json:wineopenxr64.json"
wox_path() {
    case $1 in
        system32/*) printf '%s/%s' "$sys32" "${1#system32/}" ;;
        *) printf '%s/%s' "$staging" "$1" ;;
    esac
}

# Whether a .reg file has the section, or the value line in it.
reg_has_section() {
    KEY=$2 awk 'BEGIN { key = ENVIRON["KEY"] }
        /^\[/ { h = tolower($0); sub(/\].*/, "", h); if (substr(h, 2) == key) found = 1 }
        END { exit !found }' "$1"
}
reg_has_value() {
    KEY=$2 LINE=$3 awk 'BEGIN { key = ENVIRON["KEY"]; line = ENVIRON["LINE"] }
        /^\[/ { h = tolower($0); sub(/\].*/, "", h); in_key = (substr(h, 2) == key); next }
        in_key && $0 == line { found = 1 }
        END { exit !found }' "$1"
}
# Executables that user.reg sends to a native d3d11.
d3d11_native_exes() {
    awk '/^\[/ { exe = ""; n = split($0, p, /\\\\/)
            if (n >= 5 && tolower(p[1]) == "[software" && tolower(p[2]) == "wine" && tolower(p[3]) == "appdefaults" &&
                tolower(p[5]) ~ /^dlloverrides\]/) exe = p[4]
            next }
        exe != "" && $0 == "\"d3d11\"=\"native\"" { print exe }' "$1"
}
# DXVK's d3d11 as Set Up copies it: the builtin marker cleared.
is_setup_dxvk() {
    [ "$(dd if="$1" bs=1 skip=64 count=16 2>/dev/null | od -An -tx1 | tr -d ' \n')" = 00000000000000000000000000000000 ] &&
        grep -aq DXVK "$1"
}

scan_items() {
    oldsetup=0
    # The game folder: every folder with an openvr_api.dll, its kept original, or OpenComposite's ini.
    find "$game" \( -iname openvr_api.dll -o -iname 'openvr_api.dll.*' -o -iname opencomposite.ini \) -type f 2>/dev/null |
        sed 's|/[^/]*$||' | sort -u > "$dirs"
    while IFS= read -r d; do
        dll=$d/openvr_api.dll
        orig=$dll.orig
        ini=$d/opencomposite.ini
        dll_oc=0
        [ -f "$dll" ] && is_oc "$dll" && dll_oc=1
        if [ -f "$orig" ] && ! is_oc "$orig"; then
            if [ -f "$dll" ] && [ $dll_oc = 0 ]; then
                if cmp -s "$dll" "$orig"; then
                    item stale-orig "$orig" "a spare copy of the game's own openvr_api.dll beside it" 1 any
                else
                    item stale-orig "$orig" "an older copy of the game's openvr_api.dll; the game has its own in place" 0 any
                fi
                [ -f "$ini" ] && item orphan-ini "$ini" "OpenComposite's settings beside the game's own openvr_api.dll" "$(setup_ini "$ini" && echo 1 || echo 0)" any
            else
                oldsetup=1
                rdef=1
                if [ -z "$vr_runtime" ]; then
                    rdef=0
                    why="no shared OpenVR runtime is registered, so the game would lose VR"
                elif [ ! -f "$dll" ]; then
                    why="openvr_api.dll is missing; the game's own is kept as openvr_api.dll.orig"
                elif cmp -s "$dll" "$MACVAPOR_OC"; then
                    why="OpenComposite copied in by Set Up; the shared OpenVR runtime takes its place"
                else
                    rdef=0
                    why="a different OpenComposite build from MacVapoR's, maybe one you put there"
                fi
                item oc-restore "$dll" "$why" $rdef zero-setup
                if [ -f "$ini" ]; then
                    if [ $rdef = 1 ] && setup_ini "$ini"; then
                        item oc-ini "$ini" "written by Set Up for the OpenComposite copy" 1 zero-setup
                    elif [ $rdef = 1 ]; then
                        item oc-ini "$ini" "has settings of your own" 0 zero-setup
                    else
                        item oc-ini "$ini" "goes with the OpenComposite copy" 0 zero-setup
                    fi
                fi
            fi
        elif [ $dll_oc = 1 ]; then
            item oc-no-orig "$dll" "OpenComposite with no original kept; Steam's Verify Integrity puts the game's own back" 0 kept
        elif [ -f "$ini" ] && [ -f "$dll" ]; then
            item orphan-ini "$ini" "OpenComposite's settings beside the game's own openvr_api.dll" "$(setup_ini "$ini" && echo 1 || echo 0)" any
        fi
        for f in "$d"/openvr_api.dll.oc "$d"/openvr_api.dll.bak*; do
            [ -f "$f" ] || continue
            if is_oc "$f"; then
                item stray-backup "$f" "a spare copy of OpenComposite" 1 any
            else
                item stray-backup "$f" "a spare copy, maybe of the game's own openvr_api.dll" 0 any
            fi
        done
    done < "$dirs"

    [ -n "$prefix" ] || return 0
    if reg_has_section "$prefix/user.reg" "$vr_key"; then
        oldsetup=1
        item vr-key 'HKCU\Software\Wine\VR' "written for good by Set Up; while it is there, NotProton's steam.exe does not fill in its own at launch" 1 zero-setup
    fi
    # wineopenxr in the prefix that is not NotProton's own copy.
    differ=0
    printf '%s\n' "$wox_files" > "$woxlist"
    while IFS=: read -r in_prefix in_bridge; do
        t=$(wox_path "$in_prefix")
        [ -f "$t" ] && ! cmp -s "$t" "$NP_BRIDGE/wineopenxr/$in_bridge" && differ=1
    done < "$woxlist"
    if [ $differ = 1 ]; then
        oldsetup=1
        if [ -f "$NP_BRIDGE/wineopenxr/x86_64-windows/wineopenxr.dll" ]; then
            item wineopenxr "$prefix" "wineopenxr copied in by Set Up; NotProton puts its own in place at each launch" 1 zero-setup
        else
            item wineopenxr "$prefix" "wineopenxr copied in by Set Up; NotProton has none of its own installed to replace it" 0 zero-setup
        fi
    fi
    if [ $oldsetup = 1 ] && reg_has_value "$prefix/system.reg" "$khronos_key" "$khronos_value"; then
        item khronos-runtime 'HKLM\Software\Khronos\OpenXR\1\ActiveRuntime' "written by Set Up; NotProton's steam.exe sets it at each launch" 1 zero-setup
    fi
    # DXVK put in place by Set Up without GFX=dxmt: an override in user.reg, d3d11.dll beside the exe.
    d3d11_native_exes "$prefix/user.reg" | sort -u > "$exes"
    while IFS= read -r x; do
        find "$game" -iname "$x" -type f 2>/dev/null | while IFS= read -r e; do
            dx=$(dirname "$e")/d3d11.dll
            [ -f "$dx" ] && is_setup_dxvk "$dx" || continue
            if [ "$(printf '%s' "${GFX:-}" | tr '[:upper:]' '[:lower:]')" = dxmt ]; then
                item d3d11-override "HKCU\\Software\\Wine\\AppDefaults\\$x\\DllOverrides\\d3d11" "makes $x load DXVK, though the game is set to DXMT in NotProton" 1 zero-setup
                item d3d11-dll "$dx" "DXVK copied in by Set Up; the game is set to DXMT in NotProton" 1 zero-setup
            else
                item d3d11-override "HKCU\\Software\\Wine\\AppDefaults\\$x\\DllOverrides\\d3d11" "the game is not set to DXMT in NotProton, so DXVK is what it uses" 0 kept
                item d3d11-dll "$dx" "the game is not set to DXMT in NotProton, so DXVK is what it uses" 0 kept
            fi
        done
    done < "$exes"
}

work=$(mktemp -d "${TMPDIR:-/tmp}/macvapor-cleanup.XXXXXX")
trap 'rm -rf "$work"' EXIT
dirs=$work/dirs woxlist=$work/wox exes=$work/exes

if notproton_zero_setup; then np=zero-setup; elif [ -f "$NOTPROTON_RUN" ]; then np=old; else np=missing; fi
running=0
prefix_running && running=1

if [ "$mode" = scan ]; then
    printf 'status\tnotproton\t%s\n' "$np"
    printf 'status\trunning\t%s\n' "$running"
    printf 'status\tgame\t%s\n' "$game"
    printf 'status\tprefix\t%s\n' "$prefix"
    printf 'status\topenvr-runtime\t%s\n' "${vr_runtime:-none}"
    scan_items
    exit 0
fi

[ $running = 0 ] || { echo "the game is running (its wineserver is up): quit it first" >&2; exit 1; }

# A copy of a file about to be edited or replaced, beside it; an earlier one is never overwritten.
keep_copy() {
    k=$1.before-macvapor-cleanup
    [ -e "$k" ] && k=$k-$(date +%Y%m%d-%H%M%S)
    cp -p "$1" "$k"
    kept_as=${k##*/}
}
# Rewrites a .reg file through awk, keeping one copy of it from before this run; the result
# must still be a registry.
reg_copies=
reg_rewrite() {
    f=$1
    shift
    case $reg_copies in
        *"|$f="*) kept_as=${reg_copies#*"|$f="}; kept_as=${kept_as%%"|"*} ;;
        *) keep_copy "$f"; reg_copies="$reg_copies|$f=$kept_as|" ;;
    esac
    awk "$@" "$f" > "$f.macvapor-tmp"
    if head -1 "$f.macvapor-tmp" | grep -q '^WINE REGISTRY Version 2' && [ -s "$f.macvapor-tmp" ]; then
        mv -f "$f.macvapor-tmp" "$f"
    else
        rm -f "$f.macvapor-tmp"
        echo "could not edit $f; left as it was" >&2
        return 1
    fi
}
# The key and every key under it.
reg_drop_section() {
    KEY=$2 reg_rewrite "$1" 'BEGIN { key = ENVIRON["KEY"]; sub_ = key "\\\\" }
        /^\[/ { h = tolower($0); sub(/\].*/, "", h); h = substr(h, 2)
            skip = (h == key || index(h, sub_) == 1) }
        !skip { print }'
}
reg_drop_value() {
    KEY=$2 LINE=$3 reg_rewrite "$1" 'BEGIN { key = ENVIRON["KEY"]; line = ENVIRON["LINE"] }
        /^\[/ { h = tolower($0); sub(/\].*/, "", h); in_key = (substr(h, 2) == key) }
        !(in_key && $0 == line) { print }'
}

apply() {
    case $1 in
        stray-backup|stale-orig|orphan-ini|oc-ini|d3d11-dll)
            rm -f "$2" && echo "removed ${2#"$game"/}" ;;
        oc-restore)
            if [ -f "$2" ]; then
                keep_copy "$2"
                mv -f "$2.orig" "$2"
                echo "put the game's own ${2#"$game"/} back (OpenComposite kept as $kept_as)"
            else
                mv -f "$2.orig" "$2"
                echo "put the game's own ${2#"$game"/} back"
            fi ;;
        wineopenxr)
            printf '%s\n' "$wox_files" > "$woxlist"
            while IFS=: read -r in_prefix in_bridge; do rm -f "$(wox_path "$in_prefix")"; done < "$woxlist"
            echo "removed wineopenxr from the prefix" ;;
        vr-key)
            reg_drop_section "$prefix/user.reg" "$vr_key" &&
                echo "removed HKCU\\Software\\Wine\\VR from user.reg (copy kept as $kept_as)" ;;
        khronos-runtime)
            reg_drop_value "$prefix/system.reg" "$khronos_key" "$khronos_value" &&
                echo "removed the OpenXR ActiveRuntime value from system.reg (copy kept as $kept_as)" ;;
        d3d11-override)
            x=${2#'HKCU\Software\Wine\AppDefaults\'}
            x=${x%'\DllOverrides\d3d11'}
            reg_drop_value "$prefix/user.reg" "software\\\\wine\\\\appdefaults\\\\$(printf '%s' "$x" | tr '[:upper:]' '[:lower:]')\\\\dlloverrides" '"d3d11"="native"' &&
                echo "removed the d3d11 override for $x from user.reg (copy kept as $kept_as)" ;;
        *) echo "unknown kind $1" >&2; return 1 ;;
    esac
}

scan_items > "$work/items"
shift
status=0
for want in "$@"; do
    kind=${want%%:*}
    target=
    case $want in *:*) target=${want#*:} ;; esac
    found=0
    while IFS=$tab read -r tag k t reason def m; do
        [ "$k" = "$kind" ] || continue
        [ -z "$target" ] || [ "$t" = "$target" ] || continue
        found=1
        case $m in
            kept) echo "kept ${t#"$game"/}: $reason"; continue ;;
            zero-setup) [ $np = zero-setup ] || { echo "kept ${t#"$game"/}: the installed NotProton still needs it"; continue; } ;;
        esac
        apply "$k" "$t" </dev/null || status=1
    done < "$work/items"
    [ $found = 1 ] || echo "nothing to clean for $want" >&2
done
exit $status
fi

wine_unix="$RUNNER/lib/wine/aarch64-unix"
export CX_ROOT="$RUNNER" CX_HOME="$HOME/Library/Application Support/CrossOver"
export WINELOADER="$wine_unix/wine.app/Contents/MacOS/wine"
export WINESERVER="$RUNNER/bin/wineserver-arm64"
export WINEDLLPATH="$RUNNER/lib/wine/x86_64-windows:$wine_unix"
export WINEPREFIX="$prefix" WINEDEBUG=-all
# The game's own process; matching the prefix path would also catch anything tailing its logs.
if pgrep -fi "$exe_name" >/dev/null 2>&1; then
    echo "close the game first" >&2
    exit 1
fi

reg() { "$WINELOADER" reg "$@" >/dev/null; }

# The game's own 64-bit openvr_api.dlls, or their kept originals.
openvr_dlls() {
    find "$game" \( -iname openvr_api.dll -o -iname openvr_api.dll.orig \) | sed 's/\.orig$//' | sort -u |
        while IFS= read -r f; do
            orig=$f.orig
            [ -f "$orig" ] || orig=$f
            file "$orig" | grep -q "PE32+" && printf '%s\n' "$f"
        done
}

if [ $undo -eq 1 ]; then
    openvr_dlls | while IFS= read -r f; do
        if [ -f "$f.orig" ]; then
            mv -f "$f.orig" "$f"
            rm -f "$(dirname "$f")/opencomposite.ini"
        fi
    done
    rm -rf "$staging/aarch64-windows/wineopenxr.dll" "$staging/aarch64-unix/wineopenxr.so" \
        "$staging/aarch64-unix/libopenxr_loader.dylib" "$sys32/wineopenxr.dll" "$sys32/wineopenxr64.json" \
        "$exe_dir/d3d11.dll"
    reg delete 'HKCU\Software\Wine\VR' /f || true
    reg delete "HKCU\\Software\\Wine\\AppDefaults\\$exe_name\\DllOverrides" /v d3d11 /f || true
    reg delete 'HKLM\Software\Khronos\OpenXR\1' /v ActiveRuntime /f || true
    "$WINESERVER" -w
    echo "removed from $prefix (left ~/.config/openxr/1/active_runtime.json in place)"
    exit 0
fi

for f in x86_64-windows/wineopenxr.dll aarch64-unix/wineopenxr.so aarch64-unix/libopenxr_loader.dylib wineopenxr64.json; do
    [ -f "$WOX/$f" ] || { echo "missing $WOX/$f; run NotProton's wineopenxr/build.sh" >&2; exit 1; }
done

mkdir -p "$staging/aarch64-windows" "$staging/aarch64-unix"
cp -f "$WOX/x86_64-windows/wineopenxr.dll" "$staging/aarch64-windows/"
cp -f "$WOX/aarch64-unix/wineopenxr.so" "$WOX/aarch64-unix/libopenxr_loader.dylib" "$staging/aarch64-unix/"
# The Khronos loader opens the runtime by its system32 path; Wine then takes the builtin.
cp -f "$WOX/x86_64-windows/wineopenxr.dll" "$WOX/wineopenxr64.json" "$sys32/"

if [ "${GFX:-dxvk}" = dxmt ]; then
    rm -f "$exe_dir/d3d11.dll"
    reg delete "HKCU\\Software\\Wine\\AppDefaults\\$exe_name\\DllOverrides" /v d3d11 /f 2>/dev/null || true
else
python3 -I - "$RUNNER/lib/dxvk/x86_64-windows/d3d11.dll" "$exe_dir/d3d11.dll" <<'PY'
import sys
b = bytearray(open(sys.argv[1], "rb").read())
assert b[0x40:0x50] == b"Wine builtin DLL", "not CrossOver's DXVK d3d11"
b[0x40:0x50] = bytes(16)
open(sys.argv[2], "wb").write(b)
PY
reg add "HKCU\\Software\\Wine\\AppDefaults\\$exe_name\\DllOverrides" /v d3d11 /t REG_SZ /d native /f
fi

if [ -n "${OC:-}" ]; then
    file "$OC" | grep -q "PE32+" || { echo "$OC is not a 64-bit DLL" >&2; exit 1; }
    grep -aq "IVRCompositor_" "$OC" || { echo "$OC does not look like OpenComposite" >&2; exit 1; }
    list=$(mktemp)
    openvr_dlls > "$list"
    [ -s "$list" ] || { rm -f "$list"; echo "no 64-bit openvr_api.dll in $game" >&2; exit 1; }
    while IFS= read -r f; do
        [ -f "$f.orig" ] || cp -p "$f" "$f.orig"
        cp -f "$OC" "$f"
        printf 'initUsingVulkan=false\n' > "$(dirname "$f")/opencomposite.ini"
        echo "OpenComposite in place of ${f#"$game"/}"
    done < "$list"
    rm -f "$list"
fi

reg add 'HKLM\Software\Khronos\OpenXR\1' /v ActiveRuntime /t REG_SZ /d 'C:\windows\system32\wineopenxr64.json' /f
reg add 'HKCU\Software\Wine\WineDbg' /v ShowCrashDialog /t REG_DWORD /d 0 /f
# The values wineopenxr_init_registry records for alvrxr under CrossOver (see alvrxr's vulkan.m).
reg add 'HKCU\Software\Wine\VR' /v state /t REG_DWORD /d 1 /f
reg add 'HKCU\Software\Wine\VR' /v openxr_vulkan_instance_extensions /t REG_SZ \
    /d 'VK_KHR_get_physical_device_properties2 VK_KHR_surface VK_KHR_win32_surface' /f
reg add 'HKCU\Software\Wine\VR' /v openxr_vulkan_device_extensions /t REG_SZ /d 'VK_KHR_maintenance1' /f
reg add 'HKCU\Software\Wine\VR' /v openxr_vulkan_device_vid /t REG_DWORD /d 0x106b /f
reg add 'HKCU\Software\Wine\VR' /v openxr_vulkan_device_pid /t REG_DWORD /d 0x1b0003f1 /f
"$WINESERVER" -w

mkdir -p "$HOME/.config/openxr/1"
active="$HOME/.config/openxr/1/active_runtime.json"
# Another runtime's manifest is left alone; an earlier alvrxr one is pointed at this runtime.
if [ -e "$active" ] && ! grep -q "libalvrxr.dylib" "$active"; then
    echo "note: $active names another runtime; leaving it" >&2
else
    cat > "$active" <<JSON
{
    "file_format_version": "1.0.0",
    "runtime": {
        "name": "alvrxr",
        "library_path": "$ALVRXR_LIB"
    }
}
JSON
fi
echo "set up $prefix for OpenXR ($exe)"
