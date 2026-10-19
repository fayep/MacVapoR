#!/bin/sh
# Builds libalvrxr.dylib (the OpenXR runtime) and its loader manifest into out/.
#   ./build.sh --install-variant NAME   also puts the runtime and vapord in MacVapoR/runtimes/NAME,
#                                       for tools/runtime-switch.sh to choose
set -eu
variant=
if [ "${1:-}" = --install-variant ]; then
    variant=${2:?--install-variant needs a name}
    case "$variant" in installed | */* | .*) echo "can't use $variant as a variant name" >&2; exit 2 ;; esac
fi
here=$(cd "$(dirname "$0")" && pwd)
ALVR=${ALVR:-$HOME/Source/ALVR-20.14.1}
OPENXR=${OPENXR:-$HOME/Source/OpenXR-SDK-Source}
# The oldest macOS a release supports; without it everything targets the build machine's.
MIN_VER=${MIN_VER:-15.0}
export MACOSX_DEPLOYMENT_TARGET=$MIN_VER
out="$here/out"
mkdir -p "$out" "$here/build"
# ALVR fixes the runtime needs, each applied once (see patches/).
for p in "$here"/patches/alvr-*.patch; do
    ( cd "$ALVR" && { git apply --reverse --check "$p" 2>/dev/null || git apply "$p"; } )
done
( cd "$ALVR" && cargo build -q -p alvr_server_core --release )
cp "$ALVR/target/release/libalvr_server_core.dylib" "$out/"
install_name_tool -id @rpath/libalvr_server_core.dylib "$out/libalvr_server_core.dylib"
codesign -f -s - "$out/libalvr_server_core.dylib" 2>/dev/null
{ printf 'static const char compose_metal[] =\n'; sed 's/\\/\\\\/g; s/"/\\"/g; s/^/"/; s/$/\\n"/' "$here/src/compose.metal"; printf ';\n'; } \
    > "$here/build/compose_metal.h"
clang -dynamiclib -mmacosx-version-min="$MIN_VER" -fobjc-arc -O2 -g -Wall -Wno-unused-function -fvisibility=hidden \
    -I "$here/src" -I "$here/build" -I "$OPENXR/build/include" -I /opt/homebrew/include \
    "$here/src/runtime.m" "$here/src/slots.m" "$here/src/backend.m" "$here/src/vulkan.m" "$here/src/audio.m" \
    -framework Foundation -framework Metal -framework CoreVideo -framework CoreMedia -framework VideoToolbox -framework ImageIO -framework CoreGraphics -framework CoreAudio -framework IOSurface \
    -L "$out" -lalvr_server_core -Wl,-rpath,@loader_path \
    -install_name @rpath/libalvrxr.dylib -o "$out/libalvrxr.dylib"
# The home scene (home/vapord.m), which MacVapoR keeps running while no game holds the headset,
# and the scenes it can show (home/scenes), each a folder: their pictures are drawn here.
embed() { { printf 'static const char %s[] =\n' "$1"; sed 's/\\/\\\\/g; s/"/\\"/g; s/^/"/; s/$/\\n"/' "$2"; printf ';\n'; } > "$here/build/$1.h"; }
embed prelude_metal "$here/home/prelude.metal"
embed objects_metal "$here/home/objects.metal"
clang -mmacosx-version-min="$MIN_VER" -fobjc-arc -O2 -g -Wall \
    -I "$here/build" -I "$OPENXR/build/include" -I "$OPENXR/include" \
    "$here/home/vapord.m" -framework Foundation -framework Metal -framework CoreGraphics -framework ImageIO \
    -o "$out/vapord"
rm -rf "$out/scenes"
mkdir -p "$out/scenes"
cp "$here/home/SCENES.md" "$here/home/prelude.metal" "$out/scenes/"
for dir in "$here"/home/scenes/*/; do
    name=$(basename "$dir")
    mkdir -p "$out/scenes/$name"
    cp "$dir"scene.json "$dir"*.metal "$out/scenes/$name/"
    find "$dir" -maxdepth 1 -name '*.png' -exec cp {} "$out/scenes/$name/" \;
    if [ -f "$dir/pictures.m" ]; then
        clang -fobjc-arc -O2 -Wall "$dir/pictures.m" -framework Foundation -framework CoreGraphics -framework CoreText \
            -framework ImageIO -framework UniformTypeIdentifiers -o "$here/build/pictures-$name"
        "$here/build/pictures-$name" "$out/scenes/$name"
    fi
done
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
if [ -n "$variant" ]; then
    dest="$HOME/Library/Application Support/MacVapoR/runtimes/$variant"
    mkdir -p "$dest"
    # Replaced by rename, so a running game or vapord keeps the copy it loaded.
    for f in libalvrxr.dylib libalvr_server_core.dylib vapord; do
        cp "$out/$f" "$dest/.$f.new" && mv -f "$dest/.$f.new" "$dest/$f"
    done
    echo "installed into $dest (choose it with tools/runtime-switch.sh $variant)"
fi
