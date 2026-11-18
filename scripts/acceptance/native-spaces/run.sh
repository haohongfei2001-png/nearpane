#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../../.."
scratch="$(mktemp -d "/private/tmp/nearpane-wp5.XXXXXXXX")"
trap 'rm -rf -- "$scratch"' EXIT
xcrun clang -c Sources/CReadOnlySpaces/ReadOnlySpaces.c -I Sources/CReadOnlySpaces/include -o "$scratch/reader.o"
xcrun swiftc -module-cache-path "$scratch/module-cache" -import-objc-header Sources/CReadOnlySpaces/include/ReadOnlySpaces.h \
    scripts/acceptance/native-spaces/observe.swift "$scratch/reader.o" -o "$scratch/observe"
xcrun swiftc -module-cache-path "$scratch/module-cache" scripts/acceptance/native-spaces/metrics.swift -o "$scratch/metrics"
if [[ ${1:-} == title-image || ${1:-} == candidate ]]; then
    xcrun swiftc -parse-as-library -module-cache-path "$scratch/module-cache" scripts/acceptance/native-spaces/capture.swift -o "$scratch/capture"
fi
if [[ ${1:-} == roster || ${1:-} == controlled-window || ${1:-} == single-window || ${1:-} == fixture-inventory || ${1:-} == candidate ]]; then
    mkdir -p "$scratch/Field Notes.app/Contents/MacOS"
    cp scripts/acceptance/native-spaces/fixture.plist "$scratch/Field Notes.app/Contents/Info.plist"
    xcrun swiftc -module-cache-path "$scratch/module-cache" scripts/acceptance/native-spaces/window.swift \
        -o "$scratch/Field Notes.app/Contents/MacOS/FieldNotes"
    codesign --force --sign - "$scratch/Field Notes.app"
fi
if [[ ${1:-} == roster ]]; then
    [[ $# == 2 ]]
    python3 scripts/acceptance/native-spaces/roster.py "$scratch/observe" "$2"
    exit $?
fi
if [[ ${1:-} == candidate ]]; then
    [[ $# == 2 ]]
    mkdir "$2"
    failures=0
    for mode in preflight single-window controlled-window title-image hidden-budget; do
        python3 scripts/acceptance/native-spaces/acceptance.py --observer "$scratch/observe" "$mode" "$2/$mode" || failures=1
    done
    exit "$failures"
fi
python3 scripts/acceptance/native-spaces/acceptance.py --observer "$scratch/observe" "$@"
