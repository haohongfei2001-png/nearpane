#!/usr/bin/env python3
"""Sign a separate development Host and observe its production ABI in the current GUI session."""
import argparse
import json
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import tempfile
import uuid

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT/"scripts"))
import candidate_signing as signing


def checked(*args):
    return subprocess.check_output(list(map(str, args)), stderr=subprocess.STDOUT, text=True, timeout=45)


def metadata(app):
    data = plistlib.loads((app/"Contents/Info.plist").read_bytes())
    raw = checked("/usr/bin/codesign", "-dvvv", app)
    fields = dict(re.findall(r"^(CDHash|TeamIdentifier|Identifier)=(.+)$", raw, re.MULTILINE))
    return dict(fields, version=data["CFBundleShortVersionString"], build=data["CFBundleVersion"])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("development_app", type=Path)
    parser.add_argument("output", type=Path, help="fresh evidence directory; the built app stays in a private temporary directory")
    args = parser.parse_args()
    source, out = args.development_app.resolve(strict=True), args.output.resolve()
    if ROOT/"build" not in source.parents or metadata(source)["Identifier"] != "com.holdsnow.nearpane.host":
        parser.error("an existing Nearpane development build is required")
    daily = Path("/Applications/Nearpane.app")
    before = metadata(daily)
    out.mkdir(mode=0o700, parents=True, exist_ok=False)
    private = Path(tempfile.mkdtemp(dir="/private/tmp", prefix="nearpane-stage-engine-dev."))
    app = private/"Nearpane.app"
    evidence = {"scope": "readOnlyIsolatedDevelopmentHost", "qualifiedBackends": [],
                "officialHostRoundTrip": "NOT_RUN", "dailyBefore": before, "status": "UNKNOWN"}
    try:
        checked("/usr/bin/ditto", "--norsrc", "--noextattr", "--noqtn", source, app)
        fingerprint = signing.product_fingerprint(checked("/usr/bin/security", "find-identity", "-v", "-p", "codesigning"))
        info = app/"Contents/Info.plist"
        plist = plistlib.loads(info.read_bytes())
        helpers = app/"Contents/Helpers"
        expected = {"NearpaneDesktopReader", "NearpaneOrdinaryWindowController", "NearpaneSpaceAction", "NearpaneCornerGuardian"}
        if {p.name for p in helpers.iterdir()} != expected:
            raise ValueError("unrecognized development package helpers")
        def seal(path, identifier):
            checked("/usr/bin/codesign", "--force", "--sign", fingerprint, "--options", "runtime", "--timestamp=none",
                    "--preserve-metadata=entitlements", "--identifier", identifier, path)
        for name in sorted(expected):
            path = helpers/name
            if path.is_symlink() or not path.is_file():
                raise ValueError("invalid helper")
            identifier = "com.holdsnow.nearpane.alpha.corner-guardian" if name == "NearpaneCornerGuardian" else name
            seal(path, identifier)
            plist[name+"SHA256"] = signing.sha(path)
        info.write_bytes(plistlib.dumps(plist))
        for relative, identifier in signing.gate.update_runtime.COMPONENTS:
            seal(app/relative, identifier)
        seal(app, "com.holdsnow.nearpane.host")
        checked("/usr/bin/codesign", "--verify", "--strict", "--deep", app)
        checked(sys.executable, "-B", ROOT/"scripts/verify-packages.py", app)
        host = app/"Contents/MacOS/NearpaneHost"
        challenge = str(uuid.uuid4())
        stdout, stderr = private/"probe.json", private/"probe.stderr"
        checked("/usr/bin/open", "-n", "-g", "-W", "-a", app, "--stdin", "/dev/null", "--stdout", stdout,
                "--stderr", stderr, "--args", "--probe-stage-window-engine", challenge)
        observed = json.loads(stdout.read_bytes())
        if (observed.get("challenge") != challenge or observed.get("closed") is not True
                or {row["backend"] for row in observed["engines"] if row.get("unqualifiedWriteRefused") is True} != {"corner","spaces"}):
            raise ValueError("Launch Services did not return the correlated packaged Host observation")
        evidence.update(system={"version": checked("sw_vers", "-productVersion").strip(),
                                "build": checked("sw_vers", "-buildVersion").strip(),
                                "sip": checked("csrutil", "status").strip()},
                        signedHost=metadata(app), hostSHA256=signing.sha(host),
                        engineBoundary=observed, launch="Launch Services background, challenge correlated",
                        sourceHead=plist.get("NearpaneStageEngineSourceRevision"),
                        sourceState=plist.get("NearpaneStageEngineSourceState", "unrecorded"),
                        signedBundleVerified=True, status="PASS")
        (out/"local-app-path.txt").write_text(str(app)+"\n")
    finally:
        evidence["dailyAfter"] = metadata(daily)
        if evidence["dailyAfter"] != before:
            evidence["status"] = "UNKNOWN"
        (out/"target.json").write_text(json.dumps(evidence, indent=2)+"\n")
    if evidence["status"] != "PASS":
        raise SystemExit(2)


if __name__ == "__main__":
    main()
