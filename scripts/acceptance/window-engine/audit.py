"""Audit vendored origins and the resolved Cargo graph used by the engine."""
import argparse
import hashlib
import json
import re
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
ENGINE = ROOT / "Engine/nearpane-window-engine"
UPSTREAM = "eugene-tea/stage-manager"
COMMIT = "69a73665488243bf78982c6d523ac4e0850c1ddb"
TREE = "1bcc92e00ad44d6e455fa0a5f335805b4cf66ae1"

def main():
    args = argparse.ArgumentParser(description=__doc__)
    args.add_argument("tree", type=Path, help="recursive GitHub Git Trees response for the pinned tree")
    args.add_argument("output", type=Path)
    args.add_argument("--origins", nargs="+", default=None)
    a = args.parse_args()
    source = json.loads(a.tree.read_bytes())
    if source["sha"] != TREE or source["truncated"]:
        raise ValueError("upstream tree incomplete or changed")
    refs = {r["path"]: r["sha"] for r in source["tree"] if r["type"] == "blob"}
    entries = []
    files = [ENGINE/"origins"/(n+".json") for n in a.origins] if a.origins else sorted((ENGINE/"origins").glob("*.json"))
    for manifest in files:
        for row in json.loads(manifest.read_bytes()):
            path = (ENGINE/row["local"]).resolve(strict=True)
            if ENGINE not in path.parents or refs.get(row["upstream"]) != row["blob"] or not row["modifications"]:
                raise ValueError(f"unverified upstream origin {row}")
            entries.append(dict(local=row["local"], upstream=row["upstream"], blob=row["blob"],
                                upstreamCommit=COMMIT, localSHA256=hashlib.sha256(path.read_bytes()).hexdigest()))
    license_bytes = (ENGINE/"LICENSE.upstream").read_bytes()
    if hashlib.sha1(b"blob " + str(len(license_bytes)).encode() + b"\0" + license_bytes).hexdigest() != refs["LICENSE"]:
        raise ValueError("changed upstream copyright/license")
    graph = json.loads(subprocess.check_output(["cargo","metadata","--locked","--all-features","--offline",
        "--manifest-path",str(ENGINE/"Cargo.toml"),"--format-version","1"]))
    resolved = {node["id"] for node in graph["resolve"]["nodes"]}
    packages = [p for p in graph["packages"] if p["id"] in resolved]
    if len(packages)!=1 or Path(packages[0]["manifest_path"]).resolve() != ENGINE/"Cargo.toml":
        raise ValueError("Cargo dependencies changed; review each dependency and its license before integration")
    out = dict(upstream=UPSTREAM, commit=COMMIT, tree=TREE, upstreamLicense="MIT", origins=entries,
               firstPartyPackage=packages[0]["name"], cargoLockSHA256=hashlib.sha256((ENGINE/"Cargo.lock").read_bytes()).hexdigest(),
               externalCargoDependencies=[], status="PASS")
    a.output.parent.mkdir(parents=True, exist_ok=True)
    a.output.write_text(json.dumps(out,ensure_ascii=False,indent=2)+"\n")

if __name__ == "__main__":
    main()
