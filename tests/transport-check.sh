#!/bin/sh
# Builds and runs tests/transport-check.m: the XPC transport and the CLIENT/SERVER slots against
# tests/compositor-stub.m, in one process, headless, without launchd or ALVR.
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
scratch=$(mktemp -d)
clang -fobjc-arc -O1 -g -Wall -Wno-unused-function -I "$here/src" -I "$here/tests" \
    "$here/tests/transport-check.m" "$here/tests/compositor-stub.m" \
    "$here/src/slots.m" "$here/src/client.m" "$here/src/transport.m" \
    -framework Foundation -framework Metal -framework IOSurface -o "$scratch/transport-check"
echo '{"compositor": true}' > "$scratch/tune.json"
ALVRXR_CONFIG_DIR=$scratch "$scratch/transport-check" client
ALVRXR_CONFIG_DIR=$scratch ALVRXR_HOME=1 "$scratch/transport-check" server
