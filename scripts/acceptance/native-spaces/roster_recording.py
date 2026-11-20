"""Sample the installed sidebar while its two disposable windows open and close."""
import hashlib
import json
from pathlib import Path
import subprocess
import threading
import time


class RosterRecording:
    def __init__(self, kit, folder, pid, digest, output):
        self.kit, self.folder, self.pid, self.digest, self.output = kit, folder, pid, digest, output
        self.scratch = folder.parent / "frames"
        self.scratch.mkdir(mode=0o700)
        self.samples = []
        self.camera = threading.Lock()
        self.stop = threading.Event()
        self.thread = threading.Thread(target=self.capture)
        self.thread.start()

    def capture(self):
        while not self.stop.is_set():
            sample = {"begin": time.monotonic(), "saved": False}
            try:
                state = json.loads((self.folder / "windows.json").read_bytes())
                nums = state["numbers"]
                owned = state["session"] == self.folder.name and state["pid"] == self.pid
                if owned and len(nums) in (0, 2) and len(set(nums)) == len(nums):
                    image = self.scratch / f"{len(self.samples):04}.png"
                    with self.camera:
                        captured = subprocess.run([self.kit / "capture", self.kit / "observe", "roster-panel", self.digest,
                                                   str(self.pid if nums else 0), *map(str, nums), image],
                                                  capture_output=True, text=True, timeout=12, check=True)
                    proof = json.loads(captured.stdout)
                    if proof.get("ready") and proof.get("isolatedProfile") and image.is_file():
                        sample.update(saved=True, windows=nums, filename=image.name, sha256=hashlib.sha256(image.read_bytes()).hexdigest())
                    else:
                        sample["reason"] = proof.get("reason", "geometry or window set changed")
            except (OSError, KeyError, ValueError, subprocess.SubprocessError) as error:
                sample["reason"] = type(error).__name__
            sample["end"] = time.monotonic()
            self.samples.append(sample)
            self.stop.wait(0.075)

    def witness(self, numbers):
        start = len(self.samples)
        deadline = time.monotonic() + 2.5
        while time.monotonic() < deadline:
            if sum(s.get("windows") == list(numbers) for s in self.samples[start:]) >= 3:
                return
            self.stop.wait(0.075)

    def finish(self):
        self.stop.set()
        self.thread.join()
        frames = [s for s in self.samples if s["saved"]]
        runs = []
        for f in frames:
            count = len(f["windows"])
            if not runs or runs[-1] != count:
                runs.append(count)
        receipt = {"status": "INCOMPLETE", "method": "timestamped ScreenCaptureKit sidebar samples with pre/post authorization",
                   "windowsPerRun": runs, "samples": self.samples, "inputFrames": len(frames), "continuousSpaceTransition": False}
        if len(frames) >= 2:
            manifest = self.scratch / "timing.json"
            manifest.write_text(json.dumps([{"file": (self.scratch / f["filename"]).as_uri(), "time": f["end"] - frames[0]["end"]} for f in frames]))
            movie = self.output / "installed-sidebar.mp4"
            encoder = self.scratch / "encode"
            try:
                subprocess.run(["xcrun", "swiftc", "-parse-as-library", Path(__file__).with_name("title-movie.swift"), "-o", encoder], check=True)
                receipt["tracks"] = json.loads(subprocess.check_output([encoder, manifest, movie, "source-size"], timeout=40))
                receipt["sha256"] = hashlib.sha256(movie.read_bytes()).hexdigest()
                receipt["status"] = "CAPTURED" if runs == [0, 2, 0] else "INCOMPLETE"
            except (OSError, ValueError, subprocess.SubprocessError) as error:
                receipt["error"] = type(error).__name__
        (self.output / "recording.json").write_text(json.dumps(receipt, indent=2) + "\n")
