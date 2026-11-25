#!/bin/bash
# Build the session-owning helper against the exact same Rust archive as the Host.
# The app packager signs it and seals its final signed bytes in Info.plist.
set -euo pipefail
cd "$(dirname "$0")/../.."
out=${1:?destination executable}
archive=${2:?compiled product Rust static archive}
xcrun clang -mmacosx-version-min=14.0 -fobjc-arc -O2 -Wall -Wextra -Werror \
  -I Engine/nearpane-window-engine/include \
  Engine/nearpane-window-engine/src/spaces/worker/main.m "$archive" \
  -framework AppKit -framework Foundation -framework ApplicationServices \
  -framework CoreGraphics -framework CoreFoundation -framework Carbon \
  -framework Security -framework ImageIO -framework ScreenCaptureKit -lc++ -o "$out"
