#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
python3 scripts/prepare-domains.py
configuration="${1:-debug}"
case "$configuration" in debug|release) ;; *) echo "Usage: $0 [debug|release]" >&2; exit 2 ;; esac
swift build -c "$configuration" --product NearpaneHost --disable-sandbox \
  --scratch-path .build --cache-path .build/cache --config-path .build/config --security-path .build/security
binary_dir="$(swift build -c "$configuration" --show-bin-path --disable-sandbox \
  --scratch-path .build --cache-path .build/cache --config-path .build/config --security-path .build/security)"
destination="build/$configuration"
if [ "${NEARPANE_FOUNDATION_ONLY:-0}" = 1 ]; then destination="build/foundation/$configuration"; fi
bundle="$destination/Nearpane.app"
mkdir -p "$destination"
# The compiler supplies the local executable signature. Distribution bundle signing
# is a P6 concern; File Provider metadata on this worktree prevents a durable bundle seal.
/usr/bin/codesign --verify --strict "$binary_dir/NearpaneHost"
# A fresh stage avoids carrying old resources/signatures into a development bundle.
stage="$(mktemp -d "$PWD/$destination/.Nearpane-stage.XXXXXX")"
mkdir -p "$stage/Contents/MacOS" "$stage/Contents/Resources"
cp "$binary_dir/NearpaneHost" "$stage/Contents/MacOS/NearpaneHost"
cp Resources/Info.plist "$stage/Contents/Info.plist"
if [ "${NEARPANE_FOUNDATION_ONLY:-0}" = 1 ]; then
  /usr/bin/plutil -replace LSMinimumSystemVersion -string 14.0 "$stage/Contents/Info.plist"
else
  resources="$stage/Contents/Resources"
  cp -R "$binary_dir/Nearpane_SaytileKit.bundle" "$resources/"
  pcm="Nearpane_SaytileKit.bundle/Contents/Resources/ConnectionSample.pcm"
  cmp "$binary_dir/$pcm" "$resources/$pcm"
  cp .build/domain-inputs/2bd114f526013e6ccb422a26e17f4514e9d63836/Sources/CAudio/WEBRTC-LICENSE.txt "$resources/"
fi
/usr/bin/plutil -lint "$stage/Contents/Info.plist"
if [ -e "$bundle" ]; then
  previous="$(mktemp -d "$PWD/$destination/previous.XXXXXX")"
  mv "$bundle" "$previous/Nearpane.app"
fi
mv "$stage" "$bundle"
cmp "$binary_dir/NearpaneHost" "$bundle/Contents/MacOS/NearpaneHost"
echo "Built $bundle (development bundle; executable signature verified; not launched)."
