#!/bin/bash
# run-d01.sh {preflight|run} FRESH_OUTPUT [--scope PRIVATE_SCOPE_JSON]
set -euo pipefail
[[ $# == 2 || $# == 4 ]] || { echo 'usage: run-d01.sh {preflight|run} OUTPUT [--scope SCOPE]' >&2; exit 2; }
[[ "$1" == preflight || "$1" == run ]] || exit 2
cd "$(dirname "$0")/../../.."
umask 077
kit="$(mktemp -d /private/tmp/nearpane-d01.XXXXXXXX)"
trap 'rm -rf -- "$kit"' EXIT
src=scripts/acceptance/native-spaces
include=Sources/CReadOnlySpaces/include
xcrun clang -I "$include" -c Sources/CReadOnlySpaces/ReadOnlySpaces.c -o "$kit/reader.o"
for name in observe d01_input; do
    dest="$name"
    [[ "$name" != d01_input ]] || dest=d01-input
    xcrun swiftc -module-cache-path "$PWD/.build/clang-cache" -import-objc-header "$include/ReadOnlySpaces.h" \
        "$src/$name.swift" "$kit/reader.o" -o "$kit/$dest"
done
mkdir -p "$kit/Field Notes.app/Contents/MacOS"
cp "$src/fixture.plist" "$kit/Field Notes.app/Contents/Info.plist"
xcrun swiftc -module-cache-path "$PWD/.build/clang-cache" "$src/window.swift" -o "$kit/Field Notes.app/Contents/MacOS/FieldNotes"
/usr/bin/codesign --force --sign - "$kit/Field Notes.app"
/usr/bin/codesign --verify --strict "$kit/Field Notes.app"
python3 "$src/d01.py" --kit "$kit" "$@"
