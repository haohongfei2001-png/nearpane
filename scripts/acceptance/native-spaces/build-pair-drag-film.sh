#!/bin/bash
# Adds only the passive movie collector to an already-built private pair-pointer kit.
set -euo pipefail
cd "$(dirname "$0")/../../.."
kit="${1:?private pair-pointer kit required}"
[[ "$kit" == /private/tmp/nearpane-d01.* && -d "$kit" && ! -L "$kit" && "$(stat -f '%u:%Lp' "$kit")" == "$(id -u):700" ]]
[[ -x "$kit/observe" && -x "$kit/Field Notes.app/Contents/MacOS/FieldNotes" && ! -e "$kit/pair-drag-film" ]]
codesign --verify --strict '-R=identifier "net.example.nearpane.p2-observer" and anchor apple generic and certificate leaf[subject.OU] = "ZB9D4T66QB"' "$kit/observe"
src=scripts/acceptance/native-spaces
dest=$(mktemp -d "$kit/pair-film-build.XXXXXXXX")
trap 'rm -rf "$dest"' EXIT
xcrun clang -I Sources/CReadOnlySpaces/include -c Sources/CReadOnlySpaces/ReadOnlySpaces.c -o "$dest/reader.o"
xcrun swiftc -O -D PAIRED_OVERVIEW_TEST -D CARD_FILM -parse-as-library -Xcc -I -Xcc Sources/CReadOnlySpaces/include \
    -import-objc-header "$src/contract_members.h" "$src/pair-pointer-palette.swift" "$src/screen-presentation-clock.swift" \
    "$src/p2-document-physical.swift" "$src/paired-preview-palette.swift" "$src/paired-preview-overview.swift" \
    "$src/paired-card-film.swift" "$src/paired-card-apng.swift" "$src/pair-drag-film.swift" "$dest/reader.o" -o "$dest/film"
signer=$(PYTHONPATH=scripts python3 -c 'import candidate_signing as s; listing=s.gate.cmd("/usr/bin/security","find-identity","-v","-p","codesigning"); print(s.product_fingerprint(listing))')
codesign --force --sign "$signer" --options runtime --timestamp=none --identifier net.example.nearpane.pair-drag-film "$dest/film"
codesign --verify --strict '-R=identifier "net.example.nearpane.pair-drag-film" and anchor apple generic and certificate leaf[subject.OU] = "ZB9D4T66QB"' "$dest/film"
ln "$dest/film" "$kit/pair-drag-film"
