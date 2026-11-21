"""Opt-in native directory smoke for an already admitted Stage-OFF empty lease on 26A428."""
import importlib
import json
import os
from pathlib import Path
import plistlib
import select
import stat
import subprocess
import time
import uuid

from acceptance import identity
from contract_workspace import empty_system_desktop, write_owned
from installed_profile import APP, PROFILE, installed_pid, owns_profile, validate_home
from p2_stage_surfaces import fresh_ordinary_reader
from space_scope import ScopeError, require

driver = importlib.import_module("preview-workspace")
ERRORS = (OSError, RuntimeError, ValueError, KeyError, TypeError, subprocess.SubprocessError)
TEAM = "ZB9D4T66QB"


class QuarantineViolation(ValueError):
    """A matching, enabled Space button explicitly advertised AXPress."""


def expected_topology(scope):
    return dict(display=str(uuid.UUID(scope["scope"])).upper(), current=scope["current"], records=[
        dict(id=r["id"], type=r["type"], uuid=str(uuid.UUID(r["uuid"])).upper()) for r in scope["records"]])


def review(topology, proof):
    """Compare actual AX metadata with independent physical ordering without issuing a row action."""
    ids = [f'native-space-row:{topology["display"]}:{r["id"]}' for r in topology["records"] if r["type"] in (0, 4)]
    rows = proof.get("rows")
    require(ids and isinstance(rows, list) and [r.get("id") for r in rows] == ids, "incompleteOrReorderedSpaceRows")
    require(len(set(ids)) == len(ids) and sum(r["id"] == topology["current"] for r in topology["records"]) == 1,
            "ambiguousFrozenSource")
    require(all(r.get("labelMatches") is True for r in rows), "currentOrNumberedLabelChanged")
    require(proof.get("quarantineText") is True, "quarantineExplanationUnavailable")
    for row in rows:
        if row.get("actionsRead") is True and row.get("role") == "AXButton" and row.get("canPress") is True and row.get("enabled") is True:
            raise QuarantineViolation("enabledQuarantinedSpaceButton")
        require(row.get("actionsRead") is True and type(row.get("canPress")) is bool and
                row.get("role") in {"AXStaticText", "AXGroup", "AXCell", "AXRow", "AXButton"} and
                (row["enabled"] is False or (not row["canPress"] and row["role"] != "AXButton")),
                "actionableOrUnknownQuarantinedRow")
    return rows


def private_binary(path, identifier):
    path = Path(path)
    mode = path.stat()
    require(path.resolve(strict=True) == path and path.parent.parent == Path("/private/tmp") and
            path.parent.stat().st_uid == os.getuid() and not path.parent.stat().st_mode & 0o077 and
            stat.S_ISREG(mode.st_mode) and mode.st_uid == os.getuid() and not mode.st_mode & 0o022,
            "untrustedPrivateObserverPath")
    requirement = f'identifier "{identifier}" and anchor apple generic and certificate leaf[subject.OU] = "{TEAM}"'
    subprocess.run(["/usr/bin/codesign", "--verify", "--strict", "-R=" + requirement, path],
                   check=True, capture_output=True, timeout=6)


