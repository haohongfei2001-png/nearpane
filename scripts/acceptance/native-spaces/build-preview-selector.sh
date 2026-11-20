#!/bin/bash
# Compile the existing semantic Mission Control tile selector for the acceptance kit.
set -euo pipefail
umask 077
cd "$(dirname "$0")/../../.."
src=scripts/acceptance/native-spaces
kit="${1:?existing private preview kit required}"
[[ $kit == /private/tmp/nearpane-d01.* && -d $kit && ! -L $kit && ! -e $kit/preview-space-select ]]
python3 - "$kit/preview-system-library.swift" <<'PY'
from pathlib import Path
import sys
s=Path("scripts/acceptance/native-spaces/system_workspace.swift").read_text()
assert s.count("@main enum Main {")==1
Path(sys.argv[1]).write_text(s.split("@main enum Main {")[0])
PY
xcrun swiftc -D PREVIEW_SCOPE_SELECTOR -D SECONDARY_FOCUS_OBSERVER -D NATIVE_CONTRACT -parse-as-library \
  -Xcc -I -Xcc Sources/CReadOnlySpaces/include -import-objc-header "$src/contract_members.h" \
  scripts/acceptance/observe-secondary-space-controls.swift "$kit/preview-system-library.swift" "$src/p0-mission-list.swift" \
  "$src/p0-mission.swift" "$src/preview-space-select.swift" "$kit/reader.o" "$kit/members.o" -framework ColorSync -o "$kit/preview-space-select"
codesign --verify --strict "$kit/preview-space-select"
# installed_profile's existing focus keeper retains a live system-wide AX reference.
# Only its state/hold-original commands are used by the wrapper.
if [[ ! -e $kit/p0-card ]]; then
  xcrun clang -fobjc-arc -c "$src/p0-hotkey.m" -o "$kit/preview-focus-hotkey.o"
  xcrun swiftc -Xcc -I -Xcc Sources/CReadOnlySpaces/include -import-objc-header "$src/p0-reader.h" \
    "$src/p0-card.swift" "$kit/reader.o" "$kit/preview-focus-hotkey.o" -framework Carbon -o "$kit/p0-card"
  codesign --verify --strict "$kit/p0-card"
fi
