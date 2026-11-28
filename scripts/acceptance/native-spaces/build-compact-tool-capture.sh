#!/bin/bash
# Compile the independent single-window read only. No app or system UI is launched.
set -euo pipefail
umask 077
cd "$(dirname "$0")/../../.."
kit=${1:?supply the private paired-preview kit}
src=scripts/acceptance/native-spaces
test -f "$kit/reader.o" && test -f "$kit/members.o"
xcrun swiftc -parse-as-library -D PAIRED_OVERVIEW_TEST -Xcc -I -Xcc Sources/CReadOnlySpaces/include \
    -import-objc-header "$src/contract_members.h" "$src/paired-preview-palette.swift" "$src/paired-preview-overview.swift" \
    "$src/compact-tool-capture.swift" "$kit/reader.o" "$kit/members.o" -framework ColorSync -o "$kit/compact-tool-capture"
codesign --verify --strict "$kit/compact-tool-capture"
