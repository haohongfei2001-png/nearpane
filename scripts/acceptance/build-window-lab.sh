#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
export NEARPANE_FOUNDATION_ONLY=1
if (( $# > 1 )); then echo "Usage: $0 [verified Nearpane.app]" >&2; exit 2; fi
args=(--package-path engineering/window-lab --scratch-path "$PWD/build/window-lab/swift" --disable-sandbox -c release)
swift build "${args[@]}"
bin="$(swift build "${args[@]}" --show-bin-path)"
umask 077
# File Provider attaches Finder metadata to repo directories. Keep the signed test apps in a private local cache.
apps_dir="${NEARPANE_LAB_APP_CACHE:-$HOME/Library/Caches/org.nearpane.window-lab/P4.2}"
mkdir -p "$apps_dir"
stage="$(mktemp -d "$apps_dir/.stage.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
for name in NearpaneFrameController NearpaneFixtureWindows NearpaneRegularFixture; do
    app="$stage/$name.app"
    mkdir -p "$app/Contents/MacOS"
    python3 - "$app/Contents/Info.plist" "$name" <<'PY'
import plistlib, sys
with open(sys.argv[1], "wb") as f:
    plistlib.dump(dict(CFBundleExecutable=sys.argv[2], CFBundleIdentifier="org.nearpane.lab." + sys.argv[2],
                       CFBundleName=sys.argv[2], CFBundlePackageType="APPL", LSUIElement=sys.argv[2] != "NearpaneRegularFixture",
                       CFBundleVersion="1", LSMinimumSystemVersion="14.0"), f)
PY
    install -m 755 "$bin/$name" "$app/Contents/MacOS/$name"
    if [[ "$name" == NearpaneFixtureWindows && $# == 1 ]]; then
        reader="$1/Contents/Helpers/NearpaneDesktopReader"
        expected="$(/usr/bin/plutil -extract NearpaneDesktopReaderSHA256 raw -o - "$1/Contents/Info.plist")"
        /usr/bin/codesign --verify --strict "$reader"
        [[ "$(shasum -a 256 "$reader" | cut -d ' ' -f1)" == "$expected" ]]
        mkdir -p "$app/Contents/Helpers"
        install -m 755 "$reader" "$app/Contents/Helpers/NearpaneDesktopReader"
        /usr/bin/plutil -insert NearpaneDesktopReaderSHA256 -string "$expected" "$app/Contents/Info.plist"
    fi
    /usr/bin/codesign --force --sign - --identifier "org.nearpane.lab.$name" "$app"
    /usr/bin/codesign --verify --strict --deep "$app"
    destination="$apps_dir/$name.app"
    if [[ -e "$destination" ]]; then mv "$destination" "$stage/old-$name.app"; fi
    if ! mv "$app" "$destination"; then
        if [[ -e "$stage/old-$name.app" ]]; then mv "$stage/old-$name.app" "$destination"; fi
        exit 1
    fi
    /usr/bin/codesign --verify --strict --deep "$destination"
    shasum -a 256 "$destination/Contents/MacOS/$name"
done
printf '%s\n' "$apps_dir" > build/window-lab/apps-path.txt
