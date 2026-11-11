#!/usr/bin/env python3
"""Exercise the pinned page program in a fresh headless browser after scripts/build-app.sh debug."""
import argparse
import base64
from contextlib import closing
import hashlib
import json
import runpy
import sqlite3
from pathlib import Path
import platform
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--product", action="store_true", help="Exercise the ordinary Swift adapter and durable queue with an isolated Chromium transport")
    parser.add_argument("--candidate", type=Path, help="Check both exercised browser resources against this signed, installed product")
    parser.add_argument("--session")
    parser.add_argument("--asset-id")
    parser.add_argument("--sha256")
    args = parser.parse_args()
    fixture = {"productDriver": True} if args.product else {}
    if any((args.session, args.asset_id, args.sha256)):
        if not all((args.session, args.asset_id, args.sha256)):
            parser.error("Specify session, asset ID and SHA-256 together")
        native = runpy.run_path(str(ROOT / "scripts/native-acceptance.py"))
        session = native["folder"](args.session)
        native["allowed_asset"](session, args.asset_id, args.sha256)
        library = session / "support/Riftlet"
        with closing(sqlite3.connect((library / "queue.sqlite").as_uri() + "?mode=ro", uri=True)) as db:
            name, raw = db.execute("SELECT file_name, image_json FROM assets WHERE id = ? COLLATE NOCASE", (args.asset_id,)).fetchone()
        media = library / "media" / name
        if (media.parent != library / "media" or media.resolve() != media or media.suffix.lower() != ".png"
                or media.stat().st_size > (8 * 1024 * 1024 if args.product else 256 * 1024)):
            parser.error("Expected a bounded, verified session PNG (8 MiB product / 256 KiB test fixture)")
        fixture.update(assetID=args.asset_id, sha256=args.sha256, png=base64.b64encode(media.read_bytes()).decode("ascii"))
        if args.product:
            image = json.loads(raw)
            fixture.update(origin=image["origin"], width=image["pixelWidth"], height=image["pixelHeight"])
    build = ROOT / ".build/app-native/debug"
    lock = json.loads((ROOT / "Dependencies/domains.lock.json").read_bytes())["domains"]["saytile"]
    module = ROOT / ".build/domain-cache-v1" / (lock["commit"] + "-" + lock["treeSHA256"]) / "Sources/CSQLite"
    product = ROOT / "build/debug/Nearpane.app/Contents"
    subprocess.run([str(product / "MacOS/NearpaneHost"), "--verify-bundled-resources"], check=True, cwd=ROOT)
    page = Path("Resources/Riftlet_RiftletAdapters.bundle/Contents/Resources/chatgpt-web-20261027.js")
    if args.candidate:
        if not args.product or args.candidate.suffix != ".app":
            parser.error("--candidate requires an installed product .app and --product")
        subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(args.candidate)], check=True)
        hashes = {}
        for resource in [Path("Resources/AcceptanceTargetGuard.js"), page]:
            blob = (product / resource).read_bytes()
            if blob != (args.candidate / "Contents" / resource).read_bytes():
                parser.error("Installed candidate differs from the exercised browser resource " + resource.name)
            hashes[resource.name] = hashlib.sha256(blob).hexdigest()
        fixture["candidateBrowserResources"] = hashes
    with tempfile.TemporaryDirectory(dir=ROOT / "build", prefix="local-compose-") as work:
        helper = Path(work) / "compose"
        objects = [p for p in (build / "NearpaneHost.product/Objects.LinkFileList").read_text().splitlines()
                   if "/NearpaneHost.build/" not in p]
        subprocess.run(["xcrun", "swiftc", "-parse-as-library", "-target", platform.machine() + "-apple-macos26.0",
                        "-module-cache-path", str(ROOT / "build/verification/browser-compiler-cache"),
                        "-I", str(build / "Modules"), "-I", str(build / "CAudio.build"), "-I", str(module),
                        str(ROOT / "scripts/acceptance" / ("product-browser-driver.swift" if args.product else "compose-local-adapter.swift")), *objects, "-lsqlite3", "-lc++", "-o", str(helper)],
                       check=True, cwd=ROOT)
        source = product / page
        subprocess.run(["node", "scripts/acceptance/local-browser.mjs", str(helper), str(source)],
                       input=json.dumps(fixture), text=True, check=True, cwd=ROOT)


if __name__ == "__main__":
    main()
