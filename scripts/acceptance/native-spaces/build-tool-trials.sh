#!/bin/bash
set -euo pipefail
umask 077
[[ $# == 1 ]] || { echo 'usage: build-tool-trials.sh NEW_BIN_DIR' >&2; exit 2; }
src="$(cd "$(dirname "$0")" && pwd)"
mkdir "$1"
target="$(uname -m)-apple-macos26.0"
for name in selection capture; do
    extra=()
    if [[ "$name" == selection ]]; then extra+=("$src/translation-proof.swift"); fi
    xcrun swiftc -parse-as-library -target "$target" "$src/tool-context.swift" "$src/tool-$name.swift" ${extra[@]+"${extra[@]}"} -o "$1/tool-$name"
done
fixture="$1/Nearpane Tool Fixture.app"
mkdir -p "$fixture/Contents/MacOS"
info="$fixture/Contents/Info.plist"
plutil -create xml1 "$info"
plutil -insert CFBundlePackageType -string APPL "$info"
plutil -insert CFBundleExecutable -string ToolWindow "$info"
plutil -insert CFBundleIdentifier -string org.nearpane.acceptance.tool-window "$info"
plutil -insert CFBundleName -string 'Nearpane Tool Fixture' "$info"
plutil -insert CFBundleVersion -string 1 "$info"
plutil -insert NSPrincipalClass -string NSApplication "$info"
xcrun swiftc -target "$target" "$src/tool-window.swift" -o "$fixture/Contents/MacOS/ToolWindow"
codesign --force --sign - "$fixture"
codesign --verify --strict "$fixture"
