#!/bin/bash
# Builds a universal (arm64 + x86_64) Hubless.app into ./build, ad-hoc signs it,
# and zips it as build/Hubless-<version>.zip for distribution.
#   VERSION=1.2.0 ./scripts/build_app.sh   # version defaults to Info.plist's value
#   ARCHS="arm64" ./scripts/build_app.sh   # faster single-arch local build
set -euo pipefail
cd "$(dirname "$0")/.."
APP=build/Hubless.app
ARCHS=${ARCHS:-"arm64 x86_64"}
PLIST_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
VERSION=${VERSION:-$PLIST_VERSION}
VERSION=${VERSION#v}

ARCH_FLAGS=()
for a in $ARCHS; do ARCH_FLAGS+=(--arch "$a"); done
swift build -c release "${ARCH_FLAGS[@]}"
BIN=$(swift build -c release "${ARCH_FLAGS[@]}" --show-bin-path)/Hubless

rm -rf "$APP" && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Hubless"
cp Resources/Info.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${BUILD_NUMBER:-1}" "$APP/Contents/Info.plist"
if [ ! -f build/AppIcon.icns ]; then
  rm -rf build/AppIcon.iconset
  swift scripts/make_icon.swift build/AppIcon.iconset
  iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
fi
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - --entitlements Resources/Hubless.entitlements --options runtime "$APP"

ZIP="build/Hubless-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
echo "Built $APP ($(lipo -archs "$APP/Contents/MacOS/Hubless"), version $VERSION)"
echo "Packaged $ZIP"
