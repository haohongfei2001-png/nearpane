"""W01 on two owned files in a fresh, signed system TextEdit process."""
import hashlib
import json
import os
import re
import subprocess
import time
import uuid

from space_scope import ScopeError, private_file, require


ERRORS = (ValueError, OSError, KeyError, TypeError, subprocess.SubprocessError)


class DocumentIdentityError(ScopeError):
    def __init__(self, stage, reason):
        self.stage = stage
        super().__init__(reason)


def valid_expanded_reads(row):
    if "expandedState" not in row and "expandedReads" not in row:
        return row.get("status") != "verifiedExpandedPair"
    allowed = {"generationChanged", "physicalInputChanged", "serverCensusAboveBound", "countUnqualified", "arrayUnqualified", "foreignOrUnreadableOwner", "unidentifiedSurface",
               "additionalAXSurface", "oneAXRefMultipleCGIDs", "distinctAXRefsShareCGID", "nonstandardOrUnresolvedRole",
               "noPreviouslyBoundPair", "missingEnrolledSurface", "serverCensusUnavailable", "additionalServerSurface",
               "missingServerSurface", "fileBindingUnreadable", "fileBindingChanged", "unstableReads", "duplicateReferences", "countDrift", "exactPair"}
    completed = {"duplicateReferences", "countDrift", "exactPair"}
    reads = row.get("expandedReads")
    if not isinstance(reads, list) or not 1 <= len(reads) <= 2 or not isinstance(row.get("expandedState"), str) or row["expandedState"] not in allowed:
        return False
    for sample in reads:
        numeric = {"countAXError", "reported", "copyAXError", "copied", "serverCount", "serverCountAtLeast"}
        if (not isinstance(sample, dict) or sample.keys() - (numeric | {"state", "start", "end", "rows", "fileMatches", "enrolledNumbers", "serverNumbers"}) or
                not isinstance(sample.get("state"), str) or sample["state"] not in allowed or
                any(type(sample[k]) is not int for k in numeric & sample.keys()) or
                not all(type(sample.get(k)) in (int, float) and 0 < sample[k] < 2**53 for k in ("start", "end")) or
                not row["start"] <= sample["start"] <= sample["end"] <= row["end"]):
            return False
        members = sample.get("rows", [])
        if not isinstance(members, list) or len(members) > 8:
            return False
        for member in members:
            if not isinstance(member, dict) or set(member) - {"ref", "owner", "number", "role", "subrole"}:
                return False
            if type(member.get("ref")) is not int or not 0 <= member["ref"] < 8 or member.get("owner") not in ("enrolled", "other", "unreadable"):
                return False
            if member["owner"] != "enrolled":
                if set(member) != {"ref", "owner"}:
                    return False
            elif (type(member.get("number")) is not int or not 0 <= member["number"] <= 0xffffffff or
                  member.get("role") not in ("window", "sheet", "other", "unreadable") or
                  member.get("subrole") not in ("standard", "dialog", "floating", "systemDialog", "unknown", "other", "unreadable")):
                return False
        enrolled = sample.get("enrolledNumbers", [])
        server = sample.get("serverNumbers", [])
        if (not isinstance(enrolled, list) or len(enrolled) not in (0, 2) or
                not isinstance(server, list) or len(server) > 9 or
                any(type(n) is not int or not 0 <= n <= 0xffffffff for n in enrolled + server) or
                len(set(enrolled)) != len(enrolled) or 0 in enrolled or
                ("serverNumbers" in sample and sample.get("serverCount",sample.get("serverCountAtLeast")) != len(server))):
            return False
        files = sample.get("fileMatches")
        if files is not None and (not isinstance(files, list) or len(files) != 2 or any(type(f) is not bool for f in files)):
            return False
        if sample["state"] in completed and (files != [True, True] or sample.get("serverCount") != 2 or
                                             len(enrolled) != 2 or set(enrolled) != set(server) or {m.get("number") for m in members} != set(enrolled) or
                                             len({m["ref"] for m in members}) != 2 or sample.get("copied") != len(members)):
            return False
    if reads[-1]["state"] != row["expandedState"]:
        return False
    if row["expandedState"] in completed:
        return (row.get("status") == "verifiedExpandedPair" and row.get("binding") == "bothEnrolledURLs" and len(reads) == 2 and
                reads[0]["state"] == reads[1]["state"] and reads[0].get("rows") == reads[1].get("rows") and
                reads[0].get("enrolledNumbers") == reads[1].get("enrolledNumbers") and reads[0]["end"] <= reads[1]["start"])
    return row.get("status") == "additionalWindowsReported" and row.get("binding") == "notChecked"


