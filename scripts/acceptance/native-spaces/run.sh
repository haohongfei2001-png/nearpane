#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../../.."
scratch="$(mktemp -d "/private/tmp/nearpane-wp5.XXXXXXXX")"
trap 'rm -rf -- "$scratch"' EXIT
xcrun clang -c Sources/CReadOnlySpaces/ReadOnlySpaces.c -I Sources/CReadOnlySpaces/include -o "$scratch/reader.o"
xcrun swiftc -module-cache-path "$scratch/module-cache" -import-objc-header Sources/CReadOnlySpaces/include/ReadOnlySpaces.h \
    scripts/acceptance/native-spaces/observe.swift "$scratch/reader.o" -o "$scratch/observe"
xcrun swiftc -module-cache-path "$scratch/module-cache" scripts/acceptance/native-spaces/metrics.swift -o "$scratch/metrics"
if [[ ${1:-} == controlled-window ]]; then
    mkdir -p "$scratch/Field Notes.app/Contents/MacOS"
    cp scripts/acceptance/native-spaces/fixture.plist "$scratch/Field Notes.app/Contents/Info.plist"
    xcrun swiftc -module-cache-path "$scratch/module-cache" scripts/acceptance/native-spaces/window.swift \
        -o "$scratch/Field Notes.app/Contents/MacOS/FieldNotes"
    codesign --force --sign - "$scratch/Field Notes.app"
fi
python3 scripts/acceptance/native-spaces/acceptance.py --observer "$scratch/observe" "$@"
