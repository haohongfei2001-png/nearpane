#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
scripts/build-app.sh release
source scripts/build-paths.sh
app="$product_root/release/Nearpane.app"
scripts/acceptance/build-window-lab.sh "$app"
lab="$(cat build/window-lab/apps-path.txt)"
delivery="${NEARPANE_CANDIDATE_OUTPUT:-$HOME/Applications/Nearpane P5.0}"
mkdir -p "$delivery"
stage="$(mktemp -d "$delivery/.stage.XXXXXXXX")"
trap 'rm -rf "$stage"' EXIT
candidate="$stage/Nearpane P5.0 Alpha.app"
ditto --norsrc --noextattr "$app" "$candidate"
/usr/bin/plutil -replace CFBundleIdentifier -string com.holdsnow.nearpane.candidate.p50 "$candidate/Contents/Info.plist"
/usr/bin/plutil -replace CFBundleName -string 'Nearpane Alpha' "$candidate/Contents/Info.plist"
/usr/bin/plutil -replace CFBundleShortVersionString -string '5.0' "$candidate/Contents/Info.plist"
/usr/bin/plutil -insert LSMultipleInstancesProhibited -bool true "$candidate/Contents/Info.plist"
for helper in NearpaneFrameController NearpaneFixtureWindows; do
    ditto --norsrc --noextattr "$lab/$helper.app" "$candidate/Contents/Helpers/$helper.app"
done
mkdir "$candidate/Contents/Resources/WorkRect"
cp scripts/window-management.py "$candidate/Contents/Resources/WorkRect/"
codesign --force --sign - --identifier com.holdsnow.nearpane.candidate.p50 "$candidate"
codesign --verify --strict --deep "$candidate"
"$candidate/Contents/MacOS/NearpaneHost" --verify-bundled-resources
if [[ -e "$delivery/Nearpane P5.0 Alpha.app" ]]; then
    mv "$delivery/Nearpane P5.0 Alpha.app" "$(mktemp -d "$delivery/.previous.XXXXXXXX")/"
fi
mv "$candidate" "$delivery/"
