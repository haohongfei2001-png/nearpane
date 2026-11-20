#!/bin/bash
# Add the scoped adapter and the existing lifecycle fixture to a private paired-preview kit.
set -euo pipefail
umask 077
cd "$(dirname "$0")/../../.."
src=scripts/acceptance/native-spaces
kit="${1:?existing paired-preview kit required}"
[[ "$kit" == /private/tmp/nearpane-d01.* && ! -L "$kit" && -x "$kit/paired-scope" && -f "$kit/members.o" ]]
app="$kit/Split Notes.app"
[[ ! -e "$app" && ! -e "$kit/split-view-read" ]]
mkdir -p "$app/Contents/MacOS"
cp "$src/fixture.plist" "$app/Contents/Info.plist"
plutil -replace CFBundleIdentifier -string net.example.spaces-split-documents "$app/Contents/Info.plist"
plutil -replace CFBundleExecutable -string SplitNotes "$app/Contents/Info.plist"
plutil -replace CFBundleName -string 'Split Notes' "$app/Contents/Info.plist"
xcrun swiftc -D SPLIT_VIEW_FIXTURE "$src/lifecycle-window.swift" -o "$app/Contents/MacOS/SplitNotes"
codesign --force --sign - --identifier net.example.spaces-split-documents "$app"
python3 - "$src" "$kit/split-view-read.swift" <<'PY'
import sys
from pathlib import Path
src, destination=map(Path,sys.argv[1:])
part=(src/'observe.swift').read_text().split('if CommandLine.arguments.count > 1 {')
assert len(part)==2
destination.write_text(part[0]+'\n'+(src/'lifecycle-menu.swift').read_text()+'\n'+(src/'split-view-read.swift').read_text())
PY
xcrun swiftc -D NATIVE_CONTRACT -Xcc -I -Xcc Sources/CReadOnlySpaces/include -import-objc-header "$src/contract_members.h" \
  "$kit/split-view-read.swift" "$kit/reader.o" "$kit/members.o" -framework ColorSync -o "$kit/split-view-read"
codesign --verify --strict "$kit/split-view-read"
codesign --verify --strict "$app"
