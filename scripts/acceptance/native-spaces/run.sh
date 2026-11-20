#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../../.."
scratch="$(mktemp -d "/private/tmp/nearpane-wp5.XXXXXXXX")"
trap 'rm -rf -- "$scratch"' EXIT
xcrun clang -c Sources/CReadOnlySpaces/ReadOnlySpaces.c -I Sources/CReadOnlySpaces/include -o "$scratch/reader.o"
xcrun swiftc -module-cache-path "$scratch/module-cache" -import-objc-header Sources/CReadOnlySpaces/include/ReadOnlySpaces.h \
    scripts/acceptance/native-spaces/observe.swift "$scratch/reader.o" -o "$scratch/observe"
xcrun swiftc -module-cache-path "$scratch/module-cache" scripts/acceptance/native-spaces/metrics.swift -o "$scratch/metrics"
if [[ ${1:-} == compare-roster ]]; then
    [[ $# == 2 ]]
    mkdir -m 700 "$2"
    "$scratch/observe" compare-roster | tee "$2/membership.json"
    python3 -c 'import json,sys;sys.exit(0 if json.load(open(sys.argv[1]))["status"]=="PASS" else 2)' "$2/membership.json"
    exit $?
fi
if [[ ${1:-} == guide ]]; then
    [[ $# == 2 ]]
    mkdir -m 700 "$2"
    "$scratch/observe" guide > "$2/guide.json"
    python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); print(r); sys.exit(0 if r["status"]=="PASS" else 2)' "$2/guide.json"
    exit $?
fi
if [[ ${1:-} == title-image || ${1:-} == candidate || ${1:-} == roster || ${1:-} == current-sidebar ]]; then
    xcrun swiftc -parse-as-library -module-cache-path "$scratch/module-cache" scripts/acceptance/native-spaces/capture.swift -o "$scratch/capture"
fi
if [[ ${1:-} == roster || ${1:-} == controlled-window || ${1:-} == single-window || ${1:-} == fixture-inventory || ${1:-} == candidate || ${1:-} == current-sidebar ]]; then
    mkdir -p "$scratch/Field Notes.app/Contents/MacOS"
    cp scripts/acceptance/native-spaces/fixture.plist "$scratch/Field Notes.app/Contents/Info.plist"
    xcrun swiftc -module-cache-path "$scratch/module-cache" scripts/acceptance/native-spaces/window.swift \
        -o "$scratch/Field Notes.app/Contents/MacOS/FieldNotes"
    codesign --force --sign - "$scratch/Field Notes.app"
fi
if [[ ${1:-} == current-sidebar ]]; then
    [[ $# == 2 ]]
    mkdir -m 700 "$2"
    "$scratch/observe" > "$2/before.json"
    if python3 scripts/acceptance/native-spaces/sidebar-result.py guide-visible "$2"; then
        "$scratch/observe" guide > "$2/guide.json"
        python3 scripts/acceptance/native-spaces/sidebar-result.py guide-closed "$2"
    fi
    python3 scripts/acceptance/native-spaces/roster.py "$scratch/observe" "$2/roster" || test -s "$2/roster/roster-result.json"
    python3 scripts/acceptance/native-spaces/sidebar-result.py fixture-clean "$2"
    if python3 scripts/acceptance/native-spaces/sidebar-result.py select-siblings "$2"; then
        selection=controlled-window
    else
        selection=single-window
    fi
    python3 scripts/acceptance/native-spaces/acceptance.py --observer "$scratch/observe" "$selection" "$2/selection"
    python3 scripts/acceptance/native-spaces/sidebar-result.py finish "$2"
    exit $?
fi
if [[ ${1:-} == roster ]]; then
    [[ $# == 2 ]]
    xcrun swiftc -parse-as-library -module-cache-path "$scratch/module-cache" scripts/acceptance/native-spaces/r4-scene.swift -o "$scratch/r4-scene"
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
