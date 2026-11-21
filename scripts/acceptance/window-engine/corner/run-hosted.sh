#!/bin/bash
# Build-only is safe on a developer login. The running fixture independently requires a
# disposable console, limits input to its own enrolled windows and never writes a preference.
set -euo pipefail
umask 077
cd "$(dirname "$0")/../../../.."
out=${1:?new receipt directory required}
mode=${2:-run}
case "$mode" in run|--build-only) ;; *) exit 2;; esac
mkdir -m 700 "$out"
out=$(cd "$out" && pwd -P)
export NP_CORNER_RECEIPTS="$out"
write_result() { python3 - "$1" "$2" <<'PY'
import json,os,sys
from pathlib import Path
p=Path(os.environ['NP_CORNER_RECEIPTS'])/'result.json'
if not p.exists():
    p.write_text(json.dumps(dict(schema=1,status=sys.argv[1],reason=sys.argv[2],qualification="UNQUALIFIED",ten=0,fifty=0,
                                officialInstalledHost="NOT_RUN",physicalMultiDisplay="NOT_RUN"),indent=2)+'\n')
PY
}
trap 'write_result UNKNOWN fixtureBuildOrTransportError' ERR
if [[ "$mode" = run ]]; then
    if [[ ! ( "$(id -un)" == runner && "${GITHUB_ACTIONS:-}" == true && "${RUNNER_ENVIRONMENT:-}" == github-hosted ) &&
          ! ( "$(id -un)" == nearpane-fixture-* && "${NP_DISPOSABLE_CORNER_LOGIN:-}" == "$(id -un)" ) ]]; then
        write_result BLOCKED disposableWindowServerLoginRequired
        exit 0
    fi
fi
rustdir=build/window-engine/toolchain/portable/bin
if ! command -v cargo >/dev/null && [[ -x "$rustdir/cargo" ]]; then export PATH="$PWD/$rustdir:$PATH"; fi
kit=$(mktemp -d "${TMPDIR:-/private/tmp}/nearpane-engine-corner.XXXXXXXX")
trap 'rm -rf "$kit"' EXIT
src=scripts/acceptance/window-engine/corner
manifest=Engine/nearpane-window-engine/Cargo.toml
cargo build --locked --offline --manifest-path "$manifest" --target-dir "$kit/target" --release --features corner,isolated-fixtures > "$out/build.log" 2>&1
xcrun clang -fobjc-arc -O2 -Wall -Wextra -Werror "$src/owner.m" -framework AppKit -framework Foundation -o "$kit/owner"
xcrun clang -fobjc-arc -O2 -Wall -Wextra -Werror -I Engine/nearpane-window-engine/include "$src/trial.m" \
 "$kit/target/release/libnearpane_window_engine.a" -framework AppKit -framework Foundation \
 -framework CoreFoundation -framework CoreGraphics -framework ApplicationServices -framework Security -framework Carbon -o "$kit/controller"
for name in a b; do
    app="$kit/Fixture$name.app"
    mkdir -p "$app/Contents/MacOS"
    cp "$kit/owner" "$app/Contents/MacOS/Owner"
    python3 - "$app" "$name" <<'PY'
import plistlib,sys
from pathlib import Path
(Path(sys.argv[1])/'Contents/Info.plist').write_bytes(plistlib.dumps(dict(CFBundleIdentifier='com.holdsnow.nearpane.engine-fixture.'+sys.argv[2],
    CFBundleName='Nearpane Corner Fixture '+sys.argv[2],CFBundleExecutable='Owner',CFBundlePackageType='APPL',CFBundleVersion='1',NSHighResolutionCapable=True,
    NSPrincipalClass='NSApplication',LSUIElement=False,LSMinimumSystemVersion='14.0')))
PY
    codesign --force --options runtime --timestamp=none --sign - "$app" >> "$out/build.log" 2>&1
    codesign --verify --deep --strict "$app"
done
codesign --force --options runtime --timestamp=none --identifier com.holdsnow.nearpane.engine-fixture --sign - "$kit/controller" >> "$out/build.log" 2>&1
codesign --verify --strict "$kit/controller"
{
    for bin in "$kit/controller" "$kit/Fixturea.app" "$kit/Fixtureb.app"; do
        codesign -d -vvv "$bin" 2>&1 | sed -n -E '/^(Identifier|CDHash|Signature|TeamIdentifier)=/p'
    done
    uname -m; /usr/bin/sw_vers -productVersion; /usr/bin/sw_vers -buildVersion; git rev-parse HEAD
} > "$out/signatures.txt"
if [[ "$mode" == --build-only ]]; then
    write_result NOT_RUN signedFixtureBuiltWithoutOpeningSession
else
    "$kit/controller" "$kit" "$out"
    test -s "$out/result.json"
fi
