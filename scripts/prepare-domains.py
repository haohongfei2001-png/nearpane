#!/usr/bin/env python3
"""Resolve immutable first-party compiler inputs from local Git objects. No checkout or network."""
import fcntl
import hashlib
import io
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile

root = Path(__file__).resolve().parents[1]
cache = root / ".build" / "domain-inputs"
riftlet_files = [
    "Sources/RiftletCore",
    "Sources/RiftletCapture",
    "Sources/RiftletAdapters",
    "Sources/CSQLite",
    "Sources/RiftletUI/RiftConfiguration.swift",
    "Sources/RiftletUI/RiftLayout.swift",
    "Sources/RiftletUI/ArrivalMotionMode.swift",
    "Sources/RiftletUI/MagnetMotionPlan.swift",
    "Sources/RiftletUI/MagnetFlightPresenter.swift",
    "Sources/RiftletUI/RiftThumbnailAppearance.swift",
    "Sources/RiftletApp/ArrivalMotionPreferences.swift",
    "Sources/RiftletApp/ApplicationInstanceOwnership.swift",
    "Sources/RiftletApp/OrdinaryCaptureConfiguration.swift",
    "Sources/RiftletApp/SelectionAuthority.swift",
    "Sources/RiftletApp/AutomationPermission.swift",
    "Sources/RiftletApp/ScreenshotEntryPreferences.swift",
    "Sources/RiftletUI/ThumbnailCache.swift",
]
domains = [
    ("Riftlet", "5c0e3da8ae2339910321fa9211dc6c5d6d6a3a7d", riftlet_files),
    ("saytile", "2bd114f526013e6ccb422a26e17f4514e9d63836", ["Sources/SaytileKit", "Sources/CAudio", "Sources/CSQLite"]),
]

def prepare(name, revision, paths):
    repo = root.parent / name
    def git(*args):
        return subprocess.check_output(["git", "-C", repo, *args])
    listing = git("ls-tree", "-rz", revision, "--", *paths)
    expected = {}
    for line in listing.split(b"\0"):
        if line:
            meta, path = line.split(b"\t", 1)
            mode, kind, oid = meta.split()
            if mode not in [b"100644", b"100755"] or kind != b"blob":
                raise SystemExit("Unexpected upstream file type")
            expected[os.fsdecode(path)] = oid.decode()
    if not expected:
        raise SystemExit("Missing pinned domain sources: " + name)
    def verify(directory, allow_missing=False):
        found = {p.relative_to(directory).as_posix() for p in directory.rglob("*") if p.is_file() and p.name != ".DS_Store"}
        if not found.issubset(expected) or (not allow_missing and found != set(expected)):
            return False
        for path in found:
            oid = expected[path]
            data = (directory / path).read_bytes()
            if hashlib.sha1(b"blob " + str(len(data)).encode() + b"\0" + data).hexdigest() != oid:
                return False
        return True
    dest = cache / revision
    if dest.exists() and verify(dest):
        return
    if dest.exists() and not verify(dest, allow_missing=True):
        raise SystemExit("Pinned inputs differ; inspect ignored cache: " + str(dest))
    with tempfile.TemporaryDirectory(dir=cache) as scratch:
        stage = Path(scratch) / "inputs"
        with tarfile.open(fileobj=io.BytesIO(git("archive", revision, "--", *paths))) as archive:
            for member in archive:
                if member.name in expected and member.isfile():
                    out = stage / member.name
                    out.parent.mkdir(parents=True, exist_ok=True)
                    out.write_bytes(archive.extractfile(member).read())
        if not verify(stage):
            raise SystemExit("Incomplete pinned input: " + name)
        if not dest.exists():
            stage.rename(dest)
        else:
            # A later stage may request additional targets at the very same pin.
            for path in expected:
                out = dest / path
                if not out.exists():
                    out.parent.mkdir(parents=True, exist_ok=True)
                    (stage / path).rename(out)

if os.environ.get("NEARPANE_FOUNDATION_ONLY") != "1":
    cache.mkdir(parents=True, exist_ok=True)
    with (cache / ".lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        for domain in domains:
            prepare(*domain)
        for filename in ["module.modulemap", "shim.h"]:
            if len({(cache / sha / "Sources/CSQLite" / filename).read_bytes() for _, sha, _ in domains}) != 1:
                raise SystemExit("Upstream SQLite module definitions no longer match")
