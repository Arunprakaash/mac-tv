#!/bin/bash
# Builds Mac TV and packages it as build/MacTV-<version>.dmg, with an Applications shortcut
# so it installs by drag and drop.
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ "${MACTV_SKIP_BUILD:-0}" != "1" ]]; then ./build.sh; fi
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Info.plist)
mkdir -p build
STAGE=$(mktemp -d "build/dmg-stage.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT
cp -R "build/Mac TV.app" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "build/MacTV-$VERSION.dmg"
hdiutil create -volname "Mac TV" -srcfolder "$STAGE" -ov -format UDZO "build/MacTV-$VERSION.dmg" >/dev/null
echo "Built $(pwd)/build/MacTV-$VERSION.dmg"
