"""A single independent reader for the whole installed-sidebar action sequence."""
import importlib
import json
from pathlib import Path
import subprocess
import sys
import time
import uuid

from p0_drift_classification import POST_CONFIRMATION, classify

reader = importlib.import_module("p0-drift")


def matches_source(checkpoint, request):
    top = request["topology"]
    binding = checkpoint.get("binding") or {}
    host = checkpoint.get("host") or {}
    window = request["sourceWindow"]
    source = next((row for row in top["records"] if row["id"] == top["current"]), {})
    return (checkpoint.get("state") == "observed" and checkpoint.get("current") == top["current"]
            and checkpoint.get("display", "").upper() == top["display"].upper()
            and checkpoint.get("spaceUUID", "").upper() == source.get("uuid", "").upper()
            and bool(source.get("uuid")) and binding.get("spaces") == [top["current"]]
            and binding.get("window") == {key:window[key] for key in ("pid", "birth", "number")}
            and binding.get("foregroundCDHash") == window["hash"]
            and (host.get("pid"), host.get("birth"), host.get("cdhash")) ==
                (request["hostPID"], request["hostBirth"], request["hostHash"]))


class ActionObserver:
    def __init__(self, kit, directory, seconds):
        self.directory = directory
        self.session = None
        self.process = subprocess.Popen(
            [sys.executable, "-B", str(Path(reader.__file__)), "observe", str(kit), str(directory),
             "--seconds", str(seconds), "--managed"], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL)

    def ready(self):
        deadline = time.monotonic() + 12
        while time.monotonic() < deadline and self.process.poll() is None:
            path = self.directory / "active.json"
            if path.exists():
                state = json.loads(path.read_bytes())
                self.session = state.get("session")
                if self.session and state.get("open"):
                    return
                if state.get("reason") == "userSuperseded":
                    break
            time.sleep(.06)
        raise ValueError("independent reader did not bind the active signed Host, Space and focused document")

    def before(self, request):
        checkpoint = reader.admission(self.directory)
        if self.session != checkpoint.get("session") or not matches_source(checkpoint, request):
            raise ValueError("continuous observer refused source, Host generation, or preceding transition: " +
                             str(checkpoint.get("reason", checkpoint.get("id"))))
        return checkpoint

    def after(self, operation):
        operation = str(uuid.UUID(operation)).upper()
        deadline = time.monotonic() + POST_CONFIRMATION + 4
        outcome = {"classification":"unknown","reason":"confirmed installed journal was not independently bound"}
        while time.monotonic() < deadline:
            path = next((p for p in (self.directory/"operations").glob("*.json")
                         if p.stem.upper() == operation), None)
            if path:
                action = json.loads(path.read_bytes())
                if action["operation"] != operation:
                    break
                rows = reader.read_rows(self.directory/"events.jsonl")
                outcome = classify(rows, action)
                # Retain the full diagnostic interval after the first handoff: Dock may
                # follow the newly activated window several seconds later.
                if outcome.get("coverage", {}).get("afterConfirmationSeconds", 0) >= POST_CONFIRMATION:
                    break
            if self.process.poll() is not None:
                break
            time.sleep(.12)
        return outcome

    def close(self):
        if self.session and self.process.poll() is None:
            reader.write(self.directory/"finish.json", {"session":self.session})
        try:
            self.process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.process.terminate()
            self.process.wait(timeout=5)
        path = self.directory/"result.json"
        return json.loads(path.read_bytes()) if path.is_file() else {"status":"UNKNOWN"}
