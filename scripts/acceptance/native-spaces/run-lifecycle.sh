#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../../.."
[[ $# == 1 ]]
root=scripts/acceptance/native-spaces
kit="$(mktemp -d /private/tmp/nearpane-lifecycle.XXXXXXXX)"
trap 'rm -rf -- "$kit"' EXIT
app="$kit/Lifecycle Window.app"
mkdir -p "$app/Contents/MacOS"
cp "$root/fixture.plist" "$app/Contents/Info.plist"
plutil -replace CFBundleIdentifier -string org.nearpane.acceptance.LifecycleWindow "$app/Contents/Info.plist"
plutil -replace CFBundleExecutable -string Lifecycle "$app/Contents/Info.plist"
plutil -replace CFBundleName -string 'Lifecycle Window' "$app/Contents/Info.plist"
xcrun swiftc "$root/lifecycle-window.swift" -o "$app/Contents/MacOS/Lifecycle"
codesign --force --sign - "$app"
xcrun clang -c Sources/CReadOnlySpaces/ReadOnlySpaces.c -I Sources/CReadOnlySpaces/include -o "$kit/r.o"
python3 - "$root" "$kit" <<'PY'
from pathlib import Path
import sys
src,kit=map(Path,sys.argv[1:])
s=(src/'observe.swift').read_text().split('if CommandLine.arguments.count > 1 {')
assert len(s)==2
(kit/'main.swift').write_text(s[0]+'\n'+(src/'lifecycle-menu.swift').read_text()+'\n'+(src/'lifecycle-read.swift').read_text())
PY
xcrun swiftc -import-objc-header Sources/CReadOnlySpaces/include/ReadOnlySpaces.h "$kit/main.swift" "$kit/r.o" -o "$kit/lifecycle-read"
xcrun swiftc -parse-as-library "$root/fixture-film.swift" -o "$kit/film"
xcrun swiftc "$root/metrics.swift" -o "$kit/metrics"
python3 "$root/lifecycle.py" "$kit" "$1"
