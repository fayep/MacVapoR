#!/bin/sh
# Sets up one NotProton game prefix for OpenXR through wineopenxr and alvrxr, without touching
# NotProton or its CrossOver runner. Run it with the game closed, after the game has been
# launched once so its prefix exists.
#
#   tools/notproton-vr-setup.sh APPID 'Game.exe'      e.g. 620980 'Beat Saber.exe'
#   tools/notproton-vr-setup.sh --undo APPID 'Game.exe'
#
# What goes where, and why (NotProton 1.0.3's run script):
#   - wineopenxr goes into aarch64-windows/ and aarch64-unix/ under the prefix's Steam staging
#     directory. The run script puts that directory first on WINEDLLPATH and prunes stray
#     files in it, but not subdirectories; Wine's ARM64EC loader looks in those two.
#   - HKCU\Software\Wine\VR is written as a persistent key. The Steam shim creates it volatile
#     on every launch and leaves it alone when it already exists; without SteamVR it would
#     mark VR unavailable.
#   - DXVK's d3d11 goes beside the game with its builtin marker cleared, and an AppDefaults
#     override makes the game load it: on the FEX runner CrossOver's own DXVK switch never
#     reaches an ARM64EC process.
#   - The native OpenXR loader inside wineopenxr finds alvrxr through the per-user
#     ~/.config/openxr/1/active_runtime.json, since the run script passes no XR_* variables.
#
# Overridable: RUNNER, WOX (wineopenxr build output), ALVRXR_JSON, STEAM
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
undo=0
[ "${1:-}" = "--undo" ] && { undo=1; shift; }
[ $# -eq 2 ] || { sed -n 2,9p "$0" >&2; exit 2; }
appid=$1
exe=$2
case "$appid" in ''|*[!0-9]*) echo "not an app id: $appid" >&2; exit 2 ;; esac

RUNNER=${RUNNER:-$HOME/Library/Application Support/notproton/runners/current}
WOX=${WOX:-$HOME/Source/NotProton/build/wineopenxr-out}
ALVRXR_JSON=${ALVRXR_JSON:-$here/out/alvrxr.json}
STEAM=${STEAM:-$HOME/Library/Application Support/Steam}

prefix="$STEAM/steamapps/compatdata/$appid/pfx"
[ -f "$prefix/system.reg" ] || { echo "no prefix at $prefix; launch the game once first" >&2; exit 1; }
game_dir=$(sed -n 's/.*"installdir"[[:space:]]*"\(.*\)".*/\1/p' "$STEAM/steamapps/appmanifest_$appid.acf")
game="$STEAM/steamapps/common/$game_dir"
[ -f "$game/$exe" ] || { echo "no $exe in $game" >&2; exit 1; }
staging="$prefix/drive_c/Program Files (x86)/Steam"
sys32="$prefix/drive_c/windows/system32"

wine_unix="$RUNNER/lib/wine/aarch64-unix"
export CX_ROOT="$RUNNER" CX_HOME="$HOME/Library/Application Support/CrossOver"
export WINELOADER="$wine_unix/wine.app/Contents/MacOS/wine"
export WINESERVER="$RUNNER/bin/wineserver-arm64"
export WINEDLLPATH="$RUNNER/lib/wine/x86_64-windows:$wine_unix"
export WINEPREFIX="$prefix" WINEDEBUG=-all
# The game's own process; matching the prefix path would also catch anything tailing its logs.
if pgrep -fi "$exe" >/dev/null 2>&1; then
    echo "close the game first" >&2
    exit 1
fi

reg() { "$WINELOADER" reg "$@" >/dev/null; }

if [ $undo -eq 1 ]; then
    rm -rf "$staging/aarch64-windows/wineopenxr.dll" "$staging/aarch64-unix/wineopenxr.so" \
        "$staging/aarch64-unix/libopenxr_loader.dylib" "$sys32/wineopenxr.dll" "$sys32/wineopenxr64.json" \
        "$game/d3d11.dll"
    reg delete 'HKCU\Software\Wine\VR' /f || true
    reg delete "HKCU\\Software\\Wine\\AppDefaults\\$exe\\DllOverrides" /v d3d11 /f || true
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

python3 -I - "$RUNNER/lib/dxvk/x86_64-windows/d3d11.dll" "$game/d3d11.dll" <<'PY'
import sys
b = bytearray(open(sys.argv[1], "rb").read())
assert b[0x40:0x50] == b"Wine builtin DLL", "not CrossOver's DXVK d3d11"
b[0x40:0x50] = bytes(16)
open(sys.argv[2], "wb").write(b)
PY

reg add 'HKLM\Software\Khronos\OpenXR\1' /v ActiveRuntime /t REG_SZ /d 'C:\windows\system32\wineopenxr64.json' /f
reg add "HKCU\\Software\\Wine\\AppDefaults\\$exe\\DllOverrides" /v d3d11 /t REG_SZ /d native /f
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
if [ -e "$active" ] && ! cmp -s "$ALVRXR_JSON" "$active"; then
    echo "note: $active exists and differs; leaving it" >&2
else
    cp -f "$ALVRXR_JSON" "$active"
    # The manifest's library path is relative to the manifest, so point it at the build.
    python3 -I - "$active" "$here/out/libalvrxr.dylib" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))
m["runtime"]["library_path"] = sys.argv[2]
json.dump(m, open(sys.argv[1], "w"), indent=4)
PY
fi
echo "set up $prefix for OpenXR ($exe)"
