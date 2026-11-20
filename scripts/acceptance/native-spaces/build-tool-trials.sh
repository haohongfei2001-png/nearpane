#!/bin/bash
set -euo pipefail
umask 077
[[ $# == 1 ]] || { echo 'usage: build-tool-trials.sh NEW_BIN_DIR' >&2; exit 2; }
src="$(cd "$(dirname "$0")" && pwd)"
mkdir "$1"
target="$(uname -m)-apple-macos26.0"
for name in selection capture; do
    xcrun swiftc -parse-as-library -target "$target" "$src/tool-context.swift" "$src/tool-$name.swift" -o "$1/tool-$name"
done
