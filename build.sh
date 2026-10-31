#!/bin/bash
# Builds "Mac TV.app" into ./build
set -euo pipefail
cd "$(dirname "$0")"

# One universal binary: Apple silicon and Intel Macs.
ARCHS=(--arch arm64 --arch x86_64)
BUILD_LOCATION=(--scratch-path "${MACTV_BUILD_DIR:-.build}")
swift build -c release "${ARCHS[@]}" "${BUILD_LOCATION[@]}"
BIN="$(swift build -c release "${ARCHS[@]}" "${BUILD_LOCATION[@]}" --show-bin-path)"

APP="build/Mac TV.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/MacTV" "$APP/Contents/MacOS/MacTV"
cp Info.plist "$APP/Contents/Info.plist"
cp -R Icons "$APP/Contents/Resources/Icons"
cp Assets/AppIcon.icns Assets/AppIcon.png "$APP/Contents/Resources/"
# Sign with the local certificate when it exists (scripts/make-signing-cert.sh), so macOS keeps
# permissions like Accessibility across builds; otherwise sign ad hoc.
IDENTITY="${MACTV_SIGN_IDENTITY:-Mac TV Local Signing}"
if security find-identity -p codesigning 2>/dev/null | grep -q "\"$IDENTITY\""; then
    codesign --force --entitlements Assets/MacTV.entitlements --sign "$IDENTITY" "$APP" >/dev/null
else
    codesign --force --entitlements Assets/MacTV.entitlements --sign - "$APP" >/dev/null
fi

echo "Built $(pwd)/$APP"
