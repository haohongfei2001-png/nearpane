#!/bin/bash
# Build only acceptance fixtures and independent readers; never launches an application.
set -euo pipefail
umask 077
cd "$(dirname "$0")/../../.."
src=scripts/acceptance/native-spaces
kit="${1:-$(mktemp -d /private/tmp/nearpane-d01.XXXXXXXX)}"
[[ "$kit" == /private/tmp/nearpane-d01.* && -d "$kit" && ! -L "$kit" ]]
if [[ -x "$kit/system-workspace" && -x "$kit/observe" && -x "$kit/Route Notes.app/Contents/MacOS/FieldNotes" ]]; then
    xcrun swiftc -D SECONDARY_FOCUS_OBSERVER -D NATIVE_CONTRACT -parse-as-library -Xcc -I -Xcc Sources/CReadOnlySpaces/include \
        -import-objc-header "$src/contract_members.h" scripts/acceptance/observe-secondary-space-controls.swift \
        "$src/system_workspace.swift" "$kit/reader.o" "$kit/members.o" -framework ColorSync -o "$kit/system-workspace.next"
    mv "$kit/system-workspace.next" "$kit/system-workspace"
else
    "$src/build-contract.sh" "$kit"
fi
app="$kit/Lifecycle Window.app"
mkdir -p "$app/Contents/MacOS"
cp "$src/fixture.plist" "$app/Contents/Info.plist"
plutil -replace CFBundleIdentifier -string org.nearpane.acceptance.LifecycleWindow "$app/Contents/Info.plist"
plutil -replace CFBundleExecutable -string Lifecycle "$app/Contents/Info.plist"
plutil -replace CFBundleName -string 'Lifecycle Window' "$app/Contents/Info.plist"
xcrun swiftc "$src/lifecycle-window.swift" -o "$app/Contents/MacOS/Lifecycle"
codesign --force --sign - "$app"
mkdir -p "$kit/p0-document-source"
python3 - "$src/window.swift" "$kit/p0-document-source/main.swift" <<'PY'
from pathlib import Path
import sys
source=Path(sys.argv[1]).read_text()
assert source.count('app.run()')==1
Path(sys.argv[2]).write_text(source.replace('app.run()', 'MainActor.assumeIsolated { installP0Generations(folder:run,birth:birth,windows:{windows}) }\napp.run()'))
PY
xcrun swiftc "$kit/p0-document-source/main.swift" "$src/p0-generation.swift" -o "$kit/Field Notes.app/Contents/MacOS/FieldNotes"
cp "$kit/Field Notes.app/Contents/MacOS/FieldNotes" "$kit/Route Notes.app/Contents/MacOS/FieldNotes"
codesign --force --sign - --identifier net.example.spaces-document "$kit/Field Notes.app"
codesign --force --sign - --identifier net.example.spaces-route-witness "$kit/Route Notes.app"
xcrun clang -fobjc-arc -c "$src/p0-hotkey.m" -o "$kit/p0-hotkey.o"
xcrun swiftc -Xcc -I -Xcc Sources/CReadOnlySpaces/include -import-objc-header "$src/p0-reader.h" "$src/p0-card.swift" "$kit/reader.o" "$kit/p0-hotkey.o" -framework Carbon -o "$kit/p0-card.next"
mv "$kit/p0-card.next" "$kit/p0-card"
# Reuse the guarded Mission Control inventory, Apple owner checks, and owned overview dismissal.
# Only the P0 entry point differs. The existing generic selection driver stays intact.
python3 - "$src/system_workspace.swift" "$kit/p0-system-library.swift" <<'PY'
from pathlib import Path
import sys
source=Path(sys.argv[1]).read_text()
marker='@main enum Main {'
assert source.count(marker)==1
Path(sys.argv[2]).write_text(source.split(marker)[0])
PY
xcrun swiftc -D SECONDARY_FOCUS_OBSERVER -D NATIVE_CONTRACT -parse-as-library -Xcc -I -Xcc Sources/CReadOnlySpaces/include \
    -import-objc-header "$src/contract_members.h" scripts/acceptance/observe-secondary-space-controls.swift \
    "$kit/p0-system-library.swift" "$src/p0-mission.swift" "$kit/reader.o" "$kit/members.o" -framework ColorSync -o "$kit/p0-mission"
printf '%s\n' "$kit"
