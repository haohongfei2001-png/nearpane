#!/usr/bin/env python3
"""Ask the already running installed Host for its own existing grants. Never launch the Host."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import plistlib
import re
import subprocess
import tempfile
import uuid

ROOT = Path(__file__).resolve().parents[4]
APP = Path("/Applications/Nearpane.app")
METRICS = ROOT / "scripts/acceptance/native-spaces/metrics.swift"


def output(*args, timeout=60):
    return subprocess.check_output(list(map(str, args)), text=True, stderr=subprocess.STDOUT, timeout=timeout)


def installed():
    info = plistlib.loads((APP / "Contents/Info.plist").read_bytes())
    exe = APP / "Contents/MacOS" / info["CFBundleExecutable"]
    fields = dict(re.findall(r"^(CDHash|Identifier|TeamIdentifier)=(.+)$", output("/usr/bin/codesign", "-dvvv", APP), re.M))
    output("/usr/bin/codesign", "--verify", "--strict", "--deep", APP)
    if len(fields) != 3 or fields["Identifier"] != "com.holdsnow.nearpane.alpha":
        raise ValueError("unexpected installed signing identity")
    with exe.open("rb") as stream:
        executable_hash = hashlib.file_digest(stream, "sha256").hexdigest()
    return exe, dict(fields, version=info["CFBundleShortVersionString"], build=info["CFBundleVersion"],
                     source=info.get("NearpaneSourceRevision"), engineABI=info.get("NearpaneStageEngineABI"),
                     hostSHA256=executable_hash)


def decode_message(message, nonce):
    pattern = (r"Permission check " + re.escape(nonce) +
               r" screen=(true|false) accessibility=(true|false) postEvent=(true|false)(?: listenEvent=(true|false))?$")
    match = re.fullmatch(pattern, message)
    if not match:
        raise ValueError("the Host's nonce-specific message has an unknown schema")
    return dict(zip(("screenCapture", "accessibility", "postEvent", "listenEvent"),
                    [None if x is None else x == "true" for x in match.groups()]))


def sample():
    exe, before = installed()
    rows = (line.strip().split(None, 1) for line in output("/bin/ps", "-axo", "pid=,comm=").splitlines())
    pids = [int(pid) for pid, path in rows if path == str(exe)]
    receipt = dict(schema=1, scope="installedHostOwnReadOnlyPermissions", recordedUTC=datetime.now(timezone.utc).isoformat(),
                   observerSource=output("git", "-C", ROOT, "rev-parse", "HEAD").strip(), installed=before,
                   macOS=output("sw_vers", "-productVersion").strip(), osBuild=output("sw_vers", "-buildVersion").strip(),
                   sip=output("csrutil", "status").strip(), targetHostCount=len(pids), permissionPrompts=0,
                   windowActions=0, hostLaunched=False, status="BLOCKED", permissions=None)
    if len(pids) != 1:
        receipt["reason"] = "runningInstalledHostNotUnique"
        return receipt
    pid = pids[0]
    with tempfile.TemporaryDirectory(prefix="nearpane-host-permission-", dir="/private/tmp") as work:
        reporter = Path(work) / "metrics"
        output("xcrun", "swiftc", "-module-cache-path", ROOT / ".build/cache/ModuleCache", METRICS, "-o", reporter, timeout=240)
        # This process only sends a nonce and listens for the acknowledgement. The installed Host calls TCC.
        reply = json.loads(output(reporter, pid, "--permission-subject"))
    nonce = str(uuid.UUID(reply["nonce"])).upper()
    if reply["cdhash"] != before["CDHash"] or reply["pid"] != pid or reply["birth"] <= 0:
        raise ValueError("running and installed images do not match")
    receipt["subject"] = reply
    predicate = (f'processID == {pid} AND subsystem == "com.holdsnow.nearpane.alpha" AND '
                 f'category == "PermissionCheck" AND eventMessage BEGINSWITH "Permission check {nonce} "')
    entries = json.loads(output("/usr/bin/log", "show", "--last", "1m", "--style", "json", "--predicate", predicate))
    matching = [e for e in entries if e.get("processID") == pid and e.get("eventMessage", "").startswith("Permission check "+nonce+" ")]
    if len(matching) != 1:
        receipt["reason"] = "nonceSpecificHostLogNotUnique"
        return receipt
    event = matching[0]
    receipt["hostLog"] = {key: event.get(key) for key in ("timestamp", "processID", "subsystem", "category", "eventMessage")}
    receipt["permissions"] = decode_message(event["eventMessage"], nonce)
    if installed()[1] != before:
        receipt.update(status="UNKNOWN", reason="installedImageChanged")
    else:
        receipt.update(status="PASS", reason="signedLiveHostAnswered")
    return receipt


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("receipt", type=Path)
    args = parser.parse_args()
    args.receipt.parent.mkdir(parents=True, exist_ok=True)
    with args.receipt.open("x") as stream:
        try:
            result = sample()
        except (OSError, subprocess.SubprocessError, ValueError) as error:
            result = dict(status="UNKNOWN", reason=type(error).__name__, message=str(error)[:420], windowActions=0)
        json.dump(result, stream, ensure_ascii=False, indent=2)
        stream.write("\n")
    raise SystemExit(0 if result["status"] == "PASS" else 2)
