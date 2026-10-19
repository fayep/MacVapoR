#!/bin/sh
# Checks notproton-vr-setup.sh --scan and --clean against a made-up Steam library in a scratch
# folder: two libraries, three games, their prefixes, NotProton's run script and bridge, a
# shared OpenVR runtime. Nothing outside the scratch folder is read or changed, except that
# RUNNER's wineserver (NotProton's runner, if there) is started on a scratch prefix to check
# that a running prefix is refused.
#
#   tests/cleanup-check.sh            KEEP=1 keeps the scratch folder and prints where it is
#   APP=path/to/MacVapoR tests/cleanup-check.sh
#       also runs the app's own scan and clean-up (its hidden --cleanup-scan) on a copy
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
script=$here/tools/notproton-vr-setup.sh
RUNNER=${RUNNER:-$HOME/Library/Application Support/notproton/runners/current}
S=$(mktemp -d "${TMPDIR:-/tmp}/cleanup-check.XXXXXX")
[ -n "${KEEP:-}" ] && echo "scratch: $S" || trap 'rm -rf "$S"' EXIT
fails=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi; }

main=$S/Steam
ext=$S/Ext
mkdir -p "$main/steamapps/common" "$ext/steamapps/common" "$main/compatibilitytools.d/notproton" \
    "$main/userdata/1/config"
cat > "$main/steamapps/libraryfolders.vdf" <<EOF
"libraryfolders"
{
	"0"
	{
		"path"		"$main"
	}
	"1"
	{
		"path"		"$ext"
	}
}
EOF
# Only the names --scan looks for; the rest of a run script doesn't matter here.
printf '#!/bin/sh\nlink_vrclient() {\n  :\n}\nstage_wineopenxr() {\n  :\n}\n' > "$S/run-new"
printf '#!/bin/sh\n# NotProton 1.0.3\n' > "$S/run-old"
cp "$S/run-new" "$main/compatibilitytools.d/notproton/run"
cat > "$main/userdata/1/config/localconfig.vdf" <<'EOF'
"UserLocalConfigStore"
{
	"Software"
	{
		"Valve"
		{
			"Steam"
			{
				"apps"
				{
					"100"
					{
						"LaunchOptions"		"CX_GRAPHICS_BACKEND=dxmt %command%"
					}
				}
			}
		}
	}
}
EOF

# NotProton's wineopenxr, MacVapoR's older one, OpenComposite builds and the shared runtime.
bridge=$S/bridge
mkdir -p "$bridge/wineopenxr/x86_64-windows" "$bridge/wineopenxr/aarch64-unix"
echo "notproton wineopenxr dll" > "$bridge/wineopenxr/x86_64-windows/wineopenxr.dll"
echo "notproton wineopenxr so" > "$bridge/wineopenxr/aarch64-unix/wineopenxr.so"
echo "notproton loader" > "$bridge/wineopenxr/aarch64-unix/libopenxr_loader.dylib"
echo '{"runtime":"wineopenxr"}' > "$bridge/wineopenxr/wineopenxr64.json"
mkdir -p "$S/oc" "$S/openvr/bin/win64"
printf 'MZ OpenComposite OpenOVR initUsingVulkan IVRCompositor_ build 1\n' > "$S/oc/openvr_api.dll"
printf 'MZ OpenComposite OpenOVR initUsingVulkan IVRCompositor_ build 2 (patched)\n' > "$S/oc-custom.dll"
cp "$S/oc/openvr_api.dll" "$S/openvr/bin/win64/vrclient_x64.dll"
printf '{ "runtime": ["%s"], "version": 1 }\n' "$S/openvr" > "$S/openvrpaths.vrpath"

