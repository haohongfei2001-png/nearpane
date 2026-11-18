#!/usr/bin/env python3
"""Independent macOS observations of the normally launched, installed Nearpane sidebar."""
import argparse
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import platform
import plistlib
import re
import subprocess
import time
import uuid

APP = Path("/Applications/Nearpane.app")
ROOT = Path(__file__).resolve().parents[3]
SCENARIOS = "S01 S02 S03 W01 W02 W03 V01 D01 L01 L02 C01 F01 M01 R01 P01 R02 N01 I01".split()


def checked(cmd, *, timeout=15, env=None):
    return subprocess.run(cmd, check=True, capture_output=True, text=True, timeout=timeout, env=env).stdout


def encode(obj):
    return json.dumps(obj, ensure_ascii=False, indent=2, sort_keys=True) + "\n"


def digest(path):
    with path.open("rb") as f:
        h = hashlib.sha256()
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
        return h.hexdigest()


def identity(path):
    p = subprocess.run(["/usr/bin/codesign", "-dv", "--verbose=4", str(path)], text=True, capture_output=True)
    fields = dict(s.split("=", 1) for s in p.stderr.splitlines() if "=" in s)
    return {k: fields.get(k) for k in ("Identifier", "CDHash", "TeamIdentifier")}


def host_startup_permissions(host):
    if not host or not host.get("launch"):
        return None
    start = dt.datetime.fromtimestamp(host["launch"] - 1).strftime("%Y-%m-%d %H:%M:%S")
    predicate = (f'processID == {int(host["pid"])} AND subsystem == "com.holdsnow.nearpane.alpha" AND '
                 'category == "WindowOverview" AND eventMessage BEGINSWITH "Window overview access:"')
    try:
        logs = checked(["/usr/bin/log", "show", "--style", "compact", "--start", start, "--predicate", predicate])
    except (subprocess.SubprocessError, OSError):
        return None
    matches = re.findall(r'Window overview access: screen=(true|false) accessibility=(true|false)', logs)
    if len(matches) != 1:
        return None
    screen, ax = matches[0]
    return {"screen": screen == "true", "accessibility": ax == "true", "source": "installed Host startup log"}


def manifest(observation):
    plist = plistlib.loads((APP / "Contents/Info.plist").read_bytes())
    host = APP / "Contents/MacOS" / plist["CFBundleExecutable"]
    files = [host]
    for item in sorted((APP / "Contents/Helpers").iterdir()):
        if item.is_file():
            files.append(item)
        elif item.suffix == ".app":
            exe = plistlib.loads((item / "Contents/Info.plist").read_bytes())["CFBundleExecutable"]
            files.append(item / "Contents/MacOS" / exe)
    binaries = {str(p.relative_to(APP)): {**identity(p), "sha256": digest(p)} for p in files}
    verified = subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(APP)], capture_output=True)
    live = observation.get("host", {})
    return {"installed": str(APP), "bundleID": plist["CFBundleIdentifier"],
            "source": plist.get("NearpaneSourceRevision"), "version": plist["CFBundleShortVersionString"],
            "build": plist["CFBundleVersion"], "binaries": binaries, "signatureValid": verified.returncode == 0,
            "loadedMatchesInstalled": bool(live.get("codeHash")) and live["codeHash"] == identity(host)["CDHash"],
            "installedHostStartupPermissions": host_startup_permissions(live),
            "installedActionHelperPin": plist.get("NearpaneSpaceActionSHA256"),
            "os": checked(["sw_vers", "-productVersion"]).strip(), "osBuild": checked(["sw_vers", "-buildVersion"]).strip(),
            "arch": platform.machine(), "sip": checked(["csrutil", "status"]).strip(),
            "checkoutRevision": checked(["git", "-C", str(ROOT), "rev-parse", "HEAD"]).strip(),
            "checkoutDomainsLockSHA256": digest(ROOT / "Dependencies/domains.lock.json"),
            "observed": observation}


