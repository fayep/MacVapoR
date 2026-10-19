#!/bin/sh
# Chooses which build of the runtime games and the home scene use, so a new one can be tried and
# the known-good one put back. A variant is a folder in MacVapoR/runtimes holding libalvrxr.dylib,
# libalvr_server_core.dylib and vapord; "installed" is MacVapoR's own runtime folder, which its
# Install button writes. Two things select one: the OpenXR manifest, which every game's runtime
# loader reads, and the home scene's launchd agent, which runs that variant's vapord with its
# libalvrxr.dylib.
#
# Usage: runtime-switch.sh status | list | NAME
set -eu
support="$HOME/Library/Application Support/MacVapoR"
manifest="$HOME/.config/openxr/1/active_runtime.json"
label=com.zippysoft.macvapor.home
plist="$HOME/Library/LaunchAgents/$label.plist"
domain="gui/$(id -u)"
claim="$HOME/Library/Application Support/alvrxr/claim.pid"

variant_dir() {
    if [ "$1" = installed ]; then echo "$support/runtime"; else echo "$support/runtimes/$1"; fi
}

# The variant whose folder holds this path, or the path itself if none does.
variant_of() {
    dir=$(dirname "$1")
    [ "$dir" = "$support/runtime" ] && { echo installed; return; }
    case "$dir" in "$support/runtimes/"*) basename "$dir" ;; *) echo "$1" ;; esac
}

# A game holds the headset while the pid it recorded is alive and isn't the home scene.
game_holding() {
    [ -f "$claim" ] || return 1
    pid=$(tr -dc 0-9 < "$claim")
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null || return 1
    case "$(ps -o comm= -p "$pid" 2>/dev/null)" in */vapord | vapord) return 1 ;; esac
    echo "$pid"
}

status() {
    lib=$(plutil -extract runtime.library_path raw -o - "$manifest" 2>/dev/null || echo "?")
    echo "games:      $(variant_of "$lib")  ($lib)"
    if [ -f "$plist" ]; then
        prog=$(plutil -extract ProgramArguments.0 raw -o - "$plist" 2>/dev/null || echo "?")
        echo "home scene: $(variant_of "$prog")  ($prog)"
    else
        echo "home scene: no launchd agent"
    fi
    pid=$(launchctl print "$domain/$label" 2>/dev/null | awk '$1 == "pid" {print $3; exit}')
    if [ -n "$pid" ]; then echo "vapord:     running, pid $pid"; else echo "vapord:     not running"; fi
    if holder=$(game_holding); then
        echo "headset:    held by a game, pid $holder ($(ps -o comm= -p "$holder"))"
    fi
}

case "${1:-status}" in
status)
    status
    ;;
list)
    [ -d "$support/runtime" ] && echo installed
    [ -d "$support/runtimes" ] && ls "$support/runtimes"
    ;;
-*)
    echo "usage: $0 status | list | NAME" >&2
    exit 2
    ;;
*)
    name=$1
    dir=$(variant_dir "$name")
    for f in libalvrxr.dylib libalvr_server_core.dylib vapord; do
        [ -f "$dir/$f" ] || { echo "no $f in $dir" >&2; exit 1; }
    done
    if holder=$(game_holding); then
        echo "a game holds the headset (pid $holder); quit it first" >&2
        exit 1
    fi
    mkdir -p "$(dirname "$manifest")"
    cat > "$manifest" <<JSON
{
    "file_format_version": "1.0.0",
    "runtime": {
        "name": "alvrxr",
        "library_path": "$dir/libalvrxr.dylib"
    }
}
JSON
    if [ -f "$plist" ]; then
        plutil -replace ProgramArguments -json "[\"$dir/vapord\", \"$dir/libalvrxr.dylib\"]" "$plist"
        # Games reach the compositor through this; a build without one never looks it up.
        plutil -replace MachServices -json '{"com.zippysoft.macvapor.compositor": true}' "$plist"
        launchctl bootout "$domain/$label" 2>/dev/null || true
        # bootout returns before the job is gone, and bootstrap fails until it is.
        i=0
        while launchctl print "$domain/$label" >/dev/null 2>&1 && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
        launchctl bootstrap "$domain" "$plist"
    fi
    status
    ;;
esac
