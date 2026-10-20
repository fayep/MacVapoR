#!/bin/sh
# Adds a Meta Rift (Oculus PC) game to Steam as a NotProton game that runs on the Vision Pro through
# alvrxr: the files, a Steam shortcut with artwork, its prefix, and the OpenXR and Rift setup.
#
#   tools/rift-add.sh [--account NAME] [--from-pc HOST] [--patched-dxmt] META_APP_ID
#       e.g. tools/rift-add.sh --account default 1180401875303371          (Asgard's Wrath)
#            tools/rift-add.sh --account wife --from-pc jormungandr 1081190428622821
#
#   --account  AVP-Play's keychain account (`avpplay login --account NAME`). Meta has to confirm
#              that this account owns the game before anything is copied or installed.
#   --patched-dxmt  our DXMT with SwapDeviceContextState, for games that need it (Lone Echo);
#              others keep CrossOver's (Robo Recall crashed on ours).
#   --from-pc  copy the game over ssh from that Windows PC's Meta library (D:\Oculus or wherever
#              its manifests say), when it isn't in RIFT_DIR yet. The copy is checked file by file
#              against the SHA-256 values in Meta's manifest.
#
# Steam must be closed for the last step (the shortcut); the script waits for that.
#
# Overridable: RIFT_DIR (/Volumes/Ext/AVPPlay/rift: games, art, oculus-platform), STEAM, STEAM_USER,
#   RIFTLIFT_BRIDGE (a RiftLiftOpenXR64.dll with vtable hooks, ~/Source/RiftLift/build-msvc/bin),
#   DXMT_BUILD (an ARM64EC DXMT with SwapDeviceContextState, ~/Source/dxmt/install-arm64ec/aarch64-windows)
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
account=default host= patched_dxmt=0
while [ $# -gt 1 ]; do
    case "$1" in
        --patched-dxmt) patched_dxmt=1; shift ;;
        --account) account=$2; shift 2 ;;
        --from-pc) host=$2; shift 2 ;;
        *) sed -n 2,14p "$0" >&2; exit 2 ;;
    esac
done
[ $# -eq 1 ] || { sed -n 2,14p "$0" >&2; exit 2; }
app=$1
case "$app" in ''|*[!0-9]*) echo "not a Meta app ID: $app" >&2; exit 2 ;; esac

RIFT_DIR=${RIFT_DIR:-/Volumes/Ext/AVPPlay/rift}
STEAM=${STEAM:-$HOME/Library/Application Support/Steam}
RIFTLIFT_BRIDGE=${RIFTLIFT_BRIDGE:-$HOME/Source/RiftLift/build-msvc/bin/RiftLiftOpenXR64.dll}
DXMT_BUILD=${DXMT_BUILD:-$HOME/Source/dxmt/install-arm64ec/aarch64-windows}
M="$HOME/Library/Application Support/MacVapoR"
if [ -z "${STEAM_USER:-}" ]; then
    STEAM_USER=$(ls -t "$STEAM/userdata" | head -1)
fi
step() { printf '\n== %s\n' "$*"; }

# Meta's Graph API with the account's token, sent only as a header.
meta() {
    security find-generic-password -s avpplay-meta -a "$account" -w | python3 -I -c '
import json, sys, urllib.parse, urllib.request
token, what, app = sys.stdin.read().strip(), sys.argv[1], sys.argv[2]
def call(path, data=None):
    req = urllib.request.Request("https://graph.oculus.com" + path, data=data,
                                 headers={"Authorization": "Bearer " + token})
    return json.load(urllib.request.urlopen(req, timeout=30))
if what == "owns":
    me = call("/me?fields=id")["id"]
    r = call("/%s/verify_entitlement" % app, urllib.parse.urlencode({"user_id": me}).encode())
    print("yes" if r.get("success") else "no")
else:
    print(call("/%s?fields=display_name" % app).get("display_name", ""))
' "$1" "$app"
}

