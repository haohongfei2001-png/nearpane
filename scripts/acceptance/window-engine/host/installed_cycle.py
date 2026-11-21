"""Window Engine trial for the existing reversible canonical-install supervisor."""
import hashlib
import importlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

HERE = Path(__file__).resolve().parent
backup = importlib.import_module("backup-daily")
recovery = importlib.import_module("daily-recovery")


def census_and_recovery(work, app, current_install=None):
    with tempfile.TemporaryDirectory(dir=work) as scratch:
        reader, launcher = (Path(scratch) / n for n in ("window", "roster"))
        subprocess.run(["xcrun", "swiftc", HERE / "recovery-window.swift", "-o", reader], check=True, timeout=180)
        subprocess.run(["xcrun", "clang", "-fobjc-arc", HERE / "launch-scope.m", "-framework", "AppKit",
                        "-framework", "Security", "-framework", "CoreGraphics", "-o", launcher], check=True, timeout=90)
        roster = json.loads(subprocess.check_output([launcher, app, "--roster"], timeout=15))
        leases = recovery.inspect(recovery.PROFILE, recovery.SUPPORT, recovery.SHARED, reader, current_install)
        return dict(roster=roster, leases=leases)


def admit_daily(gate, pid):
    roster = gate["roster"]
    return (roster.get("complete") is True and roster.get("session", {}).get("qualified") is True
            and roster.get("pids") == [pid] and pid is not None and gate["leases"].get("quitPermitted") is True)


def stamp_is_gone(stamp):
    result = subprocess.run(["/bin/ps", "-p", str(stamp[0]), "-o", "pid="], capture_output=True, text=True)
    if result.returncode == 1 and not result.stdout.strip() and not result.stderr.strip():
        return True
    return (result.returncode == 0 and result.stdout.strip() == str(stamp[0]) and
            backup.install.process_stamp(stamp[0]) != stamp)


def prepare(mac, args):
    work = args.engine_work
    if (work is None or args.output.parent != work or os.path.lexists(args.output)
            or args.output != args.output.resolve() or not args.output.name):
        raise ValueError("use a fresh receipt directory in the private --engine-work directory")
    backup.install.owned_dir(work)
    try:
        return collect_preflight(mac, args, work)
    except (OSError, ValueError, RuntimeError, KeyError, TypeError, subprocess.SubprocessError) as error:
        return dict(status="UNKNOWN", reason=type(error).__name__, detail=str(error)[:240],
                    candidateLaunched=False, quitRequests=0)


def collect_preflight(mac, args, work):
    saved = backup.backup(work)
    facts = census_and_recovery(work, mac.canonical)
    target = subprocess.check_output(["sw_vers", "-productVersion"], text=True).strip()
    build = subprocess.check_output(["sw_vers", "-buildVersion"], text=True).strip()
    sip = subprocess.check_output(["csrutil", "status"], text=True).strip()
    ready = (saved["status"] == "PASS" and admit_daily(facts, mac.pid()) and target == "27.0" and
             build == "26A428" and sip == "System Integrity Protection status: enabled.")
    response = backup.permissions.sample() if ready else None
    if ready:
        ready = (response["status"] == "PASS" and response["subject"]["pid"] == mac.pid()
                 and response["installed"]["source"] == args.original_source
                 and response["installed"]["CDHash"] == args.original_cdhash)
    return dict(**facts, status="PASS" if ready else "BLOCKED", backup=saved,
                originalPermissions=response, macOS=target, build=build, sip=sip)


def verify_daily(before, restored):
    after = backup.permissions.sample()
    verified = (after["status"] == "PASS" and after["subject"]["pid"] == restored[0]
                and after["subject"]["birth"] == restored[1] * 1_000_000 + restored[2]
                and before["installed"] == after["installed"] and before["permissions"] == after["permissions"])
    return dict(status="PASS" if verified else "UNKNOWN", after=after)


def run(tx):
    # Called under the publisher lock and the real daily writer lock, after the atomic exchange.
    # No ordinary app bootstrap or access to the user's active generation is needed by the one-shot.
    out = tx.out / "window-engine.json"
    candidate = tx.rec["candidate"]
    tx.save("running-installed-window-engine", engineProbeIntended=True)
    with backup.install.free_lock(tx.slot_parent / "trial.lock", create=True) as guard:
        p = subprocess.run([sys.executable, "-B", HERE / "sample-membership.py", tx.app, out, "--installed",
                            "--expected-source", candidate["source"], "--expected-cdhash", candidate["cdhash"],
                            "--enrolled-spaces-cycle"], stdin=subprocess.DEVNULL, check=False,
                           pass_fds=(guard, tx.daily_fd, tx.mac.publisher_fd))
    data = json.loads(out.read_bytes())
    tx.rec["trials"]["WindowEngine"] = dict(status=data["status"], exit=p.returncode,
                                            resourcesClear=data.get("probeResourcesClear") is True,
                                            receipt=out.name, sha256=hashlib.sha256(out.read_bytes()).hexdigest())
    tx.save("finished-installed-window-engine")


def resources_clear(tx):
    # The durable intent precedes exec. Missing output after a crash never authorizes a swap back.
    if not tx.rec.get("engineProbeIntended"):
        return True
    path = tx.out / "window-engine.json"
    if not path.is_file() or path != path.resolve() or path.stat().st_uid != os.getuid():
        return False
    data = json.loads(path.read_bytes())
    recorded = tx.rec["trials"].get("WindowEngine", {}).get("sha256")
    return (recorded == hashlib.sha256(path.read_bytes()).hexdigest() and data.get("probeResourcesClear") is True
            and data.get("safeToRollback") is True and data.get("probeResources", {}).get("clear") is True)
