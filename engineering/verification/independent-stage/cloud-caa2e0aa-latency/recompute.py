#!/usr/bin/env python3
"""Recompute caa2 derivatives from frozen raw originals; write only caa2."""
import importlib.util
import json
import pathlib

DEST = pathlib.Path(__file__).resolve().parent
ROOT = DEST.parent

def module(name, filename):
    spec = importlib.util.spec_from_file_location(name, ROOT / filename)
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value

compare = module("audit_compare", "audit_compare.py")
timeline = module("audit_timeline", "audit_timeline.py")
names = [n for n in ["5e3a/fast", "5e3a/full", "1e5d/fast", "1e5d/full", "caa2/fast", "caa2/full"]
         if (ROOT / n / "independent-runtime/runtime/summary.json").exists()]
comparison = [compare.audit(n) for n in names]
timelines = [timeline.build(n) for n in names]
for filename, data in [("comparison.json", comparison), ("click-timelines.json", timelines)]:
    (DEST / filename).write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n")
for row in comparison:
    result = row["r4"]
    print(row["name"], result["status"], "R4", result["confirmed"], "/", result["inputs"],
          "latencies", [round(s["latencyMS"], 2) for s in result["steps"]],
          "released", result["hostShutdown"].get("released"))
