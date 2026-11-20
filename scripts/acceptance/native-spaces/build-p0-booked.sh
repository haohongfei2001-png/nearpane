#!/bin/bash
# Compile the two-lease metadata reader and native setup input, without launching either.
set -euo pipefail
umask 077
cd "$(dirname "$0")/../../.."
src=scripts/acceptance/native-spaces
kit="${1:?existing P0 kit required}"
[[ "$kit" == /private/tmp/nearpane-d01.* && "$(cd "$kit" && pwd -P)" == "$kit" && -x "$kit/p0-card" ]]
tmp="$(mktemp -d "$kit/p0-booked-build.XXXXXXXX")"
trap 'rm -rf "$tmp"' EXIT
cat "$src/p0-reader.h" "$src/contract_members.h" > "$tmp/bridge.h"
cat "$src/p0-read-state.swift" "$src/p0-booked.swift" "$src/p0-card.swift" > "$tmp/main.swift"
xcrun swiftc -D P0_BORROWED_DIAGNOSTIC -D P2_STAGE_OFFLINE -Xcc -I -Xcc Sources/CReadOnlySpaces/include \
  -import-objc-header "$tmp/bridge.h" "$tmp/main.swift" "$src/p2-stage-surface.swift" \
  "$kit/reader.o" "$kit/members.o" "$kit/p0-hotkey.o" -framework Carbon -o "$tmp/p0-booked"
codesign --verify --strict "$tmp/p0-booked"
mv "$tmp/p0-booked" "$kit/p0-booked"
printf '%s\n' "$kit/p0-booked"
