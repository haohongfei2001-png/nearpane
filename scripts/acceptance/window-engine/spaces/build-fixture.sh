#!/bin/bash
# Builds, signs and verifies the two-document test app. Building does not launch a GUI or request permission.
set -euo pipefail
umask 077
src="$(cd "$(dirname "$0")" && pwd -P)"
root="$(cd "$src/../../../.." && pwd -P)"
engine="$root/Engine/nearpane-window-engine"
archive="${1:?Cargo isolated-fixtures static archive required}"
out="${2:?new private output directory required}"
[[ -f "$archive" && ! -e "$out" ]]
mkdir -m 700 "$out"
app="$out/Spaces Gate Fixture.app"
mkdir -p "$app/Contents/MacOS"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundlePackageType</key><string>APPL</string><key>CFBundleIdentifier</key><string>com.holdsnow.nearpane.engine-fixture</string>
<key>CFBundleExecutable</key><string>SpacesGate</string><key>CFBundleName</key><string>Spaces Gate Fixture</string>
<key>CFBundleVersion</key><string>1</string><key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
xcrun clang -fobjc-arc -Wall -Wextra -Werror -I "$engine/include" -I "$engine/src/spaces" \
  "$src/fixture.m" "$archive" -framework AppKit -framework Foundation -framework CoreGraphics -framework ApplicationServices \
  -framework Security -framework QuartzCore -framework CoreFoundation -framework Carbon -framework ImageIO -lc++ -o "$app/Contents/MacOS/SpacesGate"
codesign --force --sign "${NP_ENGINE_FIXTURE_SIGN_IDENTITY:--}" --identifier com.holdsnow.nearpane.engine-fixture "$app"
codesign --verify --strict --deep "$app"
printf '%s\n' "$app"
