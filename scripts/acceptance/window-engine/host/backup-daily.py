#!/usr/bin/env python3
"""Create and verify a private pre-quit copy of the installed product and its daily recovery data."""
import argparse
from datetime import datetime, timezone
import hashlib
import importlib
import json
import os
from pathlib import Path
import subprocess
import sys

HERE = Path(__file__).resolve().parent
# Share the same tree fingerprint as the reversible APFS installation supervisor.
sys.path.insert(0, str(HERE.parents[1] / "native-spaces"))
install = importlib.import_module("private-installed-trials")
permissions = importlib.import_module("installed-permissions")
SUPPORT = Path.home() / "Library/Application Support"


def fingerprint(path):
    if path.is_symlink():
        raise ValueError("unexpected backup root symlink")
    if path.is_dir():
        return install.public_tree(path)
    with path.open("rb") as source:
        return hashlib.file_digest(source, "sha256").hexdigest()


def backup(work):
    install.owned_dir(work)
    if work.parent != Path("/private/tmp") or not work.name.startswith("nearpane-host-inplace."):
        raise ValueError("expected a private in-place acceptance directory")
    dest = work / "backup"
    install.owned_dir(dest, create=True)
    app = Path("/Applications/Nearpane.app")
    roots = {"Nearpane.app": app, "profile-generations": SUPPORT / "Nearpane Alpha Profiles",
             "support": SUPPORT / "Nearpane", "install-recovery": SUPPORT / "Nearpane Acceptance Install",
             "spaces-recovery": SUPPORT / "Nearpane-Spaces-Verification",
             "preferences.plist": Path.home() / "Library/Preferences/com.holdsnow.nearpane.alpha.plist"}
    _, image = permissions.installed()
    before = install.profile.daily_state()
    items = {}
    for label, path in roots.items():
        target = dest / label
        if not os.path.lexists(path):
            if label in ("Nearpane.app", "profile-generations"):
                raise ValueError("required daily data missing")
            items[label] = {"present": False}
            continue
        first = fingerprint(path)
        if not os.path.lexists(target):
            subprocess.run(["/usr/bin/ditto", "--rsrc", "--extattr", "--acl", path, target], check=True, timeout=180)
        saved, final = fingerprint(target), fingerprint(path)
        items[label] = dict(present=True, sourceBefore=first, copy=saved, sourceAfter=final,
                            verified=(first == final == saved))
    app_copy = dest / "Nearpane.app"
    subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", "--all-architectures", app_copy], check=True)
    equal_signature = install.identity(app_copy) == install.identity(app)
    after = install.profile.daily_state()
    verified = before == after and equal_signature and all(i.get("verified", True) for i in items.values())
    return dict(status="PASS" if verified else "UNKNOWN", scope="privatePreQuitBackup", items=items,
                installed=image, dailyConfigurationBefore=before, dailyConfigurationAfter=after,
                equalSigningIdentity=equal_signature, copySignatureVerified=True, windowActions=0, quitRequests=0)


if __name__ == "__main__":
    args = argparse.ArgumentParser(description=__doc__)
    args.add_argument("work", type=Path)
    args.add_argument("receipt", type=Path)
    a = args.parse_args()
    try:
        result = backup(a.work)
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        result = dict(status="UNKNOWN", reason=type(error).__name__, windowActions=0, quitRequests=0)
    result.update(schema=1, recordedUTC=datetime.now(timezone.utc).isoformat())
    with a.receipt.open("x") as out:
        json.dump(result, out, indent=2)
        out.write("\n")
    raise SystemExit(0 if result["status"] == "PASS" else 2)
