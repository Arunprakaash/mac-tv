#!/bin/bash
# Builds Mac TV and packages it as build/MacTV-<version>.dmg: a window with Mac TV on the left,
# Applications on the right and Assets/dmg-background.tiff behind them, so it installs by drag and drop.
# Laying out the window asks Finder, so the first run asks to let Terminal (or your shell's app) control Finder.
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ "${MACTV_SKIP_BUILD:-0}" != "1" ]]; then ./build.sh; fi
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Info.plist)
VOLUME="Mac TV"
DMG="build/MacTV-$VERSION.dmg"
mkdir -p build
STAGE=$(mktemp -d "build/dmg-stage.XXXXXX")
RW="$STAGE.rw.dmg"
MOUNT=""
cleanup() {
    if [[ -n "$MOUNT" ]]; then hdiutil detach "$MOUNT" -quiet -force || true; fi
    rm -rf "$STAGE" "$RW"
}
trap cleanup EXIT

cp -R "build/Mac TV.app" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
mkdir "$STAGE/.background"
cp Assets/dmg-background.tiff "$STAGE/.background/background.tiff"

# A writable image first, so Finder can save the window layout into it.
hdiutil create -volname "$VOLUME" -srcfolder "$STAGE" -ov -format UDRW "$RW" >/dev/null
MOUNT=$(hdiutil attach "$RW" -readwrite -noverify -noautoopen | awk -F'\t' '/\/Volumes\// { print $NF; exit }')
DISK=$(basename "$MOUNT")

# Window 660×400 points of content (the background's size) plus the title bar; icon centres match
# scripts/make-dmg-background.swift.
osascript <<EOF
tell application "Finder"
    tell disk "$DISK"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set pathbar visible of container window to false
        set the bounds of container window to {200, 120, 860, 548}
        set viewOptions to the icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 128
        set text size of viewOptions to 13
        set background picture of viewOptions to file ".background:background.tiff"
        set position of item "Mac TV.app" of container window to {180, 190}
        set position of item "Applications" of container window to {480, 190}
        update without registering applications
        delay 1
        close
    end tell
end tell
EOF

sync
hdiutil detach "$MOUNT" -quiet
MOUNT=""
rm -f "$DMG"
hdiutil convert "$RW" -format UDZO -imagekey zlib-level=9 -o "$DMG" >/dev/null
echo "Built $(pwd)/$DMG"
