#!/bin/sh
# Sets up one NotProton prefix for a Meta Rift (Oculus PC) game, after notproton-vr-setup.sh has
# set it up for OpenXR. Run it with the game closed.
#
#   tools/rift-setup.sh SHORTCUT_ID META_APP_ID
#       e.g. 2449775607 1368187813209608 (Lone Echo, added to Steam as a non-Steam game)
#
# What goes where:
#   - RiftLift's Oculus-to-OpenXR bridge (https://github.com/Villagers654/RiftLift, MIT, derived
#     from Revive) goes into C:\Program Files\RiftLift. Its launcher starts the game with the
#     bridge loaded; the bridge reaches alvrxr through the prefix's wineopenxr.
#   - The Oculus registry keys say where the runtime is, as an installed Meta app would.
#   - Meta's signed LibOVRRT64_1.dll and LibOVRRT32_1.dll, which games check for but never run.
#   - The Oculus Platform SDK: Meta's own LibOVRPlatform64_1.dll and LibOVRPlatformImpl64_1.dll
#     (copied from a Meta PC install, in PLATFORM_DIR), with RiftLift's stand-in in between as
#     LibOVRPlatformImpl64_1.dll; Meta's is renamed LibOVRPlatformImpl64_1_real.dll. The stand-in
#     answers the game's start-up, user and entitlement questions locally and passes everything
#     else to Meta's. It is installed only after Meta has confirmed, with the documented
#     verify_entitlement call and AVP-Play's stored token, that the account owns the game.
#
# Overridable: RUNNER, STEAM, RIFTLIFT_ZIP (riftlift-compat.zip from RiftLift's release),
# PLATFORM_DIR, ACCOUNT (AVP-Play's keychain account, default "default")
set -eu
[ $# -eq 2 ] || { sed -n 2,6p "$0" >&2; exit 2; }
id=$1 app=$2
case "$id$app" in ''|*[!0-9]*) echo "IDs must be numeric" >&2; exit 2 ;; esac

RUNNER=${RUNNER:-$HOME/Library/Application Support/notproton/runners/current}
STEAM=${STEAM:-$HOME/Library/Application Support/Steam}
RIFTLIFT_ZIP=${RIFTLIFT_ZIP:-$HOME/Source/riftlift-dl/riftlift-compat.zip}
PLATFORM_DIR=${PLATFORM_DIR:-/Volumes/Ext/AVPPlay/rift/oculus-platform}
ACCOUNT=${ACCOUNT:-default}

prefix="$STEAM/steamapps/compatdata/$id/pfx"
[ -f "$prefix/system.reg" ] || { echo "no prefix for $id; launch the game once first" >&2; exit 1; }
for f in "$RIFTLIFT_ZIP" "$PLATFORM_DIR/LibOVRPlatform64_1.dll" "$PLATFORM_DIR/LibOVRPlatformImpl64_1.dll" \
         "$PLATFORM_DIR/LibOVRP2P64_1.dll"; do
    [ -f "$f" ] || { echo "missing $f" >&2; exit 1; }
done

