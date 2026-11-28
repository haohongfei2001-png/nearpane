#!/bin/bash
# Private staging only. No Launch Services registration, installation or UI.
set -euo pipefail
umask 077
cd "$(dirname "$0")/../../.."
stage="$(mktemp -d /private/tmp/nearpane-p0-candidate.XXXXXXXX)"
mkdir -m 700 "$stage/candidate"
src=scripts/acceptance/native-spaces
crypto="$(PYTHONPATH="$src" python3 -B -c 'from p0_diagnostic_issuer import openssl; print(openssl())')"
"$crypto" genpkey -algorithm ED25519 -out "$stage/issuer.pem"
public="$(PYTHONPATH="$src" python3 -B -c 'import base64,sys; from pathlib import Path; from p0_diagnostic_issuer import key_identity; print(base64.b64encode(key_identity(Path(sys.argv[1]))[1]).decode())' "$stage/issuer.pem")"
NEARPANE_P0_DIAGNOSTIC_PUBLIC_KEY="$public" NEARPANE_CANDIDATE_OUTPUT="$stage/candidate" NEARPANE_FROZEN_SOURCE=1 scripts/build-candidate.sh > "$stage/build.log" 2>&1 || { echo "Build failed: $stage/build.log" >&2; exit 1; }
/usr/bin/codesign --verify --strict --deep "$stage/candidate/Nearpane.app"
[[ "$(/usr/bin/plutil -extract NearpaneP0DiagnosticPublicKey raw -o - "$stage/candidate/Nearpane.app/Contents/Info.plist")" == "$public" ]]
echo "$stage"
