#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
configuration="${1:-debug}"
case "$configuration" in debug|release) ;; *) echo "Usage: $0 [debug|release]" >&2; exit 2 ;; esac
swift build -c "$configuration" --product NearpaneHost --disable-sandbox \
  --scratch-path .build --cache-path .build/cache --config-path .build/config --security-path .build/security
binary_dir="$(swift build -c "$configuration" --show-bin-path --disable-sandbox \
  --scratch-path .build --cache-path .build/cache --config-path .build/config --security-path .build/security)"
bundle="build/$configuration/Nearpane.app"
mkdir -p "build/$configuration"
# The compiler supplies the local executable signature. Distribution bundle signing
# is a P6 concern; File Provider metadata on this worktree prevents a durable bundle seal.
/usr/bin/codesign --verify --strict "$binary_dir/NearpaneHost"
# A fresh stage avoids carrying old resources/signatures into a development bundle.
stage="$(mktemp -d "$PWD/build/$configuration/.Nearpane-stage.XXXXXX")"
mkdir -p "$stage/Contents/MacOS" "$stage/Contents/Resources"
cp "$binary_dir/NearpaneHost" "$stage/Contents/MacOS/NearpaneHost"
cp Resources/Info.plist "$stage/Contents/Info.plist"
/usr/bin/plutil -lint "$stage/Contents/Info.plist"
if [ -e "$bundle" ]; then
  previous="$(mktemp -d "$PWD/build/$configuration/previous.XXXXXX")"
  mv "$bundle" "$previous/Nearpane.app"
fi
mv "$stage" "$bundle"
cmp "$binary_dir/NearpaneHost" "$bundle/Contents/MacOS/NearpaneHost"
echo "Built $bundle (development bundle; executable signature verified; not launched)."
