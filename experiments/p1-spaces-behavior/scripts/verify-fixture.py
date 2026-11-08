#!/usr/bin/env python3
"""Bounded CLI integration test. Only fixture/help/error paths; NEVER 'observe'."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import stat
import subprocess


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    binary = args.binary.resolve(strict=True)
    directory = args.output
    require(directory.is_absolute() and not directory.exists(), "output must be a new absolute path")

    def run(*arguments):
        return subprocess.run([str(binary), *arguments], capture_output=True, text=True, timeout=30)

    require(run("--help").returncode == 0, "help failed")
    require(run().returncode == 0, "no-argument help failed")
    require(run("fixture").returncode != 0, "missing output accepted")
    require(run("fixture", "--output", str(directory), "--samples", "-1").returncode != 0, "invalid bounds accepted")
    require(not directory.exists(), "invalid options created evidence")
    result = run("fixture", "--output", str(directory))
    require(result.returncode == 0, "fixture failed")
    require("NOT TESTED" in result.stdout, "fixture lost behavioral disclaimer")
    require(stat.S_IMODE(directory.stat().st_mode) == 0o700, "unsafe directory mode")
    raw_data = (directory / "raw.jsonl").read_bytes()
    sanitized_data = (directory / "sanitized.jsonl").read_bytes()
    for name in ("raw.jsonl", "sanitized.jsonl"):
        require(stat.S_IMODE((directory / name).stat().st_mode) == 0o600, "unsafe file mode")
    raw = [json.loads(line) for line in raw_data.splitlines()]
    safe = [json.loads(line) for line in sanitized_data.splitlines()]
    require(len(raw) == len(safe) == 15, "incorrect event count")
    require(raw[0]["kind"] == "sessionStart" and raw[-1]["kind"] == "sessionEnd", "incomplete fixture")
    require(raw[0]["config"]["source"] == "synthetic_fixture", "unlabeled fixture")
    require([r["sequence"] for r in raw] == list(range(15)), "sequence gap")
    require([r["sequence"] for r in safe] == list(range(15)), "sanitized sequence gap")
    require(len({r["sessionID"] for r in raw + safe}) == 1, "session identity mismatch")
    samples = [r for r in safe if r["kind"] == "sample"]
    require([r["assessment"]["stability"] for r in samples] == [
        "transient", "transient", "stable", "transient", "transient", "stable",
        "transient", "transient", "stable", "transient", "transient", "stableIncomplete",
    ], "stability sequence incorrect")
    require("operator_marker" in samples[3]["assessment"]["transitionReasons"], "marker did not invalidate")
    require("topology_changed" in samples[6]["assessment"]["transitionReasons"], "topology did not invalidate")
    require({"scope_display_unknown", "current_space_missing", "window_membership_unknown"}.issubset(
        samples[-1]["assessment"]["incompleteness"]), "unknowns were lost")

    # Search typed JSON values rather than substrings of random HMAC fingerprints.
    def values(value):
        if isinstance(value, dict):
            for item in value.values():
                yield from values(item)
        elif isinstance(value, list):
            for item in value:
                yield from values(item)
        else:
            yield value

    secrets = {"SYNTHETIC-PRIVATE-DISPLAY-UUID", "SYNTHETIC-PRIVATE-NAME", "SYNTHETIC-PRIVATE-NOTE",
               "SYNTHETIC-UNKNOWN-SCOPE", 4294900001, 4294900002, 8001, 8002, 12345}
    require(secrets.isdisjoint(set(values(safe))), "private identity leaked")
    raw_fingerprints = {r["assessment"]["topologyFingerprint"] for r in raw if r["kind"] == "sample"}
    require(raw_fingerprints.isdisjoint(set(values(safe))), "raw fingerprint leaked")
    require("SYNTHETIC-PRIVATE-NAME" in set(values(raw)), "raw fixture missing sentinel")
    require(all(r["behavioralVerdict"] == "NOT_ASSESSED_BY_OBSERVER" for r in safe), "invented behavioral verdict")

    original_hashes = [hashlib.sha256(data).hexdigest() for data in (raw_data, sanitized_data)]
    require(run("fixture", "--output", str(directory)).returncode != 0, "existing session overwritten")
    require([hashlib.sha256((directory / name).read_bytes()).hexdigest() for name in ("raw.jsonl", "sanitized.jsonl")] == original_hashes,
            "failed overwrite changed evidence")
    receipt = {
        "schemaVersion": 1, "result": "PASS", "source": "synthetic_fixture", "behavioralTesting": "NOT TESTED",
        "events": 15, "samples": 12, "stableSamples": 3, "stableIncompleteSamples": 1, "transientSamples": 8,
        "binarySHA256": hashlib.sha256(binary.read_bytes()).hexdigest(),
        "rawSHA256": original_hashes[0], "sanitizedSHA256": original_hashes[1],
        "checks": ["help_has_no_sampling", "CLI_validation", "0700_0600_permissions", "complete_ordered_session",
                   "marker_invalidation", "topology_invalidation", "stable_and_transient", "unknown_preservation",
                   "identity_and_note_redaction", "fingerprint_unlinkability", "no_overwrite"],
    }
    receipt_path = directory / "verification.json"
    fd = os.open(receipt_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w") as stream:
        json.dump(receipt, stream, indent=2, sort_keys=True)
        stream.write("\n")
    print(json.dumps(receipt, sort_keys=True))


if __name__ == "__main__":
    main()
