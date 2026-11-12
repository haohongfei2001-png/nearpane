#!/usr/bin/env python3
"""Supervise one frozen console witness. This tool never posts keyboard or mouse input."""
import argparse
import datetime as dt
import fcntl
import json
import os
from pathlib import Path
import stat
import sys
import tempfile
import time
import uuid


class Refusal(ValueError):
    pass


def require(condition, message):
    if not condition:
        raise Refusal(message)


def load(path):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd) as stream:
        info = os.fstat(fd)
        require(stat.S_ISREG(info.st_mode) and info.st_uid == os.getuid() and info.st_size <= 1_048_576,
                f"invalid evidence file: {path.name}")
        return json.load(stream)


def publish(path, data):
    require(not os.path.lexists(path), f"checkpoint already published: {path.name}")
    fd, tmp = tempfile.mkstemp(dir=path.parent)
    try:
        with os.fdopen(fd, "w") as stream:
            json.dump(data, stream)
            stream.flush()
            os.fsync(stream.fileno())
        os.rename(tmp, path)  # only the controller holding the run lock publishes these files
    finally:
        Path(tmp).unlink(missing_ok=True)


STEPS = ("unattended-consent", "enroll-A", "enroll-B", "observe-B", "return-A")


def pending(run_dir, run):
    for name in ("stopped", "completed"):
        if (run_dir / f"{name}.json").exists():
            return name
    for name in STEPS:
        request = run_dir / f"request-{name}.json"
        if request.is_file() and not (run_dir / f"{name}.ready").exists():
            data = load(request)
            require(data["run"] == run and data["checkpoint"] == name, "request belongs to another trial")
            return name
    return "waiting"


def utc(value):
    instant = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    require(instant.tzinfo is not None, "supply a time zone")
    return instant.astimezone(dt.timezone.utc)


def format_utc(instant):
    return instant.isoformat(timespec="seconds").replace("+00:00", "Z")


def check_order(origin, secondary, source, target):
    require(source != target, "identical endpoints")
    scope, = [s for s in origin["scopes"] if s["displayID"] == secondary]
    order = [r["id"] for r in scope["records"]]
    currents = [r["id"] for r in scope["records"] if r["isCurrent"]]
    require(origin["separateSpaces"] is True and currents == [source] and source in order and target in order
            and abs(order.index(source) - order.index(target)) == 1, "requested adjacent endpoints not observed")
    return order


def grant(run_dir, run, args):
    require(pending(run_dir, run) == "unattended-consent", "no pending console consent request")
    context = load(run_dir / "console-scope.json")
    origin = load(run_dir / "scope-snapshot-1.json")
    require(context["run"] == run == origin["sessionID"], "origin belongs to another trial")
    fullscreen = getattr(args, "fullscreen_only", False)
    require(fullscreen == (context.get("procedure", "route") == "fullscreen"), "consent does not match trial procedure")
    if fullscreen:
        require(not args.target and args.source.isascii() and args.source.isdecimal() and int(args.source) > 0,
                "fullscreen consent requires only the identified blank source")
        scopes = [s for s in origin["scopes"] if s["displayID"] == context["secondaryDisplay"]]
        require(origin["separateSpaces"] is True and len(scopes) == 1 and
                [r["id"] for r in scopes[0]["records"] if r["isCurrent"]] == [args.source],
                "specified fullscreen source is not the current secondary desktop")
    else:
        check_order(origin, context["secondaryDisplay"], args.source, args.target)
    starts, ends = utc(args.starts), utc(args.ends)
    now = dt.datetime.now(dt.timezone.utc)
    require(starts <= now < ends and ends - starts <= dt.timedelta(minutes=15),
            "owner-approved unattended interval must be current and at most 15 minutes")
    publish(run_dir / "unattended-consent.ready",
            dict(run=run, boot=context["boot"], securityID=int(context["securityID"]),
                 secondaryDisplay=context["secondaryDisplay"], source=args.source, target=args.target or "",
                 starts=format_utc(starts), ends=format_utc(ends), permitsCalibrationAndThreeRoundTrips=not fullscreen,
                 permitsSingleWindowFullscreen=fullscreen))


