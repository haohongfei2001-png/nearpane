#!/bin/bash
# Compile a standalone opt-in fixture and the existing observer for a fresh, private contract kit.
set -euo pipefail
umask 077
cd "$(dirname "$0")/../../.."
kit="${1:?fresh private /private/tmp/nearpane-d01.* output directory}"
[[ "$kit" == /private/tmp/nearpane-d01.* && -d "$kit" && ! -L "$kit" && ! -e "$kit/observe" && ! -e "$kit/Field Notes.app" ]]
[[ "$(stat -f %u "$kit")" == "$(id -u)" && "$(stat -f %Lp "$kit")" == 700 ]]
flavor="${2:-marker}"
[[ "$flavor" == marker || "$flavor" == --registered-documents || "$flavor" == --pair-pointer || "$flavor" == --window-switch ]]
src=scripts/acceptance/native-spaces
inc=Sources/CReadOnlySpaces/include
work="$kit/marker-build"
mkdir -m 700 "$work"
cp "$src/window.swift" "$work/main.swift"
xcrun clang -I "$inc" -c Sources/CReadOnlySpaces/ReadOnlySpaces.c -o "$work/reader.o"
xcrun clang -fobjc-arc -I "$inc" -DNEARPANE_CONTRACT_MEMBERS -c scripts/acceptance/secondary-occupancy.m -o "$work/members.o"
observer_sources=("$src/observe.swift")
fixture_sources=("$work/main.swift" "$src/field-marker-witness.swift")
flags=(-D NATIVE_MARKER_KIT)
if [[ "$flavor" != marker ]]; then
    flags=(-D P2_DOCUMENT_FIXTURE -D SECONDARY_FOCUS_OBSERVER)
    mkdir "$work/observer"
    cp "$src/observe.swift" "$work/observer/main.swift"
    observer_sources=("$work/observer/main.swift" "$src/p2-document-scope.swift" "$src/p2-stage-surface.swift" scripts/acceptance/observe-secondary-space-controls.swift "$src/p2-document-post.swift" "$src/p2-keypad.swift" "$src/p2-document-physical.swift" Sources/NearpaneCore/AXWindowList.swift)
    if [[ "$flavor" == --pair-pointer || "$flavor" == --window-switch ]]; then
        flags+=(-D P2_PAIR_POINTER)
        observer_sources+=("$src/apple-focus-surface.swift" "$src/pair-pointer.swift" "$src/pair-pointer-receiver.swift" "$src/pair-pointer-motion.swift" "$src/pair-pointer-cursor.swift" "$src/pair-pointer-post.swift" "$src/pair-pointer-readiness.swift"
                           "$src/pair-pointer-visual.swift" "$src/pair-pointer-palette.swift" "$src/screen-presentation-clock.swift")
        fixture_sources+=("$src/pair-pointer-palette.swift")
        if [[ "$flavor" == --window-switch ]]; then
            flags+=(-D P2_WINDOW_MOTION)
            observer_sources+=("$src/pair-switch-pixels.swift" scripts/acceptance/window-engine/corner/desktop-material.swift)
        fi
    fi
    fixture_sources+=("$src/p2-keypad.swift" "$src/p2-document-files.swift" "$src/p2-document-physical.swift")
fi
product_link=()
if [[ $# -gt 2 ]]; then
    [[ $# == 3 && "$flavor" == --window-switch && "$3" == --product-corner-material ]]
    engine_dir=Engine/nearpane-window-engine
    archive=$(bash scripts/build-window-engine.sh)
    xcrun clang -fobjc-arc -Wextra -Wall -Werror -I "$engine_dir/include" -I "$engine_dir/src/corner" \
        -c scripts/acceptance/window-engine/corner/product-material.m -o "$work/product-material.o"
    product_link=(-D NP_PRODUCT_CORNER_MATERIAL -Xcc -DNP_PRODUCT_CORNER_MATERIAL "$work/product-material.o" "$archive" \
        -framework ApplicationServices -framework Security -framework ImageIO -framework ScreenCaptureKit -framework Carbon)
fi
xcrun swiftc -D NATIVE_CONTRACT "${flags[@]}" -module-cache-path "$work/cache" -Xcc -I -Xcc "$inc" -import-objc-header "$src/contract_members.h" \
    "${observer_sources[@]}" "$work/reader.o" "$work/members.o" ${product_link[@]+"${product_link[@]}"} -framework ColorSync -o "$kit/observe"
app="$kit/Field Notes.app"
mkdir -p "$app/Contents/MacOS"
cp "$src/fixture.plist" "$app/Contents/Info.plist"
xcrun swiftc -D W01_MARKER_WITNESS "${flags[@]}" -module-cache-path "$work/cache" "${fixture_sources[@]}" -o "$app/Contents/MacOS/FieldNotes"
signer=-
if [[ "$flavor" != marker ]]; then
    signer=$(PYTHONPATH=scripts python3 -c 'import candidate_signing as s; listing=s.gate.cmd("/usr/bin/security","find-identity","-v","-p","codesigning"); print(s.product_fingerprint(listing))')
    codesign --force --sign "$signer" --timestamp=none --options runtime --identifier net.example.nearpane.p2-observer "$kit/observe"
fi
codesign --force --sign "$signer" --timestamp=none --options runtime --identifier net.example.spaces-document "$app"
codesign --verify --strict --deep "$app"
codesign --verify --strict "$kit/observe"
