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
domains = [
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
    def verify(directory):
        found = {p.relative_to(directory).as_posix() for p in directory.rglob("*") if p.is_file() and p.name != ".DS_Store"}
        if found != set(expected):
            return False
        for path, oid in expected.items():
            data = (directory / path).read_bytes()
            if hashlib.sha1(b"blob " + str(len(data)).encode() + b"\0" + data).hexdigest() != oid:
                return False
        return True
    dest = cache / revision
    if not dest.exists():
        with tempfile.TemporaryDirectory(dir=cache) as scratch:
            stage = Path(scratch) / "inputs"
            for member in (archive := tarfile.open(fileobj=io.BytesIO(git("archive", revision, "--", *paths)))):
                if member.name in expected and member.isfile():
                    out = stage / member.name
                    out.parent.mkdir(parents=True, exist_ok=True)
                    out.write_bytes(archive.extractfile(member).read())
            if not verify(stage):
                raise SystemExit("Incomplete pinned input: " + name)
            stage.rename(dest)
    elif not verify(dest):
        raise SystemExit("Pinned inputs differ; inspect ignored cache: " + str(dest))

if os.environ.get("NEARPANE_FOUNDATION_ONLY") != "1":
    cache.mkdir(parents=True, exist_ok=True)
    with (cache / ".lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        for domain in domains:
            prepare(*domain)
