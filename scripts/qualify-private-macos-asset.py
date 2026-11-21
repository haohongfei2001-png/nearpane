#!/usr/bin/env python3
"""Read and assess one exact private PR candidate on a fresh hosted Mac."""
import json
import http.client
import os
from pathlib import Path
import re
import shutil
import signal
import time
import subprocess
import sys
import tempfile
from urllib.parse import urlsplit

from private_notary import fingerprint, require, sha, unpack

REPO = "repos/haohongfei2001-png/nearpane"
BASE = Path(__file__).resolve().parents[1] / "engineering/verification/native-spaces/5.22-p6"


def api(route):
    return json.loads(subprocess.check_output(["gh", "api", REPO + route], timeout=25))


def download_signed_asset(link, ref, archive):
    target = urlsplit(link)
    require(target.scheme == "https" and target.netloc in {"release-assets.githubusercontent.com","objects.githubusercontent.com"}
            and target.path.startswith("/") and target.query and not target.fragment, "Unrecognized GitHub asset delivery")
    connection = http.client.HTTPSConnection(target.netloc, timeout=60)
    try:
        connection.request("GET", target.path + "?" + target.query)
        response = connection.getresponse()
        require(response.status == 200 and int(response.getheader("Content-Length", "0")) == ref["bytes"],
                "GitHub delivery did not return the exact enrolled content length")
        with archive.open("xb") as f:
            while block := response.read(1024 * 1024):
                f.write(block)
    finally:
        connection.close()


def distribution_policy(app):
    commands = {"gatekeeper": ["/usr/sbin/spctl","--assess","--type","execute","--verbose=4",app],
                "staple": ["/usr/bin/xcrun","stapler","validate",app],
                "distribution": ["/usr/bin/syspolicy_check","distribution",app]}
    checks = {}
    for name, cmd in commands.items():
        run = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=90)
        markers = [term for term in ("Unnotarized Developer ID", "source=Notarized Developer ID", "Notary Ticket Missing",
                                     "does not have a ticket", "assessment system is disabled") if term in run.stdout]
        checks[name] = {"exit": run.returncode, "messages": markers}
    admitted = all(item["exit"] == 0 for item in checks.values()) and "source=Notarized Developer ID" in checks["gatekeeper"]["messages"]
    return checks, "PASS" if admitted else "NOT_ADMITTED"


def hosted_install(app, ref):
    """Install one enrolled archive to the normal path in an empty GitHub-hosted login."""
    require([os.getenv(k) for k in ("GITHUB_ACTIONS", "RUNNER_ENVIRONMENT", "RUNNER_OS")] ==
            ["true", "github-hosted", "macOS"], "Physical daily installations are outside this supervisor")
    destination = Path("/Applications/Nearpane.app")
    result = {"installation": "BLOCKED", "launch": "NOT_RUN", "installedHostInteraction": "NOT_RUN",
              "settingWrites": 0}
    if destination.exists() or destination.is_symlink():
        result["reason"] = "existingInstallationPreserved"
        return result
    with tempfile.TemporaryDirectory(dir="/Applications", prefix=".nearpane-intake.") as staging:
        staged = Path(staging) / "Nearpane.app"
        subprocess.run(["/usr/bin/ditto", app, staged], check=True)
        identity = fingerprint(staged, ref["source"])
        fsid = staged.stat()
        procs = []
        try:
            os.rename(staged, destination)
            installed = fingerprint(destination, ref["source"])
            require(identity == installed, "Installation changed the signed candidate")
            result.update(installation="PASS", canonicalPath=str(destination), signedObjects=len(installed["binaries"]))
            installed_checks, installed_policy = distribution_policy(destination)
            result.update(installedSystemPolicy=installed_policy, installedChecks=installed_checks)
            if installed_policy != "PASS":
                result.update(launch="BLOCKED", reason="macOSDistributionPolicy")
                return result
            executable = destination / "Contents/MacOS/NearpaneHost"
            opened = subprocess.run(["/usr/bin/open", "-g", "-a", destination], capture_output=True, timeout=15)
            deadline = time.monotonic() + 8
            while time.monotonic() < deadline:
                table = subprocess.check_output(["/bin/ps","-axo","pid=,comm="], text=True)
                procs = [int(parts[0]) for row in table.splitlines()
                         if len(parts := row.strip().split(None,1)) == 2 and parts[1] == str(executable)]
                if len(procs) == 1:
                    break
                time.sleep(.2)
            result["launch"] = "PASS" if opened.returncode == 0 and len(procs) == 1 else "UNKNOWN"
            return result
        finally:
            for pid in procs:
                cmd = subprocess.run(["/bin/ps","-p",str(pid),"-o","comm="], capture_output=True, text=True)
                if cmd.stdout.strip() == str(destination / "Contents/MacOS/NearpaneHost"):
                    os.kill(pid, signal.SIGTERM)
            if destination.exists() and not destination.is_symlink() and os.path.samestat(fsid, destination.stat()):
                shutil.rmtree(destination)
            result["fixtureInstallationRemoved"] = not destination.exists()


def assess(tag):
    require(re.fullmatch(r"[0-9a-f]{7,40}", tag), "Expected a frozen candidate revision")
    ref = json.loads((BASE / ("integrated-" + tag) / "draft-asset.json").read_bytes())
    require(ref["source"].startswith(tag) and ref["draftReleaseID"] == 452393835 and not ref["publicRelease"],
            "Unenrolled release or source")
    with tempfile.TemporaryDirectory(prefix="nearpane-hosted-intake.") as tmp:
        root = Path(tmp).resolve()
        archive = root / "candidate.zip"
        link = os.environ.pop("NEARPANE_PRIVATE_ASSET_URL", "")
        if link:
            download_signed_asset(link, ref, archive)
        else:
            release = api("/releases/" + str(ref["draftReleaseID"]))
            require(release["draft"], "Private release is no longer a draft")
            matching = [a for a in release["assets"] if a["id"] == ref["assetID"]]
            require(len(matching) == 1 and matching[0]["digest"] == "sha256:" + ref["sha256"]
                    and matching[0]["size"] == ref["bytes"], "Enrolled asset metadata changed")
            with archive.open("xb") as f:
                subprocess.run(["gh", "api", "-H", "Accept: application/octet-stream",
                                REPO + "/releases/assets/" + str(ref["assetID"])], stdout=f, check=True, timeout=180)
        require(archive.stat().st_size == ref["bytes"] and sha(archive) == ref["sha256"], "Downloaded bundle differs")
        app = unpack(archive, root)
        candidate = fingerprint(app, ref["source"])
        checks, policy = distribution_policy(app)
        result = {"source": ref["source"], "assetID": ref["assetID"], "sha256": ref["sha256"],
                "verifiedBinaries": len(candidate["binaries"]), "architectures": sum(len(b["slices"]) for b in candidate["binaries"].values()),
                "osBuild": subprocess.check_output(["sw_vers","-buildVersion"], text=True).strip(), "checks": checks,
                "systemPolicy": policy,
                "installation": "NOT_RUN", "launch": "NOT_RUN", "publicRelease": False}
        if ref.get("verifyInstalledStageCandidate") is True:
            result.update(hosted_install(app, ref))
        return result


if __name__ == "__main__":
    print(json.dumps(assess(sys.argv[1]), sort_keys=True))
