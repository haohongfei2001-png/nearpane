#!/usr/bin/env python3
"""Read and assess one exact private PR candidate on a fresh hosted Mac."""
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile

from private_notary import fingerprint, require, sha, unpack

REPO = "repos/haohongfei2001-png/nearpane"
BASE = Path(__file__).resolve().parents[1] / "engineering/verification/native-spaces/5.22-p6"


def api(route):
    return json.loads(subprocess.check_output(["gh", "api", REPO + route], timeout=25))


def assess(tag):
    require(re.fullmatch(r"[0-9a-f]{7,40}", tag), "Expected a frozen candidate revision")
    ref = json.loads((BASE / ("integrated-" + tag) / "draft-asset.json").read_bytes())
    require(ref["source"].startswith(tag) and ref["draftReleaseID"] == 452393835 and not ref["publicRelease"],
            "Unenrolled release or source")
    release = api("/releases/" + str(ref["draftReleaseID"]))
    require(release["draft"], "Private release is no longer a draft")
    matching = [a for a in release["assets"] if a["id"] == ref["assetID"]]
    require(len(matching) == 1 and matching[0]["digest"] == "sha256:" + ref["sha256"]
            and matching[0]["size"] == ref["bytes"], "Enrolled asset metadata changed")
    with tempfile.TemporaryDirectory(prefix="nearpane-hosted-intake.") as tmp:
        root = Path(tmp).resolve()
        archive = root / "candidate.zip"
        with archive.open("xb") as f:
            subprocess.run(["gh", "api", "-H", "Accept: application/octet-stream",
                            REPO + "/releases/assets/" + str(ref["assetID"])], stdout=f, check=True, timeout=180)
        require(archive.stat().st_size == ref["bytes"] and sha(archive) == ref["sha256"], "Downloaded bundle differs")
        app = unpack(archive, root)
        candidate = fingerprint(app, ref["source"])
        commands = {"gatekeeper": ["/usr/sbin/spctl","--assess","--type","execute","--verbose=4",app],
                    "staple": ["/usr/bin/xcrun","stapler","validate",app],
                    "distribution": ["/usr/bin/syspolicy_check","distribution",app]}
        checks = {}
        for name, cmd in commands.items():
            run = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=90)
            markers = [term for term in ("Unnotarized Developer ID", "source=Notarized Developer ID", "Notary Ticket Missing",
                                         "does not have a ticket", "assessment system is disabled") if term in run.stdout]
            checks[name] = {"exit": run.returncode, "messages": markers}
        return {"source": ref["source"], "assetID": ref["assetID"], "sha256": ref["sha256"],
                "verifiedBinaries": len(candidate["binaries"]), "architectures": sum(len(b["slices"]) for b in candidate["binaries"].values()),
                "osBuild": subprocess.check_output(["sw_vers","-buildVersion"], text=True).strip(), "checks": checks,
                "systemPolicy": "PASS" if all(x["exit"] == 0 for x in checks.values()) and
                "source=Notarized Developer ID" in checks["gatekeeper"]["messages"] else "NOT_ADMITTED",
                "installation": "NOT_RUN", "launch": "NOT_RUN", "publicRelease": False}


if __name__ == "__main__":
    print(json.dumps(assess(sys.argv[1]), sort_keys=True))
