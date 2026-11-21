"""Pure receipt replay and parity decisions. No display, capture, event posting or AX calls."""
import copy
import importlib.util
import json
from pathlib import Path
import unittest
import uuid


spec = importlib.util.spec_from_file_location("native_focus", Path(__file__).with_name("native-focus-reference.py"))
focus = importlib.util.module_from_spec(spec)
spec.loader.exec_module(focus)


def example(route):
    count = 120 if route == "nearpane" else 20
    offset = 10 if route == "nearpane" else 200
    low = 25 if route == "nearpane" else 40
    rows = []
    for i in range(count):
        t = offset+i
        rows.append(dict(id=str(uuid.uuid5(uuid.NAMESPACE_URL,route+str(i))),ordinal=i+1,status="OBSERVED",targetSlot=i%2,
                         down=[t,t+.001],end=t+.25,presentedDocument=[low,low+2],deliveredEditorInput=[low+60,low+62],
                         markerOfferAfterUpMs=55,mouseHoldMs=45,markerKeyCount=12))
    return {"route":route,"source":"a"*40,"attempted":count,"trials":rows,"inputPolicy":55,"unmatchedClicks":0,
            "sceneStatus":"OBSERVED","checksummedLedger":"c"*64,"environment":{
                "boot":str(uuid.NAMESPACE_DNS),"osBuild":"26A428","display":str(uuid.NAMESPACE_OID),
                "bounds":[0,0,1200,800],"modePixels":[2400,1600],"refreshHz":60,"reduceMotion":False,"stageManager":False,
                "fixturePID":28,"fixtureBirth":71,"fixtureHash":"f"*40,"session":str(uuid.NAMESPACE_URL),
                "numbers":[41,42],"frames":[[5,10,190,170],[15,20,190,170]],"space":37,"spaceUUID":str(uuid.NAMESPACE_X500),
                "hostPID":15,"hostBirth":33,"hostHash":"b"*40,"otherOrdinaryAppWindows":0}}


