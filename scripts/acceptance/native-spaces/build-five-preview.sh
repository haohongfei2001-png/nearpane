#!/bin/bash
# Builds a private five-app fixture kit from source; does not launch any GUI.
set -euo pipefail
umask 077
cd "$(dirname "$0")/../../.."
src=scripts/acceptance/native-spaces
kit="${1:-$(mktemp -d /private/tmp/nearpane-d01.five.XXXXXXXX)}"
[[ "$kit" == /private/tmp/nearpane-d01.* && -d "$kit" && ! -L "$kit" &&
    $(stat -f '%u:%Lp' "$kit") == "$(id -u):700" && -z $(ls -A "$kit") ]]
mkdir "$kit/work"
inc=Sources/CReadOnlySpaces/include
xcrun clang -Wall -Wextra -Werror "$src/textedit_process.c" -o "$kit/process-generation"
xcrun clang -I"$inc" -c Sources/CReadOnlySpaces/ReadOnlySpaces.c -o "$kit/work/reader.o"
xcrun clang -I"$inc" -fobjc-arc -DNEARPANE_CONTRACT_MEMBERS -c scripts/acceptance/secondary-occupancy.m -o "$kit/work/members.o"
flags=(-D NATIVE_CONTRACT -Xcc -I -Xcc "$inc" -import-objc-header "$src/contract_members.h")
link=("$kit/work/reader.o" "$kit/work/members.o" -framework ColorSync)
cp "$src/window.swift" "$kit/work/main.swift"
xcrun swiftc -D FIVE_PREVIEW "$kit/work/main.swift" "$src/paired-preview-palette.swift" "$src/five-preview-window.swift" -o "$kit/work/FiveNotes"
python3 - "$src" "$kit" <<'PY'
from pathlib import Path
import plistlib, shutil, sys
src,kit=map(Path,sys.argv[1:])
def before(name, sentinel):
    data=(src/name).read_text()
    assert data.count(sentinel)==1, name + " source boundary changed"
    return data.split(sentinel)[0]
# Reuse the existing exact Host AX binding, 8x8 BGRA majority classifier and physical filter checks.
scope=before("observe.swift","if CommandLine.arguments.count > 1 {")+"\n"+before("paired-preview-scope.swift","func pairedPreviewProof(")
(kit/"work/main.swift").write_text(scope+"\n"+(src/"five-preview-read.swift").read_text())
capture=before("paired-preview-capture.swift","@main struct PairedCapture")
(kit/"work/capture.swift").write_text(capture+"\n"+(src/"five-preview-capture.swift").read_text())
for slot in range(1,6):
    name=f"Five Notes {slot}"
    app=kit/(name+".app")/"Contents"
    (app/"MacOS").mkdir(parents=True)
    plist=plistlib.loads((src/"fixture.plist").read_bytes())
    plist.update(CFBundleIdentifier=f"net.example.nearpane-five-preview.{slot}",CFBundleName=name,CFBundleExecutable="FiveNotes")
    (app/"Info.plist").write_bytes(plistlib.dumps(plist))
    shutil.copy2(kit/"work/FiveNotes",app/"MacOS/FiveNotes")
PY
for i in {1..5}; do
    app="$kit/Five Notes $i.app"
    codesign --force --sign - --identifier net.example.nearpane-five-preview."$i" "$app"
    codesign --verify --strict "-R=identifier \"net.example.nearpane-five-preview.$i\"" "$app"
done
xcrun swiftc "${flags[@]}" "$kit/work/main.swift" "$src/five-preview-model.swift" "$src/paired-preview-census.swift" "$src/split-fixture-identity.swift" "${link[@]}" -o "$kit/five-scope"
xcrun swiftc -O "${flags[@]}" -parse-as-library "$kit/work/capture.swift" "$src/five-preview-model.swift" "$src/paired-preview-census.swift" "$src/paired-preview-palette.swift" "${link[@]}" -o "$kit/five-capture"
codesign --verify --strict "$kit/process-generation"
codesign --verify --strict "$kit/five-scope"
codesign --verify --strict "$kit/five-capture"
printf '%s\n' "$kit"
