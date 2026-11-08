#!/bin/bash
# Xcode runs this before it signs the app. It writes the launchd jobs of nexusd and the helper into
# the app, with names that follow the bundle id of the app. So Nexus Dev, the Debug build, has jobs
# of its own next to the installed Nexus. LaunchServices/daemon.plist and helper.plist hold the
# other keys of each job.

set -euo pipefail

CONTENTS="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH"

write_job() {
    local name=$1
    local folder="$CONTENTS/Library/$2"
    local label="$PRODUCT_BUNDLE_IDENTIFIER.$name"
    local job="$folder/$label.plist"

    mkdir -p "$folder"
    find "$folder" -name '*.plist' ! -name "$label.plist" -delete
    cp "$SRCROOT/LaunchServices/$name.plist" "$job"

    /usr/libexec/PlistBuddy \
        -c "Set :Label $label" \
        -c "Set :AssociatedBundleIdentifiers:0 $PRODUCT_BUNDLE_IDENTIFIER" \
        -c "Delete :MachServices" \
        -c "Add :MachServices dict" \
        -c "Add :MachServices:$label bool true" \
        "$job"
}

write_job daemon LaunchAgents
write_job helper LaunchDaemons
