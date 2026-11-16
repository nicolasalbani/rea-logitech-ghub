#!/bin/bash
# Builds Hubless.app (release, universal-ready) into ./build and ad-hoc signs it.
set -euo pipefail
cd "$(dirname "$0")/.."
APP=build/Hubless.app
swift build -c release
rm -rf "$APP" && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Hubless "$APP/Contents/MacOS/Hubless"
cp Resources/Info.plist "$APP/Contents/Info.plist"
if [ ! -f build/AppIcon.icns ]; then
  rm -rf build/AppIcon.iconset
  swift scripts/make_icon.swift build/AppIcon.iconset
  iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
fi
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - --entitlements Resources/Hubless.entitlements --options runtime "$APP"
echo "Built $APP"
