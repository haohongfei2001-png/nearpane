#!/bin/bash
# An ordinary, independently identified local build with its own support root.
set -euo pipefail
cd "$(dirname "$0")/.."
scripts/build-app.sh debug
source scripts/build-paths.sh
preview="$product_root/voice-preview"
mkdir -p "$preview"
stage="$(mktemp -d "$preview/.stage.XXXXXXXX")"
trap 'rm -rf "$stage"' EXIT
app="$stage/Nearpane 语音体验.app"
ditto --norsrc --noextattr "$product_root/debug/Nearpane.app" "$app"
id=com.holdsnow.nearpane.voice-preview
/usr/bin/plutil -replace CFBundleIdentifier -string "$id" "$app/Contents/Info.plist"
/usr/bin/plutil -replace CFBundleName -string 'Nearpane 语音体验' "$app/Contents/Info.plist"
/usr/bin/plutil -insert LSMultipleInstancesProhibited -bool true "$app/Contents/Info.plist"
codesign --force --sign - --identifier "$id" "$app"
codesign --verify --deep --strict "$app"
"$app/Contents/MacOS/NearpaneHost" --verify-bundled-resources
# Rename only this script’s own generated candidate.
if [[ -e "$preview/Nearpane 语音体验.app" ]]; then
  mv "$preview/Nearpane 语音体验.app" "$stage/previous.app"
fi
if ! mv "$app" "$preview/"; then
  [[ ! -e "$stage/previous.app" ]] || mv "$stage/previous.app" "$preview/Nearpane 语音体验.app"
  exit 1
fi
echo "Built $preview/Nearpane 语音体验.app"