class NativeFocusReferenceTests(unittest.TestCase):
    def test_actual_candidate_has_ten_physical_results_and_no_native_reference(self):
        run = focus.load_run(focus.PACKET,"nearpane")
        result = focus.compare(run,None)
        self.assertEqual((result["status"],result["nearpane"]["observed"]),("NOT_RUN",10))
        self.assertIsNone(result["strictParity"])
        self.assertIsNone(result["contractInputP95"])
        self.assertIn("nearpaneMissingScene",result["reasons"])
        self.assertGreater(result["nearpane"]["sampleOnly"]["deliveredEditorInput"]["p95"][0],800)
        self.assertEqual(sum(r["status"] == "OBSERVED" for r in focus.load_run(focus.PACKET,"missionControl")["trials"]),0)

    def test_all_endpoints_directions_and_bounds_must_agree(self):
        p,n = example("nearpane"),example("missionControl")
        self.assertEqual(focus.compare(p,n)["status"],"PASS")
        p["trials"][-1]["presentedDocument"] = [47,48]
        decision = focus.compare(p,n)
        self.assertEqual(decision["status"],"FAIL")
        self.assertEqual(decision["strictParity"]["presentedDocument/both"]["outcomes"]["p95"],"PASS")
        self.assertEqual(decision["strictParity"]["presentedDocument/both"]["outcomes"]["p100"],"FAIL")
        self.assertEqual(decision["contractInputP95"],"PASS")
        p["trials"][-1]["presentedDocument"] = [39,43]
        self.assertEqual(focus.compare(p,n)["status"],"UNKNOWN")

    def test_a_slower_input_tail_or_single_direction_is_preserved(self):
        p,n = example("nearpane"),example("missionControl")
        for row in p["trials"][-12:]:
            if row["targetSlot"] == 1:
                row["deliveredEditorInput"] = [105,107]
        result = focus.compare(p,n)
        self.assertEqual(result["strictParity"]["deliveredEditorInput/1"]["outcomes"]["p95"],"FAIL")
        self.assertEqual(result["strictParity"]["deliveredEditorInput/0"]["outcomes"]["p95"],"PASS")
        self.assertEqual(result["contractInputP95"],"PASS")
        self.assertEqual(result["status"],"FAIL")

    def test_fixed_warmup_excluded_but_every_attempt_must_be_present(self):
        p,n = example("nearpane"),example("missionControl")
        p["trials"][0]["presentedDocument"] = [400,401]
        self.assertEqual(focus.compare(p,n)["status"],"PASS")
        for change in ("unknown","missing","extra"):
            incomplete = copy.deepcopy(p)
            if change == "unknown": incomplete["trials"][0]["status"] = "UNKNOWN"
            elif change == "missing": incomplete["trials"].pop()
            else: incomplete["unmatchedClicks"] = 1
            self.assertEqual(focus.compare(incomplete,n)["status"],"UNKNOWN")

    def test_display_space_workload_motion_and_marker_offer_must_match(self):
        p,n = example("nearpane"),example("missionControl")
        for key,value in {"boot":str(uuid.uuid4()),"display":str(uuid.uuid4()),"spaceUUID":str(uuid.uuid4()),
                          "refreshHz":120,"reduceMotion":True,"hostBirth":44,"fixtureHash":"1"*40,
                          "frames":[[6,10,190,170],[15,20,190,170]]}.items():
            other = copy.deepcopy(n); other["environment"][key] = value
            self.assertEqual(focus.compare(p,other)["status"],"UNKNOWN",key)
        for key in ("refreshHz","boot","frames"):
            a,b = copy.deepcopy(p),copy.deepcopy(n)
            del a["environment"][key]; del b["environment"][key]
            self.assertEqual(focus.compare(a,b)["status"],"UNKNOWN",key)
        n["trials"][0]["markerOfferAfterUpMs"] = 300
        self.assertIn("observedMarkerOfferScheduleChanged",focus.compare(p,n)["reasons"])

    def test_overlapping_replayed_or_different_target_orders_are_ineligible(self):
        p,n = example("nearpane"),example("missionControl")
        for change in ("sameID","overlap","target","reverse"):
            other = copy.deepcopy(n)
            if change == "sameID": other["trials"][0]["id"] = p["trials"][0]["id"]
            elif change == "overlap": other["trials"][1]["down"] = other["trials"][0]["down"]
            elif change == "reverse":
                for row in other["trials"]: row["targetSlot"] = 1-row["targetSlot"]
            else: other["trials"][1]["targetSlot"] = other["trials"][0]["targetSlot"]
            self.assertEqual(focus.compare(p,other)["status"],"UNKNOWN",change)

    def test_long_press_or_larger_injected_workload_does_not_compete_with_a_click(self):
        p,n = example("nearpane"),example("missionControl")
        for field,value in (("mouseHoldMs",300),("markerKeyCount",6)):
            other = copy.deepcopy(n); other["trials"][0][field] = value
            self.assertIn("clickDurationOrKeyboardWorkloadChanged",focus.compare(p,other)["reasons"])

    def test_only_routed_system_events_for_both_exact_links_can_qualify(self):
        pdir = focus.PACKET
        run = json.loads((pdir/"pair-pointer.json").read_text())
        raw = next(r["proof"] for r in map(json.loads,(pdir/"actions.jsonl").read_text().splitlines())
                   if r["event"] == "pair-pointer-system-proof")
        original = run["attempts"][0]; target = original["target"]
        numbers = json.loads((pdir/"window-presentation-01.json").read_text())["fixtureWindows"]
        down,up = [[e["beforePost"],e["afterPost"]] for e in raw["events"]]
        # Synthetic enrollment proves the classifier's schema, never enters the real packet.
        owner = {"bundle":"com.apple.dock","birth":123,"pid":41,"cdHash":"5"*40}
        linked = [run["registration"]["pid"],run["registration"]["birth"],target]
        point = raw["events"][0]["point"]
        before = {"status":"LINKS_OBSERVED","issued":False,"retainedPixelBytes":0,"interval":[down[0]-0.3,down[0]-0.2],
                  "spaceUUID":run["scope"]["spaceUUID"],"owner":owner,"fixturePID":linked[0],"fixtureBirth":linked[1],
                  "targets":[{"number":n,"rect":[point[0]-5 if n == target else 10,point[1]-5,10,10]} for n in numbers],
                  "observations":[{"firstLinks":1,"secondLinks":1}]*2}
        raw["systemRouting"] = {"status":"OBSERVED","owner":owner,
            "events":[{**e,"acceptingPointer":"boundNativeButton","underPointer":"boundNativeButton","linkedFixture":linked}
                      for e in raw["hostRouting"]["events"]]}
        focus.admitted_click("missionControl",raw,original,run["scope"],numbers,target,down,up,before)
        raw["systemRouting"]["events"][1]["linkedFixture"] = [linked[0],linked[1],original["sibling"]]
        with self.assertRaisesRegex(ValueError,"nativeFixtureButtonNotBound"):
            focus.admitted_click("missionControl",raw,original,run["scope"],numbers,target,down,up,before)

    def test_quartz_raise_or_private_window_frames_cannot_replace_the_display_clock(self):
        v = json.loads((focus.PACKET/"window-presentation-01.json").read_text())
        for change in ("slot","synthetic","wrongWindow","wrongClock","missingInput","otherFront"):
            altered = copy.deepcopy(v)
            if change == "slot": altered["targetSlot"] = 1-altered["targetSlot"]
            elif change == "synthetic": altered["evidenceKind"] = "AXFocused"
            elif change == "wrongClock": altered["firstTargetPresentationMachTicks"] += 1
            elif change == "wrongWindow": altered["fixtureWindows"][0] += 4
            elif change == "missingInput": altered["clickDownUptime"] = None
            else: altered["frames"][-1]["stackAfter"][2] = None
            with self.assertRaises(ValueError):
                focus.first_frame(altered,v["fixtureWindows"],v["spaceUUID"],v["fixtureWindows"][v["targetSlot"]],
                                  v["clickDownUptime"],v["clickUpUptime"])


if __name__ == "__main__":
    unittest.main()
