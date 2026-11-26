#!/bin/bash
set -euo pipefail

# Build the pinned BSD adapter using Xcode alone. Never downloads or invokes
# `test` (which can publish fabricated Now Playing information).
if [[ "$(uname -s)" != Darwin ]]; then
  echo "MediaRemote helper must be built with Xcode on macOS." >&2
  exit 1
fi
lyrictile_root="$(cd "$(dirname "$0")/.." && pwd)"
source_dir="$lyrictile_root/Vendor/mediaremote-adapter"
output_dir="${1:-$lyrictile_root/.build/media-helper/MediaRemote}"
framework_dir="$output_dir/MediaRemoteAdapter.framework"
mkdir -p "$framework_dir/Versions/A/Resources" "$framework_dir/Versions/A/Headers"
sdk_path="$(xcrun --sdk macosx --show-sdk-path)"
arch_args=()
for architecture in ${2:-${LYRICTILE_ARCH:-${LYRICTILE_ARCHS:-arm64}}}; do arch_args+=(-arch "$architecture"); done
source_files=()
for name in env get globals keys now_playing repeat seek send shuffle speed stream commands test; do
  source_files+=("$source_dir/src/adapter/$name.m")
done
source_files+=("$source_dir/src/private/MediaRemote.m" "$source_dir/src/utility/Debounce.m" "$source_dir/src/utility/helpers.m")
xcrun --sdk macosx clang -dynamiclib -fobjc-arc -fvisibility=default -O2 \
  -isysroot "$sdk_path" -mmacosx-version-min=14.0 "${arch_args[@]}" \
  -I "$source_dir/include" -I "$source_dir/src" \
  -framework Foundation -framework AppKit -framework UniformTypeIdentifiers \
  -install_name '@rpath/MediaRemoteAdapter.framework/Versions/A/MediaRemoteAdapter' \
  "${source_files[@]}" -o "$framework_dir/Versions/A/MediaRemoteAdapter"
cat > "$framework_dir/Versions/A/Resources/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.holdsnow.lyrictile.MediaRemoteAdapter</string>
<key>CFBundleName</key><string>MediaRemoteAdapter</string>
<key>CFBundleExecutable</key><string>MediaRemoteAdapter</string>
<key>CFBundlePackageType</key><string>FMWK</string>
<key>CFBundleShortVersionString</key><string>0.9.0</string>
<key>CFBundleVersion</key><string>900</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
</dict></plist>
PLIST
cp "$source_dir/include/MediaRemoteAdapter.h" "$framework_dir/Versions/A/Headers/"
ln -sfn A "$framework_dir/Versions/Current"
ln -sfn Versions/Current/MediaRemoteAdapter "$framework_dir/MediaRemoteAdapter"
ln -sfn Versions/Current/Resources "$framework_dir/Resources"
ln -sfn Versions/Current/Headers "$framework_dir/Headers"
cp "$source_dir/bin/mediaremote-adapter.pl" "$output_dir/"
cp "$source_dir/LICENSE" "$output_dir/LICENSE"
cp "$source_dir/SOURCE.json" "$output_dir/SOURCE.json"
chmod 755 "$output_dir/mediaremote-adapter.pl"
# Development ad-hoc signature only; distribution must re-sign this framework
# with the app's Developer ID before signing the enclosing bundle.
codesign --force --sign - "$framework_dir"
echo "Built pinned media helper at $output_dir"
