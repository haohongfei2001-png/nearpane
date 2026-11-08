#!/usr/bin/env python3
"""Verify independent full packages, including their upstream notices, with source caches inaccessible."""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
RESOURCE_PATHS = {
    "saytile": {"Sources/SaytileKit/Resources/ConnectionSample.pcm": "Nearpane_SaytileKit.bundle/Contents/Resources/ConnectionSample.pcm"},
    "riftlet": {"Sources/RiftletAdapters/Resources/" + file: "Riftlet_RiftletAdapters.bundle/Contents/Resources/" + file
                for file in ("chatgpt-web-20261027.js","legacy-web-observe.js")}
}


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def verify(app, lock, sandbox):
    contents = app / "Contents"
    plist = plistlib.loads((contents/"Info.plist").read_bytes())
    if plist["LSMinimumSystemVersion"] != "26.0" or plist["NearpaneNativeAcceptanceSchema"] != 1:
        raise ValueError("Unexpected full package metadata")
    binary = contents / "MacOS" / plist["CFBundleExecutable"]
    load = subprocess.check_output(["/usr/bin/otool","-l",str(binary)],text=True)
    if not re.search(r"cmd LC_BUILD_VERSION\s+cmdsize \d+\s+platform (?:1|MACOS)\s+minos 26\.0\b",load):
        raise ValueError("Unexpected Mach-O deployment target")
    result = subprocess.check_output(sandbox + [str(binary), "--verify-bundled-resources"],text=True)
    if "Packaged Saytile and Riftlet resources verified." not in result:
        raise ValueError("Missing full packaged resource verification")
    root = contents / "Resources"
    for name,pin in lock["domains"].items():
        provenance = json.loads((root/"Upstream"/name/"source.json").read_text())
        if provenance != {k:pin[k] for k in ("repository","commit","treeSHA256","notices")}:
            raise ValueError("Incorrect packaged provenance: "+name)
        checks = {**RESOURCE_PATHS[name], **{n: "Upstream/"+name+"/"+n for n in pin["notices"]}}
        for src,out in checks.items():
            if digest(root/out) != pin["files"][src]:
                raise ValueError("Packaged checksum mismatch: "+out)
    inventory = {}
    for path in sorted(root.rglob("*")):
        if path.is_file() and path.name != ".DS_Store":
            if root not in path.resolve().parents:
                raise ValueError("Packaged resource escapes its bundle")
            inventory[path.relative_to(root).as_posix()] = digest(path)
    resource_hash = hashlib.sha256(json.dumps(inventory, sort_keys=True, separators=(",",":")).encode()).hexdigest()
    print(f"{app}: {len(inventory)} resources, SHA-256 {resource_hash}; executable {digest(binary)}")
    return resource_hash


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("apps", nargs="+", type=Path)
    parser.add_argument("--deny-cache", action="append", type=Path, default=[])
    args = parser.parse_args()
    deny = [ROOT/".build", ROOT.parent/"saytile", ROOT.parent/"Riftlet", *args.deny_cache]
    params = []
    for index,path in enumerate(deny):
        params.extend(["-D", f"C{index}={path.resolve()}"])
    paths = " ".join(f'(subpath (param "C{i}"))' for i in range(len(deny)))
    profile = f"(version 1)(allow default)(deny file-read* file-write* {paths})(deny network-outbound (remote tcp) (remote udp))"
    sandbox = ["/usr/bin/sandbox-exec", *params, "-p", profile]
    lock = json.loads((ROOT/"Dependencies/domains.lock.json").read_text())
    hashes = {verify(app.resolve(), lock, sandbox) for app in args.apps}
    if len(hashes) != 1:
        raise ValueError("Packages contain different resource files or bytes")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        sys.exit(f"Package verification: {error}")
