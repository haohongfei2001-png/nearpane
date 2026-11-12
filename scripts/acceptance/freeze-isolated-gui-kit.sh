#!/bin/bash
# Prepare the fixture for a second macOS account; never launch a GUI or enable sharing.
set -euo pipefail
cd "$(dirname "$0")/../.."
export NEARPANE_FOUNDATION_ONLY=1
umask 077
scratch="$PWD/build/isolated-gui"
mkdir -p "$scratch"
stage="$(mktemp -d "${NEARPANE_SPACE_KIT_PARENT:-/Users/Shared}/Nearpane-P431.XXXXXXXX")"
ready=0
trap 'if [[ "$ready" != 1 ]]; then rm -rf "$stage"; fi' EXIT
lab=(--package-path engineering/window-lab --scratch-path "$PWD/build/window-lab/swift" --disable-sandbox -c release)
reader=(--scratch-path "$scratch/reader" --disable-sandbox -c release -Xswiftc -DNEARPANE_ISOLATED_GUI_LAB)
swift build "${lab[@]}" --product NearpaneSpaceWitness
swift build "${reader[@]}" --product NearpaneDesktopReader
app="$stage/NearpaneSpaceWitness.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Helpers"
install -m 755 "$(swift build "${lab[@]}" --show-bin-path)/NearpaneSpaceWitness" "$app/Contents/MacOS/"
install -m 755 "$(swift build "${reader[@]}" --show-bin-path)/NearpaneDesktopReader" "$app/Contents/Helpers/"
/usr/bin/codesign --force --sign - --identifier org.nearpane.lab.SpaceReader "$app/Contents/Helpers/NearpaneDesktopReader"
python3 - "$app/Contents/Info.plist" <<'PY'
import plistlib,sys
with open(sys.argv[1],"wb") as out:
    plistlib.dump(dict(CFBundleName="NearpaneSpaceWitness",CFBundleExecutable="NearpaneSpaceWitness",
                       CFBundleIdentifier="org.nearpane.lab.NearpaneSpaceWitness",CFBundleVersion="1",
                       CFBundlePackageType="APPL",LSUIElement=True),out)
PY
# The staged test bundle may acquire Finder metadata under a synced Documents folder.
for attribute in com.apple.FinderInfo com.apple.ResourceFork; do
  /usr/bin/xattr -rd "$attribute" "$app" 2>/dev/null || true
done
codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"
xcrun swiftc -O engineering/window-lab/isolated-gui/SessionProbe.swift -o "$stage/SessionProbe"
codesign --force --sign - --identifier org.nearpane.lab.SessionProbe "$stage/SessionProbe"
codesign --verify --strict "$stage/SessionProbe"
"$stage/SessionProbe" baseline > "$stage/protected.json"
install -m 755 scripts/acceptance/space-checkpoint.py "$stage/space-checkpoint.py"
cd "$stage"
shasum -a 256 SessionProbe protected.json space-checkpoint.py NearpaneSpaceWitness.app/Contents/{Info.plist,MacOS/NearpaneSpaceWitness,Helpers/NearpaneDesktopReader,_CodeSignature/CodeResources} > SHA256SUMS
shasum -a 256 -c SHA256SUMS
# Only this fresh, initially private folder is published. Trial data goes to the test user's private cache.
chmod -R a+rX,go-w "$stage"
ready=1
printf '%s\n' "$stage"
