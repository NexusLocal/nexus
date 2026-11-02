#!/bin/bash
# Xcode runs this after it copies Sparkle into the app. Sparkle then shows the texts of
# Config/Sparkle.strings. The file is part of the signature of the framework, so the framework
# gets a new signature. A build without signing skips that step.

set -euo pipefail

SOURCE="$SRCROOT/Config/Sparkle.strings"
FRAMEWORK="$TARGET_BUILD_DIR/$FRAMEWORKS_FOLDER_PATH/Sparkle.framework/Versions/B"
TEXT_FILE="$FRAMEWORK/Resources/Base.lproj/Sparkle.strings"

unknown=$(/usr/bin/jq -n -r \
    --argjson ours "$(/usr/bin/plutil -convert json -o - "$SOURCE")" \
    --argjson sparkle "$(/usr/bin/plutil -convert json -o - "$TEXT_FILE")" \
    '$ours | keys[] | select(in($sparkle) | not)')

if [ -n "$unknown" ]; then
    echo "error: Sparkle has no text with these keys of Config/Sparkle.strings. Use the new texts of Sparkle as keys:"
    echo "$unknown"
    exit 1
fi

/usr/bin/plutil -convert binary1 -o "$TEXT_FILE" "$SOURCE"

if [ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]; then
    /usr/bin/codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" -o runtime \
        --preserve-metadata=identifier,entitlements,flags,requirements \
        --generate-entitlement-der "$FRAMEWORK"
fi
