"""Run a command with the ordinary signed application and a new, private macOS data home."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import time
import uuid

APP = Path("/Applications/Nearpane.app")
HOST = APP / "Contents/MacOS/NearpaneHost"
CACHES = Path.home() / "Library/Caches"
PROFILE = Path("Library/Application Support/Nearpane Alpha Profiles")


def installed_pid():
    rows = subprocess.check_output(["/bin/ps", "-axo", "pid=,comm="], text=True).splitlines()
    matches = [int(line.split(None, 1)[0]) for line in rows if line.strip().endswith(" " + str(HOST))
               and line.strip().split(None, 1)[1] == str(HOST)]
    if len(matches) > 1:
        raise RuntimeError("Multiple running instances at the installed path")
    return matches[0] if matches else None


def quit_host(pid):
    if installed_pid() != pid:
        raise RuntimeError("Installed Host changed before normal termination")
    # NSRunningApplication uses the ordinary application termination delegate.
    script = '''import AppKit
let pid = Int32(CommandLine.arguments[1])!
guard let app = NSRunningApplication(processIdentifier: pid),
      app.bundleURL?.standardizedFileURL.path == "/Applications/Nearpane.app",
      app.bundleIdentifier == "com.holdsnow.nearpane.alpha", app.terminate() else { exit(2) }
'''
    subprocess.run(["/usr/bin/swift", "-e", script, str(pid)], check=True, timeout=20)
    deadline = time.monotonic() + 20
    while installed_pid() == pid and time.monotonic() < deadline:
        time.sleep(.15)
    if installed_pid() is not None:
        raise RuntimeError("Installed application did not finish its normal exit")


def owns_profile(pid, root):
    if not pid or not (root / "writer.lock").is_file():
        return False
    result = subprocess.run(["/usr/sbin/lsof", "-a", "-p", str(pid), "-t", str(root / "writer.lock")],
                            capture_output=True, text=True, timeout=5)
    return result.returncode == 0 and result.stdout.strip() == str(pid)


def validate_home(home):
    parent = home.parent
    if (parent.parent != CACHES or not parent.name.startswith("nearpane-native-acceptance.")
            or parent.resolve() != parent or parent.stat().st_uid != os.getuid()
            or parent.stat().st_mode & 0o077 or home.resolve() != home):
        raise ValueError("Expected a private acceptance home under the current user's Caches")
    if not home.exists():
        home.mkdir(mode=0o700)
    if not home.is_dir() or home.stat().st_uid != os.getuid() or home.stat().st_mode & 0o077:
        raise ValueError("Unsafe acceptance home")


def launch_isolated(home):
    validate_home(home)
    if installed_pid() is not None:
        raise RuntimeError("An installed Host is already running")
    root = home / PROFILE
    root.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(["/usr/bin/open", "-g", "--env", "CFFIXED_USER_HOME=" + str(home), str(APP)], check=True)
    deadline = time.monotonic() + 20
    while time.monotonic() < deadline:
        pid = installed_pid()
        if owns_profile(pid, root):
            active = json.loads((root / "profile-index.json").read_text())["active"]
            if str(uuid.UUID(active)) != active:
                raise ValueError("Unexpected test generation identity")
            generation = root / "generations" / active
            if generation.resolve() != generation or not (generation / "Nearpane/Voice/Saytile.sqlite").is_file():
                raise RuntimeError("Isolated generation failed validation")
            return pid, generation
        time.sleep(.2)
    raise RuntimeError("Launch Services did not produce a Host holding the isolated profile lock")


def daily_state():
    root = Path.home() / PROFILE
    index = root / "profile-index.json"
    if not index.is_file():
        return None
    data = index.read_bytes()
    current = json.loads(data)["active"]
    if str(uuid.UUID(current)) != current:
        raise RuntimeError("Daily profile index is invalid")
    config = root / "generations" / current / "Nearpane/host-configuration.json"
    return {"index": hashlib.sha256(data).hexdigest(), "configuration": hashlib.sha256(config.read_bytes()).hexdigest()}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path, help="a new directory for the isolation/cleanup receipt")
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command:
        parser.error("provide the actual acceptance command after --")
    output = args.output.resolve()
    output.mkdir(mode=0o700, parents=True, exist_ok=False)
    info = plistlib.loads((APP / "Contents/Info.plist").read_bytes())
    if info.get("CFBundleIdentifier") != "com.holdsnow.nearpane.alpha":
        raise RuntimeError("Wrong installed bundle")
    subprocess.run(["/usr/bin/codesign", "--verify", "--strict", "--deep", str(APP)], check=True)
    original = installed_pid()
    daily_root = Path.home() / PROFILE
    if original and not owns_profile(original, daily_root):
        raise RuntimeError("Existing Host belongs to another isolated run")
    container = Path(tempfile.mkdtemp(prefix="nearpane-native-acceptance.", dir=CACHES))
    home = container / "home"
    before = daily_state()
    receipt = {"installed": str(APP), "build": info["CFBundleVersion"], "source": info.get("NearpaneSourceRevision"),
               "startedWithDailyHost": bool(original), "normalLaunch": True, "isolatedLockConfirmed": False}
    def save():
        (output / "profile-session.json").write_text(json.dumps(receipt, indent=2) + "\n")
    save()
    stopped = False
    try:
        if original:
            quit_host(original)
            stopped = True
        pid, generation = launch_isolated(home)
        receipt.update(isolatedLockConfirmed=True, isolatedPID=pid)
        save()
        env = dict(os.environ, NEARPANE_TEST_HOME=str(home), NEARPANE_TEST_GENERATION=str(generation))
        result = subprocess.run(command, env=env)
        receipt["commandExit"] = result.returncode
        return result.returncode
    finally:
        current = installed_pid()
        if current and owns_profile(current, home / PROFILE):
            quit_host(current)
        current = installed_pid()
        if stopped and not current:
            subprocess.run(["/usr/bin/open", "-g", str(APP)], check=True)
            deadline = time.monotonic() + 20
            while not owns_profile(installed_pid(), daily_root) and time.monotonic() < deadline:
                time.sleep(.2)
        current = installed_pid()
        receipt["dailyHostRestored"] = owns_profile(current, daily_root) if original else current is None
        receipt["dailyProfileAndConfigurationUnchanged"] = daily_state() == before
        receipt["isolatedHomeRemoved"] = False
        if receipt["dailyHostRestored"] and (not current or not owns_profile(current, home / PROFILE)):
            shutil.rmtree(container)
            receipt["isolatedHomeRemoved"] = True
        save()
        if not receipt["dailyHostRestored"] or not receipt["dailyProfileAndConfigurationUnchanged"]:
            raise RuntimeError("Daily state readback incomplete. See profile-session.json")


if __name__ == "__main__":
    raise SystemExit(main())
