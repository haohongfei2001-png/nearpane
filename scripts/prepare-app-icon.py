#!/usr/bin/env python3
"""Validate versioned visual sources and install the frozen, multi-resolution App icon."""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import shutil
import struct

ROOT = Path(__file__).resolve().parents[1]
REVISION = "2026-11-15-v2"
ASSETS = ROOT / "design/assets" / REVISION
MANIFEST = ASSETS / "manifest.json"
ICON = ROOT / "Resources/Nearpane.icns"
SIZES = {"icp4": 16, "ic11": 32, "icp5": 32, "ic12": 64, "ic07": 128,
         "ic13": 256, "ic08": 256, "ic14": 512, "ic09": 512, "ic10": 1024}


def digest(data):
    return hashlib.sha256(data).hexdigest()


def png_dimensions(data):
    if len(data) < 24 or data[:8] != b"\x89PNG\r\n\x1a\n" or data[12:16] != b"IHDR":
        raise ValueError("Invalid icon PNG representation")
    return struct.unpack(">II", data[16:24])


def regular(path):
    if path.is_symlink() or not path.is_file():
        raise ValueError("Missing or indirect icon resource: " + str(path))
    return path.read_bytes()


def validate_icon(data, expected):
    if (len(data) < 8 or data[:4] != b"icns" or struct.unpack(">I", data[4:8])[0] != len(data)
            or len(data) != expected["byteLength"] or digest(data) != expected["sha256"]):
        raise ValueError("App icon container fingerprint mismatch")
    offset, members = 8, []
    while offset < len(data):
        if offset + 8 > len(data):
            raise ValueError("Incomplete App icon member")
        kind = data[offset:offset + 4].decode("ascii")
        length = struct.unpack(">I", data[offset + 4:offset + 8])[0]
        if length < 8 or offset + length > len(data) or kind not in SIZES:
            raise ValueError("Unknown or invalid App icon member")
        png = data[offset + 8:offset + length]
        width, height = png_dimensions(png)
        if width != SIZES[kind] or height != width:
            raise ValueError("Wrong App icon representation dimensions")
        members.append(dict(type=kind, pixelWidth=width, pixelHeight=height, sha256=digest(png)))
        offset += length
    if len(members) != len(SIZES) or {m["type"] for m in members} != set(SIZES) or members != expected["members"]:
        raise ValueError("Incomplete App icon resolution inventory")


def provenance():
    manifest = json.loads(regular(MANIFEST))
    if manifest["revision"] != REVISION or manifest["schemaVersion"] != 1:
        raise ValueError("Unknown visual source revision")
    for item in manifest["assets"]:
        data = regular(ASSETS / item["file"])
        if (digest(data) != item["sha256"] or len(data) != item["byteLength"]
                or png_dimensions(data) != (item["pixelWidth"], item["pixelHeight"])):
            raise ValueError("Visual source fingerprint mismatch: " + item["file"])
    packaged = manifest["packagedIcon"]
    if (packaged["bundleResource"] != "Nearpane.icns"
            or packaged["sourceSHA256"] != digest(regular(ASSETS / packaged["source"]))):
        raise ValueError("App icon source mismatch")
    validate_icon(regular(ICON), packaged)
    return dict(schemaVersion=1, visualRevision=REVISION, packagedIcon=packaged,
                originalBrandSHA256=next(item["sha256"] for item in manifest["assets"]
                                         if item["role"] == "authoritative-brand-reference"))


def embed(app):
    source = provenance()
    contents = app / "Contents"
    resources = contents / "Resources"
    resources.mkdir(exist_ok=True)
    shutil.copyfile(ICON, resources / "Nearpane.icns")
    (resources / "AppIconSource.json").write_text(json.dumps(source, indent=2, sort_keys=True) + "\n")
    plist = contents / "Info.plist"
    info = plistlib.loads(plist.read_bytes())
    info.update(CFBundleIconFile="Nearpane.icns", NearpaneAppIconSHA256=source["packagedIcon"]["sha256"],
                NearpaneAppIconSourceSHA256=source["packagedIcon"]["sourceSHA256"], NearpaneVisualAssetRevision=REVISION)
    plist.write_bytes(plistlib.dumps(info))
    return verify(app)


def verify(app):
    expected = provenance()
    contents = app / "Contents"
    resources = contents / "Resources"
    info = plistlib.loads(regular(contents / "Info.plist"))
    if (info.get("CFBundleIconFile") != "Nearpane.icns"
            or info.get("NearpaneAppIconSHA256") != expected["packagedIcon"]["sha256"]
            or info.get("NearpaneAppIconSourceSHA256") != expected["packagedIcon"]["sourceSHA256"]
            or info.get("NearpaneVisualAssetRevision") != REVISION):
        raise ValueError("App icon metadata absent or inconsistent")
    if json.loads(regular(resources / "AppIconSource.json")) != expected:
        raise ValueError("Packaged App icon provenance mismatch")
    validate_icon(regular(resources / "Nearpane.icns"), expected["packagedIcon"])
    return dict(revision=REVISION, sha256=expected["packagedIcon"]["sha256"],
                sourceSHA256=expected["packagedIcon"]["sourceSHA256"], representations=len(SIZES))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--embed", type=Path, metavar="APP")
    mode.add_argument("--verify", type=Path, metavar="APP")
    args = parser.parse_args()
    try:
        result = embed(args.embed) if args.embed else verify(args.verify) if args.verify else provenance()
    except (OSError, ValueError, KeyError, StopIteration) as error:
        parser.exit(1, "App icon: " + str(error) + "\n")
    print(json.dumps(result, indent=2, sort_keys=True))
