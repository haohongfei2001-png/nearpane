#!/bin/bash
# Exercise the actual helper and Host journal without building unrelated SwiftUI settings on hosted machines.
set -euo pipefail
cd "$(dirname "$0")/../../.."
work="$(mktemp -d "${TMPDIR:-/tmp}/nearpane-protocol.XXXXXXXX")"
trap 'rm -rf -- "$work"' EXIT
mkdir -p "$work/Sources/NearpaneUI" "$work/Tests/NearpaneUITests"
for target in CNativeSpaceActions CReadOnlySpaces NearpaneCore NearpaneSpaceAction WindowGeometryCore; do
    cp -R "Sources/$target" "$work/Sources/"
done
cp Sources/NearpaneUI/NativeSwitchJournal.swift "$work/Sources/NearpaneUI/"
cp -R Tests/NearpaneSpaceActionTests "$work/Tests/"
cp Tests/NearpaneUITests/NativeSwitchJournalTests.swift "$work/Tests/NearpaneUITests/"
cat > "$work/Package.swift" <<'SWIFT'
// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "InstalledProtocolTests", platforms: [.macOS("26.0")], targets: [
    .target(name: "WindowGeometryCore"),
    .target(name: "CReadOnlySpaces"),
    .target(name: "CNativeSpaceActions"),
    .target(name: "NearpaneCore", dependencies: ["WindowGeometryCore"]),
    .executableTarget(name: "NearpaneSpaceAction", dependencies: ["NearpaneCore", "CReadOnlySpaces", "CNativeSpaceActions"]),
    .target(name: "NearpaneUI", dependencies: ["NearpaneCore"]),
    .testTarget(name: "NearpaneSpaceActionTests", dependencies: ["NearpaneSpaceAction", "NearpaneCore", "CNativeSpaceActions"]),
    .testTarget(name: "NearpaneUITests", dependencies: ["NearpaneUI", "NearpaneCore"])
], swiftLanguageModes: [.v6])
SWIFT
flags=()
frameworks="$(xcode-select -p)/Library/Developer/Frameworks"
if [[ -d "$frameworks/Testing.framework" ]]; then
    toolchain="$(dirname "$(xcrun --find swiftc)")"
    flags=(-Xswiftc -F -Xswiftc "$frameworks" -Xlinker -F -Xlinker "$frameworks"
        -Xlinker -rpath -Xlinker "$frameworks" -Xswiftc -external-plugin-path
        -Xswiftc "$toolchain/../lib/swift/host/plugins/testing#$toolchain/swift-plugin-server")
fi
swift test --build-system native --package-path "$work" --disable-xctest --enable-swift-testing "${flags[@]}"
