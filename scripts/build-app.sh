#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
python3 scripts/prepare-domains.py
configuration="${1:-debug}"
case "$configuration" in debug|release) ;; *) echo "Usage: $0 [debug|release]" >&2; exit 2 ;; esac
scratch=.build
if [ "${NEARPANE_FOUNDATION_ONLY:-0}" = 1 ]; then scratch=.build/foundation; fi
swift build -c "$configuration" --product NearpaneHost --disable-sandbox \
  --scratch-path "$scratch" --cache-path .build/cache --config-path .build/config --security-path .build/security
binary_dir="$(swift build -c "$configuration" --show-bin-path --disable-sandbox \
  --scratch-path "$scratch" --cache-path .build/cache --config-path .build/config --security-path .build/security)"
destination="build/$configuration"
if [ "${NEARPANE_FOUNDATION_ONLY:-0}" = 1 ]; then destination="build/foundation/$configuration"; fi
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
  for usage in NSMicrophoneUsageDescription NSSpeechRecognitionUsageDescription NSAppleEventsUsageDescription; do
    /usr/bin/plutil -remove "$usage" "$stage/Contents/Info.plist"
  done
else
  resources="$stage/Contents/Resources"
  cp -R "$binary_dir/Nearpane_SaytileKit.bundle" "$resources/"
  # In an .app the original Riftlet loader deliberately requires this name, independent of the SwiftPM product.
  cp -R "$binary_dir/Nearpane_RiftletAdapters.bundle" "$resources/Riftlet_RiftletAdapters.bundle"
  for program in chatgpt-web-20261027.js legacy-web-observe.js; do
    asset="Contents/Resources/$program"
    cmp "$binary_dir/Nearpane_RiftletAdapters.bundle/$asset" "$resources/Riftlet_RiftletAdapters.bundle/$asset"
  done
  pcm="Nearpane_SaytileKit.bundle/Contents/Resources/ConnectionSample.pcm"
  cmp "$binary_dir/$pcm" "$resources/$pcm"
  cp .build/domain-inputs/2bd114f526013e6ccb422a26e17f4514e9d63836/Sources/CAudio/WEBRTC-LICENSE.txt "$resources/"
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
