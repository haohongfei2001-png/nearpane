"""W01 on two owned files in a fresh, signed system TextEdit process."""
import hashlib
import json
import os
import subprocess
import time
import uuid

from space_scope import ScopeError, require


def run(workspace, receipt, desktop):
    folder = workspace.kit / str(uuid.uuid4())
    folder.mkdir(mode=0o700)
    for name in ("A.txt", "B.txt"):
        (folder/name).touch(mode=0o600, exist_ok=False)

    def action(mode, **extra):
        request = dict(mode=mode, folder=str(folder), display=workspace.display, space=desktop,
                       hostPID=workspace.host["pid"], hostHash=workspace.host["codeHash"], hid=workspace.hid, **extra)
        cmd = subprocess.run([str(workspace.kit/"textedit")], input=json.dumps(request),
                             capture_output=True, text=True, timeout=13)
        data = json.loads(cmd.stdout)
        if cmd.returncode:
            raise ScopeError(data.get("reason", "system TextEdit witness unavailable"))
        return data

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

    status = dict(status="BLOCKED", reason="TextEdit was not launched", issued=0, passes=0, cleanup=None)
    try:
        launched = action("open")
        receipt.log("W01-system-document-launch", **launched)
        empty = hashlib.sha256(b"").hexdigest()
        initially = wait(lambda d: d["front"] and d["focused"] in d["numbers"]
                         and d["main"] == d["focused"] and d["hashes"] == [empty, empty])
        numbers = initially["numbers"]
        first = 1-numbers.index(initially["focused"])
        for turn in range(10):
            index = (first+turn) % 2
            n = numbers[index]
            before = wait(lambda d: d["front"] and d["numbers"] == numbers)
            attempt = dict(scenario="W01", application="com.apple.TextEdit", trial=turn+1, target=n,
                           status="UNKNOWN", inputAcknowledged=None)
            receipt.attempts.append(attempt)
            receipt.log("W01-system-document-intent", **attempt)
            reply = action("press", index=index)
            attempt["inputAcknowledged"] = reply.get("axError") == 0
            status["issued"] += int(reply.get("issued") is True)
            receipt.log("W01-installed-sidebar-press", trial=turn+1, **reply)
            if not attempt["inputAcknowledged"]:
                attempt["status"] = "FAIL"
                continue
            try:
                wait(lambda d: d["front"] and d["numbers"] == numbers and d["focused"] == n and d["main"] == n)
            except ScopeError:
                # A definite owned but wrong window is a failure. Never send its editor a marker.
                actual = action("sample")
                if actual["numbers"] == numbers and actual["front"] and actual["focused"] != n:
                    attempt.update(status="FAIL", actual=actual["focused"])
                    receipt.log("W01-wrong-window", trial=turn+1, actual=actual["focused"], expected=n)
                    continue
                raise
            marker = "NP"+uuid.uuid4().hex[:10]
            require(action("marker", index=index, marker=marker).get("issued"), "marker was not admitted in the exact target editor")
            counts = [0, 0]
            counts[index] = 1
            landed = wait(lambda d: d["numbers"] == numbers and d["focused"] == d["main"] == n
                          and d["markerCounts"] == counts and d["hashes"][index] != before["hashes"][index]
                          and d["hashes"][1-index] == before["hashes"][1-index], marker)
            status["passes"] += 1
            attempt.update(status="PASS", siblingUnchanged=True)
            receipt.log("W01-system-document-readback", trial=turn+1, focused=n, markerCounts=counts, hashes=landed["hashes"])
        status.update(status="PASS" if status["passes"] == 10 else "FAIL",
                      reason=f'{status["passes"]}/10 installed sidebar selections confirmed exact TextEdit key/main and target-only input.')
    except (ValueError, OSError, KeyError, subprocess.SubprocessError) as exc:
        status.update(status="FAIL" if status["issued"] else "BLOCKED", reason=str(exc))
    finally:
        if (folder/"instance.json").exists():
            try:
                result = action("close")
                deadline = time.monotonic()+4
                while time.monotonic()<deadline and (result := action("terminated")).get("terminated") is not True:
                    time.sleep(.1)
                require(result.get("terminated") is True, "owned TextEdit process did not exit")
                status["cleanup"] = result
            except (ValueError, OSError, subprocess.SubprocessError) as exc:
                status.update(status="FAIL", cleanup={"reason": str(exc)}, reason="Owned TextEdit cleanup is incomplete.")
        receipt.write("W01-system-documents.json", status)
    return status
