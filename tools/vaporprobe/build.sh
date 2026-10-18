#!/bin/sh
# Builds vaporprobe as version.dll for 64-bit Windows games, with mingw-w64.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
out=${1:-$here/../../out/vaporprobe}
mkdir -p "$out"
x86_64-w64-mingw32-gcc -O2 -Wall -Wextra -Wno-cast-function-type -shared -static-libgcc \
    -o "$out/version.dll" "$here/probe.c" "$here/version.def" -lwinmm
echo "built $out/version.dll"
