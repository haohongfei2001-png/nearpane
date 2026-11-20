#!/bin/bash
set -euo pipefail
umask 077
cd "$(dirname "$0")/../../.."
work="$(mktemp -d /private/tmp/nearpane-space-trials.XXXXXXXX)"
trap 'rm -rf -- "$work"' EXIT
drivers=scripts/acceptance/native-spaces
# Share the exact independent product UI/WindowServer decoder used by W01.
python3 - "$work/main.swift" <<'PY'
from pathlib import Path
import sys
here = Path("scripts/acceptance/native-spaces")
base = (here / "observe.swift").read_text()
boundary = "if CommandLine.arguments.count > 1 {"
if base.count(boundary) != 1:
    raise SystemExit("Observer program boundary changed; source review required")
Path(sys.argv[1]).write_text(base.split(boundary)[0] + "\n" + (here / "row_trials.swift").read_text())
PY
xcrun clang -c Sources/CReadOnlySpaces/ReadOnlySpaces.c -I Sources/CReadOnlySpaces/include -o "$work/reader.o"
flags=(-module-cache-path "$work/module-cache" -import-objc-header Sources/CReadOnlySpaces/include/ReadOnlySpaces.h)
xcrun swiftc "${flags[@]}" "$drivers/observe.swift" "$work/reader.o" -o "$work/observe"
xcrun swiftc "${flags[@]}" "$work/main.swift" "$work/reader.o" -o "$work/row-driver"
python3 "$drivers/space_trials.py" --observer "$work/observe" --driver "$work/row-driver" "$@"
