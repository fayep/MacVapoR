#!/bin/sh
# Runs the Windows build of hello_xr under NotProton's FEX CrossOver runner, through
# wineopenxr and alvrxr, in a test prefix of its own. Nothing in the runner is modified:
# wineopenxr comes in through WINEDLLPATH and CrossOver's own DXVK is selected.
#
#   tools/wine-hello.sh [hello_xr args]     default: -g D3D11
#   APP='C:\games\x\x.exe' tools/wine-hello.sh [args]   any other app in the prefix
#
# Overridable: RUNNER, PREFIX, WOX (dir with wineopenxr.dll and wineopenxr.so), HELLO (dir
# with hello_xr.exe and libopenxr_loader.dll), ALVRXR_JSON.
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
RUNNER=${RUNNER:-$HOME/Library/Application Support/notproton/runners/crossover-27.0.0.41069-fex/CrossOver}
PREFIX=${PREFIX:-$HOME/Library/Application Support/alvrxr/wine-prefix}
WOX=${WOX:-$here/build/wineopenxr}
HELLO=${HELLO:-$HOME/Source/OpenXR-SDK-Source/build-win64}
ALVRXR_JSON=${ALVRXR_JSON:-$here/out/alvrxr.json}
MINGW=/opt/homebrew/opt/mingw-w64/toolchain-x86_64/x86_64-w64-mingw32

wine_unix="$RUNNER/lib/wine/aarch64-unix"
export CX_ROOT="$RUNNER"
# CrossOver's compatibility database, which is also what applies CX_GRAPHICS_BACKEND.
export CX_HOME="$HOME/Library/Application Support/CrossOver"
export WINELOADER="$wine_unix/wine.app/Contents/MacOS/wine"
export WINESERVER="$RUNNER/bin/wineserver-arm64"
export WINEDLLPATH="$RUNNER/lib/wine/x86_64-windows:$wine_unix:$WOX/x86_64-windows:$WOX/aarch64-unix"
export WINEPREFIX="$PREFIX"
export PATH="$RUNNER/bin:$PATH"
# The native OpenXR loader inside wineopenxr's unix half finds alvrxr through this.
export XR_RUNTIME_JSON="$ALVRXR_JSON"
export WINEDEBUG=${WINEDEBUG:-err+all,fixme-all}

[ -x "$WINELOADER" ] || { echo "no FEX wine loader at $WINELOADER" >&2; exit 1; }
for f in "$WOX/x86_64-windows/wineopenxr.dll" "$WOX/aarch64-unix/wineopenxr.so" "$HELLO/src/tests/hello_xr/hello_xr.exe"; do
    [ -f "$f" ] || { echo "missing $f" >&2; exit 1; }
done

if [ ! -f "$PREFIX/system.reg" ]; then
    echo "==> creating the test prefix $PREFIX"
    mkdir -p "$PREFIX"
    "$WINELOADER" wineboot --init
    "$WINESERVER" -w
fi

sys32="$PREFIX/drive_c/windows/system32"
# wineopenxr turns D3D11 into Vulkan through DXVK. On the FEX build every process is ARM64EC,
# so Wine's builtin search returns its own ARM64X d3d11 and never CrossOver's x86_64 DXVK; with
# the builtin marker blanked, the DXVK copy loads as a native DLL under FEX instead.
python3 -I - "$RUNNER/lib/dxvk/x86_64-windows/d3d11.dll" "$sys32/d3d11.dll" <<'PYEOF'
import sys
b = bytearray(open(sys.argv[1], "rb").read())
assert b[0x40:0x50] == b"Wine builtin DLL"
b[0x40:0x50] = bytes(16)
open(sys.argv[2], "wb").write(b)
PYEOF
# Wine does not find a builtin through WINEDLLPATH when the OpenXR loader asks for it by its
# system32 path, so the PE half goes into the test prefix; its unix half is still found
# through WINEDLLPATH.
cp -f "$WOX/x86_64-windows/wineopenxr.dll" "$sys32/wineopenxr.dll"
cat > "$sys32/wineopenxr64.json" <<'JSON'
{
   "file_format_version": "1.0.0",
   "runtime": {
      "library_path": "C:\\windows\\system32\\wineopenxr.dll"
   }
}
JSON
# Crashes go to the log rather than a dialog on the user's screen.
"$WINELOADER" reg add 'HKCU\Software\Wine\WineDbg' /v ShowCrashDialog /t REG_DWORD /d 0 /f >/dev/null
"$WINELOADER" reg add 'HKLM\Software\Khronos\OpenXR\1' /v ActiveRuntime /t REG_SZ \
    /d 'C:\windows\system32\wineopenxr64.json' /f >/dev/null

# What Proton's steam helper does at launch: mark VR available, then have wineopenxr ask the
# runtime for its Vulkan requirements and record them where it reads them back.
"$WINELOADER" reg add 'HKCU\Software\Wine\VR' /v state /t REG_DWORD /d 1 /f >/dev/null
"$WINELOADER" rundll32 wineopenxr.dll,wineopenxr_init_registry

app="$PREFIX/drive_c/alvrxr-test"
mkdir -p "$app"
cp -f "$HELLO/src/tests/hello_xr/hello_xr.exe" "$HELLO/src/loader/libopenxr_loader.dll" \
    "$MINGW/lib/libstdc++-6.dll" "$MINGW/lib/libgcc_s_seh-1.dll" "$MINGW/bin/libwinpthread-1.dll" "$app/"

if [ -n "${APP:-}" ]; then
    exe=$APP
    cd "$PREFIX/drive_c"
else
    exe='C:\alvrxr-test\hello_xr.exe'
    [ $# -gt 0 ] || set -- -g D3D11
    cd "$app"
fi
export WINEDLLOVERRIDES="d3d11=n"
# hello_xr quits on a key press; keep its stdin open.
sleep 100000 | "$WINELOADER" "$exe" "$@"
