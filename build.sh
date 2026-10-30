#!/bin/bash
# Builds Matinee.app into ./build
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP=build/Matinee.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Matinee "$APP/Contents/MacOS/Matinee"
cp Info.plist "$APP/Contents/Info.plist"
cp -R Icons "$APP/Contents/Resources/Icons"
codesign --force --sign - "$APP" >/dev/null

echo "Built $(pwd)/$APP"
