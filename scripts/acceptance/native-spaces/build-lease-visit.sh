#!/bin/bash
# Reuse the two-window Lifecycle binary from the confirmed ordinary return to Space 6.
set -euo pipefail
umask 077
cd "$(dirname "$0")/../../.."
src=scripts/acceptance/native-spaces
kit="$(mktemp -d /private/tmp/nearpane-d01.lease-visit.XXXXXXXX)"
readers=Sources/CReadOnlySpaces
xcrun clang -I "$readers/include" -c "$readers/ReadOnlySpaces.c" -o "$kit/reader.o"
xcrun swiftc -parse-as-library -Xcc -I -Xcc "$readers/include" -import-objc-header "$src/p0-reader.h" \
    "$src/p0-read-state.swift" "$src/lease-visit-focus.swift" "$kit/reader.o" -framework ColorSync -o "$kit/lease-visit-focus"
identity="$(/usr/bin/security find-identity -v -p codesigning | /usr/bin/awk '/Developer ID Application: .*\(ZB9D4T66QB\)/ {print $2}')"
[[ ${#identity} -eq 40 ]]
codesign --force --sign "$identity" --identifier net.example.nearpane.lease-visit-focus --options runtime --timestamp=none "$kit/lease-visit-focus"
codesign --verify --strict "$kit/lease-visit-focus"
printf '%s\n' "$kit"
