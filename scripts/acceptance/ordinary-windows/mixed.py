"""Two independent, blank AppKit applications. Nearpane receives only their system identities."""


def run(t, documents, palette, *, out, check, put):
    check(t.focus(t.peer.run_focus) and t.run_focus["side"] == t.peer.run_focus["side"],
          "foreground, focused window or display changed when launching second sample")
    check(t.fixture.pid != t.peer.fixture.pid and t.bundle != t.peer.bundle,
          "expected separate signed applications")
    first, document_sibling = documents
    second, palette_sibling = palette
    original = {**documents, **palette}
    check(len(original) == 4, "each ordinary window needs a unique CG number")
    x, y, w, h = t.run_focus["bounds"]
    left = x + 160
    width = w - 160
    whole = [left, y, width, h]
    half = {first: [left, y, width / 2, h], second: [left + width / 2, y, width / 2, h]}
    split = round(width * .6)
    custom = {first: [left, y, split, h], second: [left + split, y, width - split, h]}
    seen = set()
    stages = []
    def expect(label, positions, changed):
        actions = t.checkpoint(label, {**original, **positions}, len(seen) + len(changed))
        ids = {a["operation"] for a in actions}
        new = [a for a in actions if a["operation"] not in seen]
        check(seen <= ids and len(new) == len(changed) and {a["id"]["number"] for a in new} == changed,
              "unexpected window write at " + label)
        for a in actions:
            expected = {first: t, second: t.peer}
            owner = expected.get(a["id"]["number"])
            check(owner is not None and a["id"]["pid"] == owner.fixture.pid
                  and a["id"]["launch"] == owner.checkpoints[0]["system"]["ownerLaunch"]
                  and a["readback"]["second"]["bundle"] == owner.bundle,
                  "receipt did not match the exact enrolled application and generation")
        seen.update(ids)
        stages.append(dict(label=label, writes=len(new), maxAXCGErrorPt=t.receipts[-1]["maxErrorPt"]))
        put(out/"mixed.json", dict(session=t.sid, apps=[dict(bundle=a.bundle, pid=a.fixture.pid,
            launch=a.checkpoints[0]["system"]["ownerLaunch"]) for a in (t,t.peer)], stages=stages,
            unmanagedSiblings=[document_sibling,palette_sibling], siblingWrites=0))

    check(t.sample("after-peer-launch") == documents and t.peer.sample("after-documents-readback") == palette,
          "launching second independent application changed original geometry")
    t.start_host()
    t.press("admission-open")
    selection = "Standard documents #" + str(first) + "、Standard palette #" + str(second)
    def preview(label):
        for owner, name, number in ((t,"documents",first),(t.peer,"palette",second)):
            t.press("admission-ordinary-app-" + str(owner.fixture.pid))
            put(out/(label+"-"+name+"-choices.json"), t.ui())
            t.press("admission-window-" + str(number))
        check(t.ui().get("admission-selection", {}).get("value") == selection, "mixed selection changed")
        t.press("admission-read")
    def confirm():
        check(t.ui().get("admission-selection", {}).get("value") == selection, "mixed grant scope changed")
        t.press("ordinary-confirm")
    preview("initial")
    expect("mixed-preview-before-consent", {}, set())
    confirm()
    expect("mixed-half", half, {first, second})
    t.press("ordinary-pair")
    expect("mixed-saved-ratio", custom, {first, second})
    t.press("ordinary-pause")
    expect("paused", custom, set())
    t.press("ordinary-resume")
    expect("resumed", custom, set())
    t.press("ordinary-stop")
    expect("both-restored", {}, {first, second})
    check(not (t.records/"journal.json").exists(), "journal remains after normal restoration")
    # Stopping releases the old AX handles. Explicitly reselect both windows from their
    # current process inventories; a previously selected row may already have expired.
    preview("renewal")
    confirm()
    expect("explicitly-regranted", half, {first, second})
    t.press("ordinary-exclude-" + str(second))
    expected = {first:whole, second:half[second]}
    expect("one-owner-excluded", expected, {first})
    t.press("ordinary-stop")
    expect("stop-after-exclusion", {second:half[second]}, {first})
    check(not (t.records/"journal.json").exists(), "journal remains after exclusion and stop")
