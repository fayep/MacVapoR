#!/bin/sh
# Builds and runs tests/dashboard-check.m against out/libalvrxr.dylib, headless, with a scratch
# config dir: the runtime side of the dashboard (docs/compositor.md). Twice: as a game (LEGACY,
# no ALVRXR_HOME), which must never see the system button and must follow exit_request; and as
# vapord (ALVRXR_HOME, SERVER mode on a test Mach service name), which sees the button and may use
# the private functions of alvrxr_ext.h.
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
OPENXR=${OPENXR:-$HOME/Source/OpenXR-SDK-Source}
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
clang -fobjc-arc -O1 -Wall -I "$here/src" -I "$OPENXR/build/include" -I "$OPENXR/include" -framework Foundation -framework Metal \
    "$here/tests/dashboard-check.m" -o "$scratch/dashboard-check"
press='"fake_press": ["/user/hand/right/input/system/click", "/user/hand/right/input/a/click"]'
echo "== game: the system button is filtered, exit_request ends the session, private functions refused"
mkdir "$scratch/game"
sed "s/\"web_server_port\": 8082/\"web_server_port\": 18082/" "$here/macvapor/session-template.json" > "$scratch/game/session.json"
echo "{$press}" > "$scratch/game/tune.json"
ALVRXR_CONFIG_DIR=$scratch/game ALVRXR_TEST_FOCUS_FILE=$scratch/game/focus ALVRXR_RUNTIME=$here/out/libalvrxr.dylib \
    "$scratch/dashboard-check" game
echo "== home: the system button is seen, the private functions work (SERVER mode)"
mkdir "$scratch/home"
sed "s/\"web_server_port\": 8082/\"web_server_port\": 18082/" "$here/macvapor/session-template.json" > "$scratch/home/session.json"
echo "{\"compositor\": true, $press}" > "$scratch/home/tune.json"
ALVRXR_CONFIG_DIR=$scratch/home ALVRXR_RUNTIME=$here/out/libalvrxr.dylib ALVRXR_HOME=1 \
    ALVRXR_COMPOSITOR_SERVICE=com.zippysoft.macvapor.compositor.test-$$ "$scratch/dashboard-check" home