# Ownership first: nothing is installed for a game Meta doesn't confirm.
owned=$(security find-generic-password -s avpplay-meta -a "$ACCOUNT" -w | python3 -I -c '
import json, sys, urllib.parse, urllib.request
token, app = sys.stdin.read().strip(), sys.argv[1]
def call(path, data=None):
    req = urllib.request.Request("https://graph.oculus.com" + path, data=data,
                                 headers={"Authorization": "Bearer " + token})
    return json.load(urllib.request.urlopen(req, timeout=30))
me = call("/me?fields=id")["id"]
print("yes" if call("/%s/verify_entitlement" % app, urllib.parse.urlencode({"user_id": me}).encode()).get("success") else "no")
' "$app")
[ "$owned" = yes ] || { echo "Meta says account '$ACCOUNT' does not own app $app; nothing installed" >&2; exit 1; }
echo "Meta confirms account '$ACCOUNT' owns app $app"

wine_unix="$RUNNER/lib/wine/aarch64-unix"
export CX_ROOT="$RUNNER" CX_HOME="$HOME/Library/Application Support/CrossOver"
export WINELOADER="$wine_unix/wine.app/Contents/MacOS/wine"
export WINESERVER="$RUNNER/bin/wineserver-arm64"
export WINEDLLPATH="$RUNNER/lib/wine/x86_64-windows:$wine_unix"
export WINEPREFIX="$prefix" WINEDEBUG=-all
reg() { "$WINELOADER" reg "$@" >/dev/null; }

riftlift="$prefix/drive_c/Program Files/RiftLift"
runtime="$prefix/drive_c/Program Files/Oculus/Support/oculus-runtime"
mkdir -p "$riftlift" "$runtime"
unzip -oq "$RIFTLIFT_ZIP" -d "$riftlift"
mv -f "$riftlift/LibOVRPlatformImpl64_1.dll" "$runtime/LibOVRPlatformImpl64_1.dll"
cp -f "$PLATFORM_DIR/LibOVRPlatform64_1.dll" "$runtime/"
cp -f "$PLATFORM_DIR/LibOVRPlatformImpl64_1.dll" "$runtime/LibOVRPlatformImpl64_1_real.dll"
# Most of the stand-in's exports are forwarders to LibOVRPlatformImpl64_1_real; Wine resolves those
# through the standard search order, which includes system32 but not the PATH set below.
cp -f "$PLATFORM_DIR/LibOVRPlatformImpl64_1.dll" "$prefix/drive_c/windows/system32/LibOVRPlatformImpl64_1_real.dll"
# Meta's implementation needs its peer-to-peer library beside it.
cp -f "$PLATFORM_DIR/LibOVRP2P64_1.dll" "$runtime/"
cp -f "$PLATFORM_DIR/LibOVRP2P64_1.dll" "$prefix/drive_c/windows/system32/"
# Meta's signed runtime DLLs are never run: a game's LibOVR shim checks that the file is there
# (and signed) before loading it, and RiftLift's bridge takes over the load.
for f in LibOVRRT64_1.dll LibOVRRT32_1.dll; do
    [ -f "$PLATFORM_DIR/$f" ] && cp -f "$PLATFORM_DIR/$f" "$runtime/"
done

# As an installed Meta app writes them (see RiftLift's runtime.py); Base ends in a backslash,
# since the Platform SDK appends Support\oculus-runtime\ to it.
for key in 'HKCU\Software\Oculus VR, LLC\Oculus' 'HKLM\Software\Oculus VR, LLC\Oculus' \
           'HKLM\Software\WOW6432Node\Oculus VR, LLC\Oculus'; do
    reg add "$key" /v Base /t REG_SZ /d 'C:\Program Files\Oculus\' /f
    reg add "$key\\Config" /v UseSystemProxy /t REG_DWORD /d 0 /f
done
# The stand-in loads Meta's LibOVRPlatformImpl64_1_real.dll by name.
path=$("$WINELOADER" reg query 'HKLM\System\CurrentControlSet\Control\Session Manager\Environment' /v PATH 2>/dev/null |
       tr -d '\r' | sed -n 's/^ *PATH *REG_[A-Z_]* *//p')
case ";$path;" in
    *';C:\Program Files\Oculus\Support\oculus-runtime;'*) ;;
    *) reg add 'HKLM\System\CurrentControlSet\Control\Session Manager\Environment' /v PATH /t REG_EXPAND_SZ \
           /d "$path;C:\\Program Files\\Oculus\\Support\\oculus-runtime" /f ;;
esac
# The stand-in's settings, for every process in the prefix: NotProton only passes the game its
# own variables. Offline: achievements, cloud saves and friends are answered locally rather
# than by Meta's service, which doesn't run here. The user ID is a stable local number.
reg add 'HKCU\Environment' /v RIFTLIFT_PLATFORM_OFFLINE /t REG_SZ /d 1 /f
"$WINELOADER" reg query 'HKCU\Environment' /v RIFTLIFT_USER_ID >/dev/null 2>&1 ||
    reg add 'HKCU\Environment' /v RIFTLIFT_USER_ID /t REG_SZ \
        /d "$(od -An -N6 -tu8 /dev/urandom | tr -d ' ')" /f
"$WINESERVER" -w
echo "set up $prefix for Rift app $app"
echo "launch it as: \"C:\\Program Files\\RiftLift\\RiftLiftLauncher.exe\" /wait /openxr /app <canonical name> /cwd <game folder> <game exe>"
