#!/bin/zsh
# Builds FloatShot.app (universal) and FloatShot.dmg into ./build
set -euo pipefail
cd "$(dirname "$0")"

APP=build/FloatShot.app
rm -rf build && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

for arch in arm64 x86_64; do
  swiftc -O -swift-version 5 -target $arch-apple-macos14.0 \
    -framework AppKit -framework ScreenCaptureKit -framework Vision -framework Carbon -framework AVFoundation -framework CoreMedia \
    Sources/main.swift -o build/FloatShot-$arch
done
lipo -create build/FloatShot-arm64 build/FloatShot-x86_64 -output "$APP/Contents/MacOS/FloatShot"
rm build/FloatShot-arm64 build/FloatShot-x86_64

cp Info.plist "$APP/Contents/Info.plist"
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# A stable identity keeps the Screen Recording grant across rebuilds; fall back to ad-hoc.
IDENTITY="FloatShot Local Signing"
security find-identity -p codesigning | grep -q "$IDENTITY" || IDENTITY=-
codesign --force --deep --sign "$IDENTITY" "$APP"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)

STAGE=build/dmg
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
# Volume icon shown when the DMG is mounted.
cp AppIcon.icns "$STAGE/.VolumeIcon.icns"
SetFile -c icnC "$STAGE/.VolumeIcon.icns"
SetFile -a C "$STAGE"
DMG=build/FloatShot-$VERSION.dmg
hdiutil create -volname "FloatShot $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
rm -rf "$STAGE"
# Icon on the .dmg file itself in Finder.
osascript -l JavaScript -e "ObjC.import('AppKit'); \$.NSWorkspace.sharedWorkspace.setIconForFileOptions(\$.NSImage.alloc.initWithContentsOfFile('AppIcon.icns'), '$DMG', 0)" >/dev/null
echo "Built $DMG"
