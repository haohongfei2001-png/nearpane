#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
prepare_only=0
if (( $# )); then
    [[ $# == 2 && "$1" == --prepare-in-place ]] || { echo "Usage: $0 [--prepare-in-place PRIVATE_WORK]" >&2; exit 2; }
    python3 -I -B - "$2" <<'PY'
from pathlib import Path
import os, sys
p = Path(sys.argv[1])
if (p.parent != Path("/private/tmp") or not p.name.startswith("nearpane-host-inplace.") or
        p != p.resolve(strict=True) or p.stat().st_uid != os.getuid() or p.stat().st_mode & 0o077):
    raise SystemExit("Expected a private in-place acceptance directory")
(p / "candidate").mkdir(mode=0o700)
PY
    prepare_only=1
    export NEARPANE_FROZEN_SOURCE=1 NEARPANE_CANDIDATE_OUTPUT="$2/candidate"
fi
# A receipt for an installed acceptance candidate must identify the compiled sources.
# Local development packages from an export or dirty tree stay buildable.
release_inputs=(Package.swift Engine/nearpane-window-engine Sources Resources Dependencies scripts engineering/window-lab docs/ALPHA-HELP.md ':(exclude)scripts/acceptance/native-spaces/**')
source_revision="$(git rev-parse HEAD 2>/dev/null || echo unversioned)"
source_state=modified
if [[ "$source_revision" != unversioned && -z "$(git status --porcelain --untracked-files=all -- "${release_inputs[@]}")" ]]; then
    source_state=clean
fi
check_candidate_source() {
    if [[ "$(git rev-parse HEAD 2>/dev/null || echo unversioned)" != "$source_revision" ||
          -n "$(git status --porcelain --untracked-files=all -- "${release_inputs[@]}" 2>/dev/null)" ]]; then
        source_state=modified
    fi
    if [[ "${NEARPANE_FROZEN_SOURCE:-0}" == 1 && "$source_state" != clean ]]; then
        echo "The candidate requires a clean, unchanged source revision." >&2
        return 1
    fi
}
check_candidate_source
if [[ -n "${NEARPANE_P0_DIAGNOSTIC_PUBLIC_KEY:-}" ]]; then
    python3 - <<'P0CHECK'
import base64,os,stat
from pathlib import Path
key=base64.b64decode(os.environ["NEARPANE_P0_DIAGNOSTIC_PUBLIC_KEY"],validate=True)
stage=Path(os.environ.get("NEARPANE_CANDIDATE_OUTPUT","."))
if not (len(key)==32 and os.environ.get("NEARPANE_FROZEN_SOURCE")=="1" and os.environ.get("NEARPANE_SIGNING_MODE","local")=="local"
        and stage.is_dir() and stage==stage.resolve() and stage.name=="candidate" and stage.parent.name.startswith("nearpane-p0-candidate.")
        and stage.parent.parent==Path("/private/tmp") and all(p.stat().st_uid==os.getuid() and not p.stat().st_mode & 0o077 for p in (stage,stage.parent))):
    raise SystemExit("Isolated P0 diagnostic candidates can only be staged in a private temporary candidate directory")
P0CHECK
fi
source scripts/build-paths.sh
base="$(mktemp -d /private/tmp/nearpane-candidate-base.XXXXXXXX)"
stage=""
clean_stages() {
    rm -rf -- "$base"
    if [[ -n "$stage" && ! -e "$stage/keep-for-recovery" ]]; then rm -rf -- "$stage"; fi
}
trap clean_stages EXIT
if (( prepare_only )); then
    scripts/build-app.sh release --prepare-candidate-base "$base"
else
    scripts/build-app.sh release --candidate-base "$base"
fi
app="$base/Nearpane.app"
scripts/acceptance/build-window-lab.sh "$app"
lab="$(cat build/window-lab/apps-path.txt)"
version=5.22
build_number=90
name="Nearpane.app"
signing_identity="${NEARPANE_LOCAL_SIGNING_IDENTITY:-installed-product}"
signing_arguments=(--identity "$signing_identity")
case "${NEARPANE_SIGNING_MODE:-local}" in
    local) ;;
    distribution) signing_arguments+=(--distribution) ;;
    *) echo "Unknown candidate signing mode" >&2; exit 1 ;;
esac
delivery="${NEARPANE_CANDIDATE_OUTPUT:-/Applications}"
if [[ -z "${NEARPANE_CANDIDATE_OUTPUT:-}" && ! -e /Applications/Nearpane.app &&
      ( -d "$HOME/Applications/Nearpane.app" || ! -w /Applications ) ]]; then
    delivery="$HOME/Applications"
fi
if [[ "${delivery%/}" == /Applications || "${delivery%/}" == "$HOME/Applications" ]]; then
    receipt="$product_root/candidate/package.json"
else
    receipt="$delivery/package.json"
fi
[[ ! -L "${delivery%/}" ]] || { echo "Installation directory is a symlink: $delivery" >&2; exit 1; }
mkdir -p "$delivery"
stage="$(mktemp -d "$delivery/.nearpane-stage.XXXXXXXX")"
candidate="$stage/$name"
ditto --norsrc --noextattr "$app" "$candidate"
/usr/bin/plutil -replace CFBundleIdentifier -string com.holdsnow.nearpane.alpha "$candidate/Contents/Info.plist"
/usr/bin/plutil -replace CFBundleName -string 'Nearpane Alpha' "$candidate/Contents/Info.plist"
services="$(/usr/bin/plutil -extract NSServices json -o - Resources/Info.plist)"
/usr/bin/plutil -insert NSServices -json "$services" "$candidate/Contents/Info.plist"
/usr/bin/plutil -replace NSServices.0.NSPortName -string "$(/usr/bin/plutil -extract CFBundleName raw "$candidate/Contents/Info.plist")" "$candidate/Contents/Info.plist"
/usr/bin/plutil -replace CFBundleShortVersionString -string "$version" "$candidate/Contents/Info.plist"
/usr/bin/plutil -replace CFBundleVersion -string "$build_number" "$candidate/Contents/Info.plist"
/usr/bin/plutil -replace NearpaneSourceRevision -string "$source_revision" "$candidate/Contents/Info.plist"
if [[ -n "${NEARPANE_P0_DIAGNOSTIC_PUBLIC_KEY:-}" ]]; then
    /usr/bin/plutil -insert NearpaneP0DiagnosticPublicKey -string "$NEARPANE_P0_DIAGNOSTIC_PUBLIC_KEY" "$candidate/Contents/Info.plist"
fi
/usr/bin/plutil -insert LSMultipleInstancesProhibited -bool true "$candidate/Contents/Info.plist"
for helper in NearpaneFrameController NearpaneFixtureWindows; do
    ditto --norsrc --noextattr "$lab/$helper.app" "$candidate/Contents/Helpers/$helper.app"
done
mkdir "$candidate/Contents/Resources/WorkRect"
cp scripts/window-management.py "$candidate/Contents/Resources/WorkRect/"
mkdir "$candidate/Contents/Resources/Profile"
install -m 644 scripts/profile-migration.py scripts/profile_domains.py "$candidate/Contents/Resources/Profile/"
install -m 644 docs/ALPHA-HELP.md "$candidate/Contents/Resources/AlphaHelp.md"
python3 -B scripts/build-helper-runtime.py "$candidate"
check_candidate_source
/usr/bin/plutil -replace NearpaneSourceState -string "$source_state" "$candidate/Contents/Info.plist"
codesign --force --sign - --entitlements Resources/NearpaneHost.entitlements --identifier com.holdsnow.nearpane.alpha "$candidate"
python3 -I -B scripts/candidate_signing.py "$candidate" "${signing_arguments[@]}"
codesign --verify --strict --deep "$candidate"
if (( prepare_only )); then
    python3 scripts/check-alpha-distribution.py "$candidate" --require-install-identity > "$stage/package.json"
    python3 -I -B - "$stage/package.json" <<'PY'
import json, sys
from pathlib import Path
p = Path(sys.argv[1])
report = json.loads(p.read_bytes())
report["inPlacePreparation"] = {"candidateExecutions": 0, "bundledResourcesSelfCheck": "NOT_RUN",
    "helperRuntimeSelfCheck": "NOT_RUN", "installedHostLaunch": "NOT_RUN"}
p.write_text(json.dumps(report, indent=2) + "\n")
PY
else
    "$candidate/Contents/MacOS/NearpaneHost" --verify-bundled-resources
    "$candidate/Contents/MacOS/NearpaneHost" --check-helper-runtime
    python3 scripts/check-alpha-distribution.py "$candidate" > "$stage/package.json"
fi
python3 -I -B scripts/publish-candidate.py "$candidate" "$delivery/$name" "$receipt"
