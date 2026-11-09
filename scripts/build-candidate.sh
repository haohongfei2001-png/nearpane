#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
scripts/build-app.sh release
source scripts/build-paths.sh
app="$product_root/release/Nearpane.app"
scripts/acceptance/build-window-lab.sh "$app"
lab="$(cat build/window-lab/apps-path.txt)"
delivery="$HOME/Applications/Nearpane P4.4"
mkdir -p "$delivery"
stage="$(mktemp -d "$delivery/.stage.XXXXXXXX")"
trap 'rm -rf "$stage"' EXIT
candidate="$stage/Nearpane Alpha.app"
ditto --norsrc --noextattr "$app" "$candidate"
/usr/bin/plutil -replace CFBundleIdentifier -string com.holdsnow.nearpane.candidate "$candidate/Contents/Info.plist"
/usr/bin/plutil -replace CFBundleName -string 'Nearpane Alpha' "$candidate/Contents/Info.plist"
/usr/bin/plutil -replace CFBundleShortVersionString -string '0.4.4' "$candidate/Contents/Info.plist"
/usr/bin/plutil -insert LSMultipleInstancesProhibited -bool true "$candidate/Contents/Info.plist"
for helper in NearpaneFrameController NearpaneFixtureWindows; do
    ditto --norsrc --noextattr "$lab/$helper.app" "$candidate/Contents/Helpers/$helper.app"
done
mkdir "$candidate/Contents/Resources/WorkRect"
cp scripts/acceptance/{candidate-workrect,verify-window-management}.py "$candidate/Contents/Resources/WorkRect/"
codesign --force --sign - --identifier com.holdsnow.nearpane.candidate "$candidate"
codesign --verify --strict --deep "$candidate"
"$candidate/Contents/MacOS/NearpaneHost" --verify-bundled-resources
if [[ -e "$delivery/Nearpane Alpha.app" ]]; then
    mv "$delivery/Nearpane Alpha.app" "$(mktemp -d "$delivery/.previous.XXXXXXXX")/"
fi
mv "$candidate" "$delivery/"
