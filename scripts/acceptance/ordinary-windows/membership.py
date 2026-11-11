"""Live membership checks in the scoped regular sample app, using shipped Settings."""
import json
import re
import subprocess
import time


def probe_registration(trial, original, *, check, put, out):
    sibling, target = original
    probe = out.parent / "window-registration"
    before = subprocess.check_output([probe, str(target), str(sibling)], text=True).strip()
    check(before == "onscreen", "unable to confirm visible positive controls")
    trial.command("close 2")
    started = time.monotonic()
    observations = []
    for delay in (0, 0.15, 0.35, 0.7, 1.4, 3, 6):
        time.sleep(max(0, started + delay - time.monotonic()))
        state = trial.observe([sibling, target])
        check(trial.focus(state) and state["side"] == trial.run_focus["side"], "focus or secondary changed")
        owner = trial.command("read")
        check([row["number"] for row in owner["windows"]] == [sibling]
              and owner["focusEvents"] == 0, "fixture changed after close")
        registration = subprocess.check_output([probe, str(target), str(sibling)], text=True).strip()
        observations.append(dict(elapsed=time.monotonic()-started, appkitWindowCount=len(owner["windows"]),
                                 system=state["windows"], cgRegistration=registration))
        put(out / "registration.json", dict(sibling=sibling, closed=target, before=before, observations=observations))


def run(trial, original, *, check, wait, put, out):
    trial.start_host()
    trial.press("admission-open")
    trial.press("admission-ordinary-app")
    first, second, third = original
    x, y, width, height = trial.run_focus["bounds"]
    left, work = x + 160, width - 160
    half, split = work / 2, round(work * 0.6)
    pair = {first: [left, y, half, height], second: [left + half, y, half, height]}
    custom = {first: [left, y, split, height], second: [left + split, y, work - split, height]}
    triple = {first: [left + half, y, half, height / 2],
              second: [left + half, y + height / 2, half, height / 2],
              third: [left, y, half, height]}
    previous = set()

    def verify(label, expected, changed):
        actions = trial.checkpoint(label, expected, len(previous) + len(changed))
        current = {action["operation"] for action in actions}
        new = [action for action in actions if action["operation"] not in previous]
        check(previous <= current and len(new) == len(changed)
              and {action["id"]["number"] for action in new} == changed, "unexpected membership write")
        previous.update(current)
        return actions

    trial.press("admission-window-" + str(first))
    trial.select(second)
    verify("authorized-pair", {**original, **pair}, {first, second})
    trial.press("ordinary-pair")
    verify("saved-pair", {**original, **custom}, {first, second})
    trial.select(third)
    actions = verify("authorized-three", triple, set(original))
    third_id = next(a["id"] for a in actions if a["id"]["number"] == third)

    trial.command("close 3")
    def closure_or_refusal():
        journal = json.loads((trial.records / "journal.json").read_text())
        refusals = [entry for entry in journal["entries"] if entry.get("refusal")]
        if refusals:
            put(out / "membership-refusal.json", dict(journal=journal, controls=trial.ui()))
            raise RuntimeError("closure not established: " + refusals[0]["refusal"])
        return next(trial.records.glob("closure-*.json"), None)

    receipt_path = wait(closure_or_refusal)
    closure = json.loads(receipt_path.read_text())
    witness = closure["witness"]
    check(closure["entry"]["id"] == witness["id"] == third_id
          and witness["destroyed"] <= witness["firstAbsent"]
          and witness["secondAbsent"] - witness["firstAbsent"] >= .075, "invalid closure witness")
    verify("pair-restored-after-close", custom, {first, second})
    journal = json.loads((trial.records / "journal.json").read_text())
    check(journal["session"] == closure["session"]
          and {entry["id"]["number"] for entry in journal["entries"]} == {first, second},
          "unexpected post-closure journal membership")
    wait(lambda: "admission-window-" + str(third) not in trial.ui())

    created = trial.command("add 3")
    replacement = next(row for row in created["windows"] if row["index"] == 3)
    rebuilt = replacement["number"]
    check(rebuilt not in (first, second), "replacement collides with a surviving window")
    def visible_unselected():
        controls = trial.ui()
        if "admission-window-" + str(rebuilt) not in controls:
            return False
        if rebuilt != third and "admission-window-" + str(third) in controls:
            return False
        selection = controls.get("admission-selection", {})
        value = selection.get("name", "") + selection.get("value", "")
        return {int(n) for n in re.findall(r"#([0-9]+)", value)} == {first, second}
    wait(visible_unselected)
    verify("rebuilt-preview-only", {**custom, rebuilt: replacement["frame"]}, set())
    trial.press("ordinary-stop")
    verify("stop-leaves-replacement-alone",
           {first: original[first], second: original[second], rebuilt: replacement["frame"]}, {first, second})
    check(not (trial.records / "journal.json").exists(), "unresolved membership journal")
    put(out / "membership.json", dict(session=trial.sid, closed=third_id, closure=witness,
                                      replacement=rebuilt, replacementActions=0, confirmedOperations=len(previous)))
