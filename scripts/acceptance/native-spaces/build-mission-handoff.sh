#!/bin/bash
# Compile the single-lifecycle test operator and read-only Host metrics into a new private kit.
set -euo pipefail
umask 077
cd "$(dirname "$0")/../../.."
src=scripts/acceptance/native-spaces
kit=$(mktemp -d /private/tmp/nearpane-d01.mission-handoff.XXXXXXXX)
build=$(mktemp -d "$kit/.build.XXXXXXXX")
trap 'rm -rf "$build"' EXIT
inc=Sources/CReadOnlySpaces/include
xcrun clang -I "$inc" -c Sources/CReadOnlySpaces/ReadOnlySpaces.c -o "$build/reader.o"
xcrun clang -fobjc-arc -I "$inc" -DNEARPANE_CONTRACT_MEMBERS -c scripts/acceptance/secondary-occupancy.m -o "$build/members.o"
python3 - "$src/system_workspace.swift" "$build/system.swift" <<'PY'
from pathlib import Path
import sys
original, target = map(Path, sys.argv[1:])
source = original.read_text()
boundary = "func frame(_ e: AXUIElement)"
if source.count(boundary) != 1:
    raise SystemExit("System ownership helper source boundary changed")
target.write_text(source.split(boundary, 1)[0])
PY
xcrun swiftc -O -D SECONDARY_FOCUS_OBSERVER -D NATIVE_CONTRACT -parse-as-library -Xcc -I -Xcc "$inc" \
  -import-objc-header "$src/contract_members.h" scripts/acceptance/observe-secondary-space-controls.swift "$build/system.swift" \
  "$src/mission-handoff-state.swift" "$src/mission-handoff.swift" "$build/reader.o" "$build/members.o" -framework ColorSync -o "$kit/mission-handoff"
xcrun swiftc -O "$src/metrics.swift" -o "$kit/metrics"
identity=$(PYTHONPATH=scripts python3 -B -c 'import subprocess; from candidate_signing import product_fingerprint; print(product_fingerprint(subprocess.check_output(["/usr/bin/security","find-identity","-v","-p","codesigning"],text=True)))')
for tool in mission-handoff metrics; do
    identifier=net.example.nearpane.mission-handoff
    if [[ "$tool" == metrics ]]; then identifier+=-metrics; fi
    codesign --force --options runtime --timestamp=none --identifier "$identifier" --sign "$identity" "$kit/$tool" >&2
    codesign --verify --strict "-R=anchor apple generic and identifier \"$identifier\" and certificate leaf[subject.OU] = \"ZB9D4T66QB\" and certificate leaf[field.1.2.840.113635.100.6.1.13] exists" "$kit/$tool"
done
printf '%s\n' "$kit"
