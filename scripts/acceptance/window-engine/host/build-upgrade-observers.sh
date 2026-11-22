#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../../../.."
work=${1:?provide the private upgrade evidence directory}
[[ "$work" == /private/tmp/nearpane-host-inplace.* && -d "$work" && ! -L "$work" ]]
umask 077
src=scripts/acceptance/window-engine/host
debug=.build/native-foundation/debug
archive=$(bash scripts/build-window-engine.sh)
# The foundation test build supplies the exact product journal and per-window lock implementations.
if [[ ! -d "$debug/NearpaneUI.build" ]]; then
    NEARPANE_FOUNDATION_ONLY=1 NEARPANE_OFFLINE=1 bash scripts/test.sh --jobs 4 --filter OrdinaryWindowManagerTests
fi
xcrun clang -fobjc-arc "$src/launch-scope.m" -framework AppKit -framework Security -framework CoreGraphics -o "$work/roster"
xcrun swiftc "$src/recovery-window.swift" -o "$work/recovery-window"
xcrun swiftc -parse-as-library -target arm64-apple-macos26.0 -I "$debug/Modules" -module-cache-path .build/clang-cache \
    -Xcc "-fmodule-map-file=$PWD/$debug/CReadOnlySpaces.build/module.modulemap" "$debug/CReadOnlySpaces.build/ReadOnlySpaces.c.o" \
    -I Engine/nearpane-window-engine/include "$debug"/{NearpaneCore,NearpaneUI,NearpaneWindowEngine,NearpaneOrdinaryWindowRuntime,WindowGeometryCore}.build/*.swift.o \
    "$archive" -lobjc -framework Carbon -framework Security -framework ApplicationServices -framework ImageIO \
    "$src/keep-stable-layout.swift" -o "$work/keep-stable-layout"
