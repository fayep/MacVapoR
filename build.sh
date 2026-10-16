#!/bin/sh
# Builds libalvrxr.dylib (the OpenXR runtime) and its loader manifest into out/.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
ALVR=${ALVR:-$HOME/Source/ALVR-20.14.1}
OPENXR=${OPENXR:-$HOME/Source/OpenXR-SDK-Source}
# The oldest macOS a release supports; without it everything targets the build machine's.
MIN_VER=${MIN_VER:-15.0}
export MACOSX_DEPLOYMENT_TARGET=$MIN_VER
out="$here/out"
mkdir -p "$out" "$here/build"
( cd "$ALVR" && cargo build -q -p alvr_server_core --release )
cp "$ALVR/target/release/libalvr_server_core.dylib" "$out/"
install_name_tool -id @rpath/libalvr_server_core.dylib "$out/libalvr_server_core.dylib"
codesign -f -s - "$out/libalvr_server_core.dylib" 2>/dev/null
{ printf 'static const char compose_metal[] =\n'; sed 's/\\/\\\\/g; s/"/\\"/g; s/^/"/; s/$/\\n"/' "$here/src/compose.metal"; printf ';\n'; } \
    > "$here/build/compose_metal.h"
clang -dynamiclib -mmacosx-version-min="$MIN_VER" -fobjc-arc -O2 -g -Wall -Wno-unused-function -fvisibility=hidden \
    -I "$here/src" -I "$here/build" -I "$OPENXR/build/include" -I /opt/homebrew/include \
    "$here/src/runtime.m" "$here/src/backend.m" "$here/src/vulkan.m" "$here/src/audio.m" \
    -framework Foundation -framework Metal -framework CoreVideo -framework CoreMedia -framework VideoToolbox -framework ImageIO -framework CoreGraphics -framework CoreAudio \
    -L "$out" -lalvr_server_core -Wl,-rpath,@loader_path \
    -install_name @rpath/libalvrxr.dylib -o "$out/libalvrxr.dylib"
cat > "$out/alvrxr.json" <<JSON
{
    "file_format_version": "1.0.0",
    "runtime": {
        "name": "alvrxr",
        "library_path": "./libalvrxr.dylib"
    }
}
JSON
echo "built $out/libalvrxr.dylib (XR_RUNTIME_JSON=$out/alvrxr.json)"
