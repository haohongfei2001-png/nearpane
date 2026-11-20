#!/bin/bash
# Compile a standalone opt-in fixture and the existing observer for a fresh, private contract kit.
set -euo pipefail
umask 077
cd "$(dirname "$0")/../../.."
kit="${1:?fresh private /private/tmp/nearpane-d01.* output directory}"
[[ "$kit" == /private/tmp/nearpane-d01.* && -d "$kit" && ! -L "$kit" && ! -e "$kit/observe" && ! -e "$kit/Field Notes.app" ]]
[[ "$(stat -f %u "$kit")" == "$(id -u)" && "$(stat -f %Lp "$kit")" == 700 ]]
src=scripts/acceptance/native-spaces
inc=Sources/CReadOnlySpaces/include
work="$kit/marker-build"
mkdir -m 700 "$work"
cp "$src/window.swift" "$work/main.swift"
xcrun clang -I "$inc" -c Sources/CReadOnlySpaces/ReadOnlySpaces.c -o "$work/reader.o"
xcrun clang -fobjc-arc -I "$inc" -DNEARPANE_CONTRACT_MEMBERS -c scripts/acceptance/secondary-occupancy.m -o "$work/members.o"
xcrun swiftc -D NATIVE_CONTRACT -module-cache-path "$work/cache" -Xcc -I -Xcc "$inc" -import-objc-header "$src/contract_members.h" \
    "$src/observe.swift" "$work/reader.o" "$work/members.o" -framework ColorSync -o "$kit/observe"
app="$kit/Field Notes.app"
mkdir -p "$app/Contents/MacOS"
cp "$src/fixture.plist" "$app/Contents/Info.plist"
xcrun swiftc -D W01_MARKER_WITNESS -module-cache-path "$work/cache" "$work/main.swift" "$src/field-marker-witness.swift" -o "$app/Contents/MacOS/FieldNotes"
codesign --force --sign - --identifier net.example.spaces-document "$app"
codesign --verify --strict --deep "$app"
codesign --verify --strict "$kit/observe"
