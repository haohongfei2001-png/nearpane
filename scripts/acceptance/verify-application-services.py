#!/usr/bin/env python3
"""Exercise the real application settings on a marked, offline secondary panel."""
import argparse
import json
import os
from pathlib import Path
import runpy
import sqlite3
import subprocess
import time

ROOT = Path(__file__).resolve().parents[2]
TOOLS = runpy.run_path(str(Path(__file__).with_name("verify-profile-upgrade.py")))
require, run = TOOLS["require"], TOOLS["run"]


def verify(app):
    host = TOOLS["binary"](app, "com.holdsnow.nearpane.alpha")
    require(subprocess.run(["pgrep", "-x", "NearpaneHost"], stdout=subprocess.DEVNULL).returncode == 1,
            "An existing Nearpane instance must finish before this isolated acceptance")
    session = TOOLS["prepare"](host, True)
    out = ROOT / "build/verification/p59/services" / session.name
    out.mkdir(parents=True, mode=0o700)
    for source, name in [("admission-controls.swift", "controls"), ("capture-panel.swift", "capture"),
                         ("ordinary-windows/SystemReadback.swift", "focus")]:
        subprocess.run(["/usr/bin/xcrun", "swiftc", ROOT / "scripts/acceptance" / source,
                        "-module-cache-path", out / "module-cache", "-o", out / name], check=True)

    def focus():
        value = json.loads(run([out / "focus"]))
        return {key: value[key] for key in ("side", "front", "focus", "bounds")}

    before = focus()
    require(before["front"] > 0 and before["focus"] > 0, "No verified focus baseline")
    env = dict(os.environ, NEARPANE_SERVICES_ACCEPTANCE=session.name,
               PATH="/usr/bin:/bin:/usr/sbin:/sbin", PYTHONHOME="/unavailable", PYTHONPATH="/unavailable")
    sandbox = TOOLS["SANDBOX"].copy()
    sandbox[-1] += TOOLS["NO_EXTERNAL_RUNTIME"]
    receipt = {"session": session.name, "hostSHA256": TOOLS["sha"](host.read_bytes()),
               "before": before, "networkDenied": True, "developerToolsDenied": True, "checkpoints": []}
    with (out / "host.log").open("xb") as log:
        child = subprocess.Popen(sandbox + [str(host), "--native-acceptance-secondary", session.name],
                                 cwd=ROOT, env=env, stdout=log, stderr=log)
        try:
            def wait(sample, duration=15):
                deadline = time.monotonic() + duration
                while time.monotonic() < deadline:
                    require(child.poll() is None, "Test Host exited before checkpoint")
                    result = sample()
                    if result:
                        return result
                    time.sleep(.15)
                raise ValueError("Application settings checkpoint timed out")

            marker = wait(lambda: next(session.glob("application-services-*.json"), None))
            window = json.loads(marker.read_bytes())
            require(window["pid"] == child.pid and window["display"] == before["side"]
                    and window["frontPID"] == before["front"], "Panel scope changed")
            prefix = [out / "controls", child.pid, window["windowNumber"], host]

            def read():
                value = json.loads(run(prefix + ["read", "--services-secondary"]))
                require(value["frontPID"] == before["front"] and focus() == before, "Focus changed")
                receipt["checkpoints"].append(value)
                return {node["id"]: node for node in value["nodes"]}

            def containing(*identifiers):
                value = read()
                return value if all(identifier in value for identifier in identifiers) else None

            nodes = wait(lambda: containing("np.update.check", "np.feedback.preview"))
            require(not nodes["np.update.check"]["enabled"] and not nodes["np.update.daily"]["enabled"],
                    "Isolated updater became actionable")

            def capture(name):
                file = out / name
                run([out / "capture", child.pid, window["windowNumber"], host, file, "--secondary-only"])
                return TOOLS["sha"](file.read_bytes())

            receipt["settingsImageSHA256"] = capture("application-settings.png")
            run(prefix + ["scroll-settings-end", "--services-secondary"])
            run(prefix + ["np.feedback.preview", "--services-secondary"])
            nodes = wait(lambda: containing("np.feedback.send"))
            require(not nodes["np.feedback.send"]["enabled"], "Synthetic feedback send became available")
            run(prefix + ["scroll-settings-end", "--services-secondary"])
            receipt["previewImageSHA256"] = capture("feedback-preview.png")
            # The helper's action whitelist does not include send, even in the offline fixture.
            refused = subprocess.run(sandbox + list(map(str, prefix + ["np.feedback.send", "--services-secondary"])),
                                     capture_output=True, text=True, timeout=10)
            require(refused.returncode == 2 and "control not allowed" in refused.stderr, "Send guard changed")
            run(prefix + ["np.services.quit", "--services-secondary"])
            require(child.wait(timeout=15) == 0, "Settings did not exit through the ordinary drain")
            db = session / "Feedback/feedback.sqlite"
            with sqlite3.connect(db.as_uri() + "?mode=ro", uri=True) as connection:
                require(connection.execute("PRAGMA integrity_check").fetchall() == [("ok",)], "Feedback database damaged")
                require(connection.execute("SELECT count(*) FROM reports").fetchone() == (0,), "Preview queued feedback")
                require(connection.execute("SELECT count(*) FROM credential_intents").fetchone() == (0,), "Preview requested secrets")
                require(connection.execute("SELECT count(*) FROM meta WHERE key='running'").fetchone() == (0,), "Feedback drain incomplete")
                draft = json.loads(connection.execute("SELECT payload FROM draft WHERE id=1").fetchone()[0])
                require("product=Nearpane" in draft["text"] and "合成反馈预览" in draft["text"], "Draft was not preserved")
            receipt.update(result="PASS", feedbackReports=0, externalInputs=0, feedbackClean=True,
                           after=focus(), exitCode=child.returncode)
            require(receipt["after"] == before, "Final focus differs")
        except Exception as error:
            receipt.update(result="FAIL", error=str(error))
            raise
        finally:
            if child.poll() is None:
                child.terminate()
                child.wait(timeout=8)
            (out / "result.json").write_text(json.dumps(receipt, ensure_ascii=False, indent=2) + "\n")
    print(out / "result.json")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    verify(parser.parse_args().app.resolve(strict=True))
