#!/usr/bin/env python3
"""Reserve a new Chrome profile inside a marked native acceptance session."""
import argparse
import json
import os
from pathlib import Path
import stat
import subprocess
import uuid

ROOT = Path(__file__).resolve().parents[2]
CHROME = Path("/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")


def private_directory(path):
    info = path.lstat()
    if path.resolve() != path or not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
        raise ValueError("Expected an owned private directory inside this acceptance session")
    return path


def profile(session, prepare=False):
    if str(uuid.UUID(session)) != session:
        raise ValueError("Expected a lowercase acceptance session UUID")
    parent = private_directory(ROOT / "build/native-acceptance" / session)
    marker = parent / "session.json"
    if marker.is_symlink() or json.loads(marker.read_bytes()).get("session") != session.upper():
        raise ValueError("Missing matching native acceptance marker")
    folder = parent / "chrome-profile"
    stamp = folder / "fixture.json"
    data = folder / "user-data"
    expected = {"version": 1, "session": session, "purpose": "isolated-native-draft"}
    if prepare and not os.path.lexists(folder):
        folder.mkdir(mode=0o700)
        data.mkdir(mode=0o700)
        with stamp.open("x") as out:
            json.dump(expected, out)
    private_directory(folder)
    private_directory(data)
    if stamp.is_symlink() or json.loads(stamp.read_bytes()) != expected:
        raise ValueError("Unrecognized or incomplete disposable profile")
    return data


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["prepare", "status", "launch"])
    parser.add_argument("--session", required=True)
    args = parser.parse_args()
    data = profile(args.session, prepare=args.action == "prepare")
    if args.action == "launch":
        # Browser Apple Events require a unique process. Never forward a launch into a running Chrome.
        existing = subprocess.run(["/usr/bin/pgrep", "-x", "Google Chrome"], stdout=subprocess.DEVNULL)
        if existing.returncode != 1 or any(os.path.lexists(data / x) for x in ("SingletonLock", "SingletonSocket", "SingletonCookie")):
            raise ValueError("Use an isolated desktop with no running Chrome and a closed dedicated profile")
        subprocess.run(["/usr/bin/codesign", "--verify", "--strict", "-R",
                        'anchor apple generic and identifier "com.google.Chrome" and certificate leaf[subject.OU] = "EQHXZ8M8AV"',
                        str(CHROME.parents[2])], check=True)
        os.execv(CHROME, [str(CHROME), "--user-data-dir=" + str(data), "--no-first-run", "--no-default-browser-check",
                          "--disable-sync", "--disable-extensions", "--new-window", "about:blank"])
    print(json.dumps({"profile": str(data), "session": args.session, "login": "not observed", "draft": "unbound"}))


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        raise SystemExit(str(error))
