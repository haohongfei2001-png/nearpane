#!/bin/bash
# Compile two nonactivating readers for the installed Stage Manager handoff test.
set -euo pipefail
umask 077
cd "$(dirname "$0")/../../.."
kit=$(mktemp -d /private/tmp/nearpane-overview-chord.XXXXXXXX)
identity=$(PYTHONPATH=scripts python3 -B -c 'import subprocess; from candidate_signing import product_fingerprint; print(product_fingerprint(subprocess.check_output(["/usr/bin/security", "find-identity", "-v", "-p", "codesigning"], text=True)))')
for tool in metrics overview-shortcut-claim; do
    xcrun swiftc -O "scripts/acceptance/native-spaces/$tool.swift" -o "$kit/$tool"
    codesign --force --options runtime --timestamp=none --identifier "com.holdsnow.nearpane.acceptance.$tool" --sign "$identity" "$kit/$tool" >&2
    codesign --verify --strict "$kit/$tool"
done
printf '%s\n' "$kit"
