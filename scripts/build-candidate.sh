#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# A receipt for an installed acceptance candidate must identify the compiled sources.
# Local development packages from an export or dirty tree stay buildable.
release_inputs=(Package.swift Sources Resources Dependencies scripts engineering/window-lab docs/ALPHA-HELP.md ':(exclude)scripts/acceptance/native-spaces/**')
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
scripts/build-app.sh release
source scripts/build-paths.sh
app="$product_root/release/Nearpane.app"
scripts/acceptance/build-window-lab.sh "$app"
lab="$(cat build/window-lab/apps-path.txt)"
version=5.21
build_number=86
name="Nearpane P$version Alpha.app"
delivery="${NEARPANE_CANDIDATE_OUTPUT:-/Applications}"
if [[ -z "${NEARPANE_CANDIDATE_OUTPUT:-}" && ! -e /Applications/Nearpane.app &&
      ( -d "$HOME/Applications/Nearpane.app" || ! -w /Applications ) ]]; then
    delivery="$HOME/Applications"
fi
if [[ "${delivery%/}" == /Applications || "${delivery%/}" == "$HOME/Applications" ]]; then
    name="Nearpane.app"
    receipt="$product_root/candidate/package.json"
else
    receipt="$delivery/package.json"
fi
[[ ! -L "${delivery%/}" ]] || { echo "Installation directory is a symlink: $delivery" >&2; exit 1; }
mkdir -p "$delivery"
stage="$(mktemp -d "$delivery/.nearpane-stage.XXXXXXXX")"
trap 'if [[ ! -e "$stage/keep-for-recovery" ]]; then rm -rf "$stage"; fi' EXIT
candidate="$stage/$name"
ditto --norsrc --noextattr "$app" "$candidate"
/usr/bin/plutil -replace CFBundleIdentifier -string com.holdsnow.nearpane.alpha "$candidate/Contents/Info.plist"
/usr/bin/plutil -replace CFBundleName -string 'Nearpane Alpha' "$candidate/Contents/Info.plist"
/usr/bin/plutil -replace CFBundleShortVersionString -string "$version" "$candidate/Contents/Info.plist"
/usr/bin/plutil -replace CFBundleVersion -string "$build_number" "$candidate/Contents/Info.plist"
/usr/bin/plutil -replace NearpaneSourceRevision -string "$source_revision" "$candidate/Contents/Info.plist"
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
codesign --force --sign - --identifier com.holdsnow.nearpane.alpha "$candidate"
if [[ -n "${NEARPANE_LOCAL_SIGNING_IDENTITY:-}" ]]; then
    python3 -I -B scripts/candidate_signing.py "$candidate" --identity "$NEARPANE_LOCAL_SIGNING_IDENTITY"
fi
codesign --verify --strict --deep "$candidate"
"$candidate/Contents/MacOS/NearpaneHost" --verify-bundled-resources
"$candidate/Contents/MacOS/NearpaneHost" --check-helper-runtime
python3 scripts/check-alpha-distribution.py "$candidate" > "$stage/package.json"
python3 -I -B scripts/publish-candidate.py "$candidate" "$delivery/$name" "$receipt"
