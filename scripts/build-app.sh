#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/build-paths.sh
python3 scripts/prepare-domains.py
configuration="${1:-debug}"
case "$configuration" in debug|release) ;; *) echo "Usage: $0 [debug|release]" >&2; exit 2 ;; esac
scratch="$build_root/app-native"
if [ "${NEARPANE_FOUNDATION_ONLY:-0}" = 1 ]; then scratch="$build_root/foundation-app-native"; fi
swift build --build-system native -c "$configuration" --product NearpaneHost --disable-sandbox \
  --scratch-path "$scratch" --cache-path "$build_root/cache" --config-path "$build_root/config" --security-path "$build_root/security"
binary_dir="$(swift build --build-system native -c "$configuration" --show-bin-path --disable-sandbox \
  --scratch-path "$scratch" --cache-path "$build_root/cache" --config-path "$build_root/config" --security-path "$build_root/security")"
destination="$product_root/$configuration"
if [ "${NEARPANE_FOUNDATION_ONLY:-0}" = 1 ]; then destination="$product_root/foundation/$configuration"; fi
bundle="$destination/Nearpane.app"
mkdir -p "$destination"
# The compiler supplies the local executable signature. Distribution bundle signing
# is a P6 concern; File Provider metadata on this worktree prevents a durable bundle seal.
/usr/bin/codesign --verify --strict "$binary_dir/NearpaneHost"
# A fresh stage avoids carrying old resources/signatures into a development bundle.
staging_dir="$(mktemp -d "$PWD/$destination/.Nearpane-stage.XXXXXX")"
stage="$staging_dir/Nearpane.app"
mkdir -p "$stage/Contents/MacOS" "$stage/Contents/Resources"
cp "$binary_dir/NearpaneHost" "$stage/Contents/MacOS/NearpaneHost"
cp Resources/Info.plist "$stage/Contents/Info.plist"
if [ "${NEARPANE_FOUNDATION_ONLY:-0}" = 1 ]; then
  /usr/bin/plutil -replace LSMinimumSystemVersion -string 14.0 "$stage/Contents/Info.plist"
  for usage in NearpaneNativeAcceptanceSchema NSMicrophoneUsageDescription NSSpeechRecognitionUsageDescription NSAppleEventsUsageDescription; do
    /usr/bin/plutil -remove "$usage" "$stage/Contents/Info.plist"
  done
else
  resources="$stage/Contents/Resources"
  cp Resources/AcceptanceTargetGuard.js "$resources/"
  # Native SwiftPM produces flat resource directories and does not attempt to sign
  # File Provider metadata. Construct the layout required by the original .app loaders.
  install_resources() {
    local module="$1" bundle_name="$2" file
    shift 2
    local input="$binary_dir/Nearpane_$module.bundle" dest="$resources/$bundle_name.bundle/Contents"
    mkdir -p "$dest/Resources"
    for file in "$@"; do cp "$input/$file" "$dest/Resources/$file"; done
    /usr/bin/plutil -create xml1 "$dest/Info.plist"
    /usr/bin/plutil -insert CFBundlePackageType -string BNDL "$dest/Info.plist"
    /usr/bin/plutil -insert CFBundleIdentifier -string "com.holdsnow.nearpane.resources.$module" "$dest/Info.plist"
  }
  install_resources SaytileKit Nearpane_SaytileKit ConnectionSample.pcm
  install_resources RiftletAdapters Riftlet_RiftletAdapters chatgpt-web-20261027.js legacy-web-observe.js
  # Saytile first asks the main bundle. This also prevents its SwiftPM development fallback from being used.
  ln -s Nearpane_SaytileKit.bundle/Contents/Resources/ConnectionSample.pcm "$resources/ConnectionSample.pcm"
  python3 scripts/prepare-domains.py --package-resources "$resources"
fi
/usr/bin/plutil -lint "$stage/Contents/Info.plist"
"$stage/Contents/MacOS/NearpaneHost" --verify-bundled-resources
if [ -e "$bundle" ]; then
  previous="$(mktemp -d "$PWD/$destination/previous.XXXXXX")"
  mv "$bundle" "$previous/Nearpane.app"
fi
mv "$stage" "$bundle"
rmdir "$staging_dir"
cmp "$binary_dir/NearpaneHost" "$bundle/Contents/MacOS/NearpaneHost"
echo "Built $bundle (development executable signature and offline resources verified; no GUI launch)."
