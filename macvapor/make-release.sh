#!/bin/sh
# Builds MacVapoR.app around the alvrxr runtime and NotProton's wineopenxr, signs it with a
# Developer ID, notarizes and staples it, and wraps it in a signed, notarized DMG.
#
#   macvapor/make-release.sh                 everything, into macvapor/dist/
#   SKIP_BUILD=1 macvapor/make-release.sh    reuse alvrxr's out/ and wineopenxr's build output
#
# Signing is your own: set IDENTITY (a codesign identity, e.g. "Developer ID Application: Name
# (TEAMID)") and NOTARY_PROFILE (a notarytool keychain profile, from `xcrun notarytool
# store-credentials`) in the environment or in macvapor/release.env, which git ignores; see
# release.env.example. Without them the build is signed ad hoc and not notarized, which is
# fine on the Mac that built it.
#
# Also overridable: NOTPROTON, OPENXR, ALVR (source trees)
set -eu
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/.." && pwd)
VERSION=$(cat "$here/VERSION")
# The environment wins over release.env, so NOTARY_PROFILE= still skips notarization.
env_id=${IDENTITY+set}:${IDENTITY-} env_np=${NOTARY_PROFILE+set}:${NOTARY_PROFILE-}
[ -f "$here/release.env" ] && . "$here/release.env"
case $env_id in set:*) IDENTITY=${env_id#set:} ;; esac
case $env_np in set:*) NOTARY_PROFILE=${env_np#set:} ;; esac
IDENTITY=${IDENTITY:--}
NOTARY_PROFILE=${NOTARY_PROFILE:-}
NOTPROTON=${NOTPROTON:-$HOME/Source/NotProton}
OPENXR=${OPENXR:-$HOME/Source/OpenXR-SDK-Source}
ALVR=${ALVR:-$HOME/Source/ALVR-20.14.1}
MIN_VER=15.0
dist=$here/dist
app=$dist/MacVapoR.app

# A signed release names the commits it was built from in build-info.txt, so each source tree
# must be committed: alvrxr, NotProton's wineopenxr, and ALVR, which build.sh patches, so it must
# differ from its commit by exactly alvrxr's patches/alvr-*.patch. It must also be built here, not
# reused with SKIP_BUILD, since nothing records what an earlier build was made from.
# ALLOW_DIRTY=1 builds anyway, and build-info.txt then says which trees were dirty.
dirty=
rev() { # tree [path]: sets r
    r=$(git -C "$1" rev-parse HEAD)
    [ -z "$(git -C "$1" status --porcelain -- "${2:-.}")" ] || { r=$r-dirty; dirty="$dirty $1${2:+/$2}"; }
}
refuse_dirty() {
    if [ "$IDENTITY" != "-" ] && [ -n "$dirty" ] && [ -z "${ALLOW_DIRTY:-}" ]; then
        echo "==> not releasing from uncommitted or unbuilt sources:$dirty (ALLOW_DIRTY=1 overrides)" >&2
        exit 1
    fi
}
alvr_patched() {
    files=$(sed -n 's|^+++ b/||p' "$repo"/patches/alvr-*.patch | sort -u)
    [ "$files" = "$(git -C "$ALVR" status --porcelain | cut -c4- | sort -u)" ] || return 1
    tmp=$(mktemp -d)
    for f in $files; do mkdir -p "$tmp/${f%/*}"; git -C "$ALVR" show "HEAD:$f" > "$tmp/$f"; done
    ( cd "$tmp" && for p in "$repo"/patches/alvr-*.patch; do git apply "$p" || exit 1; done ) || { rm -rf "$tmp"; return 1; }
    for f in $files; do cmp -s "$tmp/$f" "$ALVR/$f" || { rm -rf "$tmp"; return 1; }; done
    rm -rf "$tmp"
}
rev "$repo"; alvrxr_rev=$r
rev "$NOTPROTON" wineopenxr; wox_rev=$r
[ -z "${SKIP_BUILD:-}" ] || dirty="$dirty SKIP_BUILD"
refuse_dirty

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
cp "$repo/out/libalvrxr.dylib" "$repo/out/libalvr_server_core.dylib" "$repo/out/vapord" "$code/runtime/"
# The home scenes: data, installed beside the runtime.
cp -R "$repo/out/scenes" "$data/scenes"
cp "$wox/aarch64-unix/wineopenxr.so" "$wox/aarch64-unix/libopenxr_loader.dylib" "$code/wineopenxr/aarch64-unix/"
cp "$wox/x86_64-windows/wineopenxr.dll" "$data/wineopenxr/x86_64-windows/"
cp "$wox/wineopenxr64.json" "$data/wineopenxr/"
cp "$repo/tools/notproton-vr-setup.sh" "$here/session-template.json" "$here/MacVapoR.icns" "$data/"
cp "$here/LICENSES/"* "$data/LICENSES/"
cp "$repo/LICENSE" "$data/LICENSES/MacVapoR-MIT.txt"
cp "$ALVR/LICENSE" "$data/LICENSES/ALVR-MIT.txt"
cp "$OPENXR/LICENSES/Apache-2.0.txt" "$data/LICENSES/OpenXR-loader-Apache-2.0.txt"
cp "$NOTPROTON/wineopenxr/crossover.patch" "$data/LICENSES/wineopenxr-crossover.patch"
# Once built, ALVR must carry exactly alvrxr's patches.
alvr_rev=$(git -C "$ALVR" rev-parse HEAD)
alvr_patched || { alvr_rev=$alvr_rev-dirty; dirty="$dirty $ALVR"; }
refuse_dirty
{
    echo "MacVapoR $VERSION"
    echo "alvrxr $alvrxr_rev"
    echo "NotProton wineopenxr $wox_rev"
    echo "ALVR $alvr_rev with alvrxr's patches/alvr-*.patch"
    [ -z "${SKIP_BUILD:-}" ] || echo "binaries reused from an earlier build (SKIP_BUILD), not built from these"
} | tee "$data/build-info.txt"

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
