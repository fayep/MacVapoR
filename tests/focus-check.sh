#!/bin/sh
# Builds and runs tests/focus-check.m against out/libalvrxr.dylib with a scratch config dir.
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
OPENXR=${OPENXR:-$HOME/Source/OpenXR-SDK-Source}
scratch=$(mktemp -d)
clang -fobjc-arc -O1 -Wall -I "$OPENXR/build/include" -I "$OPENXR/include" -framework Foundation -framework Metal \
    "$here/tests/focus-check.m" -o "$scratch/focus-check"
ALVRXR_DUMP=$scratch/dump.bin ALVRXR_CONFIG_DIR=$scratch ALVRXR_TEST_FOCUS_FILE=$scratch/focus ALVRXR_RUNTIME=$here/out/libalvrxr.dylib \
    "$scratch/focus-check"
