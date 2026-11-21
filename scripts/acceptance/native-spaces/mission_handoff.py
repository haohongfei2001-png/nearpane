"""One opt-in system overview lifecycle after both signed fixture windows have exited."""
import hashlib
import importlib
import json
import os
from pathlib import Path
import signal
import stat
import subprocess

from contract_workspace import empty_system_desktop
from installed_profile import PROFILE, owns_profile
from p2_stage_surfaces import fresh_ordinary_reader
from space_scope import require


def cleared_pair(pair):
    cleanup = pair.out.get("cleanup", {})
    gone = cleanup.get("readback", {})
    numbers = pair.binding.get("numbers", [])
    return (len(numbers) == len(set(numbers)) == 2 and not pair.out.get("superseded", True)
            and cleanup.get("status") == "PASS" and cleanup.get("signal") == "close"
            and cleanup.get("ownedSessionRemoved") is True and gone.get("status") == "EXITED"
            and gone.get("generationGone") is True and gone.get("windowsGone") is True)


def signed_tool(kit, name, identifier, *, prefix="nearpane-d01."):
    path = kit / name
    require(kit.parent == Path("/private/tmp") and kit.name.startswith(prefix) and
            kit == kit.resolve(strict=True) and kit.stat().st_uid == os.getuid() and
            stat.S_IMODE(kit.stat().st_mode) == 0o700 and path.resolve(strict=True) == path and
            path.is_file() and path.stat().st_uid == os.getuid() and path.stat().st_nlink == 1 and
            not path.stat().st_mode & 0o022, "unqualifiedSignedHandoffTool")
    rule = ('anchor apple generic and identifier "' + identifier + '" and certificate leaf[subject.OU] = '
            '"ZB9D4T66QB" and certificate leaf[field.1.2.840.113635.100.6.1.13] exists')
    subprocess.run(["/usr/bin/codesign", "--verify", "--strict", "-R=" + rule, str(path)],
                   check=True, timeout=6, capture_output=True)
    return path, hashlib.sha256(path.read_bytes()).hexdigest()


def run(kit, folder, workspace, space, space_uuid, enrollment, pair, off_zero):
    folder.mkdir(mode=0o700, exist_ok=False)
    driver = importlib.import_module("preview-workspace")
    result = {"status": "BLOCKED", "launched": False, "cleanup": "NOT_NEEDED", "screenCaptures": 0,
              "spaceOrWindowSelections": 0, "inputKeys": 0}
    path = folder / "receipt.json"

    def save():
        tmp = folder / "receipt.next"
        tmp.write_text(json.dumps(result, indent=2) + "\n")
        tmp.replace(path)

    save()
    try:
        require(cleared_pair(pair), "registeredPairExitOrHardwareContinuityUnconfirmed")
        require(off_zero.get("status") == "PASS" and space in workspace.ids() and space != workspace.cleanup_current,
                "emptyInstalledWindowAreaOrLeasedSpaceUnconfirmed")
        require(kit.name.startswith("nearpane-d01.mission-handoff."), "wrongMissionHandoffKit")
        helper, helper_hash = signed_tool(kit, "mission-handoff", "net.example.nearpane.mission-handoff")
        _, metrics_hash = signed_tool(kit, "metrics", "net.example.nearpane.mission-handoff-metrics")
        observer, observer_hash = signed_tool(Path(os.environ["NP_P2_DOCUMENT_KIT"]), "observe", "net.example.nearpane.p2-observer")
        home = Path(os.environ["NEARPANE_TEST_HOME"])
        require(owns_profile(workspace.host["pid"], home / PROFILE), "isolatedHostProfileLost")
        require(driver.states(workspace.kit)[-1]["state"] is False, "loggedInStageManagerNotOff")
        checker = fresh_ordinary_reader(workspace, {"space": space, "spaceUUID": space_uuid}, enrollment, observer)
        safe = empty_system_desktop(workspace, space, check_ordinary=checker)
        snapshot = workspace.read()
        state = workspace.check(snapshot)
        require(state["current"] == space and workspace.hardware() == workspace.hid, "leaseOrOriginalHardwareChanged")
        require(enrollment["key"]["spaceUUID"] == space_uuid and enrollment["key"]["boot"] == workspace.boot,
                "leaseBootOrUUIDChanged")
        result.update(kitSHA256=helper_hash, metricsSHA256=metrics_hash, p2ObserverSHA256=observer_hash,
                      sourceSpace=space, sourceUUID=space_uuid, registeredPairExited=True, emptyChecks=len(safe))
        save()
        req = dict(command="mission-handoff", display=workspace.display, current=space, original=workspace.cleanup_current,
                   records=state["records"], owned=workspace.ids(), hostPID=workspace.host["pid"], hostHash=workspace.host["codeHash"],
                   hostBirth=workspace.host_birth, hid=workspace.hid, scope=enrollment["key"], enrolled=enrollment["surfaces"],
                   observer=str(observer))
        chord_kit = os.environ.get("NP_OVERVIEW_SHORTCUT_KIT")
        if chord_kit:
            chord, chord_hash = signed_tool(Path(chord_kit), "overview-shortcut-claim",
                                           "com.holdsnow.nearpane.acceptance.overview-shortcut-claim",
                                           prefix="nearpane-overview-chord.")
            req["chord"] = str(chord)
            result["chordProbeSHA256"] = chord_hash
            save()
        journal = folder / "events.jsonl"
        with journal.open("xb", buffering=0) as log:
            child = subprocess.Popen([helper], env=driver.login_env(), stdin=subprocess.PIPE, stdout=log, stderr=subprocess.DEVNULL)
            try:
                child.communicate(json.dumps(req).encode(), timeout=48)
            except (subprocess.TimeoutExpired, KeyboardInterrupt):
                child.send_signal(signal.SIGTERM)  # Requests scoped closure of the original Dock root.
                child.wait(timeout=18)
        rows = [json.loads(line) for line in journal.read_text().splitlines()]
        result["launched"] = any(v.get("event") == "systemLaunchRequested" for v in rows)
        final = [row for row in rows if row.get("event") == "complete"]
        require(len(final) == 1 and rows[-1] == final[0], "lifecycleCompletionUnconfirmed")
        result.update(final[0])
        require(child.returncode == (0 if result["status"] == "PASS" else 2), "helperExitContradictsReceipt")
        if result.get("cleanup") == "PASS":
            empty_system_desktop(workspace, space, check_ordinary=checker)
            require(workspace.hardware() == workspace.hid and owns_profile(workspace.host["pid"], home / PROFILE),
                    "postExitLeaseHardwareOrHostChanged")
            result["postExitEmptyChecks"] = 2
    except (OSError, ValueError, TypeError, KeyError, RuntimeError, subprocess.SubprocessError) as error:
        result.update(status="BLOCKED", reason=str(error)[:200])
        journal = folder / "events.jsonl"
        if journal.is_file():
            rows = []
            for line in journal.read_text().splitlines():
                try:
                    rows.append(json.loads(line))
                except ValueError:
                    break
            if any(v.get("event") == "systemLaunchRequested" for v in rows):
                result["launched"] = True
                if result["cleanup"] == "NOT_NEEDED":
                    result["cleanup"] = "UNKNOWN"
    save()
    return result
