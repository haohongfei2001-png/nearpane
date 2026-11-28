#!/usr/bin/env python3
"""Verify the packaged notes UI and durability on a disposable macOS CI desktop.

The normal candidate is copied and ad-hoc signed under the established alpha
acceptance identity. Every process uses an executable-bound isolated profile.
Screenshots show real AppKit/SwiftUI; their contents are labelled test fixtures.
"""
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import signal
import subprocess
import sys
import time
import uuid


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write_json(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".next")
    temporary.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n")
    temporary.replace(path)


def main() -> int:
    repo = Path(__file__).resolve().parents[3]
    output = repo / "build/quick-notes-evidence"
    output.mkdir(parents=True, exist_ok=True)
    receipt: dict = {"schema": 1, "status": "RUNNING", "processes": [], "checks": [],
                     "evidenceScope": "Packaged native UI; isolated generated contents; no real Spaces or player qualification"}
    sessions: list[tuple[str, Path]] = []
    children: list[subprocess.Popen] = []
    transparency_original: str | None = None
    transparency_changed = False
    try:
        if sys.platform != "darwin" or os.environ.get("GITHUB_ACTIONS") != "true":
            raise RuntimeError("This runner is restricted to the disposable macOS GitHub Actions desktop.")
        candidate = Path(sys.argv[1]).resolve(strict=True)
        receipt["sourceCommit"] = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=repo, text=True).strip()
        receipt["candidateExecutableSHA256"] = digest(candidate / "Contents/MacOS/NearpaneHost")
        staging = repo / "build" / ("quick-notes." + str(uuid.uuid4()))
        app = staging / "Nearpane.app"
        staging.mkdir()
        subprocess.run(["/usr/bin/ditto", str(candidate), str(app)], check=True)
        info = app / "Contents/Info.plist"
        with info.open("rb") as stream:
            values = plistlib.load(stream)
        values["CFBundleIdentifier"] = "com.holdsnow.nearpane.alpha"
        values["NearpaneQuickNotesCommit"] = receipt["sourceCommit"]
        with info.open("wb") as stream:
            plistlib.dump(values, stream)
        subprocess.run(["/usr/bin/codesign", "--force", "--deep", "--sign", "-", str(app)],
                       check=True, capture_output=True)
        binary = app / "Contents/MacOS/NearpaneHost"
        receipt["fixtureExecutableSHA256"] = digest(binary)
        receipt["fixtureBundleID"] = values["CFBundleIdentifier"]
        environment = dict(os.environ, NEARPANE_ACCEPTANCE_CHECKOUT=str(repo))

        # The old cloud evidence used Reduce Transparency. Request the ordinary
        # material on this disposable runner only, retain failure honestly, and
        # restore the original preference after the last child has exited.
        observed = subprocess.run(["defaults", "read", "com.apple.universalaccess", "reduceTransparency"],
                                  capture_output=True, text=True)
        if observed.returncode == 0:
            transparency_original = observed.stdout.strip()
        changed = subprocess.run(["defaults", "write", "com.apple.universalaccess", "reduceTransparency", "-bool", "false"],
                                 capture_output=True, text=True)
        transparency_changed = changed.returncode == 0
        receipt["materialPreference"] = {"originalReduceTransparency": transparency_original,
                                         "normalMaterialRequested": transparency_changed,
                                         "requestError": changed.stderr.strip() if changed.returncode else None}

        def prepare(label: str) -> tuple[str, Path]:
            identifier = str(uuid.uuid4())
            session = repo / "build/native-acceptance" / identifier
            with (output / (label + "-prepare.log")).open("w") as log:
                completed = subprocess.run([str(binary), "--verify-bundled-resources", "--native-acceptance-prepare", identifier],
                                           cwd=repo, env=environment, stdout=log, stderr=subprocess.STDOUT, timeout=60)
            if completed.returncode:
                raise RuntimeError(label + " preparation failed")
            sessions.append((label, session))
            return identifier, session

        def launch(mode: str, identifier: str, label: str, *, kill_when_ready: Path | None = None) -> bool:
            row: dict = {"mode": mode, "label": label, "session": identifier}
            receipt["processes"].append(row)
            with (output / (label + ".log")).open("w") as log:
                child = subprocess.Popen([str(binary), "--verify-bundled-resources", "--native-settings-readback", identifier],
                                         cwd=repo, env=dict(environment, NEARPANE_QUICK_NOTES_ACCEPTANCE=mode),
                                         stdout=log, stderr=subprocess.STDOUT)
                children.append(child)
                row["pid"] = child.pid
                try:
                    if kill_when_ready is None:
                        row["exit"] = child.wait(timeout=240)
                    else:
                        deadline = time.monotonic() + 90
                        while time.monotonic() < deadline and child.poll() is None and not kill_when_ready.exists():
                            time.sleep(0.1)
                        if not kill_when_ready.exists() or child.poll() is not None:
                            raise RuntimeError("Child failed to reach a durable native edit before the crash trial.")
                        child.send_signal(signal.SIGKILL)
                        row["exit"] = child.wait(timeout=10)
                        row["termination"] = "SIGKILL sent to the exact spawned process; no application close/flush path"
                        row["readyMarkerObserved"] = True
                except Exception as error:
                    row["error"] = str(error)
                    if child.poll() is None:
                        child.kill()
                        child.wait(timeout=10)
                finally:
                    row["exited"] = child.poll() is not None
            expected_exit = -signal.SIGKILL if kill_when_ready is not None else 0
            row["passed"] = row.get("exit") == expected_exit and "error" not in row
            write_json(output / "runner-receipt.json", receipt)
            return row["passed"]

        identifier, session = prepare("native")
        passed = launch("ui", identifier, "native-ui")
        termination_file = session / "quick-notes/normal-termination.json"
        termination = json.loads(termination_file.read_text()) if termination_file.exists() else {}
        terminated = (termination.get("status") == "PASS" and termination.get("willTerminateNotificationObserved") is True
                      and termination.get("productionTerminationCommitted") is True and termination.get("hostStopped") is True
                      and termination.get("stateUnchanged") is True and termination.get("diskMatches") is True)
        receipt["checks"].append({"check": "real-application-termination", "passed": terminated,
                                   "detail": "Requires NSApplication.willTerminateNotification and the production delegate's committed shutdown, with unchanged records on disk.",
                                   "receipt": "native/normal-termination.json"})
        passed = passed and terminated
        if passed:
            passed = launch("readback", identifier, "normal-restart") and passed
            killed = launch("crash-write", identifier, "crash-write", kill_when_ready=session / "quick-notes/crash-ready")
            passed = killed and passed
            if killed:
                passed = launch("crash-readback", identifier, "crash-restart") and passed
        else:
            receipt["checks"].append({"check": "restart-and-crash-followups", "status": "NOT_RUN",
                                       "detail": "Native input did not complete; do not fabricate recovery success from seeded notes."})

        # Migration gets a second independently prepared profile. Keep exactly
        # the old writer format and compare the immutable backup byte for byte.
        legacy_id, legacy_session = prepare("legacy")
        old_payload = {"memo": "原来的便签\n第二行仍然在。", "calculation": "(7 - 2) * 3",
                       "tasks": [{"id": "33333333-3333-4333-8333-333333333333", "title": "尚未完成的旧事项", "done": False},
                                 {"id": "44444444-4444-4444-8444-444444444444", "title": "已经完成的旧事项", "done": True}],
                       "words": [{"id": "55555555-5555-4555-8555-555555555555", "source": "idea", "translation": "想法", "language": "zh-Hans"}]}
        note = legacy_session / "support/Nearpane/sidebar-notebook.json"
        with note.open("x") as stream:
            stream.write(json.dumps(old_payload, ensure_ascii=False))
        original_bytes = note.read_bytes()
        migrated = launch("migration", legacy_id, "legacy-migration")
        if migrated:
            first_bytes = note.read_bytes()
            backup = note.with_name("sidebar-notebook.v1-backup.json")
            payload = json.loads(first_bytes)
            preserved = backup.read_bytes() == original_bytes and payload["words"] == old_payload["words"] and payload["calculation"] == old_payload["calculation"]
            receipt["checks"].append({"check": "legacy-backup-and-other-domains", "passed": preserved,
                                       "originalSHA256": hashlib.sha256(original_bytes).hexdigest(),
                                       "detail": "Exact legacy source backup plus unchanged calculation and vocabulary content."})
            reopened = launch("migration", legacy_id, "legacy-migration-restart")
            idempotent = reopened and note.read_bytes() == first_bytes
            receipt["checks"].append({"check": "migration-idempotent-relaunch", "passed": idempotent,
                                       "detail": "A second independent Host process leaves the v2 file byte-identical."})
            passed = preserved and idempotent and passed
        else:
            passed = False
        receipt["status"] = "PASS" if passed else "FAIL"
    except Exception as error:
        receipt["status"] = "FAIL"
        receipt["error"] = str(error)
    finally:
        for child in children:
            if child.poll() is None:
                child.kill()
                child.wait(timeout=10)
        for label, session in sessions:
            source = session / "quick-notes"
            if source.is_dir():
                shutil.copytree(source, output / label, dirs_exist_ok=True)
        if transparency_changed:
            command = ["defaults", "delete", "com.apple.universalaccess", "reduceTransparency"] if transparency_original is None else [
                "defaults", "write", "com.apple.universalaccess", "reduceTransparency", "-bool", "true" if transparency_original in ("1", "true", "YES") else "false"]
            restored = subprocess.run(command, capture_output=True, text=True)
            receipt["materialPreference"]["restored"] = restored.returncode == 0
            if restored.returncode:
                receipt["status"] = "FAIL"
                receipt["materialPreference"]["restoreError"] = restored.stderr.strip()
        write_json(output / "runner-receipt.json", receipt)
        print(json.dumps(receipt, ensure_ascii=False, indent=2))
    return 0 if receipt["status"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
