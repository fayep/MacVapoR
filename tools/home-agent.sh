#!/bin/sh
# Keeps MacVapoR's home scene (vapord) running through launchd: started at login, and again each
# time it exits, which it does whenever a game claims the headset. While a game holds it, vapord
# waits for the game to end.
#
# Usage: home-agent.sh install | remove | status
set -eu
label=com.zippysoft.macvapor.home
plist="$HOME/Library/LaunchAgents/$label.plist"
vapord="$HOME/Library/Application Support/MacVapoR/runtime/vapord"
domain="gui/$(id -u)"

case "${1:-}" in
install)
    [ -x "$vapord" ] || { echo "no vapord at $vapord" >&2; exit 1; }
    mkdir -p "$HOME/Library/LaunchAgents"
    cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$label</string>
    <key>ProgramArguments</key><array><string>$vapord</string></array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>ThrottleInterval</key><integer>2</integer>
    <key>ProcessType</key><string>Interactive</string>
    <key>StandardErrorPath</key><string>$HOME/Library/Logs/vapord.log</string>
</dict>
</plist>
PLIST
    launchctl bootout "$domain/$label" 2>/dev/null || true
    launchctl bootstrap "$domain" "$plist"
    echo "home scene agent installed and started"
    ;;
remove)
    launchctl bootout "$domain/$label" 2>/dev/null || true
    rm -f "$plist"
    echo "home scene agent removed"
    ;;
status)
    launchctl print "$domain/$label" 2>/dev/null | grep -E "state|pid|last exit" || echo "not installed"
    ;;
*)
    echo "usage: $0 install | remove | status" >&2
    exit 2
    ;;
esac
