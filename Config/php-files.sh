#!/bin/bash
# Xcode runs this before it signs the app. It copies the PHP library of the dump viewer into the
# app, without its tests. nexusd copies the library from the app to php/dumps in Application
# Support. So PHP never uses a file in the app (see "Part 5" in docs/dump-viewer-build.md).
# HASH names the folder of that copy. So each new version of the library gets a new folder.

set -euo pipefail

SOURCE="$SRCROOT/NexusPHP/dumps/"
TARGET="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Resources/php/dumps/"

mkdir -p "$TARGET"
/usr/bin/rsync -a --delete --delete-excluded --exclude '/tests/' --exclude '.*' "$SOURCE" "$TARGET"

cd "$TARGET"
/usr/bin/find . -type f ! -path ./HASH -print0 \
    | LC_ALL=C /usr/bin/sort -z \
    | /usr/bin/xargs -0 /usr/bin/shasum -a 256 \
    | /usr/bin/shasum -a 256 \
    | /usr/bin/cut -c 1-12 > HASH
