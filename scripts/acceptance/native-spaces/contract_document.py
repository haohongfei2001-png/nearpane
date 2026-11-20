"""W01 on two owned files in a fresh, signed system TextEdit process."""
import hashlib
import json
import subprocess
import time
import uuid

from space_scope import ScopeError, private_file, require


ERRORS = (ValueError, OSError, KeyError, TypeError, subprocess.SubprocessError)


def document_action(workspace, folder, desktop, mode, **extra):
    request = dict(mode=mode, folder=str(folder), display=workspace.display, space=desktop,
                   hostPID=workspace.host["pid"], hostHash=workspace.host["codeHash"], hid=workspace.hid, **extra)
    cmd = subprocess.run([str(workspace.kit/"textedit")], input=json.dumps(request),
                         capture_output=True, text=True, timeout=13)
    try:
        data = json.loads(cmd.stdout)
        require(isinstance(data, dict), "document witness reply was not an object")
    except ValueError as exc:
        raise ScopeError(f"TextEdit {mode} witness returned no valid reply (exit {cmd.returncode})") from exc
    if mode == "press":
        # A guard refusal on exit 2 is evidence. Losing the reply is a different outcome.
        return {**data, "exitCode": cmd.returncode}
    if cmd.returncode:
        raise ScopeError(data.get("reason", f"system TextEdit {mode} witness unavailable (exit {cmd.returncode})"))
    return data


def press_once(action, index, control):
    try:
        reply = action("press", index=index)
    except ERRORS as exc:
        return dict(pressDisposition="UNKNOWN", axIssued=None, inputAcknowledged=None, reason=str(exc))
    code = reply.get("exitCode")
    if reply.get("issued") is False and code == 2:
        return dict(pressDisposition="REFUSED", axIssued=False, inputAcknowledged=None, exitCode=code,
                    reason=reply.get("reason", "TextEdit witness refused before AXPress"))
    if reply.get("issued") is not True:
        return dict(pressDisposition="UNKNOWN", axIssued=None, inputAcknowledged=None, exitCode=code,
                    reason=reply.get("reason", "TextEdit witness did not confirm whether AXPress was issued"))
    error = reply.get("axError")
    detail = dict(pressDisposition="ISSUED", axIssued=True, axError=error, control=reply.get("control"),
                  inputAcknowledged=None, exitCode=code)
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
    if not instance.exists() and not launched:
        return {"status": "NOT_RUN", "terminated": None, "reason": "no enrolled generation to close"}
    cleanup = {"status": "UNKNOWN", "terminated": None, "observations": []}
    try:
        record = json.loads(private_file(instance))
        pid, birth = record["pid"], record["birth"]
        require(type(pid) is int and pid > 1 and type(birth) is int and birth > 0,
                "no kernel generation on the durable enrollment")
        require(type(record.get("launch")) in (float, int) and record["launch"] > 0 and
                isinstance(record.get("hash"), str) and bool(record["hash"]), "incomplete signed TextEdit enrollment")
        require(not launched or all(launched.get(k) == record[k] for k in ("pid", "birth", "launch", "hash")),
                "durable enrollment and launch receipt disagree")
    except ERRORS as exc:
        cleanup["reason"] = str(exc)
        return cleanup
    cleanup.update(pid=pid, birth=birth, observationDeadlineSeconds=seconds)
    try:
        cleanup["closeReply"] = action("close")
    except ERRORS as exc:
        cleanup["closeError"] = str(exc)
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

    def action(mode, **extra):
        return document_action(workspace, folder, desktop, mode, **extra)

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

    status = dict(status="BLOCKED", reason="TextEdit was not launched", issued=0, passes=0, cleanup=None, attempts=[])
    launched = None
    attempt = None
    stage = "launch"
    try:
        launched = action("open")
        receipt.log("W01-system-document-launch", **launched)
        stage = "initial-readback"
        empty = hashlib.sha256(b"").hexdigest()
        initially = wait(lambda d: d["front"] and d["focused"] in d["numbers"]
                         and d["main"] == d["focused"] and d["hashes"] == [empty, empty])
        numbers = initially["numbers"]
        first = 1-numbers.index(initially["focused"])
        for turn in range(10):
            index = (first+turn) % 2
            n = numbers[index]
            attempt = None
            stage = "before-press"
            before = wait(lambda d: d["front"] and d["numbers"] == numbers)
            attempt = dict(scenario="W01", application="com.apple.TextEdit", trial=turn+1, target=n,
                           status="UNKNOWN", pressDisposition="UNKNOWN", axIssued=None, inputAcknowledged=None)
            receipt.attempts.append(attempt)
            status["attempts"].append(attempt)
            receipt.log("W01-system-document-intent", **attempt)
            stage = "sidebar-press"
            reply = press_once(action, index, f"current-desktop-window:{launched['pid']}:{n}")
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
            marker_reply = action("marker", index=index, marker=marker)
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
                receipt.write("W01-system-documents.json", status)
    return status
