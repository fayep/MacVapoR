#!/bin/sh
# Builds tests/audio-mix-check.m against src/audio.m, with ALVR stubbed and no helper, and runs it;
# then checks that LEGACY's one source sends the same stream as the audio.m of known-good-2026-10-19.
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
scratch=$(mktemp -d)
flags="-fobjc-arc -O2 -g -Wall -Wno-unused-function"
clang $flags -I "$here/src" -c "$here/tests/audio-mix-check.m" -o "$scratch/test.o"
clang $flags -I "$here/src" -c "$here/src/audio.m" -o "$scratch/audio.o"
clang -framework Foundation "$scratch/test.o" "$scratch/audio.o" -o "$scratch/audio-mix-check"
# The old one launches the helper unconditionally; posix_spawn goes to the test's stub instead.
mkdir "$scratch/old"
git -C "$here" archive known-good-2026-10-19 src/audio.m src/alvrxr.h src/alvr_capi.h helper/audio_ring.h | tar -x -C "$scratch/old"
clang $flags -Dposix_spawn=test_spawn -I "$scratch/old/src" -c "$scratch/old/src/audio.m" -o "$scratch/audio-old.o"
# The old one has no mixer; "mix" is never run against it.
clang -framework Foundation "$scratch/test.o" "$scratch/audio-old.o" -Wl,-undefined,dynamic_lookup -o "$scratch/audio-mix-check-old"

touch "$scratch/helper"   # axr_audio_available() looks for it; it is never launched
export ALVRXR_AUDIO_HELPER="$scratch/helper"
ALVRXR_AUDIO_NO_HELPER=1 ALVRXR_AUDIO_RING_PREFIX="/axrtest-$$-" "$scratch/audio-mix-check" mix
ALVRXR_AUDIO_NO_HELPER=1 ALVRXR_AUDIO_RING_PREFIX="/axrtest-$$-" "$scratch/audio-mix-check" legacy "$scratch/new.raw"
"$scratch/audio-mix-check-old" legacy "$scratch/old.raw"   # its ring is named for this test's own pid
cmp "$scratch/old.raw" "$scratch/new.raw"
echo "legacy: the same $(wc -c < "$scratch/new.raw" | tr -d ' ') bytes as known-good-2026-10-19"
rm -rf "$scratch"
