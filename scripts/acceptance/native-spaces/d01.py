#!/usr/bin/env python3
"""D01 installed-sidebar mouse drag. A missing fresh positive scope is a zero-input refusal."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import time
import uuid

from acceptance import checked, encode, identity, manifest, wait_state
from space_scope import ScopeError, load_scope, validate_live


def require(condition, message):
    if not condition:
        raise ScopeError(message)


def reached(sample, target, sibling, numbers, front, closed=False):
    expected_ax = [numbers[1]] if closed else sorted(numbers)
    return (sample.get("target") == target and sample.get("sibling") == [sibling]
            and sample.get("fixtureAXNumbers") == expected_ax
            and (sample.get("front"), sample.get("focused")) == front)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("mode", choices=("preflight", "run"))
    ap.add_argument("output", type=Path)
    ap.add_argument("--scope", type=Path)
    ap.add_argument("--kit", required=True, type=Path)
    args = ap.parse_args()
    output = args.output
    output.mkdir(exist_ok=False, parents=True)
    log = (output / "actions.jsonl").open("x", encoding="utf-8")
    result = {"scenario": "D01", "status": "BLOCKED", "movementAttempts": 0, "fixtureStarted": False,
              "inputs": 0, "completed": [], "cleanup": {"required": False}}

    def record(kind, **details):
        log.write(json.dumps(dict(event=kind, monotonic=time.monotonic(), **details), ensure_ascii=False) + "\n")
        log.flush()
        os.fsync(log.fileno())

    kit = args.kit.resolve()
    observer = kit / "observe"
    driver = kit / "d01-input"
    app = kit / "Field Notes.app"
    independent = lambda: json.loads(checked([str(observer)], timeout=8))
    proc = None
    before = None
    numbers = []
    try:
        require(args.scope is not None and args.scope.is_file(), "No positive, unexpired test-Space creation manifest.")
        before = independent()
        frozen = manifest(before)
        (output / "manifest.json").write_text(encode(frozen))
        require(frozen["signatureValid"] and frozen["loadedMatchesInstalled"] and frozen["source"],
                "Installed candidate and loaded Host must match the signed manifest.")
        boot = checked(["/usr/sbin/sysctl", "-n", "kern.bootsessionuuid"]).strip()
        scope = load_scope(args.scope, before, boot, before["uptime"])
        host = before["host"]
        current = validate_live(scope, before, host)
        require(len(before["displays"]) == 1 and not scope["witnesses"] and len(scope["spaces"]) >= 2,
                "D01 needs two uncontested positively bound Spaces on the single fixture display.")
        ids = {s["id"]: s["uuid"] for s in scope["spaces"]}
        a = current
        b = next(s["id"] for s in scope["spaces"] if s["id"] != a)
        permissions = frozen.get("installedHostStartupPermissions") or {}
        require(permissions.get("accessibility") is True and before.get("observerAX"), "Installed Host or independent observer lacks AX.")
        initial_focus = (before.get("frontmostPID"), before.get("focusedNumber"))
        require(all(type(v) is int and v > 0 for v in initial_focus), "Original focused window is not independently identifiable.")
        sign = identity(app / "Contents/MacOS/FieldNotes")["CDHash"]
        require(sign, "Test app signature is unavailable.")
        record("preflight", origin=a, target=b, source=frozen["source"], display=scope["display"])
        if args.mode == "preflight":
            result.update(status="PREFLIGHT_ONLY", reason="No system input requested.")
            return
        session = str(uuid.uuid4())
        folder = kit / session
        folder.mkdir(mode=0o700)
        proc = subprocess.Popen([str(app / "Contents/MacOS/FieldNotes"), str(folder), "2"],
                                stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        result["fixtureStarted"] = True
        result["cleanup"] = {"required": True}
        state = wait_state(folder / "windows.json", lambda s: s.get("session") == session and s.get("pid") == proc.pid
                           and len(set(s.get("numbers", []))) == 2, time.monotonic() + 7)
        require(state, "Fresh isolated fixture did not publish two unique windows.")
        numbers = state["numbers"]
        latest = independent()
        if latest.get("frontmostPID") == proc.pid and latest.get("focusedNumber") == numbers[0]:
            numbers = list(reversed(numbers))
        birth = int(checked([str(driver), "--fixture-birth", str(proc.pid), sign, str(app)]).strip())
        ws = [dict(number=n, pid=proc.pid, birth=birth, space=a, bundleID="net.example.spaces-document",
                   bundlePath=str(app), codeHash=sign) for n in numbers]
        scope["witnesses"] = ws.copy()
        latest = independent()
        require(validate_live(scope, latest, host) == a and proc.poll() is None, "Fixture changed the original desktop.")
        focus = (latest["frontmostPID"], latest["focusedNumber"])
        require(focus == initial_focus or focus[0] == proc.pid and focus[1] in numbers, "Unexpected foreground after fixture creation.")
        record("bound", pid=proc.pid, birth=birth, numbers=numbers, session=session, current=a, focus=focus)

        def call(action, src, dst):
            request = dict(action=action, hostPID=host["pid"], hostHash=host["codeHash"],
                           fixture=str(app), fixtureHash=sign, target=ws[0], sibling=ws[1],
                           display=scope["display"], source=src, dest=dst, sourceUUID=ids[src], destUUID=ids[dst],
                           current=a, frontPID=focus[0], focused=focus[1], expiresUptime=scope["expiresUptime"])
            r = subprocess.run([str(driver)], input=json.dumps(request), capture_output=True, text=True, timeout=12)
            data = json.loads(r.stdout)
            if action != "sample":
                record("driver-result", action=action, evidence=data, exit=r.returncode)
                result["inputs"] += data.get("inputs", 0)
            require(r.returncode == 0, data.get("reason", "Driver refused"))
            return data

        for action, src, dst, expected in [("cancel", a, b, [a]), ("drag", a, b, [b]),
                                            ("drag", b, a, [a]), ("close-during-drag", a, b, None)]:
            require(proc.poll() is None, "Fixture owner exited")
            pre = independent()
            require(validate_live(scope, pre, host) == a, "Current desktop changed")
            require(reached(call("sample", src, dst), [src], a, numbers, focus), "Source, sibling or original focus changed")
            record("intent", action=action, source=src, destination=dst, window=numbers[0], sibling=numbers[1])
            if action == "drag":
                result["movementAttempts"] += 1
            require(call(action, src, dst).get("productDragWitnessed"), "Mouse drag did not reach the expected drop")
            closed = action == "close-during-drag"
            limit = time.monotonic() + 4
            stable_since = None
            while True:
                sample = call("sample", src, dst)
                if reached(sample, expected, a, numbers, focus, closed):
                    stable_since = stable_since or time.monotonic()
                    if time.monotonic() - stable_since >= .24:
                        break
                else:
                    stable_since = None
                require(time.monotonic() < limit, "Independent membership, focus or window generation failed to settle")
                time.sleep(.08)
            if closed:
                scope["witnesses"] = [ws[1]]
            else:
                ws[0]["space"] = expected[0]
            require(validate_live(scope, independent(), host) == a, "Unexpected desktop or unrelated member after drag")
            record("confirmed", action=action, receipt=sample)
            result["completed"].append(dict(action=action, fromSpace=src, toSpace=dst))
        result.update(status="PASS", reason="Four installed-sidebar gestures and independent final readbacks matched.")
    except (OSError, KeyError, ValueError, TypeError, subprocess.SubprocessError) as exc:
        result["status"] = "FAIL" if result["inputs"] else "BLOCKED"
        result["reason"] = str(exc)
    finally:
        if proc is not None:
            try:
                (folder / "close").touch(exist_ok=False)
                try:
                    proc.wait(timeout=4)
                except subprocess.TimeoutExpired:
                    proc.terminate()
                    proc.wait(timeout=4)
                end = independent()
                absence = json.loads(checked([str(observer), "absence", *map(str, numbers)])) if numbers else {}
                clear = len(numbers) == 2 and absence.get("allGone") is True
                restored = (end.get("frontmostPID"), end.get("focusedNumber")) == initial_focus and end.get("scopes") == before.get("scopes")
                result["cleanup"] = dict(required=True, exit=proc.returncode, windowsAbsent=clear, originalFocusAndSpacesRestored=restored)
                if not clear or not restored:
                    result.update(status="FAIL", reason="Fixture cleanup or original focus/Space readback incomplete")
            except (OSError, ValueError, subprocess.SubprocessError) as exc:
                result.update(status="FAIL", reason="Cleanup incomplete: " + str(exc))
        record("end", status=result["status"])
        log.close()
        (output / "D01.json").write_text(encode(result))
        print(result["status"], result.get("reason", ""))
        if result["status"] not in ("PASS", "PREFLIGHT_ONLY"):
            raise SystemExit(2)


if __name__ == "__main__":
    main()
