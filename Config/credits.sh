#!/bin/bash
# Writes Nexus/Credits.rtf from THIRD-PARTY-NOTICES.md. The About window of the app shows that file.
# So each copy of the app has the full license texts, as the licenses ask.
# Usage: Config/credits.sh          writes the file
#        Config/credits.sh --check  changes nothing and fails when the notices are old
#
# The check runs in Config/release.sh. It fails when Credits.rtf does not hold the notices, or when
# a shipped package has another version than THIRD-PARTY-NOTICES.md names. After a package update:
# update its section (also the BoringSSL revision of Swift Crypto), then run this script.

set -euo pipefail

MODE="${1:-}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NOTICES="$ROOT/THIRD-PARTY-NOTICES.md"
CREDITS="$ROOT/Nexus/Credits.rtf"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# The packages of the Xcode project and of NexusKit, by the name of their row in the table. Each
# other package must be in NOT_SHIPPED.
SHIPPED="sentry-cocoa=Sentry Cocoa SDK
sparkle=Sparkle
swift-argument-parser=Swift Argument Parser
swift-asn1=SwiftASN1
swift-certificates=Swift Certificates
swift-crypto=Swift Crypto"
NOT_SHIPPED=""

if [ -n "$MODE" ] && [ "$MODE" != "--check" ]; then
    echo "Unknown option $MODE. The only option is --check."
    exit 1
fi

# The About window is narrow. So the lines of a paragraph, a heading or a list item join into one
# line, and the window breaks them. The license texts in the code blocks keep their lines.
{
    echo "Nexus includes software of other projects. Their notices and licenses follow."
    echo
    awk '
        function flush() { if (paragraph != "") print paragraph; paragraph = "" }
        /^```/ { flush(); code = !code; next }
        code { print; next }
        /^$/ { flush(); print ""; next }
        /^(#|\||- |  - |[0-9]+\. )/ { flush(); paragraph = $0; next }
        { line = $0; sub(/^ +/, "", line); paragraph = (paragraph == "") ? line : paragraph " " line }
        END { flush() }
    ' "$NOTICES"
} > "$WORK/Credits.txt"

textutil -convert rtf -font Helvetica -fontsize 10 -output "$WORK/Credits.rtf" "$WORK/Credits.txt"

if [ "$MODE" != "--check" ]; then
    cp "$WORK/Credits.rtf" "$CREDITS"
    echo "Wrote $CREDITS"
    exit 0
fi

problems=0

if ! cmp -s "$WORK/Credits.rtf" "$CREDITS"; then
    echo "Nexus/Credits.rtf does not hold the current THIRD-PARTY-NOTICES.md. Run: Config/credits.sh"
    problems=1
fi

# The version of a project is in its row of the table: | [Name](#anchor) | 1.2.3 | License |
check_version() {
    local name="$1" version="$2"

    if ! grep -qF "| [$name](" "$NOTICES"; then
        echo "THIRD-PARTY-NOTICES.md has no row for $name."
        problems=1
        return
    fi

    if ! grep -F "| [$name](" "$NOTICES" | grep -qF "| $version |"; then
        echo "THIRD-PARTY-NOTICES.md does not give version $version of $name."
        problems=1
    fi
}

for resolved in "$ROOT/NexusKit/Package.resolved" "$ROOT/Nexus.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"; do
    index=0

    while identity="$(plutil -extract "pins.$index.identity" raw "$resolved" 2>/dev/null)"; do
        version="$(plutil -extract "pins.$index.state.version" raw "$resolved")"
        name="$(echo "$SHIPPED" | sed -n "s/^$identity=//p")"
        index=$((index + 1))

        if [ -n "$name" ]; then
            check_version "$name" "$version"
            continue
        fi

        if ! echo " $NOT_SHIPPED " | grep -qF " $identity "; then
            echo "The package $identity is new. Add it to THIRD-PARTY-NOTICES.md and to SHIPPED in this script, or to NOT_SHIPPED."
            problems=1
        fi
    done
done

var_dumper="$(sed -n 's/^symfony\/var-dumper v//p' "$ROOT/NexusPHP/dumps/vendor/var-dumper/VERSION")"
check_version "Symfony VarDumper" "$var_dumper"

if [ "$problems" -ne 0 ]; then
    exit 1
fi

echo "The third-party notices are up to date."
