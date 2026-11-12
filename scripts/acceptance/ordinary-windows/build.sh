#!/bin/bash
set -eu
cd "$(dirname "$0")/../../.."
out="$PWD/build/verification/p54/ordinary"
mkdir -p "$out/cache"
export CLANG_MODULE_CACHE_PATH="$out/cache"
clang -framework CoreGraphics -framework CoreFoundation scripts/acceptance/ordinary-windows/window-registration.c -o "$out/window-registration"
swiftc -swift-version 5 -module-cache-path "$out/cache" scripts/acceptance/admission-controls.swift -o "$out/controls"
swiftc -swift-version 5 -module-cache-path "$out/cache" scripts/acceptance/ordinary-windows/SystemReadback.swift -o "$out/observe"
swiftc -swift-version 5 -module-cache-path "$out/cache" scripts/acceptance/ordinary-windows/ResourceCounters.swift -o "$out/counters"
swiftc -swift-version 5 -module-cache-path "$out/cache" scripts/acceptance/ordinary-windows/StandardWindows.swift -o "$out/standard-windows"
swiftc -D PALETTE_FIXTURE -swift-version 5 -module-cache-path "$out/cache" scripts/acceptance/ordinary-windows/StandardWindows.swift -o "$out/standard-palette"
package_fixture() {
    local name="$1" identifier="$2" executable="$3" source="$4" path_file="$5"
    local stage app
    stage=$(mktemp -d /private/tmp/nearpane-standard-windows.XXXXXXXX)
    app="$stage/$name.app"
    mkdir -p "$app/Contents/MacOS"
    cp "$source" "$app/Contents/MacOS/$executable"
    python3 - "$app" "$name" "$identifier" "$executable" <<'PLIST'
from pathlib import Path
import plistlib,sys
app, name, identifier, executable = sys.argv[1:]
(Path(app)/'Contents/Info.plist').write_bytes(plistlib.dumps(dict(CFBundlePackageType='APPL', CFBundleExecutable=executable,
    CFBundleIdentifier=identifier, CFBundleName=name, CFBundleVersion='1', LSUIElement=False, NSHighResolutionCapable=True)))
PLIST
    codesign -fs - "$app"
    printf "%s\n" "$app" > "$path_file"
}
package_fixture "Standard documents" net.example.standard-documents StandardWindows "$out/standard-windows" "$out/fixture-path.txt"
package_fixture "Standard palette" net.example.standard-palette StandardPalette "$out/standard-palette" "$out/palette-path.txt"
