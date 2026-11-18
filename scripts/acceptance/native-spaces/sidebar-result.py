"""Read the installed sidebar witnesses without treating an AX press as a focus receipt."""
import json
from pathlib import Path
import sys


def read(path):
    return json.loads(path.read_text())


def check(step, output):
    guide_path = output / "guide.json"
    guide = read(guide_path) if guide_path.exists() else {}
    if step == "guide-visible":
        controls = read(output / "before.json").get("sidebar", {}).get("permissionControls", [])
        return "window-access-guide" in controls
    if step == "guide-closed":
        return guide.get("dismissed") is not False
    roster = read(output / "roster/roster-result.json")
    if step == "fixture-clean":
        cleanup = roster.get("cleanup", {})
        return bool(cleanup) and all(cleanup.values())
    granted = guide.get("visibleControls", [])
    permissions = roster.get("permissions") or {}
    if step == "select-siblings":
        if guide:
            return "window-access-focus-granted" in granted
        return permissions.get("accessibility") is True
    if step != "finish":
        raise ValueError(step)
    selection = read(output / "selection/results.json")
    trials = selection.get("controlledWindowTrials", 0)
    cleanup = selection.get("cleanup", {})
    focus = trials == (10 if selection["mode"] == "controlled-window" else 1) and bool(cleanup) and all(cleanup.values())
    guide_state = guide.get("status", "UNOBSERVED")
    if not guide and permissions.get("screen") and focus:
        guide_state = "NOT_NEEDED"
    result = {"guide": guide_state, "layout": roster["status"], "pictures": roster["pixelStatus"],
              "confirmedWindowSelections": trials, "exactFocus": focus}
    (output / "summary.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result))
    return guide_state in ("PASS", "NOT_NEEDED") and roster["status"] == roster["pixelStatus"] == "PASS" and focus


if __name__ == "__main__":
    sys.exit(0 if check(sys.argv[1], Path(sys.argv[2])) else 2)
