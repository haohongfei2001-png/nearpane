#!/bin/bash
set -eu
cd "$(dirname "$0")/../../.."
out="$PWD/build/verification/p54/ordinary"
mkdir -p "$out/cache"
export CLANG_MODULE_CACHE_PATH="$out/cache"
swiftc -swift-version 5 -module-cache-path "$out/cache" scripts/acceptance/admission-controls.swift -o "$out/controls"
swiftc -swift-version 5 -module-cache-path "$out/cache" scripts/acceptance/ordinary-windows/SystemReadback.swift -o "$out/observe"
swiftc -swift-version 5 -module-cache-path "$out/cache" scripts/acceptance/ordinary-windows/StandardWindows.swift -o "$out/standard-windows"
stage=$(mktemp -d /private/tmp/nearpane-standard-windows.XXXXXXXX)
app="$stage/Standard documents.app"
mkdir -p "$app/Contents/MacOS"
cp "$out/standard-windows" "$app/Contents/MacOS/StandardWindows"
python3 - "$app" <<'PY'
from pathlib import Path
import plistlib,sys
app = Path(sys.argv[1])
(app/'Contents/Info.plist').write_bytes(plistlib.dumps(dict(CFBundlePackageType='APPL',CFBundleExecutable='StandardWindows', CFBundleIdentifier='net.example.standard-documents', CFBundleName='Standard documents', CFBundleVersion='1',LSUIElement=False,NSHighResolutionCapable=True)))
PY
codesign -fs - "$app"
printf "%s\n" "$app" > "$out/fixture-path.txt"
