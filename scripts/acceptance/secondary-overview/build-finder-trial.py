#!/usr/bin/env python3
"""Assemble a one-use Finder launcher for a frozen single- or secondary-display route."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import uuid

ROOT = Path(__file__).resolve().parents[3]
SOURCES = Path(__file__).resolve().parent
OUTPUT = ROOT / "build/verification/finder-native-space"
SCRIPTS = ("scripts/acceptance/secondary-overview/run-route.py",
           "scripts/acceptance/verify-secondary-provision.py", "scripts/acceptance/space-checkpoint.py")
SESSION_APP = "Nearpane Secondary Session.app"


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def validated_kit(root, digest, app):
    root = root.resolve(strict=True)
    manifest = root / "SHA256SUMS"
    if sha(manifest) != digest:
        raise ValueError("Frozen manifest digest mismatch: " + root.name)
    apps = [app]
    names = [Path(line.split("  ", 1)[1]) for line in manifest.read_text().splitlines()]
    session_entries = {name for name in names if name.parts[0] == SESSION_APP}
    if session_entries:
        if app != "Nearpane Secondary Overview.app" or not {
                Path(SESSION_APP, "Contents/Info.plist"),
                Path(SESSION_APP, "Contents/MacOS/SecondarySession")} <= session_entries:
            raise ValueError("Incomplete or misplaced secondary session manifest")
        apps.append(SESSION_APP)
    subprocess.run(["/usr/bin/shasum", "-a", "256", "-c", "SHA256SUMS"], cwd=root, check=True)
    for bundle in apps:
        subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", root / bundle], check=True)
    return root, apps


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--display", type=uuid.UUID, required=True)
    parser.add_argument("--secondary-source", type=int, metavar="SPACE_ID",
                        help="test this ordinary desktop on the named secondary display")
    parser.add_argument("--existing-target", type=int, metavar="SPACE_ID",
                        help="use this explicitly designated existing adjacent secondary desktop and preserve it")
    for kit in ("overview", "witness"):
        parser.add_argument("--" + kit, required=True, type=Path)
        parser.add_argument("--" + kit + "-sha", required=True)
    args = parser.parse_args()
    if args.existing_target is not None and (args.secondary_source is None or
            not 0 < args.existing_target < 2**64 or args.existing_target == args.secondary_source):
        parser.error("--existing-target requires a distinct positive Space ID and --secondary-source")
    os.umask(0o077)
    OUTPUT.mkdir(parents=True, exist_ok=True)
    # A spent package is immutable. A new delivery gets a different receipt directory.
    folder = OUTPUT / str(uuid.uuid4())
    display = str(args.display).upper()
    overview_app = "Nearpane Secondary Overview.app"
    witness_app = "NearpaneSpaceWitness.app"
    overview, overview_bundles = validated_kit(args.overview, args.overview_sha, overview_app)
    witness, witness_bundles = validated_kit(args.witness, args.witness_sha, witness_app)
    baseline = json.loads((witness / "protected.json").read_bytes())
    target_hash = hashlib.sha256(display.encode()).hexdigest()
    monitors = baseline["displays"]
    if args.secondary_source is None:
        if monitors != [target_hash]:
            raise ValueError("Frozen protected session does not match the designated sole display")
    elif (not 0 < args.secondary_source < 2**64 or len(monitors) != 2 or
          len(set(monitors)) != 2 or target_hash not in monitors or
          not all(len(digest) == 64 and all(c in "0123456789abcdef" for c in digest) for digest in monitors)):
        raise ValueError("A secondary trial requires a valid source and two distinct frozen display identities")
    python = Path(shutil.which("python3")).resolve(strict=True)
    supervisor = ROOT / SCRIPTS[0]
    help_text = subprocess.check_output([python, "-I", "-B", supervisor, "--help"], text=True)
    required_option = "--existing-target" if args.existing_target is not None else "--check-overview-first"
    if required_option not in help_text:
        raise ValueError("Supervisor is missing " + required_option)
    # Documents is File Provider backed on this Mac and reintroduces FinderInfo
    # on signed helpers. Keep executable copies on the local volume for this boot.
    stage = Path(tempfile.mkdtemp(prefix="Nearpane-Finder-Space.", dir="/private/tmp"))
    try:
        tools = stage / "tools"
        for source, subdir, digest, bundles in (
                (overview, "overview", args.overview_sha, overview_bundles),
                (witness, "witness", args.witness_sha, witness_bundles)):
            fresh = tools / subdir
            fresh.mkdir(parents=True)
            manifest = source / "SHA256SUMS"
            shutil.copy(manifest, fresh)
            for line in manifest.read_text().splitlines():
                _, name = line.split("  ", 1)
                if Path(name).parts[0] not in bundles:
                    shutil.copy(source / name, fresh / name)
            for bundle in bundles:
                subprocess.run(["/usr/bin/ditto", "--norsrc", "--noextattr", source / bundle, fresh / bundle], check=True)
            validated_kit(fresh, digest, bundles[0])

        app = stage / "开始原生桌面往返验收.app"
        binary = app / "Contents/MacOS/NearpaneFinderTrial"
        binary.parent.mkdir(parents=True)
        resources = app / "Contents/Resources"
        resources.mkdir()
        spec = dict(directory=str(folder), repository=str(ROOT), display=display, python=str(python),
                    helpersSHA256=args.overview_sha, witnessSHA256=args.witness_sha,
                    scripts={path: sha(ROOT / path) for path in SCRIPTS})
        if args.secondary_source is not None:
            spec.update(secondarySource=str(args.secondary_source), displayFingerprints=monitors)
        if args.existing_target is not None:
            spec["existingTarget"] = str(args.existing_target)
        (resources / "trial.json").write_text(json.dumps(spec, sort_keys=True))
        info = dict(CFBundleName="Nearpane 原生桌面验收", CFBundleExecutable=binary.name,
                    CFBundleIdentifier="org.nearpane.lab.FinderSpaceTrial", CFBundleVersion="1",
                    CFBundlePackageType="APPL", LSBackgroundOnly=True,
                    NSDisableAutomaticTermination=True, NSDisableSuddenTermination=True)
        (app / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
        subprocess.run(["xcrun", "swiftc", "-O", "-warnings-as-errors", "-parse-as-library",
                        "-module-cache-path", ROOT / "build/secondary-overview/modules",
                        SOURCES / "FinderTrial.swift", "-o", binary], check=True)
        subprocess.run(["/usr/bin/codesign", "--sign", "-", "--force", app], check=True)
        subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", app], check=True)
        with tempfile.TemporaryDirectory(dir=OUTPUT) as pending:
            final = Path(pending) / "delivery"
            final.mkdir(mode=0o700)
            (final / app.name).symlink_to(app, target_is_directory=True)
            (final / "tools").symlink_to(tools, target_is_directory=True)
            scope = ("副屏测试桌面；主屏可能短暂显示系统调度中心"
                     if args.secondary_source is not None else "当前屏幕的测试桌面")
            if args.existing_target is not None:
                scope = f"副屏已有测试桌面 {args.secondary_source} 和 {args.existing_target}，往返后两者均保留"
            (final / "验收结果.txt").write_text(f"尚未启动。无人使用时在 Finder 中双击本目录的验收应用，临时借用键盘和鼠标，最长 10 分钟。范围为{scope}。\n")
            final.rename(folder)
    except BaseException:
        shutil.rmtree(stage)
        raise
    print(folder / app.name)


if __name__ == "__main__":
    main()
