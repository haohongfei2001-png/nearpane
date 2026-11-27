#!/usr/bin/env python3
"""Optional real Apple Music probe on the disposable CI desktop, without login.

The original local audio is only a test asset. All observed playback metadata and
transport acknowledgements must come from Music through Nearpane's production
adapter. A missing player, welcome screen or Automation denial remains BLOCKED.
"""
from __future__ import annotations

from array import array
import json
import math
import os
from pathlib import Path
import signal
import subprocess
import sys
import time
import wave
import shutil


def music_pids() -> set[int]:
    process = subprocess.run(["/usr/bin/pgrep", "-x", "Music"], capture_output=True, text=True)
    return {int(value) for value in process.stdout.split() if value.isdigit()}


def main() -> int:
    repo = Path(__file__).resolve().parents[3]
    evidence = repo / "build/unified-workbench-evidence"
    output = evidence / "real-player"
    output.mkdir(parents=True, exist_ok=True)
    result = {"schema": 1, "status": "BLOCKED", "scope": "optional cloud real Apple Music adapter probe"}
    owned: set[int] = set()
    session: Path | None = None
    try:
        if os.environ.get("GITHUB_ACTIONS") != "true":
            raise RuntimeError("Requires the disposable GitHub macOS desktop")
        if music_pids():
            raise RuntimeError("Music was already running before this isolated probe")
        runner = json.loads((evidence / "runner-receipt.json").read_text())
        identifier = runner["fixtureSession"]
        session = repo / "build/native-acceptance" / identifier
        app = repo / "build" / ("unified-workbench." + identifier) / "Nearpane.app"
        binary = app / "Contents/MacOS/NearpaneHost"
        native = session / "native-player"
        native.mkdir(parents=True)
        audio = native / "Nearpane original native playback.wav"
        rate, seconds = 22_050, 90
        # Quiet original three-note arpeggio, created here; no downloaded content.
        samples = array("h")
        notes = [220.0, 277.1826, 329.6276]
        for index in range(rate * seconds):
            second = index / rate
            frequency = notes[int(second / 2) % len(notes)]
            local = second % 2
            envelope = min(1.0, local / 0.04, (2 - local) / 0.10)
            samples.append(int(800 * max(0, envelope) * math.sin(2 * math.pi * frequency * second)))
        if sys.byteorder != "little":
            samples.byteswap()
        with wave.open(str(audio), "wb") as stream:
            stream.setparams((1, 2, rate, 0, "NONE", "not compressed"))
            stream.writeframes(samples.tobytes())
        script = """on run argv
tell application "Music"
    launch
    set sound volume to 0
    set added to add (POSIX file (item 1 of argv))
    if class of added is list then
        set fixtureTrack to item 1 of added
    else
        set fixtureTrack to added
    end if
    play fixtureTrack
    delay 1
    return (name of current track as text) & linefeed & (player state as text)
end tell
end run
"""
        script_file = native / "play-local.applescript"
        script_file.write_text(script)
        try:
            started = subprocess.run(["/usr/bin/osascript", str(script_file), str(audio)], capture_output=True,
                                     text=True, timeout=30)
        finally:
            owned = music_pids()
        (output / "music-setup.log").write_text(started.stdout + started.stderr)
        if started.returncode:
            raise RuntimeError("Apple Music local playback setup failed: " + started.stderr.strip())
        rows = started.stdout.strip().splitlines()
        if len(rows) < 2 or rows[-1] != "playing" or len(owned) != 1:
            raise RuntimeError("Apple Music did not confirm the original local file was playing")
        title = "\n".join(rows[:-1])
        player_pid = next(iter(owned))
        (native / "input.json").write_text(json.dumps({"playerPID": player_pid, "expectedTitle": title}))
        result["musicPlaybackConfirmed"] = True
        result["originalAudioSeconds"] = seconds
        result["physicalInputTest"] = False
        env = dict(os.environ, NEARPANE_ACCEPTANCE_CHECKOUT=str(repo))
        with (output / "native-player.log").open("w") as log:
            probe = subprocess.run([str(binary), "--verify-bundled-resources", "--native-player-probe", identifier],
                                   cwd=repo, env=env, stdout=log, stderr=subprocess.STDOUT, timeout=100)
        if probe.returncode:
            result["status"] = "FAIL"
            raise RuntimeError(f"Native player probe exited {probe.returncode}")
        measured = json.loads((native / "real-music-receipt.json").read_text())
        result["status"] = measured["status"]
        result["nativeReceipt"] = "real-music-receipt.json"
        if "reason" in measured:
            result["reason"] = measured["reason"]
    except Exception as error:
        result["reason"] = str(error)
    finally:
        # Music was absent before this probe; clean up only the process IDs
        # observed immediately after our own local-file launch.
        cleanup = []
        for pid in owned & music_pids():
            try:
                os.kill(pid, signal.SIGTERM)
                cleanup.append(pid)
            except ProcessLookupError:
                pass
        deadline = time.monotonic() + 5
        while owned & music_pids() and time.monotonic() < deadline:
            time.sleep(0.2)
        result["musicExited"] = not bool(owned & music_pids())
        if session is not None and (session / "native-player").is_dir():
            for path in (session / "native-player").glob("*.json"):
                if path.name != "input.json":
                    shutil.copy2(path, output / path.name)
        (output / "runner-player-receipt.json").write_text(json.dumps(result, indent=2) + "\n")
        print(json.dumps(result, indent=2))
    # This optional environmental attempt never changes the native UI gate.
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
