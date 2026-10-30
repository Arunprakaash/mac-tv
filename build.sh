#!/bin/bash
# Builds "Mac TV.app" into ./build
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP="build/Mac TV.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/MacTV "$APP/Contents/MacOS/MacTV"
cp Info.plist "$APP/Contents/Info.plist"
cp -R Icons "$APP/Contents/Resources/Icons"
cp Assets/AppIcon.icns Assets/AppIcon.png "$APP/Contents/Resources/"
codesign --force --sign - "$APP" >/dev/null

echo "Built $(pwd)/$APP"