def window_reads(value):
    """Export only bounded AX metadata from the signed helper, including a failed final recheck."""
    statuses = {"wrongOrUnreadableRoot", "additionalWindowsReported", "windowCountRefused", "arrayAXError", "missingArrayValue",
                "nonArrayValue", "countChanged", "emptyArray", "oneWindow", "additionalWindowsReturned", "invalidArrayMembers", "twoAXWindows", "verifiedExpandedPair"}
    bindings = {"notChecked", "wrongOrUnreadableWindowOwner", "roleAXError", "wrongWindowRole", "documentAXError", "documentValueNotString",
                "foreignOrDuplicateURL", "bothEnrolledURLs", "unregisteredWindowNumber"}
    numeric = {"rootAXError", "countAXError", "copyAXError", "reportedCount", "copiedCount", "roleAXError", "documentAXError"}
    if value is None:
        return "NOT_REPORTED", []
    if not isinstance(value, list) or not 1 <= len(value) <= 2:
        return "INVALID", []
    for row in value:
        if (not isinstance(row, dict) or row.keys() - (numeric | {"phase", "start", "end", "binding", "status", "valueKind", "expandedState", "expandedReads"}) or
                row.get("phase") not in ("initial", "recheck") or
                not isinstance(row.get("status"), str) or row["status"] not in statuses or
                not isinstance(row.get("binding"), str) or row["binding"] not in bindings or
                row.get("valueKind") not in (None, "notRead", "error", "noValue", "array", "otherCFType") or
                not all(type(row.get(k)) in (float, int) and 0 < row[k] < 2**53 for k in ("start", "end")) or
                not 0 < row["start"] <= row["end"] or any(type(row[k]) is not int for k in numeric & row.keys()) or not valid_expanded_reads(row)):
            return "INVALID", []
    return "RECORDED", value


def document_action(workspace, folder, desktop, mode, *, record_reads=None, witness_timeout=13, **extra):
    request = dict(mode=mode, folder=str(folder), display=workspace.display, space=desktop,
                   hostPID=workspace.host["pid"], hostBirth=workspace.host_birth, hostHash=workspace.host["codeHash"], hid=workspace.hid, **extra)
    track = record_reads is not None and mode in ("sample", "ready", "press", "marker", "close")
    try:
        cmd = subprocess.run([str(workspace.kit/"textedit")], input=json.dumps(request),
                             capture_output=True, text=True, timeout=witness_timeout)
    except (OSError, subprocess.SubprocessError):
        if track:
            record_reads(mode, "NO_REPLY", [])
        raise
    try:
        data = json.loads(cmd.stdout)
        require(isinstance(data, dict), "document witness reply was not an object")
    except ValueError as exc:
        if track:
            record_reads(mode, "NO_REPLY", [])
        raise ScopeError(f"TextEdit {mode} witness returned no valid reply (exit {cmd.returncode})") from exc
    if track:
        record_reads(mode, *window_reads(data.get("windowReads")))
    if mode == "press":
        # A guard refusal on exit 2 is evidence. Losing the reply is a different outcome.
        return {**data, "exitCode": cmd.returncode}
    if cmd.returncode:
        reason = data.get("reason", f"system TextEdit {mode} witness unavailable (exit {cmd.returncode})")
        if isinstance(data.get("stage"), str):
            raise DocumentIdentityError(data["stage"], reason)
        raise ScopeError(reason)
    return data