def run(binary, workspace, expected_space, stage_enrollment, stage_observer, output_dir):
    """Called inside the protected Host/profile transaction after offZeroBefore PASS, before any fixture."""
    output = Path(output_dir)
    output.mkdir(mode=0o700, parents=False, exist_ok=False)
    result = dict(status="BLOCKED", scope="QUARANTINED_DIRECTORY_ONLY", rowActionsIssued=0, systemKeyEvents=0,
                  phases=[], census=[], cleanup=dict(status="NOT_NEEDED"))
    process = None
    transport_ok = True
    attempted = False

    def exchange(phase, payload=None):
        nonlocal transport_ok
        transport_ok = False
        process.stdin.write((json.dumps(payload) if payload is not None else phase).encode() + b"\n")
        process.stdin.flush()
        require(select.select([process.stdout], [], [], 8)[0], "observerReadTimedOut")
        raw = process.stdout.readline(131073)
        require(0 < len(raw) <= 131072 and raw.endswith(b"\n"), "incompleteObserverReceipt")
        record = json.loads(raw)
        require(isinstance(record, dict) and record.get("phase") == phase and type(record.get("ok")) is bool,
                "uncorrelatedObserverReply")
        result["phases"].append(record)
        transport_ok = True
        require(record["ok"], record.get("reason", "observerRefused"))
        return record

    try:
        private_binary(binary, "net.example.nearpane.space-menu-smoke")
        private_binary(stage_observer, "net.example.nearpane.p2-observer")
        home = Path(os.environ["NEARPANE_TEST_HOME"])
        profile = home / PROFILE
        generation = Path(os.environ["NEARPANE_TEST_GENERATION"])
        require(home.resolve(strict=True) == home and home != Path.home() and home.stat().st_uid == os.getuid()
                and not home.stat().st_mode & 0o077 and generation.resolve(strict=True) == generation and
                generation.parent == profile / "generations" and uuid.UUID(generation.name) is not None,
                "privateProfileGenerationUnavailable")
        validate_home(home)
        bundle = plistlib.loads((APP / "Contents/Info.plist").read_bytes())
        signed = identity(APP)
        pid = workspace.host["pid"]
        require(signed["CDHash"] == workspace.host["codeHash"] and signed["TeamIdentifier"] == TEAM and
                signed["Identifier"] == "com.holdsnow.nearpane.alpha" and bundle.get("NearpaneSourceState") == "clean",
                "installedSignedCleanCandidateRequired")
        result["host"] = dict(pid=pid, birth=workspace.host_birth, cdhash=signed["CDHash"],
                              source=bundle["NearpaneSourceRevision"], build=bundle["CFBundleVersion"])
        _, lease_uuid = driver.lease_for(workspace, expected_space)
        scope = expected_topology(workspace.check(workspace.read()))
        require(scope["current"] == expected_space and dict(id=expected_space, type=0, uuid=lease_uuid.upper()) in scope["records"],
                "ordinaryLeaseNotCurrent")
        result["topology"] = scope
        result["boot"] = workspace.boot
        checker = fresh_ordinary_reader(workspace, dict(space=expected_space, spaceUUID=lease_uuid), stage_enrollment, stage_observer)

        def check(label):
            require(installed_pid() == pid and owns_profile(pid, profile) and
                    json.loads((profile / "profile-index.json").read_bytes())["active"] == generation.name and
                    subprocess.check_output(["/usr/sbin/sysctl", "-n", "kern.bootsessionuuid"], text=True, timeout=3).strip() == workspace.boot,
                    "consoleBootOrHostProfileChanged")
            require(expected_topology(workspace.check(workspace.read())) == scope and workspace.hardware() == workspace.hid,
                    "leaseTopologyOrUserInputChanged")
            readings = empty_system_desktop(workspace, expected_space, check_ordinary=checker)
            result["census"].append(dict(phase=label, readings=readings))

        check("beforeStatus")
        process = subprocess.Popen([binary], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, env=driver.login_env())
        exchange("bind", dict(hostPID=pid, hostBirth=workspace.host_birth, hostHash=signed["CDHash"],
                              hid5=workspace.hid, topology=scope))
        attempted = True
        exchange("status")
        check("beforeDirectory")
        exchange("directory")
        check("beforeReadback")
        stable = []
        deadline = time.monotonic() + 9
        while time.monotonic() < deadline:
            actual = exchange("read")
            try:
                rows = review(scope, actual)
            except ScopeError as error:
                # A fresh menu can initially show its loading label. A visible action on this
                # build, duplicate row, or a mismatched current label stays in the raw receipt.
                if actual.get("rows") or str(error) != "incompleteOrReorderedSpaceRows":
                    raise
                stable.clear()
            else:
                if stable:
                    require(stable[0]["rows"] == rows and actual["uptime"] - stable[0]["uptime"] >= .1,
                            "directoryChangedBetweenReads")
                    stable.append(actual)
                    break
                stable.append(actual)
            time.sleep(.15)
        require(len(stable) == 2, "twoCompleteDirectoryReadsUnavailable")
        result["readback"] = dict(status="PASS", rows=len(stable[0]["rows"]), current=scope["current"],
                                  clocks=[r["uptime"] for r in stable], quarantine=True)
    except QuarantineViolation as error:
        result.update(status="FAIL", reason=str(error), readback=dict(status="FAIL", reason=str(error)))
    except ERRORS as error:
        result["reason"] = str(error)[:220] or type(error).__name__
    finally:
        if attempted:
            result["cleanup"] = dict(status="UNKNOWN")
            # If the Host already had a presentation, this run owns nothing to dismiss.
            latest = result["phases"][-1] if result["phases"] else {}
            if latest.get("phase") == "status" and latest.get("statusAttempted") is False:
                result["cleanup"] = dict(status="NOT_NEEDED", reason="noOwnedPresentation")
            elif transport_ok:
                try:
                    check("beforeClose")
                    closed = exchange("close")
                    corroborated = exchange("verify")
                    require(corroborated.get("closedReadbacks") == 2 and corroborated.get("topology") == scope,
                            "scopeOrCloseUnconfirmed")
                    check("afterClose")
                    result["cleanup"] = dict(status="PASS", method=closed["method"],
                                             closeExercised=closed["method"] in ("AXPress", "AXCancel"))
                except ERRORS as error:
                    result["cleanup"]["reason"] = str(error)[:220]
            else:
                result["cleanup"]["reason"] = "uncertainObserverReplyNoFurtherAction"
        if process:
            try:
                process.stdin.close()
            except BrokenPipeError:
                pass
            try:
                process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=2)
            process.stdout.close()
        if result.get("readback", {}).get("status") == result["cleanup"]["status"] == "PASS":
            if result["cleanup"]["closeExercised"]:
                result["status"] = "PASS"
            else:
                result["reason"] = "directoryClosedBeforeCloseControlWasExercised"
        write_owned(output / "result.json", result)
    return result
