#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
scripts/build-app.sh release
source scripts/build-paths.sh
app="$product_root/release/Nearpane.app"
scripts/acceptance/build-window-lab.sh "$app"
lab="$(cat build/window-lab/apps-path.txt)"
version=5.5
build_number=55
name="Nearpane P$version Alpha.app"
delivery="${NEARPANE_CANDIDATE_OUTPUT:-$HOME/Applications/Nearpane P$version}"
mkdir -p "$delivery"
stage="$(mktemp -d "$delivery/.stage.XXXXXXXX")"
trap 'rm -rf "$stage"' EXIT
candidate="$stage/$name"
ditto --norsrc --noextattr "$app" "$candidate"
/usr/bin/plutil -replace CFBundleIdentifier -string com.holdsnow.nearpane.alpha "$candidate/Contents/Info.plist"
/usr/bin/plutil -replace CFBundleName -string 'Nearpane Alpha' "$candidate/Contents/Info.plist"
/usr/bin/plutil -replace CFBundleShortVersionString -string "$version" "$candidate/Contents/Info.plist"
/usr/bin/plutil -replace CFBundleVersion -string "$build_number" "$candidate/Contents/Info.plist"
/usr/bin/plutil -insert LSMultipleInstancesProhibited -bool true "$candidate/Contents/Info.plist"
for helper in NearpaneFrameController NearpaneFixtureWindows; do
    ditto --norsrc --noextattr "$lab/$helper.app" "$candidate/Contents/Helpers/$helper.app"
done
mkdir "$candidate/Contents/Resources/WorkRect"
cp scripts/window-management.py "$candidate/Contents/Resources/WorkRect/"
mkdir "$candidate/Contents/Resources/Profile"
install -m 644 scripts/profile-migration.py scripts/profile_domains.py "$candidate/Contents/Resources/Profile/"
install -m 644 docs/ALPHA-HELP.md "$candidate/Contents/Resources/AlphaHelp.md"
codesign --force --sign - --identifier com.holdsnow.nearpane.alpha "$candidate"
codesign --verify --strict --deep "$candidate"
"$candidate/Contents/MacOS/NearpaneHost" --verify-bundled-resources
python3 scripts/check-alpha-distribution.py "$candidate" > "$stage/package.json"
previous=""
if [[ -e "$delivery/$name" ]]; then
    previous="$(mktemp -d "$delivery/.previous.XXXXXXXX")"
    mv "$delivery/$name" "$previous/"
fi
if ! mv "$candidate" "$delivery/"; then
    if [[ -n "$previous" ]]; then mv "$previous/$name" "$delivery/"; fi
    exit 1
fi
mv "$stage/package.json" "$delivery/package.json"
