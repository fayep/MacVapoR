#!/bin/sh
# Builds MacVapoR.app around the alvrxr runtime and NotProton's wineopenxr, signs it with a
# Developer ID, notarizes and staples it, and wraps it in a signed, notarized DMG.
#
#   macvapor/make-release.sh                 everything, into macvapor/dist/
#   SKIP_BUILD=1 macvapor/make-release.sh    reuse alvrxr's out/ and wineopenxr's build output
#   NOTARY_PROFILE= macvapor/make-release.sh sign only, no notarization (a local test build)
#
# Overridable: IDENTITY (codesign identity, "-" for ad hoc), NOTARY_PROFILE (a notarytool
# keychain profile, from `xcrun notarytool store-credentials`), NOTPROTON, OPENXR, ALVR
set -eu
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/.." && pwd)
VERSION=$(cat "$here/VERSION")
IDENTITY=${IDENTITY:-Developer ID Application: Faye Salwin (63JE575Q9W)}
NOTARY_PROFILE=${NOTARY_PROFILE-m4xstudio-notary}
NOTPROTON=${NOTPROTON:-$HOME/Source/NotProton}
OPENXR=${OPENXR:-$HOME/Source/OpenXR-SDK-Source}
ALVR=${ALVR:-$HOME/Source/ALVR-20.14.1}
MIN_VER=15.0
dist=$here/dist
app=$dist/MacVapoR.app

if [ -z "${SKIP_BUILD:-}" ]; then
    MIN_VER=$MIN_VER "$repo/build.sh"
    "$NOTPROTON/wineopenxr/build.sh"
fi
wox=$NOTPROTON/build/wineopenxr-out

echo "==> assembling MacVapoR $VERSION"
rm -rf "$dist"
code=$app/Contents/Library/MacVapoR
data=$app/Contents/Resources
mkdir -p "$app/Contents/MacOS" "$code/runtime" "$code/wineopenxr/aarch64-unix" \
    "$data/wineopenxr/x86_64-windows" "$data/LICENSES"
swiftc -O -parse-as-library -target "arm64-apple-macos$MIN_VER" "$here/Sources/MacVapoR.swift" \
    -o "$app/Contents/MacOS/MacVapoR"
# MacVapoR Audio, which taps games' audio with a permission of its own.
helper="$app/Contents/Helpers/MacVapoR Audio.app"
mkdir -p "$helper/Contents/MacOS" "$helper/Contents/Resources"
clang -fobjc-arc -O2 -mmacosx-version-min="$MIN_VER" "$repo/helper/main.m" -framework CoreAudio -framework Foundation \
    -o "$helper/Contents/MacOS/MacVapoR Audio"
sed "s/@VERSION@/$VERSION/g" "$repo/helper/Info.plist" > "$helper/Contents/Info.plist"
cp "$here/MacVapoR.icns" "$helper/Contents/Resources/"
sed "s/@VERSION@/$VERSION/g" "$here/Info.plist" > "$app/Contents/Info.plist"
cp "$repo/out/libalvrxr.dylib" "$repo/out/libalvr_server_core.dylib" "$code/runtime/"
cp "$wox/aarch64-unix/wineopenxr.so" "$wox/aarch64-unix/libopenxr_loader.dylib" "$code/wineopenxr/aarch64-unix/"
cp "$wox/x86_64-windows/wineopenxr.dll" "$data/wineopenxr/x86_64-windows/"
cp "$wox/wineopenxr64.json" "$data/wineopenxr/"
cp "$repo/tools/notproton-vr-setup.sh" "$here/session-template.json" "$here/MacVapoR.icns" "$data/"
cp "$here/LICENSES/"* "$data/LICENSES/"
cp "$repo/LICENSE" "$data/LICENSES/MacVapoR-MIT.txt"
cp "$ALVR/LICENSE" "$data/LICENSES/ALVR-MIT.txt"
cp "$OPENXR/LICENSES/Apache-2.0.txt" "$data/LICENSES/OpenXR-loader-Apache-2.0.txt"
cp "$NOTPROTON/wineopenxr/crossover.patch" "$data/LICENSES/wineopenxr-crossover.patch"

for f in "$code"/runtime/* "$code"/wineopenxr/aarch64-unix/* "$app/Contents/MacOS/MacVapoR" "$helper/Contents/MacOS/MacVapoR Audio"; do
    case "$(vtool -show-build "$f" 2>/dev/null | sed -n 's/.*minos //p' | head -1)" in
        "$MIN_VER") ;;
        *) echo "==> $f does not target macOS $MIN_VER" >&2; exit 1 ;;
    esac
done

echo "==> signing as $IDENTITY"
sign() { codesign --force --timestamp --options runtime --sign "$IDENTITY" "$@"; }
[ "$IDENTITY" = "-" ] && sign() { codesign --force --sign - "$@"; }
for f in "$code"/runtime/* "$code"/wineopenxr/aarch64-unix/*; do sign "$f"; done
sign "$helper"
sign "$app"
codesign --verify --deep --strict "$app"

notarize() {
    xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait | tee "$dist/notary.log"
    grep -q "status: Accepted" "$dist/notary.log" || { echo "==> notarization failed; see notarytool log" >&2; exit 1; }
}
if [ -n "$NOTARY_PROFILE" ] && [ "$IDENTITY" != "-" ]; then
    echo "==> notarizing the app"
    ditto -c -k --keepParent "$app" "$dist/MacVapoR-app.zip"
    notarize "$dist/MacVapoR-app.zip"
    xcrun stapler staple "$app"
    rm "$dist/MacVapoR-app.zip"
fi

echo "==> making the DMG"
stage=$dist/dmg
mkdir -p "$stage"
cp -R "$app" "$stage/"
ln -s /Applications "$stage/Applications"
dmg=$dist/MacVapoR-$VERSION.dmg
hdiutil create -quiet -volname "MacVapoR $VERSION" -srcfolder "$stage" -format UDZO -ov "$dmg"
rm -rf "$stage"
if [ "$IDENTITY" != "-" ]; then
    codesign --force --timestamp --sign "$IDENTITY" "$dmg"
fi
if [ -n "$NOTARY_PROFILE" ] && [ "$IDENTITY" != "-" ]; then
    echo "==> notarizing the DMG"
    notarize "$dmg"
    xcrun stapler staple "$dmg"
    spctl --assess --type open --context context:primary-signature -v "$dmg"
fi
(cd "$(dirname "$dmg")" && shasum -a 256 "$(basename "$dmg")") | tee "$dmg.sha256"
echo "==> $dmg"
