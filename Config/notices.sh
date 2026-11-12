#!/bin/bash
# Checks that THIRD-PARTY-NOTICES.md names the version of each package that ships in the app.
# Usage: Config/notices.sh
#
# The build copies THIRD-PARTY-NOTICES.md into the app, and the About window shows it. Config/
# release.sh runs this check. After a package update: update its row and its section (also the
# BoringSSL revision of Swift Crypto), then run this script.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NOTICES="$ROOT/THIRD-PARTY-NOTICES.md"

# The packages of the Xcode project and of NexusKit, by the name of their row in the table. Each
# other package must be in NOT_SHIPPED.
SHIPPED="sentry-cocoa=Sentry Cocoa SDK
sparkle=Sparkle
swift-argument-parser=Swift Argument Parser
swift-asn1=SwiftASN1
swift-certificates=Swift Certificates
swift-crypto=Swift Crypto"
NOT_SHIPPED=""

problems=0

# The version of a project is in its row of the table, | [Name](#anchor) | 1.2.3 | License | Use |,
# and at the start of its section: Version 1.2.3, <repository>
check_version() {
    local name="$1" version="$2" row section

    row="$(grep -F "| [$name](" "$NOTICES" || true)"

    if [ -z "$row" ]; then
        echo "THIRD-PARTY-NOTICES.md has no row for $name."
        problems=1
        return
    fi

    if ! grep -qF "| $version |" <<< "$row"; then
        echo "The table in THIRD-PARTY-NOTICES.md does not give version $version of $name."
        problems=1
    fi

    section="$(awk -v heading="## $name" '$0 == heading { inside = 1; next } /^## / { inside = 0 } inside' "$NOTICES")"

    if ! grep -qF "Version $version, " <<< "$section"; then
        echo "The section $name in THIRD-PARTY-NOTICES.md does not give version $version."
        problems=1
    fi
}

for resolved in "$ROOT/NexusKit/Package.resolved" "$ROOT/Nexus.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"; do
    index=0

    while identity="$(plutil -extract "pins.$index.identity" raw "$resolved" 2>/dev/null)"; do
        version="$(plutil -extract "pins.$index.state.version" raw "$resolved" 2>/dev/null || true)"
        name="$(echo "$SHIPPED" | sed -n "s/^$identity=//p")"
        index=$((index + 1))

        if [ -z "$name" ]; then
            if ! echo " $NOT_SHIPPED " | grep -qF " $identity "; then
                echo "The package $identity is new. Add it to THIRD-PARTY-NOTICES.md and to SHIPPED in this script, or to NOT_SHIPPED."
                problems=1
            fi

            continue
        fi

        if [ -z "$version" ]; then
            echo "The package $identity has a branch or a revision in $resolved, not a version. THIRD-PARTY-NOTICES.md must name a version. Pin a version."
            problems=1
            continue
        fi

        check_version "$name" "$version"
    done
done

var_dumper="$(sed -n 's/^symfony\/var-dumper v//p' "$ROOT/NexusPHP/dumps/vendor/var-dumper/VERSION")"
check_version "Symfony VarDumper" "$var_dumper"

if [ "$problems" -ne 0 ]; then
    exit 1
fi

echo "The third-party notices name the shipped versions."
