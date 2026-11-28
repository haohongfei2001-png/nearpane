"""Ask the isolated installed Host to run the actual signed current-card reader on both fixture windows."""
import json
import os
import re
import stat
import subprocess
import tempfile
import time
import uuid
from pathlib import Path

from installed_profile import PROFILE, installed_pid, owns_profile, validate_home
from space_scope import private_file

POINT = {"opening", "surface", "retainedAX", "closing"}
STATE = {"confirmed", "changed", "fullRosterRequired"}
REASONS = set(("physicalDisplayCount physicalDisplayID physicalFrame usableFrame backingScale rotation separateSpaces physicalTopology stagePreference spaceInventory displaySet currentRecord currentType currentUUID "
               "spaceOrder recordType recordUUID forwardMembership reverseMembership surfaceMissing surfaceOwner "
               "surfaceLayer surfaceVisibility surfaceAlpha surfaceFrame frameDisplay axList originalElement axRole axMinimized axFrame").split())
REQUIRED = {(side, item) for side in ("opening", "closing") for item in
            ("physicalTopology", "stagePreference", "spaceInventory", "forwardMembership", "reverseMembership")}
REQUIRED.update(("surface", item) for item in ("surfaceOwner", "surfaceLayer", "surfaceVisibility", "surfaceAlpha", "surfaceFrame", "frameDisplay"))
REQUIRED.update(("retainedAX", item) for item in ("originalElement", "axMinimized", "axFrame"))


def check(ok, reason):
    if not ok:
        raise ValueError(reason)


def private_dir(path):
    s = path.lstat()
    return path.is_absolute() and path.resolve(strict=True) == path and stat.S_ISDIR(s.st_mode) and s.st_uid == os.getuid() and s.st_mode & 0o077 == 0


def matching_rows(lines, binding, token):
    targets = [{"pid": binding["pid"], "birth": binding["birth"], "number": n} for n in binding["numbers"]]
    matches = {}
    for line in lines:
        try:
            row = json.loads(line)
        except (ValueError, UnicodeDecodeError):
            continue
        if not isinstance(row, dict) or row.get("probe") != token or row.get("stage") != "enrolled-current-focus":
            continue
        w = row.get("window")
        check(row.get("mode") == "readOnlyFocusScope" and row.get("writerPID") == binding["hostPID"] and
              type(row.get("actualAXWrites")) is int and row["actualAXWrites"] == 0 and w in targets, "probeReceiptIdentityMismatch")
        n = w["number"]
        check(n not in matches, "duplicateProbeReceipt")
        state = row.get("state")
        check(state in STATE | {"unavailable"}, "invalidProbeState")
        worker = row.get("workerPID")
        check(state == "unavailable" or (type(worker) is int and worker > 1 and worker not in (binding["pid"], binding["hostPID"])), "workerIdentityUnavailable")
        clean = []
        for f in row.get("findings", []):
            check(set(f) <= {"point", "reason", "state", "observed", "expected"} and f.get("point") in POINT and
                  f.get("reason") in REASONS and f.get("state") in STATE and
                  all(type(f[k]) is int and -8192 <= f[k] <= 8192 for k in ("observed", "expected") if k in f), "invalidScopeFinding")
            clean.append(f)
        if state == "confirmed":
            check(all(f["state"] == "confirmed" for f in clean) and REQUIRED <= {(f["point"], f["reason"]) for f in clean},
                  "incompletePositiveScopeEvidence")
        matches[n] = {**w, "workerPID": worker, "state": state, "findings": clean}
    return [matches[t["number"]] for t in targets if t["number"] in matches]


def audit_lines(path):
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except FileNotFoundError:
        return []
    with os.fdopen(fd, "rb") as f:
        s = os.fstat(f.fileno())
        check(stat.S_ISREG(s.st_mode) and s.st_nlink == 1 and s.st_uid == os.getuid() and s.st_mode & 0o077 == 0
              and 0 <= s.st_size < 2_000_000, "unsafeProbeEventLog")
        return f.read(s.st_size).split(b"\n")[:-1]


