#!/bin/bash
# Private Developer ID fixtures and a metadata-only system witness. No application launch.
set -euo pipefail
umask 077
cd "$(dirname "$0")/../../.."
src=scripts/acceptance/native-spaces
kit="${1:-$(mktemp -d /private/tmp/nearpane-d01.cross-pair.XXXXXXXX)}"
[[ "$kit" == /private/tmp/nearpane-d01.* && -d "$kit" && ! -L "$kit" &&
   "$(stat -f '%u:%Lp' "$kit")" == "$(id -u):700" && -z "$(ls -A "$kit")" ]]
mkdir -p "$kit/work/fixture" "$kit/work/witness"
inc=Sources/CReadOnlySpaces/include
signer=$(PYTHONPATH=scripts python3 -c 'import candidate_signing as s; print(s.product_fingerprint(s.gate.cmd("/usr/bin/security","find-identity","-v","-p","codesigning")))')
sign() { codesign --force --options runtime --timestamp=none --identifier "$2" --sign "$signer" "$1"; codesign --verify --strict --deep "-R=anchor apple generic and identifier \"$2\" and certificate leaf[subject.OU] = \"ZB9D4T66QB\" and certificate leaf[field.1.2.840.113635.100.6.1.13] exists" "$1"; }
python3 - "$src" "$kit" <<'PY'
from pathlib import Path
import sys,plistlib
src,kit=map(Path,sys.argv[1:])
def prefix(name, boundary):
    raw=(src/name).read_text()
    if raw.count(boundary)!=1:raise ValueError(name+" source boundary changed")
    return raw.split(boundary)[0]
# Compile the unchanged card/AX-parent, stacking, cursor and isolated-lock checks used by the single-app trial.
witness=prefix("observe.swift","if CommandLine.arguments.count > 1 {")+prefix("pair-pointer-post.swift","func pairLeaseState(")+prefix("pair-pointer.swift","func pairPointer(kind:")
(kit/"work/witness/main.swift").write_text(witness+(src/"cross-app-pair.swift").read_text())
raw=(src/"window.swift").read_text()
enter='if presentation == "contract" || presentation == "contract-split" || presentation == "roster-cycle" || presentation == "five-preview" {'
if raw.count(enter)!=1:raise ValueError("five-window fixture presentation boundary changed")
guard='''guard let bytes = try? Data(contentsOf: run.appendingPathComponent("launch.json")),
                  let ticket = try? JSONDecoder().decode(P2LaunchPresentation.self, from: bytes),
                  ticket.allows(now: ProcessInfo.processInfo.systemUptime, hid: p2Physical(),
                     front: NSWorkspace.shared.frontmostApplication?.processIdentifier, fixture: getpid(),
                     mouseDown: NSEvent.pressedMouseButtons != 0, session: session)
            else { app.terminate(nil); return }'''
(kit/"work/fixture/main.swift").write_text(raw.replace(enter,enter+'\n            '+guard))
for slot in (1,2):
    name=f"Five Notes {slot}"
    bundle=kit/(name+".app")/"Contents"
    (bundle/"MacOS").mkdir(parents=True)
    info=plistlib.loads((src/"fixture.plist").read_bytes())
    info.update(CFBundleIdentifier=f"net.example.nearpane-five-preview.{slot}",CFBundleName=name,CFBundleExecutable="FiveNotes")
    (bundle/"Info.plist").write_bytes(plistlib.dumps(info))
PY
xcrun swiftc -D FIVE_PREVIEW "$kit/work/fixture/main.swift" "$src/paired-preview-palette.swift" "$src/five-preview-window.swift" "$src/p2-document-physical.swift" -o "$kit/work/FiveNotes"
for i in 1 2; do
    app="$kit/Five Notes $i.app"; cp "$kit/work/FiveNotes" "$app/Contents/MacOS/FiveNotes"
    sign "$app" "net.example.nearpane-five-preview.$i"
done
xcrun clang -I"$inc" -c Sources/CReadOnlySpaces/ReadOnlySpaces.c -o "$kit/work/reader.o"
xcrun clang -I"$inc" -fobjc-arc -DNEARPANE_CONTRACT_MEMBERS -c scripts/acceptance/secondary-occupancy.m -o "$kit/work/members.o"
xcrun swiftc -D NATIVE_CONTRACT -Xcc -I -Xcc "$inc" -import-objc-header "$src/contract_members.h" "$kit/work/witness/main.swift" \
  "$src/five-preview-model.swift" "$src/paired-preview-census.swift" "$src/split-fixture-identity.swift" "$src/p2-document-physical.swift" \
  "$src/pair-pointer-motion.swift" "$src/pair-pointer-receiver.swift" "$src/pair-pointer-cursor.swift" Sources/NearpaneCore/AXWindowList.swift \
  "$kit/work/reader.o" "$kit/work/members.o" -framework ColorSync -o "$kit/cross-pointer"
sign "$kit/cross-pointer" net.example.nearpane.p2-cross-pointer
xcrun clang -Wall -Wextra -Werror "$src/textedit_process.c" -o "$kit/process-generation"
sign "$kit/process-generation" net.example.nearpane.p2-cross-process
echo "$kit"