prefix() {   # PFX: a prefix with the sections Set Up writes, or just NotProton's own.
    p=$1/pfx
    mkdir -p "$p/drive_c/windows/system32" "$p/drive_c/Program Files (x86)/Steam/aarch64-windows" \
        "$p/drive_c/Program Files (x86)/Steam/aarch64-unix"
    cat > "$p/user.reg" <<'EOF'
WINE REGISTRY Version 2
;; All keys relative to REGISTRY\\User\\S-1-5-21-0-0-0-1000

#arch=win64

[Control Panel\\Desktop] 1792098177
#time=1dd5ce8d90453c8
"FontSmoothing"="2"

EOF
    cat > "$p/system.reg" <<'EOF'
WINE REGISTRY Version 2
;; All keys relative to REGISTRY\\Machine

#arch=win64

[Software\\Khronos\\OpenXR\\1] 1792106039
#time=1dd5cfadc3d8098
"ActiveRuntime"="C:\\windows\\system32\\wineopenxr64.json"

[Software\\Khronos\\Vulkan\\Drivers] 1792105087
#time=1dd5cfa9a28cd28
"C:\\windows\\winevulkan.json"=dword:00000000

EOF
}
old_setup() {   # PFX EXE: what Set Up adds to a prefix
    p=$1/pfx
    cat >> "$p/user.reg" <<EOF
[Software\\\\Wine\\\\AppDefaults\\\\$2\\\\DllOverrides] 1792273361
#time=1dd5e8e62ba1296
"d3d11"="native"

[Software\\\\Wine\\\\VR] 1792098303
#time=1dd5ce8d90453c8
"openxr_vulkan_device_extensions"="VK_KHR_maintenance1"
"openxr_vulkan_device_pid"=dword:1b0003f1
"openxr_vulkan_device_vid"=dword:0000106b
"openxr_vulkan_instance_extensions"="VK_KHR_get_physical_device_properties2 VK_KHR_surface VK_KHR_win32_surface"
"state"=dword:00000001

[Software\\\\Wine\\\\VR\\\\Extra] 1792098303
"x"="y"

[Software\\\\Wine\\\\VRLike] 1792098303
"keep"="me"

[Software\\\\Wine\\\\WineDbg] 1792098177
#time=1dd5ce8d90453c8
"ShowCrashDialog"=dword:00000000

EOF
    s="$p/drive_c/Program Files (x86)/Steam"
    echo "macvapor 0.3 wineopenxr dll" > "$s/aarch64-windows/wineopenxr.dll"
    echo "macvapor 0.3 wineopenxr so" > "$s/aarch64-unix/wineopenxr.so"
    echo "macvapor 0.3 loader" > "$s/aarch64-unix/libopenxr_loader.dylib"
    cp "$s/aarch64-windows/wineopenxr.dll" "$p/drive_c/windows/system32/"
    cp "$bridge/wineopenxr/wineopenxr64.json" "$p/drive_c/windows/system32/"
}
notproton_staged() {   # PFX: what the new NotProton stages itself
    p=$1/pfx
    s="$p/drive_c/Program Files (x86)/Steam"
    cp "$bridge/wineopenxr/x86_64-windows/wineopenxr.dll" "$s/aarch64-windows/"
    cp "$bridge/wineopenxr/aarch64-unix/wineopenxr.so" "$bridge/wineopenxr/aarch64-unix/libopenxr_loader.dylib" "$s/aarch64-unix/"
    cp "$bridge/wineopenxr/x86_64-windows/wineopenxr.dll" "$bridge/wineopenxr/wineopenxr64.json" "$p/drive_c/windows/system32/"
}
manifest() {   # LIBRARY APPID NAME DIR
    printf '"AppState"\n{\n\t"appid"\t\t"%s"\n\t"name"\t\t"%s"\n\t"installdir"\t\t"%s"\n}\n' "$2" "$3" "$4" \
        > "$1/steamapps/appmanifest_$2.acf"
}
dxvk() {   # a d3d11.dll as Set Up leaves it: builtin marker cleared, DXVK inside
    { printf 'MZ'; dd if=/dev/zero bs=1 count=62 2>/dev/null; dd if=/dev/zero bs=1 count=16 2>/dev/null
      printf 'DXVK d3d11\n'; } > "$1"
}