def ack(run_dir, run, args, *, timeout=20):
    name = args.checkpoint
    require(pending(run_dir, run) == name, "checkpoint is not pending")
    request = load(run_dir / f"request-{name}.json")
    consent = load(run_dir / "unattended-consent.ready")
    require(consent["run"] == run, "consent belongs to another trial")
    now = dt.datetime.now(dt.timezone.utc)
    require(utc(consent["starts"]) <= now < utc(consent["ends"]), "console consent expired")
    direction = args.observed_chord
    directional = name in ("enroll-B", "return-A")
    require(directional == bool(direction), "direction is required only for a system chord actually observed")
    endpoint = consent["target" if name in ("enroll-B", "observe-B") else "source"]
    if directional:
        origin = load(run_dir / "scope-snapshot-1.json")
        order = check_order(origin, consent["secondaryDisplay"], consent["source"], consent["target"])
        start = consent["source" if name == "enroll-B" else "target"]
        require(order.index(endpoint) == order.index(start) + (1 if direction == "right" else -1),
                "observed control-arrow conflicts with the frozen endpoint order")
    else:
        label = "A" if name == "enroll-A" else "B"
        click = load(run_dir / f"click-{label}.json")
        require(click["run"] == run and click["label"] == label and int(click["window"]) > 0,
                "missing actual click on this fixture")
    token = str(uuid.uuid4()).upper()
    release = dict(run=run, checkpoint=name, token=token)
    publish(run_dir / f"{name}.observe", release)
    end = time.monotonic() + timeout
    attestation = run_dir / f"attested-{name}.json"
    while not attestation.exists():
        require(pending(run_dir, run) == name, "witness stopped or advanced")
        require(time.monotonic() < end, "no stable live readback; checkpoint remains closed")
        time.sleep(.05)
    data = load(attestation)
    require(all(data.get(k) == v for k, v in release.items()) and data.get("endpoint") == endpoint
            and int(data["revision"]) > int(request["afterRevision"]), "invalid or stale witness readback")
    require(pending(run_dir, run) == name and dt.datetime.now(dt.timezone.utc) < utc(consent["ends"]),
            "checkpoint expired before release")
    if directional:
        release["demonstratedControlArrow"] = direction
    publish(run_dir / f"{name}.ready", release)


def main():
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""Console operator protocol (use a background command runner, retaining secondary fixture focus):
  1. Run the signed kit's NearpaneSpaceWitness --check-console. Inspect preflight.json.
  2. When both test desktops and return path are identified, start --three-rounds-console.
     Use the UUID printed by this new trial. On its unattended-consent request, record only
     an existing owner grant using consent --source ID --target ID --starts ISO8601 --ends ISO8601.
  3. After its enroll-A request and an actual click on the A fixture, use ack enroll-A.
     At enroll-B, use only the public Control-arrow mapping independently demonstrated for
     this pair. After reaching B, use ack enroll-B --observed-chord left|right. A registered
     shortcut or the order of records alone does not establish the system mapping.
  4. At observe-B, click the new B fixture and use ack observe-B. At return-A, after the
     demonstrated return, use ack return-A --observed-chord left|right. These setup steps
     do not count toward the three automated rounds. Never acknowledge unobserved input.
  Alternatively, --fullscreen-console enrolls only A. Record the existing fullscreen grant
  with consent --fullscreen-only --source ID --starts ISO8601 --ends ISO8601 and ack the
  actual enroll-A click. It attempts one public AppKit entry and exit on the enrolled window.
  5. On stopped.json, inspect pendingInput, cleanup, scopeReturn, focusReturn and raw
     per-leg records. No retry or automatic inverse shortcut is issued by this controller.
     A trial terminated without stopped.json or completed.json has an unknown outcome.""")
    parser.add_argument("run", type=uuid.UUID, help="UUID printed by the running frozen witness")
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("status")
    consent = commands.add_parser("consent", help="record an existing owner grant for these specific endpoints")
    for key in ("source", "starts", "ends"):
        consent.add_argument("--" + key, required=True)
    consent.add_argument("--target", help="required destination for a route trial")
    consent.add_argument("--fullscreen-only", action="store_true", help="grant only one native fullscreen entry and return on A")
    release = commands.add_parser("ack", help="acknowledge a witnessed fixture click or manually demonstrated system chord")
    release.add_argument("checkpoint", choices=STEPS[1:])
    release.add_argument("--observed-chord", choices=("left", "right"))
    args = parser.parse_args()
    run = str(args.run).upper()
    run_dir = Path.home() / "Library" / "Caches" / ("Nearpane-P431-" + run)
    info = run_dir.lstat()
    require(stat.S_ISDIR(info.st_mode) and info.st_uid == os.getuid() and info.st_mode & 0o077 == 0,
            "expected private witness run directory")
    if args.command == "status":
        print(pending(run_dir, run))
        return
    fd = os.open(run_dir / "checkpoint-controller.lock", os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "r+") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        if args.command == "consent":
            grant(run_dir, run, args)
        else:
            ack(run_dir, run, args)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, KeyError, TypeError) as exc:
        sys.exit(str(exc))
