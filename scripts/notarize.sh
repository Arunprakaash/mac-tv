#!/bin/bash
# Sign and notarize a local build using an existing Developer ID and notarytool keychain profile.
set -euo pipefail
cd "$(dirname "$0")/.."
: "${MACTV_DEVELOPER_ID:?Set MACTV_DEVELOPER_ID to your Developer ID Application identity}"
: "${MACTV_NOTARY_PROFILE:?Set MACTV_NOTARY_PROFILE to an existing notarytool keychain profile}"
./build.sh
APP="build/Mac TV.app"
codesign --force --options runtime --timestamp --sign "$MACTV_DEVELOPER_ID" "$APP"
codesign --verify --deep --strict "$APP"
ditto -c -k --keepParent "$APP" build/MacTV-notarize.zip
xcrun notarytool submit build/MacTV-notarize.zip --keychain-profile "$MACTV_NOTARY_PROFILE" --wait
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose "$APP"
echo "Signed and notarized: $APP"
MACTV_SKIP_BUILD=1 ./scripts/make-dmg.sh
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Info.plist)
DMG="build/MacTV-$VERSION.dmg"
codesign --force --timestamp --sign "$MACTV_DEVELOPER_ID" "$DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$MACTV_NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
echo "Notarized installer: $DMG"
