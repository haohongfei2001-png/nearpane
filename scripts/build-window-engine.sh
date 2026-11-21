#!/bin/bash
# Prints only the verified archive path. Consumed by build-app.sh and test.sh.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/build-paths.sh
engine_root=Engine/nearpane-window-engine
compiler="$(command -v cargo || true)"
if [[ -z "$compiler" && -x build/window-engine/toolchain/portable/bin/cargo ]]; then
  export PATH="$PWD/build/window-engine/toolchain/portable/bin:$PATH"
  compiler="$(command -v cargo)"
fi
if [[ -z "$compiler" ]]; then echo "Rust 1.88+ with Cargo is required to build the Nearpane window engine." >&2; exit 1; fi
export CARGO_HOME="${CARGO_HOME:-$PWD/$build_root/window-engine/cargo-home}"
target_dir="$PWD/$build_root/window-engine/cargo-target"
arch="${1:-$(uname -m)}"
case "$arch" in arm64|aarch64) triple=aarch64-apple-darwin;; x86_64) triple=x86_64-apple-darwin;; *) echo "Unsupported macOS architecture $arch" >&2; exit 2;; esac
# The build selects reviewed compiled backends; experimental fixture authorization
# is exclusive to the isolated acceptance binary.
features=""
"$compiler" build --manifest-path "$engine_root/Cargo.toml" --release --locked --offline --no-default-features \
  --features "$features" --target "$triple" --target-dir "$target_dir" >&2
archive="$target_dir/$triple/release/libnearpane_window_engine.a"
digest="$(shasum -a 256 "$archive" | cut -d' ' -f1)"
published="$PWD/$build_root/window-engine/$triple/$digest/libnearpane_window_engine.a"
if [[ ! -f "$published" ]]; then
  mkdir -p "$(dirname "$published")"
  temporary="$(mktemp "$(dirname "$published")/.archive.XXXXXXXX")"
  cp "$archive" "$temporary"
  mv "$temporary" "$published"
fi
printf '%s\n' "$published"
