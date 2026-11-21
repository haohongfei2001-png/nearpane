#!/bin/bash
# Build a distinct Developer ID app. Only the explicit physical mode opens the signed bundle through Launch Services.
set -euo pipefail
umask 077
mode=run
readonly_canary=0
if [[ "${1:-}" == --preflight ]]; then readonly_canary=1; shift; fi
if [[ "${1:-}" == --build-only ]]; then mode=build; shift; fi
if [[ "${1:-}" == --prepared ]]; then mode=prepared; kit=${2:?prepared private kit}; shift 2; fi
out=${1:?fresh receipt directory}; route=${2:-bridged}
[[ "$route" == bridged || "$route" == classic ]] || exit 64
[[ ! -e "$out" ]] || { echo 'A fresh output directory is required.' >&2; exit 2; }
mkdir -m 700 -p "$out"
out=$(cd "$out" && pwd -P)
src=$(cd "$(dirname "$0")" && pwd -P)
engine=$(cd "$src/../../../../Engine/nearpane-window-engine/src/spaces" && pwd -P)
if [[ "$mode" != prepared ]]; then
    kit=$(mktemp -d /private/tmp/nearpane-spaces-canary.XXXXXXXX)
    app="$kit/Spaces Launch Canary.app"
    mkdir -p "$app/Contents/MacOS"
    cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.holdsnow.nearpane.spaces-launch-canary</string>
<key>CFBundleName</key><string>Spaces Launch Canary</string>
<key>CFBundleExecutable</key><string>Canary</string><key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string><key>LSUIElement</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
    xcrun clang -fobjc-arc -Wall -Wextra -Werror -DNP_BUILD_EXACT_CANARY_TOOL=1 -I "$engine" \
        "$src/physical-canary.m" "$engine/platform.m" -framework Foundation -framework AppKit \
        -framework CoreGraphics -framework ApplicationServices -framework Security -o "$app/Contents/MacOS/Canary"
    identity=$(/usr/bin/security find-identity -v -p codesigning | awk '/Developer ID Application:/ && /\(ZB9D4T66QB\)/ {print $2}')
    if [[ -z "$identity" || "$identity" == *$'\n'* ]]; then
        echo '{"status":"BLOCKED","reason":"uniqueDeveloperIDApplicationIdentityUnavailable","systemWrites":0}' > "$out/result.json"
        exit 2
    fi
    /usr/bin/codesign --force --options runtime --timestamp=none --sign "$identity" "$app" >/dev/null
else
    kit=$(cd "$kit" && pwd -P)
    app="$kit/Spaces Launch Canary.app"
fi
[[ "$kit" == /private/tmp/nearpane-spaces-canary.* && "$(stat -f '%u:%Lp' "$kit")" == "$(id -u):700" ]]
/usr/bin/codesign --verify --strict --deep -R='anchor apple generic and identifier "com.holdsnow.nearpane.spaces-launch-canary" and certificate leaf[subject.OU] = "ZB9D4T66QB"' "$app"
python3 -B - "$mode" "$app" "$out" "$route" "$readonly_canary" <<'PY'
import hashlib,json,os,subprocess,sys,tempfile
from pathlib import Path
mode,app,output,route,read_only_arg=sys.argv[1:]
read_only=read_only_arg=="1"
root=Path(output); bundle=Path(app)
base=dict(developerIDTeam="ZB9D4T66QB",identifier="com.holdsnow.nearpane.spaces-launch-canary",
          executableSHA256=hashlib.sha256((bundle/"Contents/MacOS/Canary").read_bytes()).hexdigest(),
          route="preflight" if read_only else route,qualificationGranted=False,productionHost="NOT_RUN",thirdPartyWindows="NOT_RUN")
def save(data):
    pending=root/"result.next"
    pending.write_text(json.dumps({**base,**data},indent=2)+"\n");pending.replace(root/"result.json")
if mode=="build":
    save(dict(status="BUILD_ONLY",kit=str(bundle.parent),appLaunched=False))
    print(bundle.parent);raise SystemExit(0)
if not read_only and os.environ.get("NP_RUN_EXACT_SPACES_CANARY")!="1":
    save(dict(status="BLOCKED",reason="explicitExactPhysicalCanaryRequired",appLaunched=False));raise SystemExit(2)
journal=root/"events.jsonl";journal.touch(mode=0o600,exist_ok=False)
spool=Path(tempfile.mkdtemp(prefix="receipt-",dir=bundle.parent))
stdout=spool/"canary.jsonl";stderr=spool/"canary.stderr"
for entry in (stdout,stderr):entry.touch(mode=0o600,exist_ok=False)
def safe(value):
    value=value.replace(str(root),"<output>").replace(str(bundle.parent),"<signed-kit>").replace(str(Path.home()),"<home>")
    return "\n".join("".join(c for c in line if c.isprintable() or c=="\t") for line in value.splitlines())[-3000:]
def collect():
    raw=stdout.read_bytes()
    journal.write_bytes(raw)
    return [json.loads(line) for line in raw.splitlines()]
save(dict(status="UNKNOWN",reason="waitingForDedicatedLaunchServicesCanary",events=journal.name))
try:
    cmd=["/usr/bin/open","-n","-g","-W","-a",app]
    if not read_only: cmd.extend(["--env","NP_RUN_EXACT_SPACES_CANARY=1"])
    cmd.extend(["--stdin","/dev/null","--stdout",str(stdout),"--stderr",str(stderr),"--args","preflight" if read_only else route])
    done=subprocess.run(cmd,stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=subprocess.PIPE,text=True,timeout=18)
    launch=dict(launchReturn=done.returncode,launchStderr=safe(done.stderr),canaryStderr=safe(stderr.read_text(errors="replace")),
                redirectedInsidePrivateKit=True)
    rows=collect()
    end=rows[-1] if rows else {}
    if done.returncode!=0 or not end.get("status"):
        save(dict(status="UNKNOWN",reason="missingDedicatedCanaryTerminalReceipt",events=journal.name,**launch))
        raise SystemExit(2)
    facts=next((row for row in rows if row.get("event")=="developmentIdentityPreflight"),None)
    save({**end,"events":journal.name,"preflight":facts,**launch})
    print(end["status"],end.get("reason",""))
    raise SystemExit(0 if end["status"]==("PREFLIGHT_READY" if read_only else "OWN_SIGNED_CANARY_PASS") else 2)
except (OSError, ValueError, subprocess.TimeoutExpired) as err:
    journal.write_bytes(stdout.read_bytes())
    save(dict(status="UNKNOWN",reason=type(err).__name__,events=journal.name,privateSpool=spool.name,
              cleanup="Requires independent readback for this same owner; no automatic relaunch"))
    raise SystemExit(2)
PY
