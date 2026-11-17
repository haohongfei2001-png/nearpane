#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
worker="${1:?path to verified candidate helper}"
root="${2:?fresh private test directory}"
mkdir -m 700 "$root"
debug=.build/native-foundation/debug
for kind in owner host; do
    if [[ "$kind" == owner ]]; then
        dest="$root/Design Notes.app"; exe=Notes; id=net.example.nearpane-window-selection
        flags=(-D TARGET_WINDOWS)
    else
        dest="$root/Controller.app"; exe=NearpaneHost; id=com.holdsnow.nearpane.alpha
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
        cp "$worker" "$dest/Contents/Helpers/NearpaneOrdinaryWindowController"
        plutil -insert NearpaneOrdinaryWindowControllerSHA256 -string "$(shasum -a 256 "$worker" | cut -d ' ' -f1)" "$plist"
    fi
    xcrun swiftc -parse-as-library -target arm64-apple-macos14.0 -I "$debug/Modules" -module-cache-path .build/clang-cache         "${flags[@]}" -Xcc "-fmodule-map-file=$PWD/$debug/CReadOnlySpaces.build/module.modulemap" "$debug/CReadOnlySpaces.build/ReadOnlySpaces.c.o" "$debug"/{NearpaneCore,NearpaneUI,WindowGeometryCore}.build/*.swift.o         scripts/acceptance/current-desktop-selection.swift scripts/acceptance/current-desktop-gallery.swift -o "$dest/Contents/MacOS/$exe"
    codesign --force --sign - "$dest"
    codesign --verify --strict --deep "$dest"
done
