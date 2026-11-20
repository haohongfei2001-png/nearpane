#!/bin/bash
# Builds the independent read-only monitor. Does not start an application or link the action adapter.
set -euo pipefail
umask 077
cd "$(dirname "$0")/../../.."
src=scripts/acceptance/native-spaces
kit="${1:-$(mktemp -d /private/tmp/nearpane-p0-drift.XXXXXXXX)}"
[[ "$kit" == /private/tmp/nearpane-p0-drift.* && -d "$kit" && ! -L "$kit" && ! -e "$kit/p0-drift-reader" ]]
xcrun clang -I Sources/CReadOnlySpaces/include -c Sources/CReadOnlySpaces/ReadOnlySpaces.c -o "$kit/reads.o"
cat "$src/p0-read-state.swift" "$src/p0-drift-reader.swift" > "$kit/main.swift"
xcrun swiftc -import-objc-header Sources/CReadOnlySpaces/include/ReadOnlySpaces.h "$kit/main.swift" "$kit/reads.o" -o "$kit/p0-drift-reader"
codesign --verify --strict "$kit/p0-drift-reader"
printf '%s\n' "$kit"
