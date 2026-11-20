#!/bin/bash
# Builds the isolated Field Notes pair and read-only, four-patch sampler. Launches no apps.
set -euo pipefail
umask 077
cd "$(dirname "$0")/../../.."
src=scripts/acceptance/native-spaces
kit="${1:-$(mktemp -d /private/tmp/nearpane-d01.preview.XXXXXXXX)}"
if [[ ${2:-} == --refresh-copied-kit ]]; then
  [[ $kit == /private/tmp/nearpane-d01.* && -d $kit && ! -L $kit && $(stat -f '%u:%Lp' "$kit") == "$(id -u):700" ]]
  [[ -f $kit/reader.o && -f $kit/members.o && -d "$kit/Field Notes.app" ]]
else
  "$src/build-contract.sh" "$kit"
fi
mkdir -p "$kit/paired-fixture"
cp "$src/window.swift" "$kit/paired-fixture/main.swift"
xcrun swiftc -D PAIRED_PREVIEW "$kit/paired-fixture/main.swift" "$src/paired-preview-palette.swift" -o "$kit/Field Notes.app/Contents/MacOS/FieldNotes"
codesign --force --sign - --identifier net.example.spaces-document "$kit/Field Notes.app"
python3 - "$kit/paired-scope.swift" "$kit/preview-surface.swift" <<'PY'
from pathlib import Path
import sys
src=Path('scripts/acceptance/native-spaces')
prelude=(src/'observe.swift').read_text().split('if CommandLine.arguments.count > 1 {')[0]
prelude+='\n'+(src/'paired-preview-census.swift').read_text()
Path(sys.argv[1]).write_text(prelude+'\n'+(src/'paired-preview-scope.swift').read_text())
Path(sys.argv[2]).write_text(prelude+'\n'+(src/'preview-surface.swift').read_text())
PY
flags=(-D NATIVE_CONTRACT -Xcc -I -Xcc Sources/CReadOnlySpaces/include -import-objc-header "$src/contract_members.h")
link=("$kit/reader.o" "$kit/members.o" -framework ColorSync)
xcrun swiftc "${flags[@]}" "$kit/paired-scope.swift" "${link[@]}" -o "$kit/paired-scope"
xcrun swiftc "${flags[@]}" "$kit/preview-surface.swift" "${link[@]}" -o "$kit/preview-surface"
xcrun swiftc -O "${flags[@]}" -parse-as-library "$src/paired-preview-census.swift" "$src/paired-preview-palette.swift" "$src/screen-presentation-clock.swift" "$src/paired-preview-streams.swift" "$src/paired-preview-capture.swift" "${link[@]}" -o "$kit/paired-capture"
xcrun swiftc "${flags[@]}" "$src/preview-stage-control.swift" "${link[@]}" -o "$kit/preview-stage-control"
codesign --verify --strict "$kit/Field Notes.app"
for tool in "$kit/paired-scope" "$kit/paired-capture" "$kit/preview-stage-control" "$kit/preview-surface"; do codesign --verify --strict "$tool"; done
xcrun swiftc "${flags[@]}" -parse-as-library "$src/paired-preview-census.swift" "$src/paired-preview-census-checks.swift" "${link[@]}" -o "$kit/paired-census-checks"
codesign --verify --strict "$kit/paired-census-checks"
"$kit/paired-census-checks" "$kit"
"$kit/paired-capture" --stream-self-test
bash "$src/build-preview-selector.sh" "$kit"
printf '%s\n' "$kit"
