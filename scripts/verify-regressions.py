#!/usr/bin/env python3
"""Check the required test receipts from a standalone or cached regression run."""
import argparse
from pathlib import Path
import re


def passed(ok, label):
    if not ok:
        raise ValueError("Incomplete regression evidence: " + label)


def node_count(log, minimum, label):
    def count(field):
        matches = re.findall(r"^ℹ " + field + r" (\d+)$", log, re.MULTILINE)
        passed(len(matches) == 1, label + " " + field)
        return int(matches[0])
    total = count("tests")
    passed(total >= minimum and count("pass") == total, label)
    for field in ("fail", "cancelled", "skipped", "todo"):
        passed(count(field) == 0, label + " " + field)
    return total


def verify(directory):
    def read(name):
        return (directory / (name + ".log")).read_text()
    counts = {}
    for name, minimum in (("foundation", 113), ("integrated", 147)):
        log = read(name)
        matches = re.findall(r"Test run with (\d+) tests in \d+ suites passed", log)
        passed(len(matches) == 1 and int(matches[0]) >= minimum and not re.search(r"Test .* skipped", log), name)
        counts[name] = int(matches[0])
        for suite in ("SpacePreviewTests", "SpaceInventoryTests", "GeometryTests", "IdentityTests",
                      "NativeDesktopPreviewTests", "NativeDesktopProviderTests"):
            passed("Suite " + suite + " passed" in log, name + " " + suite)
        if name == "integrated":
            for suite in ("VoiceTests", "PCMPipelineTests", "TrayDomainTests", "IntegratedHostTests", "TestTargetBindingTests"):
                passed("Suite " + suite + " passed" in log, suite)
            counts["composed targets"] = node_count(log, 18, "composed targets")
    counts["target guard"] = node_count(read("target-tests"), 17, "target guard")
    for name, minimum in (("resolver-tests", 5), ("receipt-policy", 27)):
        log = read(name)
        summary = re.search(r"^Ran (\d+) tests? in [\d.]+s\s+OK\s*\Z", log, re.MULTILINE)
        passed(summary and int(summary[1]) >= minimum and "ResourceWarning" not in log, name)
        counts[name] = int(summary[1])
    return counts


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("logs", type=Path)
    try:
        for suite, number in verify(parser.parse_args().logs).items():
            print(f"{suite}: {number} passed")
    except (OSError, ValueError) as error:
        parser.exit(1, str(error) + "\n")
