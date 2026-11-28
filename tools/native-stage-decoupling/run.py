#!/usr/bin/env python3
"""Collect Route A evidence; absence of a native thumbnail never proves decoupling."""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import signal
import subprocess
import sys
import time
import uuid

HERE = Path(__file__).resolve().parent


def command(args, *, timeout=30, check=True):
    result = subprocess.run([str(x) for x in args], capture_output=True, text=True, timeout=timeout)
    if check and result.returncode:
        raise RuntimeError(f"{Path(str(args[0])).name} failed ({result.returncode}): {result.stderr[-2000:]}")
    return result


def save(path, value):
    path = Path(path)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")
    temporary.replace(path)


def intersects(a, b):
    return len(a) == 4 and len(b) == 4 and a[2] > 0 and a[3] > 0 and b[2] > 0 and b[3] > 0 and (
        a[0] < b[0] + b[2] and b[0] < a[0] + a[2] and a[1] < b[1] + b[3] and b[1] < a[1] + a[3])


def rendered_members(sample):
    """Corroborate a native AX strip member with an onscreen CG thumbnail-sized surface.

    A missing/empty AX list, a visible WM window, or an AX frame alone is insufficient.
    Pixel evidence is also saved for review; this classifier only rejects a candidate.
    """
    windows = {w["id"]: w for w in sample.get("windows", [])}
    displays = [d["bounds"] for d in sample.get("displays", [])]
    found = set()
    for manager in sample.get("managers", []):
        for strip in manager.get("ax", {}).get("strips", []):
            for item in strip.get("items", []):
                for wid in item.get("windows", []):
                    w = windows.get(wid)
                    if not w or not w.get("onscreen") or w.get("alpha", 0) <= 0:
                        continue
                    b = w["bounds"]
                    if b[2] <= 320 and b[3] <= 420 and intersects(b, item.get("frame", [])) and any(
                            intersects(b, d) for d in displays):
                        found.add(wid)
    return sorted(found)


def classify(samples):
    if not samples or not any(s.get("nativeEnabled") is True or s.get("nativeEnabled") == 1 for s in samples):
        return {"status": "NOT_RUN", "reason": "Native Stage Manager was not observed enabled."}
    evidence = [{"sample": i, "windows": rendered_members(s)} for i, s in enumerate(samples)]
    evidence = [x for x in evidence if x["windows"]]
    if evidence:
        return {"status": "REJECTED_RENDERER_SEPARATION", "reason": "Native strip members were still presented onscreen.", "evidence": evidence}
    return {"status": "INCONCLUSIVE", "reason": "No corroborated native strip was observed. This does not prove rendering suppression, edge suppression or an independent grouping API."}