step "ownership"
[ "$(meta owns)" = yes ] || { echo "Meta says account '$account' does not own app $app; stopping" >&2; exit 1; }
name=$(meta name)
echo "account '$account' owns $name ($app)"

# The game's folder: <canonical name>/ beside its manifest <canonical name>.json, in RIFT_DIR/<copy>/.
find_manifest() {
    python3 -I - "$RIFT_DIR" "$app" <<'PY'
import glob, json, os, sys
for path in glob.glob(os.path.join(sys.argv[1], "*", "*.json")):
    try:
        m = json.load(open(path, encoding="utf-8-sig"))
    except (ValueError, OSError):
        continue
    if str(m.get("appId")) == sys.argv[2] and os.path.isdir(os.path.join(os.path.dirname(path), m["canonicalName"])):
        print(path)
        break
PY
}
manifest=$(find_manifest)
if [ -z "$manifest" ]; then
    [ -n "$host" ] || { echo "app $app is not in $RIFT_DIR; give --from-pc HOST to copy it" >&2; exit 1; }
    step "copying from $host"
    # Where that PC's Meta library keeps this game: the manifest's folder sits beside Software\.
    enc=$(printf '%s' "
\$ProgressPreference = 'SilentlyContinue'
\$libs = @(Get-ItemProperty 'HKCU:\\Software\\Oculus VR, LLC\\Oculus\\Libraries\\*' -ErrorAction SilentlyContinue | ForEach-Object { \$_.OriginalPath })
\$libs += Get-PSDrive -PSProvider FileSystem | ForEach-Object { Join-Path \$_.Root 'Oculus' }
foreach (\$l in (\$libs | Select-Object -Unique)) {
  foreach (\$f in (Get-ChildItem (Join-Path \$l 'Manifests') -Filter *.json -ErrorAction SilentlyContinue)) {
    try { \$m = Get-Content \$f.FullName -Raw | ConvertFrom-Json } catch { continue }
    if (\"\$(\$m.appId)\" -eq '$app') { '{0}|{1}|{2}' -f \$l, \$m.canonicalName, \$m.version; exit }
  }
}" | iconv -f UTF-8 -t UTF-16LE | base64 | tr -d '\n')
    found=$(ssh -o BatchMode=yes "$host" "powershell -NoProfile -NonInteractive -EncodedCommand $enc" 2>/dev/null | tr -d '\r' | grep '|' | head -1)
    [ -n "$found" ] || { echo "app $app is not installed in $host's Meta library" >&2; exit 1; }
    lib=$(printf '%s' "$found" | cut -d'|' -f1 | tr '\\' '/') canon=$(printf '%s' "$found" | cut -d'|' -f2)
    version=$(printf '%s' "$found" | cut -d'|' -f3)
    dest="$RIFT_DIR/$canon-$version"
    mkdir -p "$dest"
    scp -q -o BatchMode=yes "$host:$lib/Manifests/$canon.json" "$dest/"
    scp -q -r -o BatchMode=yes "$host:$lib/Software/$canon" "$dest/"
    chmod -R u+rwX,go+rX,go-w "$dest"
    manifest="$dest/$canon.json"
fi
dir=$(dirname "$manifest")
eval "$(python3 -I - "$manifest" <<'PY'
import json, shlex, sys
m = json.load(open(sys.argv[1], encoding="utf-8-sig"))
for k in ("canonicalName", "launchFile", "version"):
    print("%s=%s" % (k, shlex.quote(str(m[k]))))
PY
)"
game="$dir/$canonicalName"

step "checking the files against Meta's manifest"
python3 -I "$here/tools/check-manifest.py" "$manifest" "$game" | tee /dev/stderr | grep -q " 0 differ, 0 missing" ||
    { echo "the copy doesn't match Meta's manifest; stopping" >&2; exit 1; }

# What to start: the launch file, or for an Unreal bootstrapper the shipping binary it would start
# as a child (which RiftLift's launcher wouldn't reach).
exe=$(printf '%s' "$launchFile" | tr '\\' '/')
stem=$(basename "$exe" .exe)
shipping="$(dirname "$exe")/$stem/Binaries/Win64/$stem-Win64-Shipping.exe"
game_args=
if [ -f "$game/$shipping" ]; then
    exe=$shipping
    # The Mac window is only the spectator mirror: keep it small rather than full screen.
    game_args=" -windowed -ResX=1280 -ResY=720"
fi
exe=${exe#./}
echo "starts $exe"

# The shortcut's app ID, from the Meta app ID, so running this again updates the same game.
id=$(python3 -I -c 'import sys, zlib; print((zlib.crc32(("rift:" + sys.argv[1]).encode()) & 0xFFFFFFFF) | 0x80000000)' "$app")
compat="$STEAM/steamapps/compatdata/$id"
prefix="$compat/pfx"
echo "Steam shortcut $id"

if [ ! -f "$prefix/system.reg" ]; then
    step "creating the prefix"
    # NotProton's own run script, as on a game's first launch; wineboot is one of its helpers.
    mkdir -p "$compat"
    STEAM_COMPAT_DATA_PATH="$compat" STEAM_COMPAT_INSTALL_PATH="$game" SteamAppId=$id \
        STEAM_COMPAT_CLIENT_INSTALL_PATH="$STEAM/Steam.AppBundle/Steam/Contents/MacOS" \
        "$STEAM/compatibilitytools.d/notproton/run" waitforexitandrun 'C:\windows\system32\wineboot.exe' >/dev/null 2>&1 || true
    # The registry files are written when the prefix's wineserver exits.
    RUNNER="$HOME/Library/Application Support/notproton/runners/current"
    CX_ROOT="$RUNNER" WINEPREFIX="$prefix" "$RUNNER/bin/wineserver-arm64" -w 2>/dev/null || true
    [ -f "$prefix/system.reg" ] || { echo "NotProton didn't create $prefix; see $compat/notproton-run.log" >&2; exit 1; }
fi

step "OpenXR"
GFX=dxmt GAME_DIR="$game" WOX="$M/wineopenxr" ALVRXR_LIB="$M/runtime/libalvrxr.dylib" STEAM="$STEAM" \
    "$here/tools/notproton-vr-setup.sh" "$id" "$exe"

step "Rift"
ACCOUNT=$account STEAM="$STEAM" PLATFORM_DIR="$RIFT_DIR/oculus-platform" "$here/tools/rift-setup.sh" "$id" "$app"
if [ -f "$RIFTLIFT_BRIDGE" ]; then
    cp -f "$RIFTLIFT_BRIDGE" "$prefix/drive_c/Program Files/RiftLift/RiftLiftOpenXR64.dll"
    echo "RiftLift bridge from $RIFTLIFT_BRIDGE"
fi

# Until CrossOver's DXMT has SwapDeviceContextState: ours, loaded as native by the game alone.
# CX_GRAPHICS_BACKEND=dxmt stays set, so CrossOver still provides winemetal and its Metal side.
if [ "$patched_dxmt" = 1 ] && [ -f "$DXMT_BUILD/d3d11.dll" ]; then
    step "DXMT ($DXMT_BUILD)"
    RUNNER="$HOME/Library/Application Support/notproton/runners/current"
    W="$RUNNER/lib/wine/aarch64-unix/wine.app/Contents/MacOS/wine"
    backup="$compat/dxmt-builtin-backup"
    mkdir -p "$backup"
    for f in d3d11 dxgi d3d10core; do
        [ -f "$backup/$f.dll" ] || cp -p "$prefix/drive_c/windows/system32/$f.dll" "$backup/$f.dll"
        python3 -I - "$DXMT_BUILD/$f.dll" "$prefix/drive_c/windows/system32/$f.dll" <<'PY'
import sys
b = bytearray(open(sys.argv[1], "rb").read())
assert b[0x40:0x50] == b"Wine builtin DLL", "not a Wine builtin DLL"
b[0x40:0x50] = bytes(16)   # native, so the per-game override loads this file
open(sys.argv[2], "wb").write(b)
PY
        CX_ROOT="$RUNNER" WINEPREFIX="$prefix" WINEDEBUG=-all WINESERVER="$RUNNER/bin/wineserver-arm64" \
            "$W" reg add "HKCU\\Software\\Wine\\AppDefaults\\$(basename "$exe")\\DllOverrides" /v $f /t REG_SZ /d native /f >/dev/null
    done
    CX_ROOT="$RUNNER" WINEPREFIX="$prefix" "$RUNNER/bin/wineserver-arm64" -w
fi

step "artwork"
art="$RIFT_DIR/art/$app"
mkdir -p "$art/page"
if curl -fsSL -A "Mozilla/5.0" -o "$art/page/store.html" "https://www.meta.com/experiences/pcvr/$app/"; then
    url=$(python3 -I - "$art/page/store.html" <<'PY'
import html, re, sys
t = open(sys.argv[1], encoding="utf-8", errors="replace").read()
best = (0, "")
for u in re.findall(r'https:\\?/\\?/scontent[^"\\ ]+?\.(?:webp|jpg|png)\?[^"\\ ]+', t):
    u = html.unescape(u.replace("\\/", "/"))
    m = re.search(r"_s(\d+)x(\d+)", u)
    size = int(m.group(1)) if m else 0
    if size > best[0]:
        best = (size, u)
print(best[1])
PY
)
    if [ -n "$url" ] && curl -fsSL -o "$art/key" "$url" && sips -s format png "$art/key" --out "$art/key.png" >/dev/null 2>&1; then
        [ -x "$here/build/steamart" ] || swiftc -O -o "$here/build/steamart" "$here/tools/steamart.swift"
        "$here/build/steamart" "$art/key.png" "$art" "$name"
        grid="$STEAM/userdata/$STEAM_USER/config/grid"
        mkdir -p "$grid"
        cp -f "$art/portrait.png" "$grid/${id}p.png"
        cp -f "$art/wide.png" "$grid/$id.png"
        cp -f "$art/hero.png" "$grid/${id}_hero.png"
    else
        echo "no artwork found on the store page; the shortcut gets none"
    fi
fi

step "Steam shortcut"
if pgrep -x steam_osx >/dev/null; then
    echo "quit Steam to finish (it rewrites its library when it quits); waiting..."
    while pgrep -x steam_osx >/dev/null; do sleep 3; done
    sleep 2
fi
# Forward slashes: Steam strips backslashes from launch options; Windows takes either. The
# variables need %command% after them, or Steam hands them to the launcher as arguments.
winpath() { case "$1" in *" "*) printf '"Z:%s"' "$1" ;; *) printf 'Z:%s' "$1" ;; esac; }
opts="CX_GRAPHICS_BACKEND=dxmt WINEMSYNC=1 %command% /wait /openxr /app $canonicalName /cwd $(winpath "$(dirname "$game/$exe")") $(winpath "$game/$exe")$game_args"
python3 -I "$here/tools/steam_shortcut.py" --steam "$STEAM" --user "$STEAM_USER" --appid "$id" --name "$name" \
    --exe "$prefix/drive_c/Program Files/RiftLift/RiftLiftLauncher.exe" \
    --start-dir "$prefix/drive_c/Program Files/RiftLift" \
    --icon "$([ -f "$art/icon.png" ] && printf '%s' "$art/icon.png")" --launch-options "$opts" --vr
printf 'app=%s\naccount=%s\nname=%s\nversion=%s\n' "$app" "$account" "$name" "$version" > "$compat/rift-app.txt"

printf '\n%s is in Steam (shortcut %s, set up for account %s). Open Steam and launch it.\n' "$name" "$id" "$account"
