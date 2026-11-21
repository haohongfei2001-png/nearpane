#!/bin/bash
set -eu
cd "$(dirname "$0")/../../../.."
scratch=$(mktemp -d "${TMPDIR:-/private/tmp}/nearpane-corner-tests.XXXXXXXX")
trap 'rm -rf "$scratch"' EXIT
compiler="${RUSTC:-rustc}"
if ! command -v "$compiler" >/dev/null && [ -x build/window-engine/toolchain/portable/bin/rustc ]; then
    compiler=build/window-engine/toolchain/portable/bin/rustc
fi
src=Engine/nearpane-window-engine/src/corner
xcrun clang -fobjc-arc -Wall -Wextra -Werror -c "$src/macos.m" -o "$scratch/reader.o"
"$compiler" --edition=2024 --test -A dead_code scripts/acceptance/window-engine/corner/offline.rs -o "$scratch/tests" \
  -C "link-arg=$scratch/reader.o" -l objc -l framework=AppKit -l framework=ApplicationServices \
  -l framework=CoreGraphics -l framework=CoreFoundation -l framework=Carbon -l framework=Security
"$scratch/tests" --test-threads=1
xcrun clang -std=c11 -Wall -Wextra -Werror scripts/acceptance/window-engine/corner/cycles-test.c -o "$scratch/cycles"
"$scratch/cycles"
xcrun clang -std=c11 -Wall -Wextra -Werror -I "$src" -I Engine/nearpane-window-engine/include scripts/acceptance/window-engine/corner/guardian-test.c -o "$scratch/guard"
"$scratch/guard"
xcrun clang -fobjc-arc -Wall -Wextra -Werror -I "$src" scripts/acceptance/window-engine/corner/scope-test.m -framework Foundation -framework CoreGraphics -o "$scratch/scope-test"
"$scratch/scope-test"
xcrun clang -fobjc-arc -Wall -Wextra -Werror -I "$src" -I Engine/nearpane-window-engine/include \
    scripts/acceptance/window-engine/corner/packaged-ledger-test.m "$scratch/reader.o" -framework AppKit \
    -framework Foundation -framework ApplicationServices -framework Security -framework Carbon \
    -framework CoreGraphics -framework CoreFoundation -o "$scratch/packaged-ledger"
"$scratch/packaged-ledger"