# Game A, OpenVR, in the second library, set to DXMT: everything Set Up leaves, plus junk.
manifest "$ext" 100 "Game A" "Game A"
a=$ext/steamapps/common/Game\ A
mkdir -p "$a/Plugins" "$a/Old"
echo "MZ game exe" > "$a/GameA.exe"
dxvk "$a/d3d11.dll"
cp "$S/oc/openvr_api.dll" "$a/Plugins/openvr_api.dll"
echo "MZ Valve openvr_api 1.0 for Game A" > "$a/Plugins/openvr_api.dll.orig"
printf 'initUsingVulkan=false\n' > "$a/Plugins/opencomposite.ini"
cp "$S/oc/openvr_api.dll" "$a/Plugins/openvr_api.dll.bak-before-notifications"
echo "MZ Valve openvr_api 0.9 for Game A" > "$a/Old/openvr_api.dll"
cp "$a/Old/openvr_api.dll" "$a/Old/openvr_api.dll.orig"
printf 'initUsingVulkan=false\n' > "$a/Old/opencomposite.ini"
cp "$S/oc/openvr_api.dll" "$a/Old/openvr_api.dll.oc"
prefix "$ext/steamapps/compatdata/100"
old_setup "$ext/steamapps/compatdata/100" GameA.exe

# Game B, OpenVR, in the main library, graphics left alone: a patched OpenComposite of the
# user's own with settings of their own, and DXVK it still uses.
manifest "$main" 200 "Game B" "Game B"
b=$main/steamapps/common/Game\ B
mkdir -p "$b/bin"
echo "MZ game exe" > "$b/bin/GameB.exe"
dxvk "$b/bin/d3d11.dll"
cp "$S/oc-custom.dll" "$b/bin/openvr_api.dll"
echo "MZ Valve openvr_api for Game B" > "$b/bin/openvr_api.dll.orig"
printf 'initUsingVulkan=false\nlogAllOpenVRCalls=true\n' > "$b/bin/opencomposite.ini"
prefix "$main/steamapps/compatdata/200"
old_setup "$main/steamapps/compatdata/200" GameB.exe

# Game C, OpenXR, never set up: only what NotProton stages itself. Nothing to clean.
manifest "$ext" 300 "Game C" "Game C"
c=$ext/steamapps/common/Game\ C
mkdir -p "$c"
echo "MZ game exe" > "$c/GameC.exe"
echo "MZ openxr_loader" > "$c/openxr_loader.dll"
prefix "$ext/steamapps/compatdata/300"
notproton_staged "$ext/steamapps/compatdata/300"

export STEAM="$main" NP_BRIDGE="$bridge" VRPATHS="$S/openvrpaths.vrpath" MACVAPOR_OC="$S/oc/openvr_api.dll"
listing() { (cd "$S" && find Steam Ext -type f ! -name '*.acf' ! -name '*.vdf' | LC_ALL=C sort); }
items() { awk -F'\t' '$1 == "item" { printf "%-15s %s %-10s %s\n", $2, $5, $6, $3 }' | sed "s|$S/||"; }

# A copy for the app, with its own library paths.
mkdir -p "$S/app"
cp -R "$main" "$ext" "$S/app/"
sed -i '' "s|$S/|$S/app/|" "$S/app/Steam/steamapps/libraryfolders.vdf"

echo "== before"
listing > "$S/before.txt"
cat "$S/before.txt"
sums() { find "$S/Steam" "$S/Ext" -type f -exec cksum {} + | LC_ALL=C sort; }
sums > "$S/sums-before"

echo "== --scan, new NotProton"
for id in 100 200 300; do
    echo "-- $id"
    GFX=$([ $id = 100 ] && echo dxmt || true) sh "$script" --scan $id > "$S/scan-$id"
    items < "$S/scan-$id"
done
sums > "$S/sums-after-scan"
check "--scan changes nothing" 'cmp -s "$S/sums-before" "$S/sums-after-scan"'
check "scan says zero-setup" 'grep -q "^status	notproton	zero-setup" "$S/scan-100"'
check "game C has nothing" '! grep -q "^item" "$S/scan-300"'
check "A: restore ticked" 'grep -q "^item	oc-restore	.*Plugins/openvr_api.dll	.*	1	zero-setup" "$S/scan-100"'
check "A: d3d11 offered (DXMT)" 'grep -q "^item	d3d11-override	.*	1	zero-setup" "$S/scan-100"'
check "B: custom OpenComposite not ticked" 'grep -q "^item	oc-restore	.*	0	zero-setup" "$S/scan-200"'
check "B: own ini not ticked" 'grep -q "^item	oc-ini	.*	0	zero-setup" "$S/scan-200"'
check "B: DXVK kept (not DXMT)" 'grep -q "^item	d3d11-dll	.*	0	kept" "$S/scan-200"'

