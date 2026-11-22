"""Upgrade one registered Host in the current login. Never force termination or replay window operations."""
import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

import installed_cycle as cycle

backup, recovery = cycle.backup, cycle.recovery
install = backup.install
require = install.require
ROOT = Path(__file__).resolve().parents[4]


def census(work, app):
    result = json.loads(subprocess.check_output([work / "roster", app, "--roster"], timeout=15))
    require(result.get("complete") is True and result.get("session", {}).get("qualified") is True,
            "Cannot identify all registered Hosts in the target GUI session")
    return result


def recoveries(work):
    return recovery.inspect(recovery.PROFILE, recovery.SUPPORT, recovery.SHARED, work / "recovery-window")


def archive_if_needed(work, leases, journal_digest):
    blocked = [r for r in leases["records"] if r["blocksExchange"]]
    if not blocked:
        require(leases["quitPermitted"], "A shared window lease remains open")
        return {"status": "NOT_RUN", "reason": "noPendingOrdinaryJournal"}
    require(len(blocked) == 1 and blocked[0]["kind"] == "ordinaryWindowRecovery"
            and blocked[0]["status"] == "pending" and blocked[0]["activeGeneration"] and blocked[0]["journalSHA256"] == journal_digest
            and leases["openSharedLeaseDescriptors"] == 0, "Unresolved ownership outside the admitted layout record")
    operator = [work / "keep-stable-layout", "--keep-current", work, leases["profileIndexSHA256"], journal_digest]
    result = subprocess.run(operator, capture_output=True, timeout=20)
    response = json.loads(result.stdout)
    install.persist(work / "07-keep-current.json", response)
    require(result.returncode == 0 and response.get("archived") is True and response.get("retainedSHA256") == journal_digest,
            "Could not confirm byte-identical keep-current archive")
    return response


def upgrade(args, progress):
    work = args.work
    mac = install.Mac()
    install.owned_dir(work)
    require(work.parent == Path("/private/tmp") and work.name.startswith("nearpane-host-inplace."), "Invalid evidence root")
    before = json.loads((work / "03-backup.json").read_bytes())
    require(before["status"] == "PASS" and before["copySignatureVerified"] and before["equalSigningIdentity"],
            "A verified backup of the original bundle and profile is required")
    old = dict(source=before["installed"]["source"], cdhash=before["installed"]["CDHash"])
    new = dict(source=args.source, cdhash=args.cdhash)
    install.expect_pair(old, new)
    app = mac.canonical
    source = work / "candidate/Nearpane.app"
    original = mac.inspect(app, old)
    saved = mac.inspect(work / "backup/Nearpane.app", old)
    require(saved["tree"] == original["tree"] == before["items"]["Nearpane.app"]["sourceAfter"], "Backup bundle changed")
    candidate = mac.inspect(source, new)
    install.publisher.signing.check_continuity(app, source)
    require(before["dailyConfigurationAfter"] == mac.config(), "Daily configuration changed since backup")

    roster = census(work, app)
    pid = mac.pid()
    require(pid and roster["pids"] == [pid], "Expected one running registered Host at the standard path")
    birth = mac.bound(pid, mac.daily, original)
    progress("sourceAndIdentityVerified", beforeRoster=roster, old=original, new=candidate, previousProcess=birth)

    stage = Path(tempfile.mkdtemp(prefix=".nearpane-stage.", dir=app.parent))
    slot = stage / "Nearpane.app"
    mac.stage(source, slot)
    shutil.copyfile(work / "candidate/package.json", stage / "package.json")
    require(mac.inspect(slot, new)["tree"] == candidate["tree"] and slot.stat().st_dev == work.stat().st_dev,
            "Staged bundle or rollback volume differs")
    verify = [sys.executable, "-B", ROOT / "scripts/verify-packages.py"]
    with (work / "staged-static-verification.log").open("xb") as log:
        subprocess.run([*verify, "--static-only", slot], stdout=log, stderr=subprocess.STDOUT, check=True, timeout=180)
    progress("staged", privateStagingPath=str(stage))
    archived = archive_if_needed(work, recoveries(work), args.keep_journal)
    leases = recoveries(work)
    require(cycle.admit_daily(dict(roster=census(work, app), leases=leases), pid)
            and mac.bound(pid, mac.daily, original) == birth, "Fresh ownership or roster check failed")
    progress("normalQuitRequested", archive=archived, beforeQuitRecovery=leases)
    mac.quit(birth)
    mac.wait_stopped([app, slot])
    empty = census(work, app)
    require(empty["pids"] == [] and cycle.stamp_is_gone(birth), "Old process generation did not retire")
    progress("oldGenerationExited", emptyRoster=empty, oldProcessRetired=True)
    with install.free_lock(mac.daily / install.LOCK_FILE):
        require(recoveries(work)["quitPermitted"] and not census(work, app)["pids"], "Recovery or Host appeared after quit")
        require(mac.inspect(app, old)["root"] == original["root"], "Original bundle changed before exchange")
        install.publisher.publish(slot, app, work / "installed-package.json")
        current, retired = mac.inspect(app, new), mac.inspect(slot, old)
        require(current["tree"] == candidate["tree"] and retired["root"] == original["root"], "Exchange readback failed")
        destination = work / "retired-original.rollback"
        require(not os.path.lexists(destination), "Rollback path already exists")
        os.rename(slot, destination)
        (stage / "package.json").unlink()
        stage.rmdir()
        progress("installed", installed=current, retiredOriginalTree=retired["tree"], canonicalPath=str(app))
    with (work / "installed-package-self-check.log").open("xb") as log:
        subprocess.run([*verify, app], stdout=log, stderr=subprocess.STDOUT, check=True, timeout=240)
    require(not census(work, app)["pids"], "Package self-check still running")
    progress("sealedBundleSelfCheckPassed")
    mac.open_daily()
    stamp = mac.wait_owner(mac.daily, current)
    roster = census(work, app)
    require(roster["pids"] == [stamp[0]], "Canonical Host not unique after launch")
    progress("running", currentProcess=stamp, runningRoster=roster, configAfter=mac.config(),
             configBefore=before["dailyConfigurationBefore"], status="PASS")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("work", type=Path)
    parser.add_argument("--source", required=True)
    parser.add_argument("--cdhash", required=True)
    parser.add_argument("--keep-journal", help="Only the reviewed SHA may be archived while retaining live geometry")
    args = parser.parse_args()
    install.owned_dir(args.work)
    out = args.work / "08-upgrade.json"
    with out.open("x"):
        pass
    record = dict(schema=1, scope="singleVersionCanonicalUpgrade", status="UNKNOWN", events=[])

    def progress(stage, **facts):
        record.update(facts, stage=stage)
        record["events"].append(dict(stage=stage, utc=datetime.now(timezone.utc).isoformat()))
        install.persist(out, record)

    mac = install.Mac()
    install.owned_dir(mac.root, create=True)
    try:
        # Serialize with the old supervisor too. The publisher itself owns the destination-directory lock.
        with install.free_lock(mac.root / "supervisor.lock", create=True):
            upgrade(args, progress)
    except (OSError, ValueError, RuntimeError, KeyError, subprocess.SubprocessError) as exc:
        record.update(error=str(exc)[:400], status="UNKNOWN")
        install.persist(out, record)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