class Lab:
    def __init__(self, output):
        self.output = output
        self.binary = output / "native-stage-probe"
        self.fixtures = []

    def probe(self, *args):
        return json.loads(command([self.binary, *args], timeout=15).stdout)

    def build(self):
        result = command(["xcrun", "clang", "-fobjc-arc", "-fblocks", "-Wall", "-Wextra", "-O1",
                          HERE / "probe.m", "-framework", "AppKit", "-framework", "ApplicationServices",
                          "-o", self.binary], timeout=120, check=False)
        (self.output / "build.log").write_text(result.stdout + result.stderr)
        if result.returncode:
            raise RuntimeError("Diagnostic build failed; see build.log")

    def inventory(self):
        save(self.output / "runtime.json", self.probe("inventory"))
        for name, args in {
            "os": ["sw_vers"], "architecture": ["uname", "-m"], "sip": ["csrutil", "status"],
            "window-manager-dependencies": ["otool", "-L", "/System/Library/CoreServices/WindowManager.app/Contents/MacOS/WindowManager"],
            "window-manager-symbols": ["nm", "/System/Library/CoreServices/WindowManager.app/Contents/MacOS/WindowManager"],
            "window-manager-entitlements": ["codesign", "-d", "--entitlements", ":-", "/System/Library/CoreServices/WindowManager.app"],
        }.items():
            result = command(args, check=False)
            value = result.stdout + result.stderr
            if name.endswith("symbols"):
                value = "\n".join(line for line in value.splitlines() if re.search(
                    r"stage|strip|shelf|pile|render|visible|present|space|bridge", line, re.I))
            (self.output / f"{name}.txt").write_text(f"exit={result.returncode}\n" + value)
            if name.endswith("symbols"):
                demangled = subprocess.run(["xcrun", "swift-demangle", "--compact"], input=value,
                                           text=True, capture_output=True, timeout=30)
                (self.output / "window-manager-demangled.txt").write_text(
                    f"exit={demangled.returncode}\n" + demangled.stdout + demangled.stderr)

    def preferences(self, values, name):
        path = self.output / name
        save(path, values)
        self.probe("set-preferences", path)

    def create_fixture(self, label):
        # Two regular applications, each with two independent windows. No daily Host restart.
        bundle = self.output / f"RouteA-{label}.app"
        executable = bundle / "Contents/MacOS/RouteA"
        executable.parent.mkdir(parents=True)
        shutil.copy2(self.binary, executable)
        identifier = "com.holdsnow.nearpane.route-a." + uuid.uuid4().hex + "." + label.lower()
        info = {"CFBundleIdentifier": identifier, "CFBundleName": "Route A " + label,
                "CFBundleExecutable": "RouteA", "CFBundlePackageType": "APPL"}
        (bundle / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
        command(["codesign", "--force", "--sign", "-", bundle])
        manifest = self.output / f"fixture-{label}.json"
        self.fixtures.append(manifest)
        command(["open", "-n", "-a", bundle, "--args", "fixture", manifest, label])
        deadline = time.monotonic() + 8
        while time.monotonic() < deadline:
            if manifest.exists():
                value = json.loads(manifest.read_text())
                if len(value.get("windows", [])) == 2:
                    return value
            time.sleep(.1)
        raise RuntimeError(f"Fixture {label} did not publish its two windows")

    def capture_edges(self, sample, stem):
        if not sample.get("screenCapture"):
            return
        for d in sample.get("displays", []):
            x, y, w, h = d["bounds"]
            width = min(330, w)
            for side, px in [("left", x), ("right", x + w - width)]:
                region = ",".join(str(round(v)) for v in (px, y, width, h))
                path = self.output / f"{stem}-{d['id']}-{side}.png"
                result = command(["screencapture", "-x", "-R", region, path], check=False, timeout=10)
                if result.returncode:
                    (self.output / f"{stem}-{d['id']}-{side}.error.txt").write_text(result.stderr)

    def cleanup_fixtures(self):
        records = []
        for manifest in self.fixtures:
            entry = {"manifest": manifest.name, "status": "UNKNOWN"}
            try:
                Path(str(manifest) + ".stop").touch()
                fixture = json.loads(manifest.read_text())
                pid, birth = fixture["pid"], fixture.get("birth", 0)
                if not isinstance(pid, int) or pid <= 1 or not isinstance(birth, int) or birth <= 0:
                    raise ValueError("originalFixtureProcessBirthUnavailable")
                deadline = time.monotonic() + 6
                while time.monotonic() < deadline:
                    current = self.probe("process", pid)
                    if current.get("pid") == pid and current.get("birth") != birth:
                        entry["status"] = "EXITED"
                        break
                    time.sleep(.1)
                if entry["status"] != "EXITED":
                    entry["reason"] = "fixtureDidNotExitAfterStopMarker"
            except Exception as error:
                entry["reason"] = str(error)
            records.append(entry)
        result = {"allExited": all(r["status"] == "EXITED" for r in records), "fixtures": records}
        save(self.output / "fixtures-cleanup.json", result)
        return result


def restore_environment(lab, original, changed, before):
    """Attempt every independent restoration step even if a previous one failed."""
    errors = []
    try:
        if not lab.cleanup_fixtures()["allExited"]:
            errors.append("A fixture's original process exit is unconfirmed; see fixtures-cleanup.json")
    except Exception as error:
        errors.append("fixture cleanup: " + str(error))
    try:
        if changed:
            lab.preferences({key: original[key] for key in changed}, "preferences-restoring.json")
        restored = lab.probe("preferences")
        save(lab.output / "preferences-restored.json", restored)
        if any(restored.get(key) != original.get(key) for key in changed):
            errors.append("A changed preference did not restore exactly")
    except Exception as error:
        errors.append("preferences: " + str(error))
    try:
        lab.probe("move-pointer", *before["pointer"])
    except Exception as error:
        errors.append("pointer: " + str(error))
    try:
        pid, birth = before.get("frontPID", 0), before.get("frontBirth", 0)
        if pid > 0 and birth > 0 and lab.probe("process", pid).get("birth") == birth:
            activation = lab.probe("activate", pid, birth)
            save(lab.output / "foreground-restored.json", activation)
            if not activation.get("accepted"):
                errors.append("Original foreground activation was not accepted")
        elif pid > 0:
            save(lab.output / "foreground-restored.json", {"accepted": False, "reason": "originalProcessNoLongerConfirmed"})
    except Exception as error:
        errors.append("foreground: " + str(error))
    try:
        time.sleep(.2)
        save(lab.output / "after.json", lab.probe("snapshot"))
    except Exception as error:
        errors.append("final snapshot: " + str(error))
    result = {"status": "RESTORED" if not errors else "RESTORE_INCOMPLETE", "errors": errors}
    save(lab.output / "restore-result.json", result)
    return result


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=["inventory", "edge-sweep", "restore"])
    parser.add_argument("--output", type=Path)
    parser.add_argument("--enable-native", action="store_true", help="Temporarily enable native Stage Manager; restore original value afterwards")
    parser.add_argument("--autohide", action="store_true", help="Exercise AutoHide=true as a negative control")
    parser.add_argument("--zero-rows", action="store_true", help="Test the historically observed LeftStripMaximumRowCount=0 key; no success is assumed")
    parser.add_argument("--no-fixtures", action="store_true", help="Use windows already present instead of four automatic fixture windows")
    args = parser.parse_args(argv)
    if sys.platform != "darwin":
        parser.error("This diagnostic needs macOS and a logged-in WindowServer session")
    output = args.output or Path("/tmp") / ("nearpane-route-a-" + uuid.uuid4().hex[:12])
    output = output.resolve()
    if args.mode == "restore":
        lab = Lab(output)
        original = json.loads((output / "preferences-original.json").read_text())
        path = output / "preferences-applied.json"
        applied = json.loads(path.read_text()) if path.exists() else {}
        lab.fixtures = sorted(output.glob("fixture-[AB].json"))
        before = json.loads((output / "before.json").read_text())
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        signal.signal(signal.SIGINT, signal.SIG_IGN)
        restored = restore_environment(lab, original, applied, before)
        print(json.dumps(restored, indent=2))
        return 0 if restored["status"] == "RESTORED" else 1
    output.mkdir(parents=True, mode=0o700, exist_ok=False)
    lab = Lab(output)
    lab.build()
    lab.inventory()
    original = lab.probe("preferences")
    before = lab.probe("snapshot")
    save(output / "preferences-original.json", original)
    save(output / "before.json", before)
    if args.mode == "inventory":
        save(output / "result.json", {"status": "INVENTORY_ONLY", "capabilityProven": False})
        print(output)
        return 0
    changed = {}
    samples = []
    failure = None
    restore_error = None
    def interrupted(signum, _frame):
        raise KeyboardInterrupt(f"signal {signum}")
    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGINT, interrupted)
    try:
        if args.enable_native:
            changed["GloballyEnabled"] = True
        if args.autohide:
            changed["AutoHide"] = True
        if args.zero_rows:
            changed["LeftStripMaximumRowCount"] = 0
        if changed:
            lab.preferences(changed, "preferences-applied.json")
            time.sleep(1.5)
        if not lab.probe("snapshot").get("nativeEnabled"):
            raise RuntimeError("Native Stage Manager is off; use --enable-native to run the reversible experiment")
        if not args.no_fixtures:
            a = lab.create_fixture("A")
            b = lab.create_fixture("B")
            # Actual app activations let Apple create native groups. CG/AX readback is evidence.
            for label, f in [("A", a), ("B", b), ("A-again", a)]:
                accepted = lab.probe("activate", f["pid"], f["birth"])
                time.sleep(.9)
                sample = lab.probe("snapshot")
                sample["fixtureActivation"] = {"label": label, "pid": f["pid"], **accepted}
                save(output / f"activation-{label}.json", sample)
        base = lab.probe("snapshot")
        save(output / "baseline.json", base)
        samples.append(base)
        lab.capture_edges(base, "baseline")
        for d in base["displays"]:
            x, y, w, h = d["bounds"]
            for side, px in [("left", x + .5), ("right", x + w - .5)]:
                for fraction in [.2, .5, .8]:
                    label = f"edge-{d['id']}-{side}-{int(fraction*100)}"
                    # Exit the edge first, then dwell; no click, tap or input suppression.
                    lab.probe("move-pointer", x + w / 2, y + h / 2)
                    time.sleep(.25)
                    lab.probe("move-pointer", px, y + h * fraction)
                    for delay in [.2, .8]:
                        time.sleep(delay)
                        sample = lab.probe("snapshot")
                        sample["edge"] = {"display": d["id"], "side": side, "fraction": fraction, "delay": delay}
                        samples.append(sample)
                        save(output / f"{label}-{int(delay*1000)}.json", sample)
                    lab.capture_edges(samples[-1], label)
    except (Exception, KeyboardInterrupt) as error:
        failure = str(error)
    finally:
        # A second handled interrupt must not abandon an already-started restore.
        # SIGKILL still requires the separate restore entry, using the saved intent.
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        signal.signal(signal.SIGINT, signal.SIG_IGN)
        restored = restore_environment(lab, original, changed, before)
        if restored["errors"]:
            restore_error = "; ".join(restored["errors"])
    result = classify(samples)
    result.update({"preferencesTested": changed, "sampleCount": len(samples), "error": failure,
                   "restoreError": restore_error, "capabilityProven": False,
                   "requires": ["A concrete render-disable mechanism", "Independent group switch/merge/split controls",
                                "Engine operations verified while rendering remains disabled", "Target macOS 27.0 SIP-enabled reproduction"]})
    save(output / "result.json", result)
    print(json.dumps({"output": str(output), **result}, indent=2))
    return 1 if failure or restore_error else 0


if __name__ == "__main__":
    raise SystemExit(main())
