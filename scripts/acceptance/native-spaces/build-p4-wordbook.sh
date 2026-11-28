#!/bin/bash
set -euo pipefail
umask 077
cd "$(dirname "$0")/../../.."
kit=$(mktemp -d /private/tmp/nearpane-p4-wordbook.XXXXXXXX)
trap 'rm -rf -- "$kit"' EXIT
NEARPANE_FOUNDATION_ONLY=1 NEARPANE_WORD_SEED_KIT="$kit" scripts/test.sh --jobs 4 --filter SeededWordbookRecoveryTests >&2
test -s "$kit/seed.json" && test -s "$kit/seed-notebook.json"
src=scripts/acceptance/native-spaces
xcrun swiftc -parse-as-library -target "$(uname -m)-apple-macos26.0" "$src/tool-context.swift" "$src/p4-wordbook-view.swift" -o "$kit/p4-wordbook-view"
/usr/bin/codesign --verify --strict "$kit/p4-wordbook-view"
chmod 600 "$kit/seed.json" "$kit/seed-notebook.json"
trap - EXIT
printf '%s\n' "$kit"