def inspect_pair(binding, folder, output):
    """Called only after the pointer harness has independently enrolled and prepared its signed pair."""
    result = {"status": "UNKNOWN", "reason": "probeNotCompleted", "issued": False, "actualAXWrites": 0,
              "hostPID": binding.get("hostPID"), "windows": []}
    manifest = stamp = None
    token = str(uuid.uuid4()).upper()
    try:
        home = Path(os.environ["NEARPANE_TEST_HOME"])
        check(private_dir(home), "unavailablePrivateProfile")
        validate_home(home)
        active_host = lambda: installed_pid() == binding["hostPID"] and owns_profile(binding["hostPID"], home/PROFILE)
        check(active_host(), "isolatedHostChanged")
        folder = Path(folder)
        check(private_dir(folder) and private_dir(folder.parent) and folder.parent.parent == Path("/private/tmp") and
              folder.parent.name.startswith("nearpane-d01.") and str(uuid.UUID(folder.name)) == folder.name and
              binding.get("folder") == str(folder) and binding.get("session") == folder.name, "fixtureFolderChanged")
        startup = json.loads(private_file(folder/"startup.json"))
        local = json.loads(private_file(folder/"windows.json"))
        keys = ("pid", "birth", "session")
        check(all(startup.get(k) == binding.get(k) == local.get(k) for k in keys) and startup.get("bundle") == "net.example.spaces-document" and
              len(binding["numbers"]) == 2 and binding["numbers"] == local.get("numbers") and len(set(binding["numbers"])) == 2,
              "fixtureWindowsChanged")
        check(all(re.fullmatch(r"[a-f0-9]{40,64}", binding[k]) for k in ("hostHash", "hash")), "fixtureSignatureUnavailable")
        targets = [{k: binding[k] for k in ("pid", "birth")} | {"number": n} for n in binding["numbers"]]
        signer = {"token": token, "hostPID": binding["hostPID"], "hostBirth": binding["hostBirth"],
                  "hostHash": binding["hostHash"], "fixtureHash": binding["hash"]}
        desk = {"display": str(uuid.UUID(binding["display"])).upper(), "record": str(binding["space"]), "uuid": str(uuid.UUID(binding["spaceUUID"])).upper()}
        request = json.dumps({"version": 1, "targets": targets, "focusScopeProbe": {"binding": signer, "desktop": desk}}).encode()
        manifest = home/"p0-window-audit-targets.json"
        with tempfile.NamedTemporaryFile(dir=home, prefix=".scope-probe.", delete=True) as staged:
            staged.write(request)
            staged.flush()
            os.fsync(staged.fileno())
            s = os.fstat(staged.fileno())
            os.link(staged.name, manifest)  # Never overwrite a pre-existing preview/audit manifest.
            stamp = (s.st_dev, s.st_ino)
        deadline = time.monotonic() + 10
        result["reason"] = "twoSignedWorkerRepliesMissing"
        while time.monotonic() < deadline:
            rows = matching_rows(audit_lines(home/"p0-window-audit.jsonl"), binding, token)
            result["windows"] = rows
            if len(rows) == 2:
                check(active_host() and private_file(manifest) == request, "isolatedHostChanged")
                passed = all(w["state"] == "confirmed" for w in rows)
                result.update(status="CONFIRMED" if passed else "BLOCKED", reason="bothOriginalsConfirmed" if passed else "scopeReadRefused")
                break
            time.sleep(.08)
    except FileExistsError:
        result.update(status="BLOCKED", reason="existingAuditManifest")
    except (KeyError, TypeError, ValueError, OSError, RuntimeError, subprocess.SubprocessError) as exc:
        # Scope labels are ours. Never copy local paths or document contents to a shareable receipt.
        allowed = {"probeReceiptIdentityMismatch", "duplicateProbeReceipt", "invalidProbeState", "workerIdentityUnavailable",
                   "invalidScopeFinding", "incompletePositiveScopeEvidence", "unsafeProbeEventLog", "unavailablePrivateProfile",
                   "isolatedHostChanged", "fixtureFolderChanged", "fixtureWindowsChanged", "fixtureSignatureUnavailable"}
        result.update(status="BLOCKED", reason=str(exc) if str(exc) in allowed else "unverifiableFixtureOrProfile")
    finally:
        if stamp is not None:
            try:
                s = manifest.lstat()
                if (s.st_dev, s.st_ino) == stamp and private_file(manifest) == request:
                    manifest.unlink()
                else:
                    result.update(status="UNKNOWN", reason="probeManifestReplaced")
            except (OSError, ValueError):
                result.update(status="UNKNOWN", reason="probeManifestRecoveryUnconfirmed")
    receipt = Path(output)/"focus-scope-probe.json"
    with os.fdopen(os.open(receipt, os.O_WRONLY | os.O_NOFOLLOW | os.O_CREAT | os.O_EXCL, 0o600), "w") as f:
        json.dump(result, f, indent=2)
        f.write("\n")
    return result
