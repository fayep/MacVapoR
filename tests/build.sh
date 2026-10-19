#!/bin/sh
# Builds the test tools (xrclient, dumpcheck) into build/tests/ (git-ignored). OPENXR is the OpenXR-SDK-Source checkout,
# as for ../build.sh. Installs nothing.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
OPENXR=${OPENXR:-$HOME/Source/OpenXR-SDK-Source}
MIN_VER=${MIN_VER:-15.0}
out="$here/../build/tests"
mkdir -p "$out"
clang -mmacosx-version-min="$MIN_VER" -fobjc-arc -O1 -g -Wall \
    -I "$OPENXR/build/include" -I "$OPENXR/include" \
    "$here/xrclient.m" -framework Foundation -framework Metal -o "$out/xrclient"
clang -mmacosx-version-min="$MIN_VER" -fobjc-arc -O1 -g -Wall \
    "$here/dumpcheck.m" -framework Foundation -framework ImageIO -framework CoreGraphics -framework UniformTypeIdentifiers \
    -o "$out/dumpcheck"
echo "built $out/xrclient $out/dumpcheck"
