#!/usr/bin/env python3
"""Materialize only the content locked by Nearpane. Python standard library; no Git checkout."""
import argparse
import fcntl
import gzip
import hashlib
import http.client
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import sys
import tarfile
import tempfile
import time
import urllib.error
import urllib.request
import zlib

ROOT = Path(__file__).resolve().parents[1]
LOCK = ROOT / "Dependencies/domains.lock.json"
MIB = 1024 * 1024


class DependencyError(Exception):
    pass


def require(condition, message):
    if not condition:
        raise DependencyError(message)


def tree_hash(files):
    listing = "".join(f"{files[path]}  {path}\n" for path in sorted(files))
    return hashlib.sha256(listing.encode()).hexdigest()


def valid_path(name):
    path = PurePosixPath(name)
    return (path.parts and not path.is_absolute() and ".." not in path.parts and path.as_posix() == name
            and not re.search(r"[\\\x00-\x1f\x7f]", name))


def selection(pin, path):
    return any(path == prefix or path.startswith(prefix + "/") for prefix in
               pin["sources"] + pin["hostSources"] + pin["notices"])


def validate(pin):
    require(re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", pin["repository"]), "Invalid GitHub repository")
    require(re.fullmatch(r"[0-9a-f]{40}", pin["commit"]), "A full immutable Git commit is required")
    files = pin["files"]
    require(files and all(valid_path(p) and selection(pin, p) and re.fullmatch(r"[a-f0-9]{64}", h)
                          for p, h in files.items()), "Invalid file inventory in lock")
    require(all(valid_path(p) and any(f == p or f.startswith(p + "/") for f in files)
                for p in pin["sources"] + pin["hostSources"] + pin["notices"]), "Missing locked selection")
    require(all(p in files for p in pin["hostSources"] + pin["notices"]), "Missing bridge source or notice")
    require(tree_hash(files) == pin["treeSHA256"], "Lock inventory SHA-256 mismatch")


def cache_root():
    run_id = os.environ.get("NEARPANE_RUN_ID", "")
    require(not run_id or re.fullmatch(r"[A-Za-z0-9_-]{1,64}", run_id), "Invalid isolated run ID")
    base = ROOT / ("build/standalone." + run_id + "/cache" if run_id else ".build")
    cache = base / "domain-cache-v1"
    require(cache.resolve() == cache, "Cache path contains a symlink")
    return cache


def key(pin):
    return pin["commit"] + "-" + pin["treeSHA256"]


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise DependencyError(f"GitHub returned a redirect (HTTP {code}); review the pinned source")


def remote(url):
    request = urllib.request.Request(url, headers={"User-Agent": "Nearpane-pinned-domains/1"})
    return urllib.request.build_opener(NoRedirect()).open(request, timeout=20)


class LimitedReader:
    def __init__(self, stream, limit, deadline):
        self.stream = stream
        self.limit = limit
        self.count = 0
        self.deadline = deadline

    def read(self, size):
        require(time.monotonic() < self.deadline, "Archive download timed out")
        chunk = self.stream.read(min(size, self.limit + 1 - self.count))
        self.count += len(chunk)
        require(self.count <= self.limit, "Archive exceeds the dependency download limit")
        return chunk


def unpack(stream, pin, expected, stage, *, git_blobs=False):
    """Only write approved regular files. A tar entry never supplies a destination path."""
    deadline = time.monotonic() + 120
    download = LimitedReader(stream, 192 * MIB, deadline)
    hashes = {}
    prefix = pin["repository"].split("/")[1] + "-" + pin["commit"] + "/"
    with gzip.GzipFile(fileobj=download) as gz:
        expanded = LimitedReader(gz, 768 * MIB, deadline)
        with tarfile.open(fileobj=expanded, mode="r|", bufsize=64 * 1024) as archive:
            require(archive.pax_headers.get("comment") == pin["commit"], "Archive Git commit mismatch")
            for member in archive:
                if not member.name.startswith(prefix):
                    continue
                path = member.name[len(prefix):]
                if path not in expected:
                    continue
                require(member.type in (tarfile.REGTYPE, tarfile.AREGTYPE) and not member.sparse
                        and path not in hashes and valid_path(path) and member.mode & 0o111 == 0
                        and 0 <= member.size <= 16 * MIB, f"Invalid pinned archive entry: {path}")
                data = archive.extractfile(member).read()
                require(len(data) == member.size, f"Incomplete source: {path}")
                digest = hashlib.sha256(data).hexdigest()
                check = hashlib.sha1(b"blob " + str(len(data)).encode() + b"\0" + data).hexdigest() if git_blobs else digest
                require(check == expected[path], f"Content checksum mismatch: {path}")
                hashes[path] = digest
                if stage is not None:
                    destination = stage / path
                    destination.parent.mkdir(parents=True, exist_ok=True)
                    destination.write_bytes(data)
                if len(hashes) == len(expected):
                    break
    missing = expected.keys() - hashes.keys()
    require(not missing, "Missing pinned files: " + ", ".join(sorted(missing)[:4]))
    return hashes, download.count


def fetch(pin, expected, stage, *, git_blobs=False):
    source = "https://codeload.github.com/" + pin["repository"] + "/tar.gz/" + pin["commit"]
    try:
        with remote(source) as response:
            return unpack(response, pin, expected, stage, git_blobs=git_blobs)
    except (OSError, EOFError, urllib.error.URLError, http.client.HTTPException, zlib.error, tarfile.TarError, DependencyError) as exc:
        raise DependencyError(f"{pin['repository']}@{pin['commit']} from {source}: {exc}") from exc


def verify(directory, pin):
    require(not directory.is_symlink() and directory.is_dir(), f"Missing regular cache directory: {directory}")
    found = {}
    for file in directory.rglob("*"):
        require(not file.is_symlink(), f"Unexpected cache symlink: {file}")
        if file.is_dir() or file.name == ".DS_Store":
            continue
        name = file.relative_to(directory).as_posix()
        require(name in pin["files"] and file.is_file() and file.stat().st_mode & 0o111 == 0
                and file.stat().st_size <= 16 * MIB,
                f"Unexpected cache file: {name}")
        digest = hashlib.sha256(file.read_bytes()).hexdigest()
        require(digest == pin["files"][name], f"Cache checksum mismatch: {file}")
        found[name] = digest
    require(found == pin["files"], f"Missing pinned files in {directory}")
    require(tree_hash(found) == pin["treeSHA256"], "Cached tree SHA-256 mismatch")


def prepare(cache, pin, offline):
    dest = cache / key(pin)
    origin = "verified cache"
    if dest.exists() or dest.is_symlink():
        verify(dest, pin)
    else:
        require(not offline, f"Offline cache missing for {pin['repository']}@{pin['commit']}")
        with tempfile.TemporaryDirectory(prefix=".fetch-", dir=cache) as work:
            stage = Path(work) / "inputs"
            _, received = fetch(pin, pin["files"], stage)
            verify(stage, pin)
            stage.rename(dest)
        origin = f"GitHub, {received} compressed bytes read"
    print(f"{pin['repository']}@{pin['commit']} | {len(pin['files'])} files | sha256 {pin['treeSHA256']} | {origin}", flush=True)
    return dest


def tray_bindings(cache, pin):
    # Unexported helpers must compile in NearpaneTray's module. All link targets are inside this checkout.
    dest = cache / ("tray-" + key(pin))
    links = {"Host": ROOT / "Sources/NearpaneTray"}
    for source in pin["hostSources"]:
        path = "Upstream/" + PurePosixPath(source).name
        require(path not in links, f"Duplicate bridge source: {path}")
        links[path] = cache / key(pin) / source
    if not dest.exists():
        with tempfile.TemporaryDirectory(prefix=".bindings-", dir=cache) as work:
            stage = Path(work) / "bindings"
            (stage / "Upstream").mkdir(parents=True)
            for path, target in links.items():
                (stage / path).symlink_to(os.path.relpath(target, (dest / path).parent))
            stage.rename(dest)
    require(not dest.is_symlink() and not (dest / "Upstream").is_symlink(), "Invalid bridge directory")
    entries = {p.name for p in dest.iterdir() if p.name != ".DS_Store"}
    require(entries == {"Host", "Upstream"}, "Unexpected entry in the NearpaneTray target")
    actual = {"Upstream/" + p.name for p in (dest / "Upstream").iterdir() if p.name != ".DS_Store"}
    require(actual == set(links) - {"Host"}, "Unexpected NearpaneTray upstream sources")
    for path, target in links.items():
        require((dest / path).is_symlink() and (dest / path).resolve(strict=True) == target, f"Invalid bridge link: {path}")


def voice_bindings(cache, pin):
    # Keep the domain's internal dependency-injection API in its own Swift module.
    # The verified upstream directory remains byte-for-byte intact.
    dest = cache / ("voice-" + key(pin))
    links = {"Upstream": cache / key(pin) / "Sources/SaytileKit",
             "Nearpane": ROOT / "Sources/NearpaneSaytileBridge"}
    if not dest.exists():
        with tempfile.TemporaryDirectory(prefix=".bindings-", dir=cache) as work:
            stage = Path(work) / "voice"
            stage.mkdir()
            for name, target in links.items():
                (stage / name).symlink_to(os.path.relpath(target, dest))
            stage.rename(dest)
    require(not dest.is_symlink() and {p.name for p in dest.iterdir()} == set(links),
            "Unexpected entry in the SaytileKit binding")
    for name, target in links.items():
        require((dest / name).is_symlink() and (dest / name).resolve(strict=True) == target,
                f"Invalid SaytileKit bridge link: {name}")


def package_resources(resources, pins, directories):
    bundled = {
        "saytileVoiceUI": {},
        "saytile": {"Sources/SaytileKit/Resources/ConnectionSample.pcm": "Nearpane_SaytileKit.bundle/Contents/Resources/ConnectionSample.pcm"},
        "riftlet": {"Sources/RiftletAdapters/Resources/" + p: "Riftlet_RiftletAdapters.bundle/Contents/Resources/" + p
                    for p in ("chatgpt-web-20261027.js", "legacy-web-observe.js")}
    }
    for name, pin in pins.items():
        for path, relative in bundled[name].items():
            require(hashlib.sha256((resources / relative).read_bytes()).hexdigest() == pin["files"][path],
                    f"Packaged resource differs from lock: {relative}")
        dest = resources / "Upstream" / name
        dest.mkdir(parents=True)
        for path in pin["notices"]:
            notice = dest / path
            notice.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(directories[name] / path, notice)
        provenance = {k: pin[k] for k in ("repository", "commit", "treeSHA256", "notices")}
        (dest / "source.json").write_text(json.dumps(provenance, indent=2) + "\n")
    shutil.copyfile(directories["saytile"] / "Sources/CAudio/WEBRTC-LICENSE.txt", resources / "WEBRTC-LICENSE.txt")


def propose(lock, domain, revision, output):
    require(re.fullmatch(r"[0-9a-f]{40}", revision), "A full immutable Git commit is required")
    pin = lock["domains"][domain]
    pin["commit"] = revision
    url = f"https://api.github.com/repos/{pin['repository']}/git/trees/{revision}?recursive=1"
    with remote(url) as response:
        tree = json.loads(response.read(8 * MIB))
    require(tree["truncated"] is False, "GitHub returned a truncated tree")
    expected = {}
    for entry in tree["tree"]:
        path = entry["path"]
        if selection(pin, path) and entry["type"] != "tree":
            require(valid_path(path) and entry["type"] == "blob" and entry["mode"] == "100644",
                    f"Review upstream file type: {path}")
            expected[path] = entry["sha"]
    require(expected, "No selected Git blobs")
    files, _ = fetch(pin, expected, None, git_blobs=True)
    pin["files"] = dict(sorted(files.items()))
    pin["treeSHA256"] = tree_hash(files)
    validate(pin)
    with output.open("x") as fp:
        fp.write(json.dumps(lock, indent=2) + "\n")
    print("Proposed lock for review:", output)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--offline", action="store_true")
    group = parser.add_mutually_exclusive_group()
    group.add_argument("--package-resources", type=Path)
    group.add_argument("--propose", nargs=3, metavar=("DOMAIN", "FULL_COMMIT", "NEW_LOCK_FILE"))
    args = parser.parse_args()
    if os.environ.get("NEARPANE_FOUNDATION_ONLY") == "1" and not args.propose:
        print("Foundation only: no domain inputs required.")
        return
    lock = json.loads(LOCK.read_text())
    require(lock["format"] == 1 and set(lock["domains"]) == {"saytile", "riftlet", "saytileVoiceUI"}, "Unsupported dependency lock")
    pins = lock["domains"]
    for pin in pins.values():
        validate(pin)
    if args.propose:
        domain, revision, path = args.propose
        require(domain in pins and not args.offline, "Choose a locked domain for an online proposal")
        propose(lock, domain, revision, Path(path))
        return
    cache = cache_root()
    cache.mkdir(parents=True, exist_ok=True)
    with (cache / ".lock").open("a") as guard:
        fcntl.flock(guard, fcntl.LOCK_EX)
        offline = args.offline or args.package_resources is not None or os.environ.get("NEARPANE_OFFLINE") == "1"
        directories = {name: prepare(cache, pin, offline) for name, pin in pins.items()}
        for filename in ("module.modulemap", "shim.h"):
            require(len({(directories[name] / "Sources/CSQLite" / filename).read_bytes() for name in ("saytile", "riftlet")}) == 1,
                    "Pinned SQLite module definitions no longer match")
        tray_bindings(cache, pins["riftlet"])
        voice_bindings(cache, pins["saytile"])
        if args.package_resources:
            package_resources(args.package_resources, pins, directories)


if __name__ == "__main__":
    try:
        main()
    except (DependencyError, EOFError, OSError, ValueError, KeyError, http.client.HTTPException, tarfile.TarError) as error:
        sys.exit(f"Nearpane dependency error: {error}")