echo "== --scan, old NotProton"
cp "$S/run-old" "$main/compatibilitytools.d/notproton/run"
GFX=dxmt sh "$script" --scan 100 > "$S/scan-100-old"
grep '^status	notproton' "$S/scan-100-old"
echo "== --clean every kind for A, old NotProton: only the junk goes"
GFX=dxmt sh "$script" --clean 100 stray-backup stale-orig orphan-ini oc-restore oc-ini wineopenxr khronos-runtime \
    vr-key d3d11-override d3d11-dll | sed "s|$S/||"
check "old: OpenComposite still in place" 'cmp -s "$a/Plugins/openvr_api.dll" "$S/oc/openvr_api.dll"'
check "old: VR key still there" 'grep -q "^\[Software\\\\\\\\Wine\\\\\\\\VR\]" "$ext/steamapps/compatdata/100/pfx/user.reg"'
check "old: junk gone" '[ ! -e "$a/Old/openvr_api.dll.oc" ] && [ ! -e "$a/Old/openvr_api.dll.orig" ] && [ ! -e "$a/Old/opencomposite.ini" ] && [ ! -e "$a/Plugins/openvr_api.dll.bak-before-notifications" ]'
check "old: no .reg copies made" '[ ! -e "$ext/steamapps/compatdata/100/pfx/user.reg.before-macvapor-cleanup" ]'

echo "== running prefix is refused"
cp "$S/run-new" "$main/compatibilitytools.d/notproton/run"
pfx_a=$ext/steamapps/compatdata/100/pfx
cp -p "$pfx_a/user.reg" "$S/user.reg.held"
cp -p "$pfx_a/system.reg" "$S/system.reg.held"
if [ -x "$RUNNER/bin/wineserver-arm64" ]; then
    WINEPREFIX=$pfx_a "$RUNNER/bin/wineserver-arm64" -p
    sleep 1
    sh "$script" --scan 100 > "$S/scan-running"
    grep '^status	running' "$S/scan-running"
    check "scan sees the running wineserver" 'grep -q "^status	running	1" "$S/scan-running"'
    check "clean refuses" '! sh "$script" --clean 100 vr-key 2>/dev/null'
    WINEPREFIX=$pfx_a "$RUNNER/bin/wineserver-arm64" -k || true
    WINEPREFIX=$pfx_a "$RUNNER/bin/wineserver-arm64" -w || true
    sh "$script" --scan 100 > "$S/scan-stopped"
    check "scan sees it stopped" 'grep -q "^status	running	0" "$S/scan-stopped"'
    # The server may have saved the registry its own way on exit; the fixture's is put back.
    cp -p "$S/user.reg.held" "$pfx_a/user.reg"
    cp -p "$S/system.reg.held" "$pfx_a/system.reg"
    rm -f "$pfx_a/userdef.reg"
else
    echo "skip: no runner wineserver at $RUNNER"
fi

echo "== --clean, new NotProton: A, everything ticked by default; B, one item picked"
GFX=dxmt sh "$script" --scan 100 > "$S/scan-100-b"
set --
while IFS='	' read -r tag k t reason def m; do
    [ "$tag" = item ] && [ "$def" = 1 ] && set -- "$@" "$k:$t"
