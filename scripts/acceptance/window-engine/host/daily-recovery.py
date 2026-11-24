#!/usr/bin/env python3
"""Read the daily profile before normal quit or an in-place bundle exchange. Never retire a lease."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import stat
import subprocess
import uuid

SUPPORT = Path.home() / "Library/Application Support"
PROFILE = SUPPORT / "Nearpane Alpha Profiles"
SHARED = Path("/private/tmp") / f"com.holdsnow.nearpane.window-leases.{os.getuid()}"


def owned(path):
    if path != path.resolve(strict=True) or path.stat().st_uid != os.getuid():
        raise ValueError("unexpected recovery path or owner")
    return path


def file_data(path):
    if not stat.S_ISREG(owned(path).stat().st_mode) or path.stat().st_size > 16 * 1024 * 1024:
        raise ValueError("invalid recovery file")
    b = path.read_bytes()
    return json.loads(b), hashlib.sha256(b).hexdigest()


def ordinary(path, active, observer):
    journal, digest = file_data(path)
    entries = journal["entries"]
    if journal["version"] != 1 or not isinstance(entries, list):
        raise ValueError("unknown WorkRect journal format")
    row = dict(kind="ordinaryWindowRecovery", activeGeneration=active, status=journal["status"],
               journalSHA256=digest, entries=[], blocksExchange=True)
    for e in entries:
        key = e["id"]
        pid, birth, window = (key[k] for k in ("pid", "launch", "number"))
        if not all(type(x) is int and x > 0 for x in (pid, birth, window)):
            raise ValueError("invalid journal window identity")
        samples = json.loads(subprocess.check_output([observer, str(pid), str(birth), str(window)], timeout=8))
        row["entries"].append(dict(pid=pid, birth=birth, window=window, original=e["original"],
                                   lastConfirmed=e["confirmed"], actionRefused=bool(e.get("refusal")),
                                   outstandingIntent=e.get("intended") is not None, samples=samples))
    # Nearpane's ordinary manager itself blocks on an unarchived journal. A matching rectangle,
    # an unused .lock file, an absent process, or a PID reused by another app cannot release it.
    if file_data(path)[1] != digest:
        raise ValueError("WorkRect journal changed during observation")
    return row


def inspect(profile, support, shared, observer, current_install=None):
    index, index_digest = file_data(profile / "profile-index.json")
    generation = owned(profile / "generations" / str(uuid.UUID(index["active"])))
    rows = []
    if (profile / "transaction.json").exists():
        rows.append(dict(kind="profileTransaction", blocksExchange=True))
    installed_spaces = support / "Nearpane-Spaces-Verification" / "active.jsonl"
    if os.path.lexists(installed_spaces):
        rows.append(dict(kind="installedSpacesRecovery", blocksExchange=True))
    for folder in sorted((profile / "generations").iterdir()):
        owned(folder)
        workrect = folder / "WorkRect/ordinary/journal.json"
        if os.path.lexists(workrect):
            rows.append(ordinary(workrect, folder == generation, observer))
        ledger = folder / "Nearpane/stage-visibility-v1.json"
        if os.path.lexists(ledger):
            record, digest = file_data(ledger)
            if record.get("version") != 1 or not isinstance(record.get("owned"), list):
                raise ValueError("unknown StageGroup ledger format")
            pending, owner = record.get("pending") is not None, record.get("owner") is not None
            releases = record.get("releases") or []
            if not isinstance(releases, list):
                raise ValueError("unknown StageGroup release format")
            rows.append(dict(kind="stageGroup", activeGeneration=folder == generation, journalSHA256=digest,
                             pending=pending, owner=owner, owned=len(record["owned"]), releases=len(releases),
                             blocksExchange=bool(pending or owner or record["owned"] or releases)))
        for f in folder.rglob("virtual-recovery.json"):
            rows.append(dict(kind="virtualWorkspaceRecovery", journalSHA256=file_data(f)[1], blocksExchange=True))
        for guard in folder.glob("Nearpane/.corner-guardians/*"):
            receipt = owned(guard) / "guardian-receipt.json"
            d = file_data(receipt)[0] if receipt.exists() else {}
            returned = (d.get("durableOwnership") == "measuredReturnAwaitingCoordinator"
                        and d.get("reason") == "unqualifiedHideReturnedAfterKernelExit"
                        and d.get("physicalRestoration") == "PASS" and d.get("originalFrameReadbacks") == 2
                        and d.get("issued") == 1 and d.get("kernelHostExit") is True
                        and d.get("unqualifiedPostimageObserved") is True and d.get("committedPostimage") is False)
            settled = d.get("status") == "PASS" and (d.get("durableOwnership") == "exactCommittedOwnershipRemoved"
                                                      or d.get("reason") == "liveHostReleasedRestoredOwnership" or returned)
            rows.append(dict(kind="cornerGuardian", receiptPresent=bool(d), result=d.get("status"),
                             blocksExchange=not settled))
    previous = support / "Nearpane Acceptance Install/active.json"
    if previous.exists():
        record, digest = file_data(previous)
        own = current_install is not None and record.get("transaction") == current_install
        restored = record.get("stage") == "restored" and record.get("restoration") == "PASS"
        rows.append(dict(kind="previousInstall", journalSHA256=digest, restoration=record.get("restoration"),
                         cleanup=record.get("cleanup"), currentInstall=own, blocksExchange=not (own or restored)))
    locks = []
    if os.path.lexists(shared):
        owned(shared)
        if shared.stat().st_mode & 0o077:
            raise ValueError("unexpected shared lease directory permissions")
        # Regular files persist after flock is released. Ask lsof for open descriptors only.
        check = subprocess.run(["/usr/sbin/lsof", "-nP", "-Fpn", "+d", shared], capture_output=True, timeout=90)
        if check.returncode not in (0, 1) or check.stderr or (check.returncode == 1 and check.stdout):
            raise ValueError("incomplete open lease inventory")
        locks = [l for l in check.stdout.splitlines() if l.startswith(os.fsencode("n" + str(shared) + "/"))]
    if file_data(profile / "profile-index.json")[1] != index_digest:
        raise ValueError("active profile changed")
    blocked = bool(locks or any(row["blocksExchange"] for row in rows))
    return dict(status="BLOCKED" if blocked else "PASS", reason="outstandingRecovery" if blocked else "clear",
                profileIndexSHA256=index_digest, generations=len(list((profile / "generations").iterdir())),
                records=rows, openSharedLeaseDescriptors=len(locks), quitPermitted=not blocked)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("observer", type=Path)
    parser.add_argument("receipt", type=Path)
    a = parser.parse_args()
    try:
        result = inspect(PROFILE, SUPPORT, SHARED, a.observer.resolve(strict=True))
    except (OSError, KeyError, ValueError, TypeError, subprocess.SubprocessError) as error:
        result = dict(status="UNKNOWN", reason=type(error).__name__, message=str(error)[:250], quitPermitted=False)
    result.update(schema=1, recordedUTC=datetime.now(timezone.utc).isoformat(), windowWrites=0,
                  journalWrites=0, quitRequests=0, permissionRequests=0)
    with a.receipt.open("x") as out:
        json.dump(result, out, indent=2)
        out.write("\n")
    raise SystemExit(0 if result["quitPermitted"] else 2)
