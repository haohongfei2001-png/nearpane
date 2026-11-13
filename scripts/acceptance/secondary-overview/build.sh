#!/bin/bash
# Build and sign isolated lab helpers in a fresh temporary directory. Does not launch any GUI.
set -euo pipefail
umask 077
cd "$(dirname "$0")/../../.."
dest="$(mktemp -d "${TMPDIR:-/tmp}/Nearpane-secondary.XXXXXXXX")"
app="$dest/Nearpane Secondary Overview.app"
src="scripts/acceptance"
header="Sources/CReadOnlySpaces/include/ReadOnlySpaces.h"
mkdir -p "$app/Contents/MacOS"
xcrun clang -c Sources/CReadOnlySpaces/ReadOnlySpaces.c -I Sources/CReadOnlySpaces/include -o "$dest/spaces.o"
module_cache="${NEARPANE_LAB_MODULE_CACHE:-$PWD/build/secondary-overview/modules}"
mkdir -p "$module_cache"
common=(-warnings-as-errors -module-cache-path "$module_cache")
xcrun swiftc "${common[@]}" -D SECONDARY_OVERVIEW_DRIVER -import-objc-header "$header" \
    "$src/observe-secondary-space-controls.swift" "$src/secondary-overview/FocusAnchor.swift" "$src/secondary-overview/ProtectedReturnWindow.swift" "$src/secondary-overview/main.swift" "$dest/spaces.o" -o "$app/Contents/MacOS/Overview"
xcrun swiftc "${common[@]}" -D SECONDARY_FOCUS_OBSERVER -parse-as-library -import-objc-header "$header" \
    "$src/observe-secondary-space-controls.swift" "$src/secondary-overview/FocusAnchor.swift" "$src/secondary-overview/UnfocusedDesktop.swift" "$src/secondary-overview/FocusReturn.swift" "$dest/spaces.o" -o "$dest/focus-return"
python3 - "$app/Contents/Info.plist" <<'PY'
import plistlib, sys
with open(sys.argv[1], "xb") as out:
    plistlib.dump(dict(CFBundleExecutable="Overview", CFBundleIdentifier="org.nearpane.lab.SecondaryOverview",
                       CFBundleName="Nearpane Secondary Overview", CFBundlePackageType="APPL", CFBundleVersion="1", LSUIElement=True), out)
PY
codesign --force --sign - "$app"
codesign --verify --strict "$app"
session="$dest/Nearpane Secondary Session.app"
mkdir -p "$session/Contents/MacOS"
xcrun swiftc "${common[@]}" -D SECONDARY_FOCUS_OBSERVER -parse-as-library -import-objc-header "$header" \
    "$src/observe-secondary-space-controls.swift" "$src/secondary-overview/FocusAnchor.swift" \
    "$src/secondary-overview/UnfocusedDesktop.swift" "$src/secondary-overview/SecondarySession.swift" "$src/secondary-overview/FrozenWitnessOwner.swift" \
    "$dest/spaces.o" -o "$session/Contents/MacOS/SecondarySession"
python3 - "$session/Contents/Info.plist" <<'PY'
import plistlib, sys
with open(sys.argv[1], "xb") as out:
    plistlib.dump(dict(CFBundleExecutable="SecondarySession", CFBundleIdentifier="org.nearpane.lab.SecondarySession",
                       CFBundleName="Nearpane Secondary Session", CFBundlePackageType="APPL", CFBundleVersion="1", LSUIElement=True), out)
PY
codesign --force --sign - "$session"
codesign --verify --strict "$session"
xcrun swiftc "${common[@]}" -parse-as-library "$src/observe-secondary-space-controls.swift" -o "$dest/observe"
xcrun clang -Wall -Wextra -Werror -fobjc-arc -I Sources/CReadOnlySpaces/include \
    "$src/secondary-occupancy.m" Sources/CReadOnlySpaces/ReadOnlySpaces.c \
    -framework Foundation -framework CoreGraphics -framework ColorSync -o "$dest/occupancy"
# Swift's executable entry file must be named main.swift when linked with shared sources.
for component in calibrate-route route-pointer; do
    mkdir "$dest/$component-src"
done
cp "$src/calibrate-secondary-route.swift" "$dest/calibrate-route-src/main.swift"
cp "$src/secondary-overview/route-pointer.swift" "$dest/route-pointer-src/main.swift"
owner="$src/secondary-overview/FrozenWitnessOwner.swift"
xcrun swiftc "${common[@]}" "$dest/calibrate-route-src/main.swift" "$owner" -o "$dest/calibrate-route"
xcrun swiftc "${common[@]}" -import-objc-header "$header" "$dest/route-pointer-src/main.swift" "$owner" "$dest/spaces.o" -o "$dest/route-pointer"
cd "$dest"
shasum -a 256 "Nearpane Secondary Overview.app/Contents/MacOS/Overview" \
    "Nearpane Secondary Session.app/Contents/Info.plist" \
    "Nearpane Secondary Session.app/Contents/MacOS/SecondarySession" \
    observe occupancy focus-return calibrate-route route-pointer > SHA256SUMS
printf '%s\n' "$dest"
