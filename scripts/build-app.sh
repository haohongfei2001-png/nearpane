#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/build-paths.sh
NEARPANE_ENGINE_ARCHIVE="$(bash scripts/build-window-engine.sh)"
export NEARPANE_ENGINE_ARCHIVE
python3 scripts/prepare-domains.py
if [ "${NEARPANE_FOUNDATION_ONLY:-0}" != 1 ]; then
  python3 scripts/prepare-update-runtime.py
fi
configuration="${1:-debug}"
case "$configuration" in debug|release) ;; *) echo "Usage: $0 [debug|release]" >&2; exit 2 ;; esac
candidate_dir=""
if (( $# > 1 )); then
  [[ $# == 3 && "$configuration" == release && "$2" == --candidate-base && -d "$3" && ! -L "$3" && ! -e "$3/Nearpane.app" ]] ||
    { echo "Usage: $0 release --candidate-base EMPTY_DIRECTORY" >&2; exit 2; }
  candidate_dir="$(cd "$3" && pwd -P)"
fi
scratch="$build_root/app-native"
if [ "${NEARPANE_FOUNDATION_ONLY:-0}" = 1 ]; then scratch="$build_root/foundation-app-native"; fi
compile=(swift build --build-system native -c "$configuration")
if [[ -n "${NEARPANE_P0_DIAGNOSTIC_PUBLIC_KEY:-}" ]]; then
  [[ -n "$candidate_dir" && "${NEARPANE_FROZEN_SOURCE:-0}" == 1 && "${NEARPANE_FOUNDATION_ONLY:-0}" != 1 ]] ||
    { echo "A diagnostic build requires the private frozen full-candidate staging entry" >&2; exit 2; }
  compile+=(-Xswiftc -DNEARPANE_P0_DIAGNOSTIC -Xcc -DNEARPANE_P0_DIAGNOSTIC=1)
  scratch="$build_root/p0-diagnostic-app-native"
fi
compile+=(--disable-sandbox --scratch-path "$scratch" --cache-path "$build_root/cache"
          --config-path "$build_root/config" --security-path "$build_root/security")
"${compile[@]}"
binary_dir="$("${compile[@]}" --show-bin-path)"
destination="$product_root/$configuration"
if [ "${NEARPANE_FOUNDATION_ONLY:-0}" = 1 ]; then destination="$product_root/foundation/$configuration"; fi
if [[ -n "$candidate_dir" ]]; then destination="$candidate_dir"; fi
bundle="$destination/Nearpane.app"
mkdir -p "$destination"
# The compiler supplies the local executable signature. Distribution bundle signing
# is a P6 concern; File Provider metadata on this worktree prevents a durable bundle seal.
/usr/bin/codesign --verify --strict "$binary_dir/NearpaneHost"
# A fresh stage avoids carrying old resources/signatures into a development bundle.
staging_dir="$(mktemp -d "$(cd "$destination" && pwd -P)/.Nearpane-stage.XXXXXX")"
trap 'rm -rf "$staging_dir"' EXIT
stage="$staging_dir/Nearpane.app"
mkdir -p "$stage/Contents/MacOS" "$stage/Contents/Resources"
cp "$binary_dir/NearpaneHost" "$stage/Contents/MacOS/NearpaneHost"
cp Resources/Info.plist "$stage/Contents/Info.plist"
mkdir -p "$stage/Contents/Resources/Upstream/window-engine"
cp Engine/nearpane-window-engine/LICENSE.upstream "$stage/Contents/Resources/Upstream/window-engine/LICENSE"
cp Engine/nearpane-window-engine/upstream.json "$stage/Contents/Resources/Upstream/window-engine/source.json"
cp -R Engine/nearpane-window-engine/origins "$stage/Contents/Resources/Upstream/window-engine/"
/usr/bin/plutil -insert NearpaneStageEngineABI -integer 1 "$stage/Contents/Info.plist"
if [[ -n "$candidate_dir" ]]; then
  # The packaging intermediate is a different bundle identifier. Only the signed candidate advertises this Service.
  /usr/bin/plutil -remove NSServices "$stage/Contents/Info.plist"
fi
python3 scripts/prepare-app-icon.py --embed "$stage"
# The ordinary catalog remains a separately verified, read-only executable.
reader="$binary_dir/NearpaneDesktopReader"
/usr/bin/codesign --verify --strict "$reader"
mkdir -p "$stage/Contents/Helpers"
install -m 755 "$reader" "$stage/Contents/Helpers/NearpaneDesktopReader"
/usr/bin/plutil -insert NearpaneDesktopReaderSHA256 -string "$(shasum -a 256 "$reader" | cut -d ' ' -f1)" "$stage/Contents/Info.plist"
"$stage/Contents/Helpers/NearpaneDesktopReader" --self-check
action="$binary_dir/NearpaneSpaceAction"
/usr/bin/codesign --verify --strict "$action"
install -m 755 "$action" "$stage/Contents/Helpers/NearpaneSpaceAction"
/usr/bin/plutil -insert NearpaneSpaceActionSHA256 -string "$(shasum -a 256 "$action" | cut -d ' ' -f1)" "$stage/Contents/Info.plist"
cp -R Resources/Upstream/NativeSpaceActions "$stage/Contents/Resources/"
"$stage/Contents/Helpers/NearpaneSpaceAction" --self-check
ordinary="$binary_dir/NearpaneOrdinaryWindowController"
/usr/bin/codesign --verify --strict "$ordinary"
install -m 755 "$ordinary" "$stage/Contents/Helpers/NearpaneOrdinaryWindowController"
/usr/bin/plutil -insert NearpaneOrdinaryWindowControllerSHA256 -string "$(shasum -a 256 "$ordinary" | cut -d ' ' -f1)" "$stage/Contents/Info.plist"
guardian="$stage/Contents/Helpers/NearpaneCornerGuardian"
bash scripts/acceptance/window-engine/corner/build-guardian.sh "$guardian" "$NEARPANE_ENGINE_ARCHIVE"
/usr/bin/codesign --force --sign - --timestamp=none --options runtime --identifier com.holdsnow.nearpane.alpha.corner-guardian "$guardian"
/usr/bin/codesign --verify --strict "$guardian"
/usr/bin/plutil -insert NearpaneCornerGuardianSHA256 -string "$(shasum -a 256 "$guardian" | cut -d ' ' -f1)" "$stage/Contents/Info.plist"
if [ "${NEARPANE_FOUNDATION_ONLY:-0}" = 1 ]; then
  /usr/bin/plutil -replace LSMinimumSystemVersion -string 14.0 "$stage/Contents/Info.plist"
  for usage in NearpaneNativeAcceptanceSchema NSMicrophoneUsageDescription NSSpeechRecognitionUsageDescription NSAppleEventsUsageDescription; do
    /usr/bin/plutil -remove "$usage" "$stage/Contents/Info.plist"
  done
else
  resources="$stage/Contents/Resources"
  cp Resources/AcceptanceTargetGuard.js "$resources/"
  /usr/bin/plutil -insert NearpaneDraftGuardSHA256 -string "$(shasum -a 256 "$resources/AcceptanceTargetGuard.js" | cut -d ' ' -f1)" "$stage/Contents/Info.plist"
  # Native SwiftPM produces flat resource directories and does not attempt to sign
  # File Provider metadata. Construct the layout required by the original .app loaders.
  install_resources() {
    local module="$1" bundle_name="$2"
    local input="$binary_dir/Nearpane_$module.bundle" dest="$resources/$bundle_name.bundle/Contents"
    mkdir -p "$dest/Resources"
    cp -R "$input/." "$dest/Resources/"
    /usr/bin/plutil -create xml1 "$dest/Info.plist"
    /usr/bin/plutil -insert CFBundlePackageType -string BNDL "$dest/Info.plist"
    /usr/bin/plutil -insert CFBundleIdentifier -string "com.holdsnow.nearpane.resources.$module" "$dest/Info.plist"
  }
  install_resources SaytileKit Nearpane_SaytileKit
  install_resources RiftletAdapters Riftlet_RiftletAdapters
  # Saytile first asks the main bundle. This also prevents its SwiftPM development fallback from being used.
  ln -s Nearpane_SaytileKit.bundle/Contents/Resources/LocalASR "$resources/LocalASR"
  ln -s Nearpane_SaytileKit.bundle/Contents/Resources/ConnectionSample.pcm "$resources/ConnectionSample.pcm"
  python3 scripts/prepare-domains.py --package-resources "$resources"
  cmp "$binary_dir/NearpaneHost" "$stage/Contents/MacOS/NearpaneHost"
  python3 scripts/prepare-update-runtime.py --embed "$stage" --sign-development
  # Removing development-only runpaths changes the load commands. Sign that exact
  # standalone image, then put it back for the later candidate bundle seal.
  cp "$stage/Contents/MacOS/NearpaneHost" "$staging_dir/NearpaneHost"
  /usr/bin/codesign --force --sign - --identifier com.holdsnow.nearpane.host "$staging_dir/NearpaneHost"
  mv "$staging_dir/NearpaneHost" "$stage/Contents/MacOS/NearpaneHost"
fi
/usr/bin/plutil -lint "$stage/Contents/Info.plist"
"$stage/Contents/MacOS/NearpaneHost" --verify-bundled-resources
# After an exchange the stage holds the former bundle. Only the publisher may dispose of it.
trap - EXIT
python3 - "$stage" "$bundle" <<'PY'
import ctypes
import fcntl
import os
from pathlib import Path
import plistlib
import shutil
import stat
import subprocess
import sys

stage, product = (Path(p).absolute() for p in sys.argv[1:])
new = stage.stat()

def entries(folder):
    return {path.relative_to(folder): stat.S_IFMT(path.lstat().st_mode) for path in folder.rglob("*")}

def verify_previous():
    if product.is_symlink() or not product.is_dir():
        raise SystemExit(f"Unexpected build output at {product}; preserved.")
    expected = entries(stage)
    previous = entries(product)
    # The previous signed domain profile included a second Saytile notice for
    # its three-source overlay. The full release has a single source notice.
    retired = Path("Contents/Resources/Upstream/saytile/updates")
    for path, kind in previous.items():
        if path == retired and kind == stat.S_IFDIR:
            continue
        if path == retired / "THIRD_PARTY_NOTICES.md" and kind == stat.S_IFREG:
            import hashlib
            if hashlib.sha256((product / path).read_bytes()).hexdigest() == '3c79110e5716c60355be23f357b36715a434437a53fabb2e54b052c5fccb8cdf':
                continue
        if (expected.get(path) != kind or kind not in (stat.S_IFREG, stat.S_IFDIR, stat.S_IFLNK)
                or (kind == stat.S_IFLNK and os.readlink(product / path) != os.readlink(stage / path))):
            raise SystemExit(f"Unexpected entry in prior development build: {path}; preserved.")
    info = plistlib.loads((product / "Contents/Info.plist").read_bytes())
    if (info.get("CFBundleIdentifier"), info.get("CFBundleExecutable")) != ("com.holdsnow.nearpane.host", "NearpaneHost"):
        raise SystemExit(f"Unrecognized development bundle at {product}; preserved.")
    executables = [product / path for path, kind in previous.items()
                   if kind == stat.S_IFREG and os.access(product / path, os.X_OK)]
    if not executables:
        raise SystemExit(f"Missing executable in prior development bundle at {product}; preserved.")
    users = subprocess.run(["/usr/sbin/lsof", "-nP", "-t", "-d", "txt", "-a", "--", *executables],
                           capture_output=True)
    if users.stdout or users.stderr or users.returncode != 1:
        raise SystemExit(f"Prior development bundle is running or its use could not be checked: {product}")

# Darwin swaps nonempty directories atomically. A failed publish leaves the original at its path.
def rename(flag):
    darwin = ctypes.CDLL(None, use_errno=True)
    if darwin.renamex_np(os.fsencode(stage), os.fsencode(product), flag) != 0:
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error), str(product))

directory = os.open(product.parent, os.O_RDONLY | os.O_DIRECTORY)
try:
    fcntl.flock(directory, fcntl.LOCK_EX)
    if os.path.lexists(product):
        verify_previous()
        rename(0x2)  # RENAME_SWAP
        shutil.rmtree(stage)
    else:
        rename(0x4)  # RENAME_EXCL
finally:
    os.close(directory)
    if stage.exists() and os.path.samestat(stage.lstat(), new):
        shutil.rmtree(stage)
    if not os.path.lexists(stage):
        stage.parent.rmdir()
PY
echo "Built $bundle (development executable signature and offline resources verified; no GUI launch)."
