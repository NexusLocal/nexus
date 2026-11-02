#!/bin/bash
# Makes a signed and notarized release and publishes it on GitHub.
# Usage: Config/release.sh 0.2.0
# Add --test to make the same files and publish nothing.
#
# This Mac needs the certificate "Developer ID Application" of the team, the notary login
# "nexus-notary" in the Keychain and the private update key of Sparkle in the Keychain.

set -euo pipefail

VERSION="${1:?Give the version, for example: Config/release.sh 0.2.0}"
MODE="${2:-}"
TEAM="4G5C39PFB2"
REPOSITORY="NexusLocal/nexus"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
BUILD="$(git -C "$ROOT" rev-list --count HEAD)"
DMG="$WORK/release/Nexus.dmg"

if [ -n "$MODE" ] && [ "$MODE" != "--test" ]; then
    echo "Unknown option $MODE. The only option is --test."
    exit 1
fi

if [ -n "$(git -C "$ROOT" status --porcelain)" ]; then
    echo "Commit your changes first."
    exit 1
fi

mkdir -p "$WORK/release" "$WORK/image/.background"

xcodebuild archive \
    -project "$ROOT/Nexus.xcodeproj" \
    -scheme Nexus \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -archivePath "$WORK/Nexus.xcarchive" \
    -derivedDataPath "$WORK/derived" \
    DEVELOPMENT_TEAM="$TEAM" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="Developer ID Application" \
    MARKETING_VERSION="$VERSION" \
    CURRENT_PROJECT_VERSION="$BUILD"

xcodebuild -exportArchive \
    -archivePath "$WORK/Nexus.xcarchive" \
    -exportOptionsPlist "$ROOT/Config/ExportOptions.plist" \
    -exportPath "$WORK/export"

cp -R "$WORK/export/Nexus.app" "$WORK/image/"
ln -s /Applications "$WORK/image/Applications"
cp "$ROOT/Config/DiskImage/background.tiff" "$WORK/image/.background/"
cp "$ROOT/Config/DiskImage/DS_Store" "$WORK/image/.DS_Store"
hdiutil create -volname Nexus -srcfolder "$WORK/image" -ov -format UDZO "$DMG"
codesign --sign "Developer ID Application" --timestamp "$DMG"

xcrun notarytool submit "$DMG" --keychain-profile nexus-notary --wait
xcrun stapler staple "$DMG"

"$WORK/derived/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_appcast" \
    --download-url-prefix "https://github.com/$REPOSITORY/releases/download/v$VERSION/" \
    "$WORK/release"

if [ "$MODE" = "--test" ]; then
    echo "Nothing is published. The files are in $WORK/release"
    exit 0
fi

gh release create "v$VERSION" "$DMG" "$WORK/release/appcast.xml" \
    --repo "$REPOSITORY" \
    --title "Nexus $VERSION" \
    --generate-notes

echo "Published https://github.com/$REPOSITORY/releases/tag/v$VERSION"