def control_read(value):
    states = {"ready", "missing", "rosterUnavailable", "duplicate", "identityChanged", "buttonUnavailable", "enabledUnreadable",
              "disabled", "pressActionUnavailable", "rosterGeometryUnavailable", "cardOutsideRoster", "panelUnverified", "wrongDisplay"}
    if not isinstance(value, dict) or not isinstance(value.get("state"), str) or value["state"] not in states:
        return {"state": "invalidRead"}
    row = {"state": value["state"]}
    for key in ("matches", "regions", "enabledAXError", "actionsAXError", "panel"):
        if type(value.get(key)) is int:
            row[key] = value[key]
    for key in ("button", "enabled"):
        if type(value.get(key)) is bool:
            row[key] = value[key]
    return row


def wait_for_control(action, index, target, identity, trial, receipt, seconds=5):
    """Two completed, independent reads of the same installed panel before a single dispatch."""
    start = time.monotonic()
    deadline = start + seconds
    previous = None
    observations = []
    result = dict(trial=trial, **identity, status="BLOCKED", observationDeadlineSeconds=seconds, observations=observations)
    while (remaining := deadline - time.monotonic()) >= .15:
        row = {}
        stop = False
        try:
            data = action("ready", index=index, target=target, numbers=identity["numbers"], witness_timeout=remaining)
        except subprocess.TimeoutExpired:
            row["state"] = "readTimedOut"
            stop = True
        except ERRORS as error:
            row.update(state="guardRefused", reason=str(error))
            stop = True
        else:
            if not isinstance(data, dict) or any(data.get(k) != v for k, v in identity.items()):
                row["state"] = "readIdentityChanged"
                stop = True
            else:
                row = control_read(data.get("controlRead"))
                stop = row["state"] == "invalidRead"
        panel = row.get("panel")
        ready = (row["state"] == "ready" and row.get("matches") == row.get("regions") == 1 and
                 row.get("button") is True and row.get("enabled") is True and
                 row.get("enabledAXError") == row.get("actionsAXError") == 0 and type(panel) is int and panel > 0)
        if row["state"] == "ready" and not ready:
            row["state"] = "invalidRead"
            stop = True
        now = time.monotonic()
        row["afterSeconds"] = round(now-start, 4)
        observations.append(row)
        receipt.log("W01-sidebar-control-read", trial=trial, target=target, **row)
        if ready and now <= deadline and previous == panel:
            result.update(status="READY", panel=panel)
            return result
        if stop:
            break
        previous = panel if ready else None
        time.sleep(max(0, min(.12, deadline-now)))
    result["reason"] = "two stable installed sidebar control reads unavailable: " + (observations[-1]["state"] if observations else "noRead")
    return result


def press_once(action, index, control, **binding):
    try:
        reply = action("press", index=index, **binding)
    except ERRORS as exc:
        return dict(pressDisposition="UNKNOWN", axIssued=None, inputAcknowledged=None, reason=str(exc))
    code = reply.get("exitCode")
    observed = {"controlRead": control_read(reply["controlRead"])} if "controlRead" in reply else {}
    if reply.get("issued") is False and code == 2:
        detail = dict(pressDisposition="REFUSED", axIssued=False, inputAcknowledged=None, exitCode=code,
                      reason=reply.get("reason", "TextEdit witness refused before AXPress"), **observed)
        if isinstance(reply.get("stage"), str):
            detail["identityRefusalStage"] = reply["stage"]
        return detail
    if reply.get("issued") is not True:
        return dict(pressDisposition="UNKNOWN", axIssued=None, inputAcknowledged=None, exitCode=code,
                    reason=reply.get("reason", "TextEdit witness did not confirm whether AXPress was issued"), **observed)
    error = reply.get("axError")
    detail = dict(pressDisposition="ISSUED", axIssued=True, axError=error, control=reply.get("control"),
                  inputAcknowledged=None, exitCode=code, **observed)
    if reply.get("focusWitness") == "systemAX":
        detail["focusWitness"] = "systemAX"
    if code != 0 or reply.get("control") != control or type(error) is not int:
        detail["reason"] = "AXPress was issued but the exact target or acknowledgement was not confirmed"
    elif error:
        detail.update(inputAcknowledged=False, reason=f"installed sidebar returned AXError {error}")
    else:
        detail["inputAcknowledged"] = True
    return detail


