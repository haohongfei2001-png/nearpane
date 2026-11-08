#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/build-paths.sh
python3 scripts/prepare-domains.py
# No app launch and no visible window. SwiftPM caches stay in this worktree.
# CLT 6.4 ships Testing as a framework. Its native SwiftPM engine needs the explicit
# framework/plugin paths; it builds a CLI test runner instead of signing XCTest bundles.
developer_dir="$(xcode-select -p)"
toolchain_bin="$(dirname "$(xcrun --find swiftc)")"
testing_frameworks="$developer_dir/Library/Developer/Frameworks"
testing_flags=()
if [ -d "$testing_frameworks/Testing.framework" ]; then
  testing_flags=(-Xswiftc -F -Xswiftc "$testing_frameworks"
    -Xlinker -F -Xlinker "$testing_frameworks"
    -Xlinker -rpath -Xlinker "$testing_frameworks"
    -Xswiftc -external-plugin-path
    -Xswiftc "$toolchain_bin/../lib/swift/host/plugins/testing#$toolchain_bin/swift-plugin-server")
fi
scratch="$build_root/native"
if [ "${NEARPANE_FOUNDATION_ONLY:-0}" = 1 ]; then scratch="$build_root/native-foundation"; fi
swift test --build-system native --disable-xctest --enable-swift-testing --disable-sandbox \
  --scratch-path "$scratch" --cache-path "$build_root/cache" --config-path "$build_root/config" \
  --security-path "$build_root/security" "${testing_flags[@]}" "$@"
