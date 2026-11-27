#!/bin/bash
set -euo pipefail
# Explicit owner-side operation. This script never creates a signing identity,
# requests credentials in chat, publishes a release, or rewrites an unsigned app.
lyrictile_root="$(cd "$(dirname "$0")/.." && pwd)"
app="${1:-$lyrictile_root/dist/LyricTile.app}"
profile="${LYRICTILE_NOTARY_PROFILE:?Set an existing Keychain notary profile}"
identity="${LYRICTILE_SIGN_IDENTITY:?Set the installed Developer ID Application identity used by build-app.sh}"
[[ "$identity" != - ]] || { echo "Ad-hoc signing cannot be notarized." >&2; exit 2; }
[[ "$(uname -s)" == Darwin ]] || exit 2
app="$(cd "$(dirname "$app")" && pwd)/$(basename "$app")"
output="${LYRICTILE_NOTARY_OUTPUT:-$lyrictile_root/dist/notarized}"
mkdir -p "$output"
output="$(cd "$output" && pwd)"
artifact_name="$(python3 - "$app/Contents/Info.plist" <<'PY'
import plistlib,re,sys
info=plistlib.load(open(sys.argv[1],'rb'))
version=info['CFBundleShortVersionString']; build=info['CFBundleVersion']
if not re.fullmatch(r'\d+\.\d+\.\d+',version) or not build.isdigit(): raise SystemExit('Invalid release version/build')
print(f'LyricTile-{version}-{build}-arm64')
PY
)"
[[ "$(lipo -archs "$app/Contents/MacOS/LyricTile")" == arm64 ]] || {
  echo "The current public distribution target is Apple silicon (arm64)." >&2; exit 2;
}
archive="$output/$artifact_name.zip"
dmg="$output/$artifact_name.dmg"
codesign --verify --deep --strict "$app"
codesign -dv --verbose=4 "$app" 2> "$output/signature-before.txt"
/usr/bin/grep -q '^Authority=Developer ID Application:' "$output/signature-before.txt" || {
  echo "The supplied app must already have a real Developer ID Application signature." >&2; exit 2;
}
ditto -c -k --sequesterRsrc --keepParent "$app" "$output/notary-submission.zip"
xcrun notarytool submit "$output/notary-submission.zip" --keychain-profile "$profile" --wait --output-format json > "$output/app-notary.json"
python3 - "$output/app-notary.json" <<'PY'
import json,sys
r=json.load(open(sys.argv[1]))
if r.get('status') != 'Accepted': raise SystemExit('Application notarization was not Accepted; inspect the stored JSON before continuing.')
PY
xcrun stapler staple "$app"
xcrun stapler validate "$app" | tee "$output/stapler-app.txt"
spctl --assess --type execute --verbose=4 "$app" 2> "$output/gatekeeper-app.txt"
ditto -c -k --sequesterRsrc --keepParent "$app" "$archive"
stage="$(mktemp -d "$output/dmg-stage.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
ditto "$app" "$stage/LyricTile.app"
ln -s /Applications "$stage/Applications"
hdiutil create -ov -volname LyricTile -srcfolder "$stage" -format UDZO "$dmg"
codesign --force --sign "$identity" --timestamp "$dmg"
xcrun notarytool submit "$dmg" --keychain-profile "$profile" --wait --output-format json > "$output/dmg-notary.json"
python3 - "$output/dmg-notary.json" <<'PY'
import json,sys
r=json.load(open(sys.argv[1]))
if r.get('status') != 'Accepted': raise SystemExit('DMG notarization was not Accepted; inspect the stored JSON.')
PY
xcrun stapler staple "$dmg"
xcrun stapler validate "$dmg" | tee "$output/stapler-dmg.txt"
spctl --assess --type open --context context:primary-signature --verbose=4 \
  "$dmg" 2> "$output/gatekeeper-dmg.txt"
python3 - "$output" "$archive" "$dmg" <<'PY'
import hashlib,sys
from pathlib import Path
root=Path(sys.argv[1]); files=[Path(sys.argv[2]),Path(sys.argv[3])]
(root/'SHA256SUMS').write_text(''.join(f'{hashlib.sha256(p.read_bytes()).hexdigest()}  {p.name}\n' for p in files))
PY
echo "Notarized files and actual receipts: $output"