class Receipt:
    def __init__(self, output):
        self.output = output
        output.mkdir(parents=True, exist_ok=False)
        self.stream = (output / "actions.jsonl").open("x", encoding="utf-8")
        self.scenarios = {k: {"status": "NOT_RUN", "reason": "No completed production sample in this run."}
                          for k in SCENARIOS}
        self.attempts = []
        self.summary = {}

    def log(self, event, **fields):
        json.dump(dict(event=event, monotonic=time.monotonic(), **fields), self.stream, ensure_ascii=False)
        self.stream.write("\n")
        self.stream.flush()
        os.fsync(self.stream.fileno())

    def write(self, name, value):
        (self.output / name).write_text(encode(value))

    def finish(self):
        self.stream.close()
        data = {**self.summary, "scenarios": self.scenarios, "productAttempts": self.attempts,
                "attemptCount": len(self.attempts), "failedAttempts": sum(x["status"] == "FAIL" for x in self.attempts),
                "unknownAttempts": sum(x["status"] == "UNKNOWN" for x in self.attempts),
                "performancePercentiles": None, "allRequiredPassed": all(x["status"] == "PASS" for x in self.scenarios.values())}
        self.write("results.json", data)
        lines = ["# Installed Native Spaces acceptance", "", f"Product attempts: {len(self.attempts)}.", "",
                 "| Scenario | Result | Evidence |", "| --- | --- | --- |"]
        lines += [f"| {k} | {v['status']} | {v['reason']} |" for k, v in self.scenarios.items()]
        (self.output / "RESULTS.md").write_text("\n".join(lines) + "\n")


def catalog_match(o):
    system = {f'native-space-row:{s["scope"]}:{r["id"]}' for s in o.get("scopes") or [] for r in s["records"]
              if r["type"] in (0, 4)}
    rows = o.get("sidebar", {}).get("rows", [])
    ui = {r["identifier"] for r in rows if r["matches"] == 1}
    currents = {f'native-space-row:{s["scope"]}:{s["current"]}' for s in o.get("scopes") or []}
    selected = {r["identifier"] for r in rows if r["selected"] is True or r.get("currentLabel")}
    return {"independentCount": len(system), "sidebarCount": len(rows), "rowIdentitiesMatch": bool(system) and ui == system,
            "highlightMatchesSystem": bool(currents) and selected == currents}


def wait_state(path, predicate, deadline):
    while time.monotonic() < deadline:
        try:
            data = json.loads(path.read_text())
        except (FileNotFoundError, ValueError):
            data = {}
        if predicate(data):
            return data
        time.sleep(.06)
    return {}


