#!/bin/bash
# Build only acceptance fixtures and independent readers; never launches an application.
set -euo pipefail
umask 077
cd "$(dirname "$0")/../../.."
src=scripts/acceptance/native-spaces
kit="${1:-$(mktemp -d /private/tmp/nearpane-d01.XXXXXXXX)}"
[[ "$kit" == /private/tmp/nearpane-d01.* && -d "$kit" && ! -L "$kit" ]]
[[ -x "$kit/system-workspace" && -x "$kit/observe" && -x "$kit/Route Notes.app/Contents/MacOS/FieldNotes" ]] || "$src/build-contract.sh" "$kit"
app="$kit/Lifecycle Window.app"
mkdir -p "$app/Contents/MacOS"
cp "$src/fixture.plist" "$app/Contents/Info.plist"
plutil -replace CFBundleIdentifier -string org.nearpane.acceptance.LifecycleWindow "$app/Contents/Info.plist"
plutil -replace CFBundleExecutable -string Lifecycle "$app/Contents/Info.plist"
plutil -replace CFBundleName -string 'Lifecycle Window' "$app/Contents/Info.plist"
xcrun swiftc "$src/lifecycle-window.swift" -o "$app/Contents/MacOS/Lifecycle"
codesign --force --sign - "$app"
xcrun clang -fobjc-arc -c "$src/p0-hotkey.m" -o "$kit/p0-hotkey.o"
xcrun swiftc -Xcc -I -Xcc Sources/CReadOnlySpaces/include -import-objc-header "$src/p0-reader.h" "$src/p0-card.swift" "$kit/reader.o" "$kit/p0-hotkey.o" -framework Carbon -o "$kit/p0-card.next"
mv "$kit/p0-card.next" "$kit/p0-card"
printf '%s\n' "$kit"
