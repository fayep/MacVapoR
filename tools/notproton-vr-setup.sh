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
# Overridable: RUNNER, WOX (wineopenxr build output), ALVRXR_LIB (the runtime), STEAM, GAME_DIR
#
# Only tools a Mac has without the Command Line Tools, except python3 for DXVK mode.
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
ALVRXR_LIB=${ALVRXR_LIB:-$here/out/libalvrxr.dylib}
STEAM=${STEAM:-$HOME/Library/Application Support/Steam}

# The game may be in any Steam library; its prefix is in that library's compatdata or the main one's.
# A shortcut's prefix is always in the main one's.
if [ -n "${GAME_DIR:-}" ]; then
    game=$GAME_DIR
    prefix="$STEAM/steamapps/compatdata/$appid/pfx"
    [ -f "$prefix/system.reg" ] || { echo "no prefix for $appid; launch the game once first" >&2; exit 1; }
else
library=
for lib in "$STEAM" $(sed -n 's/.*"path"[[:space:]]*"\(.*\)".*/\1/p' "$STEAM/steamapps/libraryfolders.vdf" | tr ' ' '\001'); do
    lib=$(printf '%s' "$lib" | tr '\001' ' ')
    [ -f "$lib/steamapps/appmanifest_$appid.acf" ] && { library=$lib; break; }
done
[ -n "$library" ] || { echo "app $appid is not installed in any Steam library" >&2; exit 1; }
prefix="$library/steamapps/compatdata/$appid/pfx"
[ -f "$prefix/system.reg" ] || prefix="$STEAM/steamapps/compatdata/$appid/pfx"
[ -f "$prefix/system.reg" ] || { echo "no prefix for $appid; launch the game once first" >&2; exit 1; }
game_dir=$(sed -n 's/.*"installdir"[[:space:]]*"\(.*\)".*/\1/p' "$library/steamapps/appmanifest_$appid.acf")
game="$library/steamapps/common/$game_dir"
fi
[ -f "$game/$exe" ] || { echo "no $exe in $game" >&2; exit 1; }
# The executable may be in a subfolder, as The Lab's TheLab/win64/TheLab.exe; Wine's per-app
# settings go by its name, and DXVK's d3d11 goes beside it.
exe_name=$(basename "$exe")
exe_dir=$(dirname "$game/$exe")
staging="$prefix/drive_c/Program Files (x86)/Steam"
sys32="$prefix/drive_c/windows/system32"

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