def kernel_state(kit, pid, birth, timeout):
    """Query only the enrolled PID. A missing Launch Services record cannot establish exit."""
    cmd = subprocess.run([str(kit/"textedit-process"), str(pid)], capture_output=True, text=True, timeout=timeout)
    if cmd.returncode != 0:
        return {"state": "UNKNOWN", "exitCode": cmd.returncode}
    value = json.loads(cmd.stdout)
    if not isinstance(value, dict) or type(value.get("pid")) is not int or value["pid"] != pid:
        return {"state": "UNKNOWN", "reason": "kernel witness did not identify the enrolled PID"}
    live = value.get("birth")
    if live is None and value.get("absent") is True:
        return {"state": "ABSENT"}
    if type(live) is int and live > 0 and "absent" not in value:
        return {"state": "ALIVE" if live == birth else "REPLACED", "observedBirth": live}
    return {"state": "UNKNOWN", "reason": "kernel process identity unavailable"}


def cleanup_document(kit, folder, launched, action, seconds=4):
    instance = folder/"instance.json"
    callback = folder/"launch-callback.json"
    intent = folder/"launch-intent.json"
    if not instance.exists() and not launched and not callback.exists() and not intent.exists():
        return {"status": "NOT_RUN", "terminated": None, "reason": "no enrolled generation to close"}
    cleanup = {"status": "UNKNOWN", "terminated": None, "observations": []}

    def verify_record(record):
        if "architecture" in record:
            arch = record["architecture"]
            require(isinstance(arch, dict) and type(arch.get("cpu")) is int and arch["cpu"] > 0 and
                    type(arch.get("subtype")) is int and type(record.get("consoleUID")) is int and record["consoleUID"] == os.getuid() and
                    isinstance(record.get("hash"), str) and re.fullmatch(r"[0-9a-f]{40}(?:[0-9a-f]{24})?", record["hash"]),
                    "incomplete signed Mach-O slice enrollment")
        else:
            require(type(record.get("launch")) in (float, int) and record["launch"] > 0 and
                    isinstance(record.get("hash"), str) and bool(record["hash"]), "incomplete signed TextEdit enrollment")
        require(not launched or all(launched.get(k) == record.get(k) for k in ("pid", "birth", "launch", "hash", "architecture")),
                "durable enrollment and launch receipt disagree")

    pending = not instance.exists()
    if pending and not callback.exists():
        cleanup["reason"] = "open was submitted without a confirmed callback generation"
        return cleanup
    try:
        record = json.loads(private_file(callback if pending else instance))
        pid, birth = record.get("pid"), record.get("birth")
        require(type(pid) is int and pid > 1 and type(birth) is int and birth > 0,
                "no kernel generation on the durable enrollment")
        if pending:
            floor = json.loads(private_file(intent))["notBefore"]
            ceiling = record.get("callbackTime")
            require(type(floor) is int and type(ceiling) is int and 0 < floor <= birth <= ceiling and
                    record.get("notBefore") == floor and not launched,
                    "unconfirmed callback does not match a fresh launch intent")
        else:
            verify_record(record)
    except ERRORS as exc:
        cleanup["reason"] = str(exc)
        return cleanup
    cleanup.update(pid=pid, birth=birth, observationDeadlineSeconds=seconds)
    try:
        cleanup["closeReply"] = action("close")
    except ERRORS as exc:
        cleanup["closeError"] = str(exc)
        if isinstance(exc, DocumentIdentityError):
            cleanup["closeIdentityRefusalStage"] = exc.stage
    if pending:
        try:
            confirmed = json.loads(private_file(instance))
            require(confirmed["pid"] == pid and confirmed["birth"] == birth and "architecture" in confirmed,
                    "callback generation did not acquire a signed enrollment")
            verify_record(confirmed)
            cleanup["recoveredSignedEnrollment"] = True
        except ERRORS as exc:
            cleanup["reason"] = f"could not confirm callback generation for cleanup: {exc}"
            return cleanup
    # A close refusal or lost reply is never retried. Only read the same kernel generation.
    started = time.monotonic()
    deadline = started + seconds
    last = {"state": "UNKNOWN"}
    checks = 0
    while (remaining := deadline - time.monotonic()) > 0:
        try:
            observed = kernel_state(kit, pid, birth, timeout=min(1, remaining))
        except ERRORS as exc:
            observed = {"state": "UNKNOWN", "reason": str(exc)}
        checks += 1
        if not cleanup["observations"] or observed != last:
            cleanup["observations"].append({**observed, "afterSeconds": round(time.monotonic() - started, 4)})
        last = observed
        if last["state"] in ("ABSENT", "REPLACED"):
            break
        time.sleep(max(0, min(.1, deadline - time.monotonic())))
    cleanup.update(kernelChecks=checks, elapsedSeconds=round(time.monotonic() - started, 4))
    if last["state"] in ("ABSENT", "REPLACED"):
        cleanup.update(status="PASS", terminated=True)
    elif last["state"] == "ALIVE":
        cleanup.update(status="FAIL", terminated=False, reason="enrolled TextEdit generation still alive at last kernel read")
    else:
        cleanup["reason"] = "enrolled TextEdit generation exit could not be established"
    return cleanup


