#!/bin/bash
# Build the optional shareable two-card capture after build-paired-preview.sh. No GUI.
set -euo pipefail
umask 077
cd "$(dirname "$0")/../../.."
kit=${1:?supply an existing private paired-preview kit}
src=scripts/acceptance/native-spaces
test -f "$kit/reader.o" && test -f "$kit/members.o"
test -f "$kit/paired-scope"
python3 - "$src" "$kit/paired-overview-scope.swift" <<'PY'
from pathlib import Path
import sys
src, out = map(Path, sys.argv[1:])
prelude = (src / 'observe.swift').read_text().split('if CommandLine.arguments.count > 1 {')[0]
census=src/'paired-preview-census.swift'
parts=[prelude]
if census.is_file():
    parts.append(census.read_text())
parts.extend((src/name).read_text() for name in ('paired-preview-overview-scope.swift','paired-preview-scope.swift'))
out.write_text('\n'.join(parts))
PY
flags=(-D NATIVE_CONTRACT -D PAIRED_OVERVIEW -Xcc -I -Xcc Sources/CReadOnlySpaces/include -import-objc-header "$src/contract_members.h")
xcrun swiftc "${flags[@]}" "$kit/paired-overview-scope.swift" "$kit/reader.o" "$kit/members.o" -framework ColorSync -o "$kit/paired-overview-scope"
xcrun swiftc -parse-as-library "$src/paired-preview-palette.swift" "$src/paired-preview-overview.swift" -o "$kit/paired-overview"
codesign --verify --strict "$kit/paired-overview-scope"
codesign --verify --strict "$kit/paired-overview"
