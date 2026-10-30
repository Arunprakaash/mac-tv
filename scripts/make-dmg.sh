#!/bin/bash
# Builds Mac TV and packages it as build/MacTV-<version>.dmg, with an Applications shortcut
# so it installs by drag and drop.
set -euo pipefail
cd "$(dirname "$0")/.."

./build.sh
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Info.plist)
STAGE=$(mktemp -d)
cp -R "build/Mac TV.app" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "build/MacTV-$VERSION.dmg"
hdiutil create -volname "Mac TV" -srcfolder "$STAGE" -ov -format UDZO "build/MacTV-$VERSION.dmg" >/dev/null
rm -rf "$STAGE"
echo "Built $(pwd)/build/MacTV-$VERSION.dmg"
