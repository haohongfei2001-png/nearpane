#!/usr/bin/env python3
"""Exercise the pinned page program in a fresh headless browser after scripts/build-app.sh debug."""
import argparse
import base64
from contextlib import closing
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
    parser.add_argument("--session")
    parser.add_argument("--asset-id")
    parser.add_argument("--sha256")
    args = parser.parse_args()
    fixture = {}
    if any((args.session, args.asset_id, args.sha256)):
        if not all((args.session, args.asset_id, args.sha256)):
            parser.error("Specify session, asset ID and SHA-256 together")
        native = runpy.run_path(str(ROOT / "scripts/native-acceptance.py"))
        session = native["folder"](args.session)
        native["allowed_asset"](session, args.asset_id, args.sha256)
        library = session / "support/Riftlet"
        with closing(sqlite3.connect((library / "queue.sqlite").as_uri() + "?mode=ro", uri=True)) as db:
            name, = db.execute("SELECT file_name FROM assets WHERE id = ? COLLATE NOCASE", (args.asset_id,)).fetchone()
        media = library / "media" / name
        if (media.parent != library / "media" or media.resolve() != media or media.suffix.lower() != ".png"
                or media.stat().st_size > 256 * 1024):
            parser.error("This single-chunk local fixture accepts a PNG up to 256 KiB")
        fixture = dict(assetID=args.asset_id, sha256=args.sha256, png=base64.b64encode(media.read_bytes()).decode("ascii"))
    build = ROOT / ".build/app-native/debug"
    lock = json.loads((ROOT / "Dependencies/domains.lock.json").read_bytes())["domains"]["saytile"]
    module = ROOT / ".build/domain-cache-v1" / (lock["commit"] + "-" + lock["treeSHA256"]) / "Sources/CSQLite"
    product = ROOT / "build/debug/Nearpane.app/Contents"
    subprocess.run([str(product / "MacOS/NearpaneHost"), "--verify-bundled-resources"], check=True, cwd=ROOT)
    with tempfile.TemporaryDirectory(dir=ROOT / "build", prefix="local-compose-") as work:
        helper = Path(work) / "compose"
        objects = [p for p in (build / "NearpaneHost.product/Objects.LinkFileList").read_text().splitlines()
                   if "/NearpaneHost.build/" not in p]
        subprocess.run(["xcrun", "swiftc", "-parse-as-library", "-target", platform.machine() + "-apple-macos26.0",
                        "-I", str(build / "Modules"), "-I", str(build / "CAudio.build"), "-I", str(module),
                        "scripts/acceptance/compose-local-adapter.swift", *objects, "-lsqlite3", "-lc++", "-o", str(helper)],
                       check=True, cwd=ROOT)
        source = product / "Resources/Riftlet_RiftletAdapters.bundle/Contents/Resources/chatgpt-web-20261027.js"
        subprocess.run(["node", "scripts/acceptance/local-browser.mjs", str(helper), str(source)],
                       input=json.dumps(fixture), text=True, check=True, cwd=ROOT)


if __name__ == "__main__":
    main()
