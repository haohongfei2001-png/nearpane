#!/bin/bash
# One checkout, fresh domain/SwiftPM caches, sandbox-enforced source isolation.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
run="$(mktemp -d "$PWD/build/standalone.XXXXXXXX")"
export NEARPANE_RUN_ID="${run##*.}"
source scripts/build-paths.sh
mkdir -p "$run/logs"
echo "Standalone evidence: $run/logs"
unset NEARPANE_RENDER_FIXTURES NEARPANE_FOUNDATION_ONLY NEARPANE_OFFLINE PACKAGE_RESOURCE_BUNDLE_PATH PACKAGE_RESOURCE_BUNDLE_URL
parent="$(dirname "$PWD")"
profile='(version 1)(allow default)(deny file-read* file-write* (subpath (param "SAYTILE")) (subpath (param "RIFTLET")) (subpath (param "PREVIOUS")) (subpath (param "SUPPORT_S")) (subpath (param "SUPPORT_R")) (subpath (param "SUPPORT_N")))'
sandbox=(/usr/bin/sandbox-exec -D "SAYTILE=$parent/saytile" -D "RIFTLET=$parent/Riftlet" -D "PREVIOUS=$PWD/.build"
  -D "SUPPORT_S=$HOME/Library/Application Support/Saytile" -D "SUPPORT_R=$HOME/Library/Application Support/Riftlet"
  -D "SUPPORT_N=$HOME/Library/Application Support/Nearpane")
# Offline compilation still uses Darwin IPC for the toolchain.
offline="$profile (deny network-outbound (remote tcp) (remote udp))"
isolated() {
  local policy="$1" name="$2"; shift 2
  if "${sandbox[@]}" -p "$policy" "$@" >"$run/logs/$name.log" 2>&1; then
    echo "$name passed"
  else
    tail -30 "$run/logs/$name.log" >&2; echo "Failed: $run/logs/$name.log" >&2; return 1
  fi
}
isolated "$offline" isolation /usr/bin/python3 - "$PWD/.build" "$parent/saytile" "$parent/Riftlet" <<'PY'
import os,sys
for path in sys.argv[1:]:
    try: os.listdir(path)
    except PermissionError: print("Read denied:", os.path.basename(path))
    except FileNotFoundError: print("Unavailable:", os.path.basename(path))
    else: raise SystemExit("Isolation failed: "+path)
PY
isolated "$offline" resolver-tests python3 -B scripts/test-dependencies.py
isolated "$offline" evidence-tests python3 -B scripts/test-native-acceptance.py
isolated "$offline" foundation env NEARPANE_FOUNDATION_ONLY=1 NEARPANE_OFFLINE=1 scripts/test.sh
test ! -e "$build_root/domain-cache-v1"
isolated "$profile" bootstrap python3 scripts/prepare-domains.py
for domain in saytile Riftlet; do
  /usr/bin/grep -Eq "/$domain@.+GitHub," "$run/logs/bootstrap.log"
done
isolated "$offline" integrated env NEARPANE_OFFLINE=1 scripts/test.sh
python3 - "$run/logs" <<'PYCOUNT'
import re,sys
from pathlib import Path
root=Path(sys.argv[1])
for name,minimum in (("foundation",49),("integrated",73)):
    log=(root/(name+".log")).read_text()
    summary=re.search(r"Test run with (\d+) tests in \d+ suites passed",log)
    if not summary or int(summary[1]) < minimum or re.search(r"Test .* skipped",log):
        sys.exit("Incomplete "+name+" suite")
    if name=="integrated" and not all("Suite "+s+" passed" in log for s in ["VoiceTests","TrayDomainTests","IntegratedHostTests"]):
        sys.exit("Missing integrated suites")
PYCOUNT
for configuration in debug release; do
  isolated "$offline" "$configuration" env NEARPANE_OFFLINE=1 scripts/build-app.sh "$configuration"
done
isolated "$offline" receipt-policy env NEARPANE_RECEIPT_TEST_BINARY="$run/products/debug/Nearpane.app/Contents/MacOS/NearpaneHost" python3 -B scripts/test-native-acceptance.py
scripts/verify-packages.py --deny-cache "$build_root" "$run"/products/{debug,release}/Nearpane.app >"$run/logs/packages.log"
/usr/bin/shasum -a 256 "$run"/logs/*.log "$run"/products/{debug,release}/Nearpane.app/Contents/MacOS/NearpaneHost >"$run/SHA256SUMS"
/usr/bin/grep 'Test run with' "$run"/logs/{foundation,integrated}.log
cat "$run/logs/bootstrap.log"
echo "Verified both packages and locked resources. Evidence: $run"
