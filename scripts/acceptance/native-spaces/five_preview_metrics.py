"""Grade independent physical color samples against five identity-bound synthetic markers."""
LIVE = "窗口画面"
FIVE = range(5)


def expected_colors(step):
    return [f"{int(slot < step)}/{slot}" for slot in FIVE]


def measure_batch(batch, step, run, hardware):
    """A wrong color is evidence only when the matching synthetic source is actually visible."""
    statuses = ["UNKNOWN"] * 5
    src, card = batch.get("sources", []), batch.get("cards", [])
    before, after = batch.get("kindsBefore", []), batch.get("kindsAfter", [])
    if (batch.get("ready") is not True or batch.get("run") != run or batch.get("hardware") != hardware
            or batch.get("onePanelSampleBuffer") is not True or batch.get("savedPixels") != 0
            or any(len(v) != 5 for v in (src, card, before, after))):
        return statuses
    owners = run.get("owners", [])
    if (len(owners) != 5 or [r.get("slot") for r in owners] != list(FIVE)
            or any(not isinstance(r.get(k),int) or r[k]<=0 for r in owners for k in ("pid","birth","number"))
            or len({r["pid"] for r in owners}) != 5 or len({r["number"] for r in owners}) != 5):
        return statuses
    geometry = batch.get("geometry", {})
    patches = geometry.get("pictures", [])
    if (not geometry.get("panel") or len(geometry.get("sources", [])) != 5 or len(patches) != 5
            or any(len(p)!=4 or p[2:] != [4,4] for p in patches) or len({tuple(p) for p in patches}) != 5):
        return statuses
    window = {(sample.get("start"), sample.get("end"), sample.get("displayTime"), sample.get("frameStatus")) for sample in card}
    if len(window) != 1 or not isinstance(card[0].get("start"), (int, float)):
        return statuses
    known = set(expected_colors(0) + expected_colors(5))
    for i, expected in enumerate(expected_colors(step)):
        if src[i].get("color") != expected:
            continue
        actual = card[i].get("color")
        if actual == expected and before[i] == after[i] == LIVE:
            statuses[i] = "MATCH"
        elif actual == "blank" or (actual in known and actual != expected) or (
            before[i] == after[i] and after[i] in ("窗口轮廓", "上次画面", "所选快照")
        ):
            statuses[i] = "MISMATCH"
    return statuses


def phase_result(samples, deadline_reached):
    """Two distinct observations of a settled phase are needed to pass or confirm a miss."""
    if len(samples) < 2:
        return ["UNKNOWN"] * 5
    prior, last = samples[-2:]
    distinct = prior.get("batch", {}).get("cards", []) and last.get("batch", {}).get("cards", [])
    if not distinct or prior["batch"]["cards"][0].get("end", float("inf")) >= last["batch"]["cards"][0].get("start", 0):
        return ["UNKNOWN"] * 5
    return [("PASS" if state == "MATCH" else "FAIL" if state == "MISMATCH" and deadline_reached else "UNKNOWN")
            if state == prior["verdicts"][i] else "UNKNOWN" for i, state in enumerate(last["verdicts"])]


def overall(phases):
    full = [p.get("step") for p in phases] == list(range(6))
    per_card = []
    for i in FIVE:
        covered = [p["bySlot"][i] for p in phases]
        per_card.append("FAIL" if "FAIL" in covered else "PASS" if full and all(x == "PASS" for x in covered) else "UNKNOWN")
    return per_card, "FAIL" if "FAIL" in per_card else "PASS" if all(x == "PASS" for x in per_card) else "UNKNOWN"
