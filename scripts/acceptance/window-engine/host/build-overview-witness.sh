#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../../../.."
work=${1:?private witness build directory}
[[ "$work" == /private/tmp/nearpane-overview.* && -d "$work" && ! -L "$work" ]]
umask 077
source scripts/build-paths.sh
src=scripts/acceptance/window-engine/host
debug="$build_root/native-foundation/debug"
archive=$(bash scripts/build-window-engine.sh)
if [[ ! -f "$debug/Modules/NearpaneCore.swiftmodule" ]]; then
    NEARPANE_FOUNDATION_ONLY=1 NEARPANE_OFFLINE=1 bash scripts/test.sh --jobs 4 --filter StageInstalledProbeTests
fi
common=(-parse-as-library -package-name nearpane -target "$(uname -m)-apple-macos26.0" -I "$debug/Modules" -module-cache-path "$build_root/clang-cache" \
    -Xcc "-fmodule-map-file=$PWD/$debug/CReadOnlySpaces.build/module.modulemap" "$debug/CReadOnlySpaces.build/ReadOnlySpaces.c.o" \
    -I Engine/nearpane-window-engine/include "$debug"/{NearpaneCore,NearpaneOrdinaryWindowRuntime,WindowGeometryCore}.build/*.swift.o \
    "$archive" -lobjc -framework Carbon -framework Security -framework ImageIO \
    Sources/NearpaneHost/{StageEngineHostScope,StageScopeReply,StageOverviewHitTest,StageOverviewFocusTrace,StageCanaryOverview}.swift)
xcrun swiftc "${common[@]}" "$src/overview-media.swift" "$src/finish-presented.swift" -o "$work/finish-presented"
xcrun swiftc "${common[@]}" "$src/fixture-readback.swift" -o "$work/fixture-readback"
xcrun swiftc "${common[@]}" "$src/overview-media.swift" "$src/overview-witness.swift" -o "$work/overview-witness"
xcrun swiftc -module-cache-path "$build_root/clang-cache" scripts/acceptance/native-spaces/metrics.swift -o "$work/metrics"
xcrun swiftc -parse-as-library -module-cache-path "$build_root/clang-cache" scripts/acceptance/native-spaces/title-movie.swift -o "$work/strip-movie"
