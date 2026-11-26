#!/bin/bash
set -euo pipefail
lyrictile_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$lyrictile_root"
if [[ "$(uname -s)" != Darwin ]]; then
  echo "LyricTile requires Xcode on macOS to build its native application." >&2
  exit 1
fi
architecture="${LYRICTILE_ARCH:-arm64}"
case "$architecture" in arm64|x86_64) ;; *) echo "Unsupported architecture: $architecture" >&2; exit 2 ;; esac
configuration="${LYRICTILE_CONFIGURATION:-release}"
case "$configuration" in debug|release) ;; *) exit 2 ;; esac
destination="${LYRICTILE_OUTPUT:-$lyrictile_root/dist}"
mkdir -p "$destination"
destination="$(cd "$destination" && pwd)"
app="$destination/LyricTile.app"
# Only the known generated bundle is replaced, never a user's installed app.
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/Notices" "$app/Contents/Frameworks"
swift build --configuration "$configuration" --arch "$architecture" --product LyricTile
binary_path="$(swift build --configuration "$configuration" --arch "$architecture" --show-bin-path)"
cp "$binary_path/LyricTile" "$app/Contents/MacOS/LyricTile"
chmod 755 "$app/Contents/MacOS/LyricTile"
sparkle_framework="$(python3 - <<'PY'
from pathlib import Path
p = list(Path('.build/artifacts').glob('**/Sparkle.xcframework/macos-*/Sparkle.framework'))
if len(p) != 1:
    raise SystemExit(f'Expected one resolved Sparkle framework; found {len(p)}')
print(p[0].resolve())
PY
)"
ditto "$sparkle_framework" "$app/Contents/Frameworks/Sparkle.framework"
# SwiftPM's executable rpath may point only to its build directory. Add the
# actual bundle-relative framework path before code signing.
if ! otool -l "$app/Contents/MacOS/LyricTile" | /usr/bin/grep -F '@executable_path/../Frameworks' > /dev/null; then
  install_name_tool -add_rpath '@executable_path/../Frameworks' "$app/Contents/MacOS/LyricTile"
fi
bash Scripts/build-media-helper.sh "$app/Contents/Resources/MediaRemote" "$architecture"
iconset="$lyrictile_root/.build/LyricTile.iconset"
xcrun swift Scripts/render-icon.swift "$iconset"
xcrun iconutil -c icns "$iconset" -o "$app/Contents/Resources/LyricTile.icns"
commit="$(git rev-parse HEAD)"
python3 Scripts/write-bundle-info.py "$app/Contents/Info.plist" \
  --version "${LYRICTILE_VERSION:-1.0.0}" --build "${LYRICTILE_BUILD_NUMBER:-1}" --commit "$commit"
cp Documentation/THIRD_PARTY_NOTICES.md "$app/Contents/Resources/Notices/"
if [[ -d Packaging/Notices ]]; then cp Packaging/Notices/* "$app/Contents/Resources/Notices/"; fi
cp Vendor/mediaremote-adapter/LICENSE "$app/Contents/Resources/Notices/mediaremote-adapter-LICENSE"
for name in Yams Sparkle; do
  package_dir="$(python3 - "$name" <<'PY'
from pathlib import Path
import sys
p = [p for p in Path('.build/checkouts').iterdir() if p.name.lower() == sys.argv[1].lower()]
if len(p) != 1: raise SystemExit('Resolved source checkout missing')
print(p[0].resolve())
PY
)"
  license_file="$(python3 - "$package_dir" <<'PY'
from pathlib import Path
import sys
names = ['LICENSE', 'LICENSE.md', 'LICENSE.txt']
p = next((Path(sys.argv[1])/n for n in names if (Path(sys.argv[1])/n).is_file()), None)
if p is None: raise SystemExit('Dependency license missing')
print(p)
PY
)"
  cp "$license_file" "$app/Contents/Resources/Notices/$name-LICENSE"
done
if [[ -f Package.resolved ]]; then cp Package.resolved "$app/Contents/Resources/Notices/Package.resolved"; fi
identity="${LYRICTILE_SIGN_IDENTITY:--}"
signing_args=(--force --sign "$identity" --options runtime)
if [[ "$identity" != - ]]; then signing_args+=(--timestamp); fi
# Re-sign nested Sparkle code from the inside out, preserving its own XPC
# entitlements. No --deep signing that could hide a missed nested component.
while IFS= read -r path; do
  codesign "${signing_args[@]}" --preserve-metadata=entitlements "$path"
done < <(python3 - "$app/Contents/Frameworks/Sparkle.framework" <<'PY'
from pathlib import Path
import sys
root = Path(sys.argv[1])
paths = []
for p in root.rglob('*'):
    if p.is_symlink(): continue
    if p.is_dir() and p.suffix in ('.xpc', '.app', '.framework'): paths.append(p)
    elif p.is_file() and p.name in ('Autoupdate', 'fileop'): paths.append(p)
for p in sorted(paths, key=lambda x: len(x.parts), reverse=True): print(p)
print(root)
PY
)
codesign "${signing_args[@]}" "$app/Contents/Resources/MediaRemote/MediaRemoteAdapter.framework"
codesign "${signing_args[@]}" --entitlements Packaging/LyricTile.entitlements "$app"
codesign --verify --deep --strict --verbose=2 "$app"
python3 Scripts/verify-bundle.py "$app" --architecture "$architecture" --output "$destination/bundle-verification.json"
archive="$destination/LyricTile-${LYRICTILE_VERSION:-1.0.0}-candidate-$architecture.zip"
ditto -c -k --sequesterRsrc --keepParent "$app" "$archive"
if [[ "${LYRICTILE_CREATE_DMG:-1}" == 1 ]]; then
  stage="$(mktemp -d "$lyrictile_root/.build/dmg-stage.XXXXXX")"
  trap 'rm -rf "$stage"' EXIT
  ditto "$app" "$stage/LyricTile.app"
  ln -s /Applications "$stage/Applications"
  hdiutil create -ov -volname LyricTile -srcfolder "$stage" -format UDZO \
    "$destination/LyricTile-${LYRICTILE_VERSION:-1.0.0}-candidate-$architecture.dmg"
fi
python3 - "$destination" <<'PY'
import hashlib,sys
from pathlib import Path
root=Path(sys.argv[1])
files=sorted([*root.glob('*.zip'),*root.glob('*.dmg')])
(root/'SHA256SUMS').write_text(''.join(f'{hashlib.sha256(p.read_bytes()).hexdigest()}  {p.name}\n' for p in files))
PY
echo "Independent candidate: $app"
