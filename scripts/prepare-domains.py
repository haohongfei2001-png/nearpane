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
import subprocess
import sys
import tarfile
import tempfile
import time
import urllib.error
import urllib.request
import zlib

from domain_resources import source_receipt, verify_resources

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
    if path in pin.get("sharedSources", {}):
        return False
    return any(path == prefix or path.startswith(prefix + "/") for prefix in
               pin["sources"] + pin["hostSources"] + pin["notices"])


def validate(pin):
    require(re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", pin["repository"]), "Invalid GitHub repository")
    require(re.fullmatch(r"[0-9a-f]{40}", pin["commit"]), "A full immutable Git commit is required")
    if "upstreamBuild" in pin:
        build = pin["upstreamBuild"]
        require(isinstance(build, dict) and re.fullmatch(r"\d+(?:\.\d+)+", str(build.get("version", "")))
                and type(build.get("build")) is int and build["build"] > 0
                and build.get("channel") in ("development", "internal", "release", "beta")
                and ((type(build.get("pullRequest")) is int and build["pullRequest"] > 0)
                     or (build["channel"] == "release" and isinstance(pin.get("releaseTag"), str)
                         and pin["releaseTag"].strip())),
                "Invalid upstream product build")
    release = pin.get("latestStableRelease")
    if release is not None:
        require(isinstance(release, dict) and isinstance(release.get("version"), str)
                and re.fullmatch(r"\d+(?:\.\d+)+", release["version"])
                and isinstance(release.get("tag"), str) and release["tag"].strip()
                and type(release.get("releaseID")) is int and release["releaseID"] > 0 and release.get("prerelease") is False
                and type(release.get("build")) is int and release["build"] > 0
                and re.fullmatch(r"[0-9a-f]{40}", str(release.get("commit", ""))), "Invalid stable release record")
    files = pin["files"]
    require(files and all(valid_path(p) and selection(pin, p) and re.fullmatch(r"[a-f0-9]{64}", h)
                          for p, h in files.items()), "Invalid file inventory in lock")
    require(all(valid_path(p) and any(f == p or f.startswith(p + "/") for f in files)
                for p in pin["sources"] + pin["hostSources"] + pin["notices"]), "Missing locked selection")
    require(all(p in files for p in pin["hostSources"] + pin["notices"]), "Missing bridge source or notice")
    for path, target in pin.get("sharedSources", {}).items():
        name = PurePosixPath(path).name
        require(re.fullmatch(r"[A-Za-z0-9_]+\.swift", name) and path == "Sources/SaytileKit/" + name
                and target == "Sources/SaytileVoiceUI/" + name and target in files and path not in files,
                "Invalid shared Saytile source")
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


def validate_voice_updates(pin, updates):
    validate(updates)
    require(updates["repository"] == pin["repository"] and not updates["hostSources"]
            and updates["notices"] and updates["sources"], "Invalid Saytile update source")
    sources = updates["sources"]
    require(len(set(sources)) == len(sources) and set(updates["files"]) == set(sources + updates["notices"])
            and all(re.fullmatch(r"Sources/SaytileKit/[A-Za-z0-9_]+\.swift", p) and p in pin["files"] for p in sources),
            "Updates must replace exact locked Saytile sources")


def voice_bindings(cache, pin, updates=None):
    # Keep the domain's internal dependency-injection API in its own Swift module.
    # The verified upstream directory remains byte-for-byte intact.
    adjustment = pin.get("captureReadiness")
    suffix = "-" + adjustment["compiledSHA256"] if adjustment else ""
    dest = cache / ("voice-" + key(pin) + ("-" + key(updates) if updates else "") + suffix)
    links = {"Upstream": cache / key(pin) / "Sources/SaytileKit",
             "Nearpane": ROOT / "Sources/NearpaneSaytileBridge"}
    # Compile the shared source in both modules, using only the locked regular file.
    for path, target in pin.get("sharedSources", {}).items():
        links[PurePosixPath(path).name] = cache / key(pin) / target
    if updates:
        # SwiftPM excludes these originals and discovers only these verified replacements.
        links.update({PurePosixPath(path).name: cache / key(updates) / path for path in updates["sources"]})
    module_bindings(cache, dest, links, links["Upstream"] / "AudioCapture.swift",
                    "saytile-capture-readiness.patch", adjustment)


def adapter_bindings(cache, pin):
    adjustment = pin["draftWitness"]
    upstream = cache / key(pin) / "Sources/RiftletAdapters"
    original = upstream / "ChromeAppleEventsExecutor.swift"
    links = {child.name: child for child in upstream.iterdir() if child != original}
    dest = cache / ("adapters-" + key(pin) + "-" + adjustment["compiledSHA256"])
    module_bindings(cache, dest, links, original, "riftlet-draft-witness.patch", adjustment)


def module_bindings(cache, dest, links, original, patch_name, adjustment):
    expected = set(links)
    patch = ROOT / "Dependencies" / patch_name
    if adjustment:
        require(re.fullmatch(r"[0-9a-f]{64}", adjustment["compiledSHA256"])
                and hashlib.sha256(patch.read_bytes()).hexdigest() == adjustment["patchSHA256"]
                and original.name not in expected, f"Unqualified adaptation: {patch_name}")
        expected.add(original.name)
    if not dest.exists():
        with tempfile.TemporaryDirectory(prefix=".bindings-", dir=cache) as work:
            stage = Path(work) / "module"
            stage.mkdir()
            for name, target in links.items():
                (stage / name).symlink_to(os.path.relpath(target, dest))
            if adjustment:
                result = subprocess.run(["/usr/bin/patch", "-s", "-F", "0", "-o", str(stage / original.name),
                                         str(original), str(patch)], cwd=stage)
                require(result.returncode == 0 and hashlib.sha256((stage / original.name).read_bytes()).hexdigest()
                        == adjustment["compiledSHA256"], f"Cannot reproduce {patch_name}")
            stage.rename(dest)
    require(not dest.is_symlink() and {p.name for p in dest.iterdir()} == expected,
            f"Unexpected entry in {dest.name}")
    if adjustment:
        adapted = dest / original.name
        require(not adapted.is_symlink() and adapted.is_file()
                and hashlib.sha256(adapted.read_bytes()).hexdigest() == adjustment["compiledSHA256"],
                f"Compiled source differs from {patch_name}")
    for name, target in links.items():
        require((dest / name).is_symlink() and (dest / name).resolve(strict=True) == target,
                f"Invalid binding for {name}")



def package_resources(resources, pins, directories, updates, update_directory):
    for name, pin in pins.items():
        verify_resources(resources, name, pin)
        dest = resources / "Upstream" / name
        dest.mkdir(parents=True)
        for path in pin["notices"]:
            notice = dest / path
            notice.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(directories[name] / path, notice)
        provenance = source_receipt(pin)
        if name == "saytile" and updates:
            provenance["updates"] = updates
            for path in updates["notices"]:
                target = dest / "updates" / path
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(update_directory / path, target)
        (dest / "source.json").write_text(json.dumps(provenance, indent=2) + "\n")
    shutil.copyfile(directories["saytile"] / "Sources/CAudio/WEBRTC-LICENSE.txt", resources / "WEBRTC-LICENSE.txt")


def propose(lock, domain, revision, output):
    require(re.fullmatch(r"[0-9a-f]{40}", revision), "A full immutable Git commit is required")
    pin = lock["saytileUpdates"] if domain == "saytileUpdates" else lock["domains"][domain]
    pin["commit"] = revision
    pin.pop("releaseTag", None)
    pin.pop("upstreamBuild", None)  # Verify the product version at the new commit before adopting it.
    pin.pop("latestStableRelease", None)
    url = f"https://api.github.com/repos/{pin['repository']}/git/trees/{revision}?recursive=1"
    with remote(url) as response:
        tree = json.loads(response.read(8 * MIB))
    require(tree["truncated"] is False, "GitHub returned a truncated tree")
    expected = {}
    shared = pin.get("sharedSources", {})
    entries = {entry["path"]: entry for entry in tree["tree"]}
    for path, target in shared.items():
        link = os.path.relpath(target, PurePosixPath(path).parent).encode()
        oid = hashlib.sha1(b"blob " + str(len(link)).encode() + b"\0" + link).hexdigest()
        require(entries.get(path, {}).get("mode") == "120000" and entries[path]["sha"] == oid,
                f"Review upstream shared source: {path}")
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
    require(lock["format"] == 1 and set(lock["domains"]) == {"saytile", "riftlet"}, "Unsupported dependency lock")
    pins = lock["domains"]
    for pin in pins.values():
        validate(pin)
    updates = lock.get("saytileUpdates")
    if updates:
        validate_voice_updates(pins["saytile"], updates)
    if args.propose:
        domain, revision, path = args.propose
        require((domain in pins or (updates and domain == "saytileUpdates")) and not args.offline,
                "Choose saytile, saytileUpdates or riftlet for an online proposal")
        propose(lock, domain, revision, Path(path))
        return
    cache = cache_root()
    cache.mkdir(parents=True, exist_ok=True)
    with (cache / ".lock").open("a") as guard:
        fcntl.flock(guard, fcntl.LOCK_EX)
        offline = args.offline or args.package_resources is not None or os.environ.get("NEARPANE_OFFLINE") == "1"
        directories = {name: prepare(cache, pin, offline) for name, pin in pins.items()}
        update_directory = prepare(cache, updates, offline) if updates else None
        for filename in ("module.modulemap", "shim.h"):
            require(len({(p / "Sources/CSQLite" / filename).read_bytes() for p in directories.values()}) == 1,
                    "Pinned SQLite module definitions no longer match")
        adapter_bindings(cache, pins["riftlet"])
        tray_bindings(cache, pins["riftlet"])
        voice_bindings(cache, pins["saytile"], updates)
        if args.package_resources:
            package_resources(args.package_resources, pins, directories, updates, update_directory)


if __name__ == "__main__":
    try:
        main()
    except (DependencyError, EOFError, OSError, ValueError, KeyError, http.client.HTTPException, tarfile.TarError) as error:
        sys.exit(f"Nearpane dependency error: {error}")
