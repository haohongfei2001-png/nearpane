#!/bin/bash
# Builds only isolated, lab-only executables; launches no apps and touches no desktops.
set -euo pipefail
umask 077
cd "$(dirname "$0")/../../.."
kit="${1:?provide a fresh private /private/tmp/nearpane-d01.* directory}"
[[ "$kit" == /private/tmp/nearpane-d01.* && -d "$kit" && ! -L "$kit" && ! -e "$kit/observe" ]]
src=scripts/acceptance/native-spaces
inc=Sources/CReadOnlySpaces/include
clang_flags=(-I "$inc")
xcrun clang -Wall -Wextra -Werror "$src/textedit_process.c" -o "$kit/textedit-process"
xcrun clang "${clang_flags[@]}" -c Sources/CReadOnlySpaces/ReadOnlySpaces.c -o "$kit/reader.o"
xcrun clang -fobjc-arc "${clang_flags[@]}" -DNEARPANE_CONTRACT_MEMBERS -c scripts/acceptance/secondary-occupancy.m -o "$kit/members.o"
swift_flags=(-D NATIVE_CONTRACT -module-cache-path "$PWD/.build/clang-cache" -Xcc -I -Xcc "$inc"
    -import-objc-header "$src/contract_members.h")
link=("$kit/reader.o" "$kit/members.o" -framework ColorSync)
xcrun swiftc "${swift_flags[@]}" -D SECONDARY_FOCUS_OBSERVER -parse-as-library scripts/acceptance/observe-secondary-space-controls.swift "$src/system_workspace.swift" "${link[@]}" -o "$kit/system-workspace"
xcrun swiftc "${swift_flags[@]}" "$src/observe.swift" "${link[@]}" -o "$kit/observe"
python3 - "$kit/main.swift" "$kit/textedit-trials.swift" "$kit/leased-row.swift" <<'PY'
from pathlib import Path
import sys
src=Path("scripts/acceptance/native-spaces")
before,after=(src/"observe.swift").read_text().split("if CommandLine.arguments.count > 1 {")
Path(sys.argv[1]).write_text(before+"\n"+(src/"row_trials.swift").read_text())
Path(sys.argv[2]).write_text(before+"\n"+Path("Sources/NearpaneCore/AXWindowList.swift").read_text()+"\n"+(src/"textedit_window_list.swift").read_text()+"\n"+(src/"textedit_window_alias.swift").read_text()+"\n"+(src/"textedit_identity.swift").read_text()+"\n"+(src/"textedit_trials.swift").read_text())
Path(sys.argv[3]).write_text(before+"\n"+(src/"leased-row.swift").read_text())
PY
xcrun swiftc "${swift_flags[@]}" "$kit/main.swift" "${link[@]}" -o "$kit/row-driver"
xcrun swiftc "${swift_flags[@]}" "$kit/textedit-trials.swift" "${link[@]}" -o "$kit/textedit"
xcrun swiftc "${swift_flags[@]}" "$kit/leased-row.swift" "${link[@]}" -o "$kit/leased-row"
xcrun swiftc "${swift_flags[@]}" "$src/d01_input.swift" "${link[@]}" -o "$kit/d01-input"
xcrun swiftc -module-cache-path "$PWD/.build/clang-cache" "$src/metrics.swift" -o "$kit/metrics"
mkdir -p "$kit/Field Notes.app/Contents/MacOS"
cp "$src/fixture.plist" "$kit/Field Notes.app/Contents/Info.plist"
xcrun swiftc -module-cache-path "$PWD/.build/clang-cache" "$src/window.swift" -o "$kit/Field Notes.app/Contents/MacOS/FieldNotes"
codesign --force --sign - "$kit/Field Notes.app"
ditto "$kit/Field Notes.app" "$kit/Route Notes.app"
plutil -replace CFBundleIdentifier -string net.example.spaces-route-witness "$kit/Route Notes.app/Contents/Info.plist"
plutil -replace CFBundleName -string 'Route Notes' "$kit/Route Notes.app/Contents/Info.plist"
codesign --force --sign - --identifier net.example.spaces-route-witness "$kit/Route Notes.app"