def controlled_window(observer, initial, frozen, rec):
    if not frozen["signatureValid"] or not frozen["loadedMatchesInstalled"] or not frozen["source"]:
        return "A signed running candidate with a frozen source revision is required."
    if not initial["observerAX"] or len(initial["displays"]) != 1 or len(initial.get("scopes") or []) != 1:
        return "One visible display, an independent current Space and observer AX are required for this fixture."
    scope = initial["scopes"][0]
    if not any(r["id"] == scope["current"] and r["type"] == 0 for r in scope["records"]):
        return "Original desktop is not an ordinary Space."
    app = observer.parent / "Field Notes.app"
    fx = app / "Contents/MacOS/FieldNotes"
    sign = identity(fx)["CDHash"]
    if not sign:
        return "Missing fixture signing identity."
    session = str(uuid.uuid4())
    folder = observer.parent / session
    folder.mkdir(mode=0o700)
    path = folder / "windows.json"
    proc = subprocess.Popen([str(fx), str(folder)], stdin=subprocess.DEVNULL,
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    rec.log("fixture-created", fixturePID=proc.pid, cdhash=sign, session=session)
    written = ["", ""]
    host = initial["host"]
    independent = lambda: json.loads(checked([str(observer)]))
    trials = []
    numbers = []
    reason = "Two-window fixture subtest finished; actual document application coverage requires its own run."
    try:
        state = wait_state(path, lambda d: d.get("session") == session and d.get("pid") == proc.pid and
                           len(set(d.get("numbers", []))) == 2, time.monotonic() + 8)
        if not state:
            startup = folder / "startup.json"
            rec.log("fixture-startup-incomplete", exit=proc.poll(), startup=json.loads(startup.read_text()) if startup.exists() else None)
            return "Fixture did not produce a unique pair of owned windows."
        numbers = state["numbers"]
        rec.log("fixture-bound", numbers=numbers, pid=proc.pid)
        time.sleep(.6)
        for turn in range(10):
            idx = turn % 2
            n = numbers[idx]
            args = [str(host["pid"]), host["codeHash"], str(proc.pid), str(n), str(app), sign,
                    scope["scope"], str(scope["current"])]
            before = independent()
            allowed_front = initial.get("frontmostPID") if turn == 0 else proc.pid
            if before.get("frontmostPID") != allowed_front or before.get("host") != host:
                return "Focus or installed process changed before the next consented selection."
            intent = str(uuid.uuid4())
            rec.log("window-intent", intent=intent, target=n, sibling=numbers[1-idx], beforeFocus=before.get("frontmostPID"))
            click = json.loads(checked([str(observer), "press", *args]))
            rec.log("sidebar-press", intent=intent, result=click)
            if not click.get("issued"):
                return click["reason"]
            attempt = {"id": intent, "kind": "window", "status": "UNKNOWN"}
            rec.attempts.append(attempt)
            focused = wait_state(path, lambda d: d.get("pid") == proc.pid and d.get("key") == n and
                                 d.get("main") == n and d.get("editorsFocused", [False, False])[idx],
                                 time.monotonic() + 4)
            if not focused or click.get("axError") != 0:
                attempt["status"] = "FAIL"
                rec.log("destination-not-confirmed", intent=intent, markerSubmitted=False)
                return "Product selection did not reach the exact owned key/main window; no marker was sent."
            marker = "NP" + uuid.uuid4().hex[:10]
            sent = json.loads(checked([str(observer), "marker", *args], env={**os.environ, "NP_TRIAL_MARKER": marker}))
            rec.log("pid-targeted-marker", intent=intent, result=sent)
            if not sent.get("issued"):
                attempt["status"] = "FAIL"
                return sent["reason"]
            written[idx] += marker
            expected = [hashlib.sha256(s.encode()).hexdigest() for s in written]
            after = wait_state(path, lambda d: d.get("sha256") == expected and d.get("key") == n,
                               time.monotonic() + 2)
            attempt["status"] = "PASS" if after else "FAIL"
            rec.log("input-readback", intent=intent, match=bool(after), expectedDocumentDigests=expected)
            if not after:
                return "Synthetic input receipt or unchanged sibling failed; stopped after the first discrepancy."
            trials.append(n)
        return reason
    finally:
        (folder / "close").touch()
        try:
            proc.wait(timeout=4)
        except subprocess.TimeoutExpired:
            proc.terminate()
            proc.wait(timeout=4)
        after = independent()
        rec.summary["controlledWindowTrials"] = len(trials)
        rec.summary["cleanup"] = {"ownedProcessExited": proc.returncode is not None,
                                  "frontmostRestored": after.get("frontmostPID") == initial.get("frontmostPID"),
                                  "originalFocusedWindowRestored": bool(initial.get("focusedNumber")) and after.get("focusedNumber") == initial["focusedNumber"],
                                  "windowNumbersGone": bool(numbers) and json.loads(checked([str(observer), "absence", *map(str, numbers)]))["allGone"],
                                  "scopesRestored": after.get("scopes") == initial.get("scopes")}
        rec.log("cleanup", **rec.summary["cleanup"])


def hidden_budget(observer, initial, frozen, rec):
    host = initial.get("host", {})
    if not frozen["signatureValid"] or not frozen["loadedMatchesInstalled"] or not host:
        return "No verified installed Host."
    pid = host["pid"]
    counters = lambda: json.loads(checked([str(observer.parent / "metrics"), str(pid)]))
    before = counters()
    rec.log("metrics-visible", sample=before)
    if before["visibleDisplays"] > 1 or before["gallerySessions"]:
        return "Multiple preview surfaces open; user-owned presentation preserved."
    was_visible = before["visibleDisplays"] == 1
    changed = False
    def toggle(direction):
        result = json.loads(checked([str(observer), "surface", str(pid), host["codeHash"], direction]))
        rec.log("status-menu-toggle", direction=direction, result=result)
        return result
    try:
        if was_visible:
            sent = toggle("hide")
            changed = sent["issued"]
            if not changed or sent.get("axError") != 0:
                return "Hide not confirmed via product menu."
        start = time.monotonic()
        points = []
        for delay in [2, 12, 22, 32, 42, 52, 62]:
            time.sleep(max(0, start + delay - time.monotonic()))
            m = counters()
            points.append(m)
            rec.log("metrics-hidden-interval", elapsed=time.monotonic()-start, sample=m)
            if m["visibleDisplays"] or m["gallerySessions"] or m["activeStreams"] or m["capturesInFlight"]:
                return "Preview visible or capturing during the hidden interval."
        ok = all(m["captureRequests"] == points[0]["captureRequests"] for m in points)
        rec.summary["hiddenBudget"] = {"observedSeconds": 60, "zeroNewRequests": ok,
                                       "priorScreenPermission": (frozen.get("installedHostStartupPermissions") or {}).get("screen")}
        return "Hidden interval completed; remaining N01 visual, native timing and memory batches require separate samples."
    finally:
        if changed:
            live = json.loads(checked([str(observer)]))
            if (live.get("host") == host and not counters()["visibleDisplays"] and
                    live.get("frontmostPID") == initial.get("frontmostPID")):
                toggle("show")
                time.sleep(.6)
            rec.summary["sidebarVisibilityRestored"] = counters()["visibleDisplays"] == before["visibleDisplays"]


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--observer", required=True, type=Path)
    ap.add_argument("mode", choices=("preflight", "controlled-window", "hidden-budget"))
    ap.add_argument("output", type=Path, help="fresh evidence directory")
    args = ap.parse_args()
    rec = Receipt(args.output)
    try:
        read = lambda: json.loads(checked([str(args.observer)]))
        first = read()
        time.sleep(.18)
        second = read()
        frozen = manifest(second)
        rec.write("manifest.json", frozen)
        stable = first.get("scopes") == second.get("scopes") and first.get("host") == second.get("host")
        rec.summary.update({"mode": args.mode, "stable": stable, "catalog": catalog_match(second),
                            "cleanup": {"fixtureObjectsCreated": 0}})
        rec.log("preflight", stable=stable, firstScopes=first.get("scopes"), secondScopes=second.get("scopes"),
                catalog=rec.summary["catalog"])
        rec.scenarios["S01"] = {"status": "BLOCKED",
                                "reason": "No controlled A/B/C inventory with independent empty/member proof in this run."}
        if len(second.get("displays") or []) < 2:
            rec.scenarios["M01"] = {"status": "BLOCKED", "reason": "One physical display attached."}
        if args.mode == "hidden-budget" and stable:
            rec.summary["hiddenBudgetConclusion"] = hidden_budget(args.observer, second, frozen, rec)
        if args.mode == "controlled-window" and stable:
            reason = controlled_window(args.observer, second, frozen, rec)
            rec.summary["controlledWindowConclusion"] = reason
            rec.scenarios["W01"] = {"status": "FAIL" if any(x["status"] == "FAIL" for x in rec.attempts) else "NOT_RUN",
                                    "reason": reason}
    except (OSError, ValueError, subprocess.SubprocessError) as ex:
        rec.summary["error"] = type(ex).__name__
        raise
    finally:
        rec.finish()


if __name__ == "__main__":
    main()
