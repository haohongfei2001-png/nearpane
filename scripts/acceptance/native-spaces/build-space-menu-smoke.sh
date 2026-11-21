#!/bin/bash
set -euo pipefail
umask 077
cd "$(dirname "$0")/../../.."
src=scripts/acceptance/native-spaces
kit=$(mktemp -d /private/tmp/nearpane-space-menu.XXXXXXXX)
xcrun clang -I Sources/CReadOnlySpaces/include -c Sources/CReadOnlySpaces/ReadOnlySpaces.c -o "$kit/reads.o"
cat "$src/p0-read-state.swift" "$src/space-menu-smoke.swift" > "$kit/main.swift"
xcrun swiftc -O -import-objc-header Sources/CReadOnlySpaces/include/ReadOnlySpaces.h "$kit/main.swift" "$kit/reads.o" -o "$kit/space-menu-smoke"
signer=$(PYTHONPATH=scripts python3 -c 'import candidate_signing as s; print(s.product_fingerprint(s.gate.cmd("/usr/bin/security","find-identity","-v","-p","codesigning")))')
codesign --force --sign "$signer" --options runtime --timestamp=none --identifier net.example.nearpane.space-menu-smoke "$kit/space-menu-smoke"
codesign --verify --strict '-R=identifier "net.example.nearpane.space-menu-smoke" and anchor apple generic and certificate leaf[subject.OU] = "ZB9D4T66QB"' "$kit/space-menu-smoke"
printf '%s\n' "$kit/space-menu-smoke"
