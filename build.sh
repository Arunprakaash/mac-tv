#!/bin/bash
# Builds "Mac TV.app" into ./build
set -euo pipefail
cd "$(dirname "$0")"

# One universal binary: Apple silicon and Intel Macs.
ARCHS=(--arch arm64 --arch x86_64)
swift build -c release "${ARCHS[@]}"
BIN="$(swift build -c release "${ARCHS[@]}" --show-bin-path)"

APP="build/Mac TV.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/MacTV" "$APP/Contents/MacOS/MacTV"
cp Info.plist "$APP/Contents/Info.plist"
cp -R Icons "$APP/Contents/Resources/Icons"
cp Assets/AppIcon.icns Assets/AppIcon.png "$APP/Contents/Resources/"
codesign --force --sign - "$APP" >/dev/null

echo "Built $(pwd)/$APP"
