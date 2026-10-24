#!/bin/bash
# Builds the direct edition ("Noria Direct"), signs it with Developer ID,
# notarizes it with Apple, and packages it in a notarized DMG.
#
# Run on a Mac with Xcode, from the repository root:
#   Tools/release_direct.sh
#
# One-time setup (see docs/DISTRIBUTION.md):
#   1. A "Developer ID Application" certificate for team 62395T6WLG in the keychain.
#   2. Notary credentials stored in the keychain:
#        xcrun notarytool store-credentials noria-notary \
#          --apple-id <your Apple ID> --team-id 62395T6WLG --password <app-specific password>
#      (or set NOTARY_PROFILE to another profile name).
set -euo pipefail

PROFILE="${NOTARY_PROFILE:-noria-notary}"
BUILD="build/release"
ARCHIVE="$BUILD/NoriaDirect.xcarchive"
EXPORT="$BUILD/export"
APP="$EXPORT/Noria.app"

step() { printf '\n==> %s\n' "$1"; }

rm -rf "$BUILD"
mkdir -p "$BUILD"

step "Archiving Noria Direct (Release)"
xcodebuild -project Noria.xcodeproj -scheme "Noria Direct" -configuration Release \
  -destination 'generic/platform=macOS' -archivePath "$ARCHIVE" archive -quiet

step "Exporting with Developer ID"
xcodebuild -exportArchive -archivePath "$ARCHIVE" \
  -exportOptionsPlist Tools/ExportOptions-DeveloperID.plist -exportPath "$EXPORT" -quiet

VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
BUILD_NUMBER=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")
DMG="$BUILD/Noria-$VERSION.dmg"

step "Verifying signature and hardened runtime"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign --display --verbose=2 "$APP" 2>&1 | grep -E 'Authority=Developer ID Application|flags=.*runtime' \
  || { echo "The app is not signed with Developer ID and the hardened runtime." >&2; exit 1; }

step "Notarizing the app"
ditto -c -k --keepParent "$APP" "$BUILD/Noria.zip"
xcrun notarytool submit "$BUILD/Noria.zip" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$APP"

step "Building the DMG"
STAGING="$BUILD/dmg"
mkdir -p "$STAGING"
ditto "$APP" "$STAGING/Noria.app"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "Noria" -srcfolder "$STAGING" -ov -format UDZO "$DMG" -quiet

IDENTITY=$(codesign --display --verbose=2 "$APP" 2>&1 | sed -n 's/^Authority=\(Developer ID Application.*\)$/\1/p' | head -1)
codesign --sign "$IDENTITY" --timestamp "$DMG"

step "Notarizing the DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$DMG"

step "Gatekeeper check"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
spctl --assess --type execute --verbose=2 "$APP"

shasum -a 256 "$DMG" | tee "$DMG.sha256"
printf '\nDone: %s (version %s, build %s)\n' "$DMG" "$VERSION" "$BUILD_NUMBER"
