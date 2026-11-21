#!/usr/bin/env python3
"""Read only the installed fixture's durable journal. This command never repairs a Space."""
import argparse
import json
import os
import pwd
import stat
import uuid


def inspect(nonce=None):
    uid = os.getuid()
    directory = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC
    home = pwd.getpwuid(uid).pw_dir
    if os.path.realpath(home) != home:
        raise ValueError("noncanonicalLoginHome")
    fd = os.open(home, directory)
    file = None
    try:
        for child in ("Library", "Application Support", "Nearpane-Spaces-Verification"):
            meta = os.fstat(fd)
            if meta.st_uid != uid or meta.st_mode & 0o022:
                raise ValueError("untrustedParent")
            nxt = os.open(child, directory, dir_fd=fd)
            os.close(fd)
            fd = nxt
        meta = os.fstat(fd)
        if meta.st_uid != uid or stat.S_IMODE(meta.st_mode) != 0o700:
            raise ValueError("invalidJournalDirectory")
        name = str(nonce) + ".jsonl" if nonce else "active.jsonl"
        file = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC, dir_fd=fd)
        info = os.fstat(file)
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != uid or stat.S_IMODE(info.st_mode) != 0o600
                or info.st_nlink not in (1, 2) or info.st_size > 65536):
            raise ValueError("invalidJournalFile")
        raw = os.read(file, 65537)
        if len(raw) != info.st_size or os.fstat(file).st_size != len(raw) or not raw.endswith(b"\n"):
            raise ValueError("incompleteOrChangingJournal")
        rows = [json.loads(line) for line in raw.splitlines()]
        initial = rows[0]
        if initial["event"] != "enrolledBeforeAnySystemWrite" or initial["route"] != "bridge":
            raise ValueError("missingBoundOrigin")
        challenge = uuid.UUID(initial["challenge"])
        if nonce and challenge != nonce:
            raise ValueError("archiveChallengeMismatch")
        # Surface only fixture/window IDs; other ordinary Space members were never recorded.
        actions = [{k: event[k] for k in ("event", "owner", "window", "space", "response")}
                   for event in rows[1:]]
        clean = bool(nonce and actions and actions[-1]["event"] == "terminalClean")
        return {"status": "ARCHIVED_CLEAN" if clean else "PENDING_RECONCILIATION",
                "challenge": str(challenge), "boot": initial["boot"],
                "hostPID": initial["hostPID"], "hostBirth": initial["hostBirth"],
                "fixturePID": initial["fixturePID"], "fixtureBirth": initial["fixtureBirth"],
                "fixtureWindow": initial["fixtureWindow"], "originalSpace": initial["home"],
                "originalFrame": initial["frame"], "originalSpaceCount": len(initial["spaceInventory"]),
                "knownActions": actions, "systemWritesByInspector": 0}
    finally:
        if file is not None:
            os.close(file)
        os.close(fd)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--archived", type=uuid.UUID, help="read one named finished archive")
    options = parser.parse_args()
    try:
        row = inspect(options.archived)
    except FileNotFoundError:
        row = {"status": "NO_RECORD", "systemWritesByInspector": 0}
    except (OSError, ValueError, KeyError, IndexError, TypeError) as exc:
        row = {"status": "UNKNOWN", "reason": type(exc).__name__, "systemWritesByInspector": 0}
    print(json.dumps(row, ensure_ascii=True, sort_keys=True))
    raise SystemExit(0 if row["status"] == "ARCHIVED_CLEAN" else 2)
