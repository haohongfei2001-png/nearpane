#!/usr/bin/env python3
"""Real, read-only packaged helper load/protocol smoke test. Never uses `test`.

Success with no media proves only load/get/symbol availability in this environment.
It is not player support, transport, clock precision, TCC, signing or acoustic proof.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import selectors
import signal
import subprocess
import sys
import time

REQUIRED_SYMBOLS = [
    "MRMediaRemoteGetNowPlayingApplicationPID", "MRMediaRemoteGetNowPlayingClient",
    "MRMediaRemoteGetNowPlayingInfo", "MRMediaRemoteGetNowPlayingApplicationIsPlaying",
    "MRMediaRemoteRegisterForNowPlayingNotifications", "MRMediaRemoteUnregisterForNowPlayingNotifications",
    "MRMediaRemoteGetNowPlayingClients", "MRNowPlayingClientGetBundleIdentifier",
    "MRNowPlayingClientGetProcessIdentifier", "MRMediaRemoteGetLocalOrigin",
    "MRNowPlayingPlayerPathCreate", "MRMediaRemoteGetNowPlayingInfoForPlayer",
    "MRMediaRemoteGetPlaybackStateForPlayer", "MRMediaRemoteGetSupportedCommandsForPlayer",
    "MRMediaRemoteCopySupportedCommands", "MRMediaRemoteSendCommand", "MRMediaRemoteSetElapsedTime",
]
SYMBOL_PROBE = r'''
use strict; use warnings; use DynaLoader;
my $path = '/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote';
my $handle = DynaLoader::dl_load_file($path, 0)
  or die "Private framework load failed: " . DynaLoader::dl_error() . "\n";
my $missing = 0;
for my $symbol (@ARGV) {
  my $found = DynaLoader::dl_find_symbol($handle, $symbol) ? 1 : 0;
  print "$symbol=$found\n";
  if (!$found) { warn "Required private API symbol missing: $symbol\n"; $missing = 1; }
}
exit($missing ? 2 : 0);
'''


def bounded_run(arguments: list[str], deadline: float) -> dict:
    output = {"stdout": bytearray(), "stderr": bytearray()}
    limits = {"stdout": 512 * 1024, "stderr": 64 * 1024}
    reason = None
    process = subprocess.Popen(arguments, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE, start_new_session=True,
                               env={"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8"})
    selector = selectors.DefaultSelector()
    for stream, name in [(process.stdout, "stdout"), (process.stderr, "stderr")]:
        os.set_blocking(stream.fileno(), False)
        selector.register(stream, selectors.EVENT_READ, name)
    try:
        while selector.get_map():
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                reason = "timeout"
                break
            for key, _ in selector.select(min(remaining, 0.1)):
                chunk = os.read(key.fileobj.fileno(), 32768)
                if not chunk:
                    selector.unregister(key.fileobj)
                    continue
                remaining_bytes = limits[key.data] - len(output[key.data])
                output[key.data].extend(chunk[:remaining_bytes])
                if len(chunk) > remaining_bytes:
                    reason = "output_limit"
                    break
            if reason:
                break
        if reason and process.poll() is None:
            os.killpg(process.pid, signal.SIGKILL)
        try:
            code = process.wait(timeout=max(0.05, min(0.2, deadline - time.monotonic())))
        except subprocess.TimeoutExpired:
            reason = reason or "exit_timeout"
            os.killpg(process.pid, signal.SIGKILL)
            code = process.wait(timeout=0.2)
        return {"exitCode": code, "failure": reason,
                "stdout": bytes(output["stdout"]).decode("utf-8", errors="replace"),
                "stderr": bytes(output["stderr"]).decode("utf-8", errors="replace")}
    finally:
        selector.close()
        if process.poll() is None:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait(timeout=0.2)
        process.stdout.close()
        process.stderr.close()


def validate_get(value: object) -> str:
    # The pinned upstream emits JSON null when no application is publishing.
    if value is None or value == {}:
        return "empty"
    if not isinstance(value, dict):
        raise ValueError("get must return an object or JSON null")
    checks = {"playing": bool, "processIdentifier": int, "title": str,
              "bundleIdentifier": str, "parentApplicationBundleIdentifier": str,
              "durationMicros": int, "elapsedTimeMicros": int, "timestampEpochMicros": int}
    for key, expected in checks.items():
        if key in value and value[key] is not None:
            if expected is int:
                item = value[key]
                if type(item) not in (int, float) or not math.isfinite(item) or item != int(item):
                    raise ValueError(f"{key} must be an integral finite number")
            elif type(value[key]) is not expected:
                raise ValueError(f"{key} has an unexpected JSON type")
    for key in ("processIdentifier", "durationMicros", "elapsedTimeMicros", "timestampEpochMicros"):
        if value.get(key) is not None and value[key] < 0:
            raise ValueError(f"{key} must be nonnegative")
    if "supportedCommands" in value:
        if not isinstance(value["supportedCommands"], list):
            raise ValueError("supportedCommands is not an array")
        for command in value["supportedCommands"]:
            if not isinstance(command, dict) or type(command.get("id")) is not int:
                raise ValueError("supportedCommands entry has no integer command id")
            if "enabled" in command and type(command["enabled"]) is not bool:
                raise ValueError("supportedCommands enabled must be boolean")
    return "media_observed"


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while chunk := handle.read(65536):
            digest.update(chunk)
    return digest.hexdigest()


def reject_nonfinite(value: str) -> None:
    raise ValueError(f"Non-finite JSON value: {value}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("helper_directory", type=Path)
    parser.add_argument("--output", type=Path, help="Optional JSON result file")
    parser.add_argument("--timeout-seconds", type=float, default=4.5)
    args = parser.parse_args()
    if not math.isfinite(args.timeout_seconds) or not 3 <= args.timeout_seconds <= 5:
        parser.error("--timeout-seconds must be between 3 and 5")
    started = time.monotonic()
    deadline = started + args.timeout_seconds - 0.25
    result = {"scope": "helper_load_only", "dataOrigin": "runtime_probe",
              "success": False, "mediaState": "not_assessed", "controlsInvoked": [],
              "fakeMediaPublished": False, "playerSupportCertified": False,
              "system": platform.platform(), "macOSVersion": platform.mac_ver()[0],
              "machine": platform.machine(), "helperDirectory": str(args.helper_directory.resolve()),
              "budgetSeconds": args.timeout_seconds}
    try:
        if sys.platform != "darwin":
            raise RuntimeError("This is a real macOS helper check; this host is not macOS")
        directory = args.helper_directory.resolve(strict=True)
        script = directory / "mediaremote-adapter.pl"
        framework = directory / "MediaRemoteAdapter.framework"
        binary = framework / "MediaRemoteAdapter"
        if not script.is_file() or not binary.is_file():
            raise RuntimeError("Packaged script/framework is missing")
        result["scriptSHA256"] = sha256(script)
        result["frameworkSHA256"] = sha256(binary)
        # This is the actual packaged invocation, without a shim/preload/test command.
        get = bounded_run(["/usr/bin/perl", str(script), str(framework), "get", "--micros",
                           "--no-artwork", "--allow-missing-title"], min(deadline - 0.65, time.monotonic() + 3.25))
        result["get"] = get
        if get["exitCode"] != 0 or get["failure"]:
            raise RuntimeError("Packaged helper get failed")
        payload = json.loads(get["stdout"], parse_constant=reject_nonfinite)
        result["mediaState"] = validate_get(payload)
        # Address resolution only: no transport function is called. A successful
        # empty `get` must not hide missing symbols needed by the actual adapter.
        symbols = bounded_run(["/usr/bin/perl", "-e", SYMBOL_PROBE, *REQUIRED_SYMBOLS], deadline)
        result["symbolProbe"] = symbols
        if symbols["exitCode"] != 0 or symbols["failure"]:
            raise RuntimeError("Required private framework symbols are unavailable")
        resolved = dict(line.split("=", 1) for line in symbols["stdout"].splitlines() if "=" in line)
        if any(resolved.get(symbol) != "1" for symbol in REQUIRED_SYMBOLS):
            raise RuntimeError("Incomplete private symbol probe response")
        result["success"] = True
        result["qualification"] = "Packaged dynamic load, read-only get protocol and symbol resolution only"
    except Exception as error:
        result["error"] = f"{type(error).__name__}: {error}"
    result["elapsedSeconds"] = round(time.monotonic() - started, 6)
    text = json.dumps(result, ensure_ascii=False, indent=2) + "\n"
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(text, encoding="utf-8")
    sys.stdout.write(text)
    return 0 if result["success"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
