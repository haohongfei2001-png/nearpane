#!/bin/bash
# Compile the production helper for the same architecture as the product Rust archive.
# The packager signs and validates both this nested executable and the outer app.
set -euo pipefail
cd "$(dirname "$0")/../../../.."
out=${1:?destination executable}
archive=${2:?compiled product Rust static archive}
shift 2
src=Engine/nearpane-window-engine/src/corner
xcrun clang -mmacosx-version-min=14.0 -fobjc-arc -O2 -Wall -Wextra -Werror "$@" -I Engine/nearpane-window-engine/include \
    "$src/guardian/main.m" "$src/macos.m" "$archive" -framework Security -framework AppKit -framework QuartzCore -framework ScreenCaptureKit \
    -framework ApplicationServices -framework Carbon -framework CoreGraphics -framework CoreFoundation -framework Foundation -o "$out"
