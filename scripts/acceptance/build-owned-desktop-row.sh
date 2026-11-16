#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
# After a foundation test build, package the product observation client and the exact reader under test.
reader="${1:?provide the signed NearpaneDesktopReader under test}"
dest="${2:?provide a fresh local .app path}"
[[ "$dest" == *.app && ! -e "$dest" && -x "$reader" ]]
debug=".build/native-foundation/debug"
mkdir -p "$dest/Contents/MacOS" "$dest/Contents/Helpers"
cp "$reader" "$dest/Contents/Helpers/NearpaneDesktopReader"
digest="$(shasum -a 256 "$reader" | cut -d ' ' -f1)"
plutil -create xml1 "$dest/Contents/Info.plist"
for kv in 'CFBundleIdentifier org.nearpane.acceptance.OwnedDesktopRow' 'CFBundleExecutable RowWitness' 'CFBundlePackageType APPL' "NearpaneDesktopReaderSHA256 $digest"; do
    plutil -insert "${kv%% *}" -string "${kv#* }" "$dest/Contents/Info.plist"
done
plutil -insert LSUIElement -bool true "$dest/Contents/Info.plist"
xcrun swiftc -parse-as-library -target arm64-apple-macos14.0 -I "$debug/Modules" -module-cache-path .build/clang-cache \
    -Xcc "-fmodule-map-file=$PWD/$debug/CReadOnlySpaces.build/module.modulemap" "$debug/CReadOnlySpaces.build/ReadOnlySpaces.c.o" \
    "$debug"/{NearpaneCore,NearpaneUI,WindowGeometryCore}.build/*.swift.o scripts/acceptance/owned-desktop-row.swift -o "$dest/Contents/MacOS/RowWitness"
codesign --force --sign - "$dest"
codesign --verify --deep --strict "$dest"