def run(workspace, receipt, desktop):
    folder = workspace.kit / str(uuid.uuid4())
    folder.mkdir(mode=0o700)
    for name in ("A.txt", "B.txt"):
        (folder/name).touch(mode=0o600, exist_ok=False)

    read_summary = {"recorded": 0, "unreported": 0, "invalid": 0, "noReply": 0, "observations": 0, "outcomes": {}}

    def record_reads(mode, coverage, readings):
        key = {"RECORDED": "recorded", "NOT_REPORTED": "unreported", "INVALID": "invalid", "NO_REPLY": "noReply"}[coverage]
        read_summary[key] += 1
        read_summary["observations"] += len(readings)
        for row in readings:
            name = row["status"]
            read_summary["outcomes"][name] = read_summary["outcomes"].get(name, 0) + 1
            if "expandedState" in row:
                extra = read_summary.setdefault("expandedOutcomes", {})
                extra[row["expandedState"]] = extra.get(row["expandedState"], 0) + 1
        receipt.log("W01-AX-window-read", operationStage="cleanup" if mode == "close" else stage, mode=mode,
                    trial=trial, coverage=coverage, reads=readings)

    bound_numbers = None
    def action(mode, **extra):
        if mode in ("sample", "close") and bound_numbers is not None:
            extra["numbers"] = bound_numbers
        return document_action(workspace, folder, desktop, mode, record_reads=record_reads, **extra)

    def wait(predicate, marker=None, seconds=5):
        deadline = time.monotonic() + seconds
        latest = "no readback"
        while time.monotonic() < deadline:
            try:
                data = action("sample", marker=marker)
            except ScopeError as error:
                latest = str(error)
            else:
                if predicate(data):
                    return data
                latest = "document identity, key/main status or input digest did not match"
            time.sleep(.1)
        raise ScopeError(latest)

    status = dict(status="BLOCKED", reason="TextEdit was not launched", issued=0, passes=0, cleanup=None, attempts=[], controlReadiness=[])
    launched = None
    attempt = None
    trial = None
    stage = "launch"
    try:
        launched = action("open")
        receipt.log("W01-system-document-launch", **launched)
        stage = "initial-readback"
        empty = hashlib.sha256(b"").hexdigest()
        initially = wait(lambda d: d["front"] and d["focused"] in d["numbers"]
                         and d["main"] == d["focused"] and d["hashes"] == [empty, empty])
        numbers = initially["numbers"]
        require(isinstance(numbers, list) and len(numbers) == 2 and all(type(n) is int and 0 < n <= 0xffffffff for n in numbers)
                and numbers[0] != numbers[1], "initial system document numbers did not identify two distinct windows")
        bound_numbers = list(numbers)
        first = 1-numbers.index(initially["focused"])
        for turn in range(10):
            index = (first+turn) % 2
            n = numbers[index]
            attempt = None
            trial = turn + 1
            stage = "before-press"
            before = wait(lambda d: d["front"] and d["numbers"] == numbers)
            stage = "control-readiness"
            control = f"current-desktop-window:{launched['pid']}:{n}"
            identity = dict(control=control, hostPID=workspace.host["pid"], hostBirth=workspace.host_birth,
                            hostHash=workspace.host["codeHash"], documentBirth=launched["birth"], numbers=numbers, display=workspace.display, space=desktop)
            readiness = wait_for_control(action, index, n, identity, trial, receipt)
            status["controlReadiness"].append(readiness)
            require(readiness["status"] == "READY", readiness.get("reason", "installed sidebar control unavailable"))
            attempt = dict(scenario="W01", application="com.apple.TextEdit", trial=trial, target=n,
                           status="UNKNOWN", pressDisposition="UNKNOWN", axIssued=None, inputAcknowledged=None)
            receipt.attempts.append(attempt)
            status["attempts"].append(attempt)
            receipt.log("W01-system-document-intent", **attempt)
            stage = "sidebar-press"
            reply = press_once(action, index, control, target=n, numbers=numbers, panel=readiness["panel"])
            attempt.update(reply)
            status["issued"] += int(reply["axIssued"] is True)
            receipt.log("W01-installed-sidebar-press", trial=turn+1, target=n, **reply)
            if reply["inputAcknowledged"] is not True:
                if reply["axIssued"] is False:
                    attempt["status"] = "BLOCKED"
                elif reply["inputAcknowledged"] is False:
                    attempt["status"] = "FAIL"
                raise ScopeError(reply["reason"])
            stage = "focus-readback"
            try:
                wait(lambda d: d["front"] and d["numbers"] == numbers and d["focused"] == n and d["main"] == n)
            except ScopeError as focus_error:
                try:
                    actual = action("sample")
                except ERRORS:
                    raise focus_error
                if actual.get("numbers") == numbers and actual.get("front") and actual.get("focused") in numbers and actual["focused"] != n:
                    attempt.update(status="FAIL", actual=actual["focused"], reason="another enrolled TextEdit window was focused")
                    receipt.log("W01-wrong-window", trial=turn+1, actual=actual["focused"], expected=n)
                    continue
                raise
            stage = "marker"
            marker = "NP"+uuid.uuid4().hex[:10]
            marker_reply = action("marker", index=index, target=n, numbers=numbers, marker=marker)
            require(marker_reply.get("issued") is True, "marker was not admitted in the exact target editor")
            counts = [0, 0]
            counts[index] = 1
            stage = "input-readback"
            landed = wait(lambda d: d["numbers"] == numbers and d["focused"] == d["main"] == n
                          and d["markerCounts"] == counts and d["hashes"][index] != before["hashes"][index]
                          and d["hashes"][1-index] == before["hashes"][1-index], marker)
            status["passes"] += 1
            attempt.update(status="PASS", siblingUnchanged=True)
            receipt.log("W01-system-document-readback", trial=turn+1, focused=n, markerCounts=counts, hashes=landed["hashes"],
                        markerFocusWitness=marker_reply.get("focusWitness"), readbackFocusWitness=landed.get("focusWitness"))
        stage = "complete"
        status.update(status="PASS" if status["passes"] == 10 else "FAIL",
                      reason=f'{status["passes"]}/10 installed sidebar selections confirmed exact TextEdit key/main and target-only input.')
    except ERRORS as exc:
        if isinstance(exc, DocumentIdentityError):
            status["identityRefusalStage"] = exc.stage
        if attempt is not None:
            attempt.update(reason=str(exc), stage=stage)
        status.update(status=attempt["status"] if attempt is not None else "BLOCKED", reason=str(exc))
    finally:
        status.update(operationStatus=status["status"], operationStage=stage)
        status["pressCounts"] = {state: sum(a["pressDisposition"] == state for a in status["attempts"])
                                 for state in ("ISSUED", "REFUSED", "UNKNOWN")}
        try:
            receipt.log("W01-system-document-operation", status=status["operationStatus"], stage=stage,
                        reason=status["reason"], pressCounts=status["pressCounts"])
        finally:
            cleanup = status["cleanup"] = cleanup_document(workspace.kit, folder, launched, action)
            if cleanup["status"] == "FAIL" or (cleanup["status"] == "UNKNOWN" and status["status"] != "FAIL"):
                status["status"] = cleanup["status"]
            try:
                receipt.log("W01-system-document-cleanup", **cleanup)
            finally:
                status["axWindowReads"] = read_summary
                receipt.write("W01-system-documents.json", status)
    return status
