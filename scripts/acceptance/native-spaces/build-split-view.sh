#!/bin/bash
# Add the scoped adapter and the existing lifecycle fixture to a private paired-preview kit.
set -euo pipefail
umask 077
cd "$(dirname "$0")/../../.."
src=scripts/acceptance/native-spaces
kit="${1:?existing paired-preview kit required}"
[[ "$kit" == /private/tmp/nearpane-d01.* && ! -L "$kit" && -x "$kit/paired-scope" && -f "$kit/members.o" ]]
app="$kit/Split Notes.app"
if [[ "${2:-}" == --reader-only ]]; then
    codesign --verify --strict --deep -R='identifier "net.example.spaces-split-documents"' "$app"
else
    [[ $# == 1 && ! -e "$app" && ! -e "$kit/split-view-read" ]]
    mkdir -p "$app/Contents/MacOS"
    cp "$src/fixture.plist" "$app/Contents/Info.plist"
    plutil -replace CFBundleIdentifier -string net.example.spaces-split-documents "$app/Contents/Info.plist"
    plutil -replace CFBundleExecutable -string SplitNotes "$app/Contents/Info.plist"
    plutil -replace CFBundleName -string 'Split Notes' "$app/Contents/Info.plist"
    xcrun swiftc -D SPLIT_VIEW_FIXTURE "$src/lifecycle-window.swift" -o "$app/Contents/MacOS/SplitNotes"
    codesign --force --sign - --identifier net.example.spaces-split-documents "$app"
fi
python3 - "$src" "$kit/split-view-read.swift" <<'PY'
import sys
from pathlib import Path
src, destination=map(Path,sys.argv[1:])
part=(src/'observe.swift').read_text().split('if CommandLine.arguments.count > 1 {')
assert len(part)==2
destination.write_text(part[0]+'\n'+(src/'paired-preview-census.swift').read_text()+'\n'+(src/'lifecycle-menu.swift').read_text()+'\n'+(src/'split-fixture-identity.swift').read_text()+'\n'+(src/'split-view-read.swift').read_text())
PY
stage=$(mktemp -d "$kit/.split-reader.XXXXXXXX")
trap 'rm -f "$stage/split-view-read" "$stage/main.swift"; rmdir "$stage"' EXIT
cp "$kit/split-view-read.swift" "$stage/main.swift"
xcrun swiftc -D NATIVE_CONTRACT -D SECONDARY_FOCUS_OBSERVER -Xcc -I -Xcc Sources/CReadOnlySpaces/include -import-objc-header "$src/contract_members.h" \
  "$stage/main.swift" scripts/acceptance/observe-secondary-space-controls.swift "$src/split-picker-geometry.swift" "$src/split-picker.swift" "$kit/reader.o" "$kit/members.o" -framework ColorSync -o "$stage/split-view-read"
codesign --verify --strict "$stage/split-view-read"
mv "$stage/split-view-read" "$kit/split-view-read"
codesign --verify --strict "$app"
