#!/bin/bash
# Makes the copy of symfony/var-dumper that the dump viewer uses, in the namespace
# Nexus\Dumps\VarDumper. Usage: Config/var-dumper.sh v7.4.22
# The script uses the newest PHP of Nexus Dev. Set PHP=/path/to/php to use another PHP.
#
# The copy has its own namespace, so it does not clash with the VarDumper of a site. The script
# does not use php-scoper. php-scoper also changes the class names of other packages in the
# caster list of the cloner, and then the casters for Doctrine, Carbon and others stop working.
#
# After an update: check the diff, run the app tests and commit the copy.

set -euo pipefail

TAG="${1:?Give the tag, for example: Config/var-dumper.sh v7.4.22}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TARGET="$ROOT/NexusPHP/dumps/vendor/var-dumper"
NEW="$TARGET.new"
OLDEST_PHP="8.2"
WORK="$(mktemp -d)"
SOURCE="$WORK/var-dumper"
trap 'rm -rf "$WORK" "$NEW"' EXIT

rm -rf "$NEW"
mkdir -p "$NEW"

# Without a PHP of Nexus Dev, the php on the PATH is used. That is the PHP of Nexus when Nexus is
# on the PATH.
if [ -z "${PHP:-}" ]; then
    RUNTIMES="$HOME/Library/Application Support/Nexus Dev/runtimes/php"
    NEWEST="$(ls "$RUNTIMES" 2>/dev/null | sort -t . -k 1,1n -k 2,2n -k 3,3n | tail -n 1 || true)"
    PHP="$RUNTIMES/$NEWEST/bin/php"

    if [ -z "$NEWEST" ] || [ ! -x "$PHP" ]; then
        PHP="$(command -v php || true)"
    fi
fi

if [ -z "$PHP" ] || [ ! -x "$PHP" ]; then
    echo "No PHP found. Install a PHP in Nexus Dev or set PHP=/path/to/php."
    exit 1
fi

# A shallow clone of an annotated tag prints the warning "is not a commit". A fetch of the tag
# gets the same files without it.
git init --quiet "$SOURCE"
git -C "$SOURCE" fetch --quiet --depth 1 https://github.com/symfony/var-dumper "refs/tags/$TAG"
git -C "$SOURCE" -c advice.detachedHead=false checkout --quiet FETCH_HEAD
COMMIT="$(git -C "$SOURCE" rev-parse HEAD)"

# Each site gets the copy. So the copy must run on the oldest PHP line of Nexus (decisions.md).
if ! "$PHP" -n -r '
    $require = json_decode(file_get_contents($argv[1]), true)["require"]["php"] ?? "";
    preg_match("/\d+\.\d+/", $require, $match);
    exit(version_compare($match[0] ?? "99", $argv[2], "<=") ? 0 : 1);
' "$SOURCE/composer.json" "$OLDEST_PHP"; then
    echo "symfony/var-dumper $TAG needs a PHP newer than $OLDEST_PHP. Choose an older tag."
    exit 1
fi

cp -R "$SOURCE/Caster" "$SOURCE/Cloner" "$SOURCE/Dumper" "$SOURCE/Exception" "$SOURCE/LICENSE" "$NEW/"

# Nexus defines dump() and dd() itself and sends the dumps to nexusd. So it needs no context
# providers and no dump server, and the two dumpers that use them cannot work without them.
rm -rf "$NEW/Dumper/ContextProvider"
rm -f "$NEW/Dumper/ContextualizedDumper.php" "$NEW/Dumper/ServerDumper.php"

# Also change the names with two backslashes, which a PHP string can hold.
find "$NEW" -name '*.php' -exec perl -pi -e \
    's/Symfony(\\+)Component(\\+)VarDumper\b/Nexus${1}Dumps${2}VarDumper/g' {} +

LEFT="$(grep -rlE 'Symfony\\+(Component\\+VarDumper|Polyfill)' "$NEW" || true)"

if [ -n "$LEFT" ]; then
    echo "These files still name Symfony\\Component\\VarDumper or Symfony\\Polyfill:"
    echo "$LEFT"
    exit 1
fi

OTHERS="$(grep -rhoE 'Symfony(\\+[A-Za-z_][A-Za-z0-9_]*)+' "$NEW" | perl -pe 's/\\+/\\/g; s/^/    /' | sort -u || true)"
echo "These Symfony names stay as they are. They belong to other packages:"
echo "$OTHERS"

# A name of a left-out class is safe only as a name, for example with ::class. Each name on this
# list was checked by hand. A new name stops the script until someone checks it too.
CHECKED_NAMES=" Nexus\\Dumps\\VarDumper\\Dumper\\ContextProvider\\SourceContextProvider "
MISSING=""

while IFS= read -r NAME; do
    RELATIVE="${NAME#Nexus\\Dumps\\VarDumper\\}"
    RELATIVE="${RELATIVE//\\//}"

    if [ -f "$NEW/$RELATIVE.php" ] || [ -d "$NEW/$RELATIVE" ]; then
        continue
    fi

    if [[ "$CHECKED_NAMES" != *" $NAME "* ]]; then
        MISSING="$MISSING    $NAME"$'\n'
    fi
done < <(grep -rhoE 'Nexus\\+Dumps\\+VarDumper(\\+[A-Za-z_][A-Za-z0-9_]*)+' "$NEW" | perl -pe 's/\\+/\\/g' | sort -u)

if [ -n "$MISSING" ]; then
    echo "These names point to classes that the copy leaves out. Check that the code only uses them as names. Then add them to CHECKED_NAMES:"
    printf '%s' "$MISSING"
    exit 1
fi

printf 'symfony/var-dumper %s\ncommit %s\n' "$TAG" "$COMMIT" > "$NEW/VERSION"

# The test loads each file of the copy. So it also finds a parse error. -n keeps a php.ini and a
# prepend file of the environment out of the test.
echo "The test runs with PHP $("$PHP" -n -r 'echo PHP_VERSION;')."
"$PHP" -n "$ROOT/NexusPHP/dumps/tests/var-dumper-test.php" "$NEW"

# Only a copy that passed all checks replaces the old copy.
rm -rf "$TARGET"
mv "$NEW" "$TARGET"

echo "Done: symfony/var-dumper $TAG ($COMMIT) is in NexusPHP/dumps/vendor/var-dumper."
