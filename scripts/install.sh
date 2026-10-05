#!/bin/bash
# Builds GlassLock, installs it to /Applications and starts it at login.
# launchd relaunches it after a crash (but not after "Quit GlassLock").
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/build-app.sh

LABEL="com.harigovind.glasslock"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
DOMAIN="gui/$(id -u)"

launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
pkill -x GlassLock 2>/dev/null || true

rm -rf /Applications/GlassLock.app
cp -R build/GlassLock.app /Applications/

mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>/Applications/GlassLock.app/Contents/MacOS/GlassLock</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
    </dict>
    <key>ThrottleInterval</key>
    <integer>1</integer>
    <key>ProcessType</key>
    <string>Interactive</string>
</dict>
</plist>
PLIST

launchctl bootstrap "$DOMAIN" "$PLIST"
echo "GlassLock installed and running. Look for the lock icon in the menu bar."
