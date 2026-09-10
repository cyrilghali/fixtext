#!/bin/bash
# Build ~/Applications/FixText.app from main.swift + Info.plist, sign it ad hoc, and (re)register its service.
set -euo pipefail
cd "$(dirname "$0")"
APP="$HOME/Applications/FixText.app"
mkdir -p "$APP/Contents/MacOS"
swiftc -O main.swift -o "$APP/Contents/MacOS/FixText"
cp Info.plist "$APP/Contents/Info.plist"
mkdir -p "$APP/Contents/Resources" && cp FixText.icns "$APP/Contents/Resources/FixText.icns"
identity=$(security find-identity -v -p codesigning | grep -q "FixText Dev" && echo "FixText Dev" || echo "-")
codesign -s "$identity" -f "$APP" >/dev/null 2>&1   # "FixText Dev" keeps Accessibility grants across rebuilds; "-" is ad hoc
pkill -x FixText || true
/System/Library/CoreServices/pbs -flush
/System/Library/CoreServices/pbs -update
echo "built $APP"