done < "$S/scan-100-b"
GFX=dxmt sh "$script" --clean 100 "$@" | sed "s|$S/||"
sh "$script" --clean 200 vr-key | sed "s|$S/||"
pa=$ext/steamapps/compatdata/100/pfx
check "A: game's own openvr_api.dll back" 'grep -q "Valve openvr_api 1.0" "$a/Plugins/openvr_api.dll" && [ ! -e "$a/Plugins/openvr_api.dll.orig" ]'
check "A: OpenComposite copy kept beside" 'cmp -s "$a/Plugins/openvr_api.dll.before-macvapor-cleanup" "$S/oc/openvr_api.dll"'
check "A: ini gone" '[ ! -e "$a/Plugins/opencomposite.ini" ]'
check "A: DXVK gone" '[ ! -e "$a/d3d11.dll" ]'
check "A: wineopenxr gone" '[ ! -e "$pa/drive_c/Program Files (x86)/Steam/aarch64-windows/wineopenxr.dll" ] && [ ! -e "$pa/drive_c/windows/system32/wineopenxr64.json" ]'
check "A: VR key and its subkey gone" '! grep -qi "^\[Software\\\\\\\\Wine\\\\\\\\VR[]\\\\]" "$pa/user.reg"'
check "A: neighbouring keys kept" 'grep -q "VRLike" "$pa/user.reg" && grep -q ShowCrashDialog "$pa/user.reg" && grep -q FontSmoothing "$pa/user.reg"'
check "A: d3d11 override gone, its key kept" '! grep -q "\"d3d11\"=\"native\"" "$pa/user.reg" && grep -q "AppDefaults" "$pa/user.reg"'
check "A: ActiveRuntime gone, Vulkan drivers kept" '! grep -q ActiveRuntime "$pa/system.reg" && grep -q winevulkan.json "$pa/system.reg"'
check "A: one copy of user.reg for the run" '[ ! -e "$pa/user.reg.before-macvapor-cleanup-"* ]'
check "A: .reg copies kept, untouched" 'cmp -s "$pa/user.reg.before-macvapor-cleanup" "$S/user.reg.held" && cmp -s "$pa/system.reg.before-macvapor-cleanup" "$S/system.reg.held"'
check "A: rescan finds nothing" '! GFX=dxmt sh "$script" --scan 100 | grep -q "^item	[^	]*	[^	]*	[^	]*	1"'
check "B: only the VR key went" '! grep -q "^\[Software\\\\\\\\Wine\\\\\\\\VR\]" "$main/steamapps/compatdata/200/pfx/user.reg" && cmp -s "$b/bin/openvr_api.dll" "$S/oc-custom.dll" && [ -f "$b/bin/d3d11.dll" ]'
check "kept items are never removed" 'sh "$script" --clean 200 d3d11-dll | grep -q "^kept" && [ -f "$b/bin/d3d11.dll" ]'

echo "== after"
listing > "$S/after.txt"
diff "$S/before.txt" "$S/after.txt" || true
echo "== user.reg of A, before and after"
diff "$S/user.reg.held" "$pa/user.reg" || true

if [ -n "${APP:-}" ]; then
    echo "== the app's scan (--cleanup-scan)"
    am=$S/app/Steam ae=$S/app/Ext
    (cd "$S/app" && find . -type f -exec cksum {} + | LC_ALL=C sort) > "$S/app-sums-before"
    MACVAPOR_STEAM=$am MACVAPOR_SETUP_SCRIPT=$script "$APP" --cleanup-scan | sed "s|$S/||g" | tee "$S/app-scan"
    (cd "$S/app" && find . -type f -exec cksum {} + | LC_ALL=C sort) > "$S/app-sums-after"
    check "app: scan changes nothing" 'cmp -s "$S/app-sums-before" "$S/app-sums-after"'
    check "app: Game A's DXVK offered (DXMT from localconfig.vdf)" 'grep -q "\[x\] Remove DXVK.s d3d11.dll" "$S/app-scan"'
    check "app: Game C not listed" '! grep -q "Game C" "$S/app-scan"'
    echo "== the app's clean-up of the ticked items (--cleanup-ticked)"
    MACVAPOR_STEAM=$am MACVAPOR_SETUP_SCRIPT=$script "$APP" --cleanup-scan --cleanup-ticked | sed "s|$S/||g" | sed -n '/^Game A:/,$p'
    check "app: A's own openvr_api.dll back" 'grep -q "Valve openvr_api 1.0" "$ae/steamapps/common/Game A/Plugins/openvr_api.dll"'
    check "app: A's VR key gone, B's custom OpenComposite kept" '! grep -q "^\[Software\\\\\\\\Wine\\\\\\\\VR\]" "$ae/steamapps/compatdata/100/pfx/user.reg" && cmp -s "$am/steamapps/common/Game B/bin/openvr_api.dll" "$S/oc-custom.dll"'
    check "app: rescan has nothing ticked" '! MACVAPOR_STEAM=$am MACVAPOR_SETUP_SCRIPT=$script "$APP" --cleanup-scan | grep -q "\[x\]"'
fi

[ $fails = 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
