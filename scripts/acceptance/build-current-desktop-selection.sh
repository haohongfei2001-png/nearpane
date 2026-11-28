#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
worker="${1:?path to verified candidate helper}"
reader="$(dirname "$worker")/NearpaneDesktopReader"
root="${2:?fresh private test directory}"
mkdir -m 700 "$root"
debug=.build/native-foundation/debug
engine_archive="${NEARPANE_ENGINE_ARCHIVE:-$(bash scripts/build-window-engine.sh)}"
for kind in owner host; do
    if [[ "$kind" == owner ]]; then
        dest="$root/Design Notes.app"; exe=Notes; id=net.example.nearpane-window-selection
        flags=(-D TARGET_WINDOWS)
    else
        dest="$root/Controller.app"; exe=NearpaneHost; id=net.example.nearpane-sidebar-observer
        flags=(-D SELECTION_CONTROLLER)
    fi
    mkdir -p "$dest/Contents/MacOS"
    plist="$dest/Contents/Info.plist"
    plutil -create xml1 "$plist"
    plutil -insert CFBundleIdentifier -string "$id" "$plist"
    plutil -insert CFBundleExecutable -string "$exe" "$plist"
    plutil -insert CFBundlePackageType -string APPL "$plist"
    if [[ "$kind" == host ]]; then
        mkdir "$dest/Contents/Helpers"
        # Never register a second, ad-hoc signed app with the shipping TCC identity.
        # Only the fixture-specific worker accepts this parent; the installed worker
        # continues to require the production bundle identifier and sealed parent.
        fixture_worker="$dest/Contents/Helpers/NearpaneOrdinaryWindowController"
        xcrun swiftc -target arm64-apple-macos14.0 -package-name nearpane -D NEARPANE_WINDOW_SELECTION_FIXTURE \
            -I "$debug/Modules" -module-cache-path .build/clang-cache \
            -Xcc "-fmodule-map-file=$PWD/$debug/CReadOnlySpaces.build/module.modulemap" \
            "$debug/CReadOnlySpaces.build/ReadOnlySpaces.c.o" "$debug"/{NearpaneCore,WindowGeometryCore}.build/*.swift.o \
            Sources/NearpaneOrdinaryWindowController/*.swift -o "$fixture_worker"
        codesign --force --sign - "$fixture_worker"
        plutil -insert NearpaneOrdinaryWindowControllerSHA256 -string "$(shasum -a 256 "$fixture_worker" | cut -d ' ' -f1)" "$plist"
        cp "$reader" "$dest/Contents/Helpers/NearpaneDesktopReader"
        plutil -insert NearpaneDesktopReaderSHA256 -string "$(shasum -a 256 "$reader" | cut -d ' ' -f1)" "$plist"
    fi
    xcrun swiftc -parse-as-library -target arm64-apple-macos14.0 -I "$debug/Modules" -module-cache-path .build/clang-cache         "${flags[@]}" -Xcc "-fmodule-map-file=$PWD/$debug/CReadOnlySpaces.build/module.modulemap" "$debug/CReadOnlySpaces.build/ReadOnlySpaces.c.o" -I Engine/nearpane-window-engine/include "$debug"/{NearpaneCore,NearpaneUI,NearpaneWindowEngine,NearpaneOrdinaryWindowRuntime,WindowGeometryCore}.build/*.swift.o "$engine_archive" -lobjc -framework Carbon -framework Security -framework ApplicationServices         scripts/acceptance/current-desktop-selection.swift scripts/acceptance/current-desktop-gallery.swift scripts/acceptance/current-space-roster.swift -o "$dest/Contents/MacOS/$exe"
    codesign --force --sign - "$dest"
    codesign --verify --strict --deep "$dest"
done
board="$root/Sketch Board.app"
ditto "$root/Design Notes.app" "$board"
plutil -replace CFBundleIdentifier -string net.example.nearpane-window-board "$board/Contents/Info.plist"
plutil -replace CFBundleExecutable -string Board "$board/Contents/Info.plist"
mv "$board/Contents/MacOS/Notes" "$board/Contents/MacOS/Board"
codesign --force --sign - "$board"
codesign --verify --strict --deep "$board"
