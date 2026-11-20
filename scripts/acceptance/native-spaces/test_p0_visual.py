"""Headless tests for timing, privacy admission and conservative P0 visual verdicts."""
import copy
import json
import os
import subprocess
import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("p0visual", Path(__file__).with_name("p0-visual.py"))
visual = importlib.util.module_from_spec(spec)
spec.loader.exec_module(visual)


class VisualTests(unittest.TestCase):
    def setUp(self):
        self.request = {"topology": {"current": 4}, "target": 5}
        self.pre = {"current": 4, "windows": [42, 43], "uptime": 9.97}
        self.post = {"current": 5, "windows": [42, 43], "uptime": 10.15}
        self.frames = []
        for n in range(13):
            t = 10 + n*.01
            source = n < 5
            self.frames.append(dict(displayTime=t, callback=t+.003, status=0, space=4 if source else 5, safe=True, lit=True,
                                    visible="source" if source else "target", matchesSource=source, matchesTarget=not source))
        self.data = dict(frames=[], ready=True, width=192, height=108, postSpace=5, refreshLimitHz=60, displayModeHz=60,
                         physical=dict(armed=True, sourceFrameReadyBeforePress=True, censusAfter=True, filter="display-excluding-other-apps", frames=self.frames))
    def result(self, data=None, press=10.013, end=10.106):
        return visual.score(self.data if data is None else data, self.request, press, end, self.pre, self.post)
    def test_keeper_checks_both_windows_and_witness_still_checks_input_and_topology(self):
        kit = Path("/private/tmp/fake-kit")
        source = dict(pid=7, birth=11, number=17, identifier="net.example.spaces-route-witness",
                      executable=str(kit/"Route Notes.app/Contents/MacOS/FieldNotes"), hash="a")
        target = dict(pid=9, birth=12, number=19, identifier="net.example.spaces-document",
                      executable=str(kit/"Field Notes.app/Contents/MacOS/FieldNotes"), hash="b")
        topology = dict(current=4, display="FFFFFFFF-9999-4444-8888-000000000001", records=[{"id":4},{"id":5}])
        p = dict(topology=topology, sourceWindow=source, targetWindow=target, target=5, hid=10)
        state = dict(topology=topology, hid=10, uptime=123)
        def keeper(windows):
            self.assertEqual(windows, [source, target])
            return {"windows": [dict(w, forward=True, standard=True, reverse=[n]) for w, n in zip(windows, [4,5])]}
        with patch.object(visual, "kit_paths", return_value=(kit, kit/"reader")), patch.object(visual, "ask", return_value=state) as read:
            self.assertEqual(visual.witness(kit, p, 4, keeper)["current"], 4)
            read.assert_called_once_with(kit/"reader", "state")
            state["hid"] = 11
            with self.assertRaises(ValueError):
                visual.witness(kit, p, 4, keeper)
            with self.assertRaises(ValueError):
                visual.witness(kit, p, 4, lambda _: {"windows":[]})

    def test_contiguous_visible_display_marker_and_exact_landing(self):
        proof = self.result()
        self.assertEqual(proof["status"], "PASS")
        self.assertAlmostEqual(proof["coverage"]["maxGapMS"], 10)
        self.frames[7].update(status=1)
        self.assertEqual(self.result()["status"], "PASS")
    def test_async_crops_neither_introduce_nor_bridge_presentation_gaps(self):
        aux=dict(origin="guarded-current-display-crop",safe=False,**{"from":10.019,"to":10.095})
        self.frames.insert(3,aux)
        proof=self.result()
        self.assertEqual(proof["status"],"PASS")
        self.assertAlmostEqual(proof["coverage"]["maxGapMS"],10)
        supplement=proof["displayProbe"]["auxiliaryRequests"][0]
        self.assertEqual(supplement["nativePresentationsInsideRequest"],8)
        self.assertFalse(supplement["usedForCoverage"])
        self.frames[:]=[r for r in self.frames if r==aux or not 10.025<r["displayTime"]<10.085]
        proof=self.result()
        self.assertEqual(proof["status"],"UNKNOWN")
        self.assertTrue(proof["coverage"]["uncoveredIntervals"])
        self.frames[:]=[aux]
        self.assertEqual(self.result()["status"],"UNKNOWN")

    def test_native_early_callback_requires_unchanged_ownership_after_presentation(self):
        self.frames[7]["callback"]-=.008
        proof=self.result()
        self.assertEqual(proof["coverage"]["earlyEventsWithFollowingProof"],1)
        self.assertEqual(proof["status"],"PASS")
        for change in (dict(visible="source"),dict(safe=False),dict(callback=11.0),dict(space=4)):
            data=copy.deepcopy(self.data);data["physical"]["frames"][8].update(change)
            self.assertEqual(self.result(data)["status"],"UNKNOWN")
        self.frames[7]["callback"]-=.020
        self.assertEqual(self.result()["status"],"UNKNOWN")

    def test_native_blank_survives_overlapping_static_reads(self):
        at=self.frames[7]["displayTime"]
        self.frames[7]["status"]=2
        self.frames.insert(7,{"origin":"guarded-current-display-crop","safe":True,"from":at-.02,"to":at+.02})
        proof=self.result()
        self.assertEqual(proof["status"],"FAIL")
        self.assertEqual(proof["subchecks"]["scopedNativeBlankEventsDuringPress"],1)
        self.frames[8]["safe"]=False
        self.assertEqual(self.result()["status"],"UNKNOWN")

    def test_target_in_same_stream_and_independent_current_target_must_both_match(self):
        terminal=dict(eligible=True,sameStream=True,freshFramesAgreeWithEnrolledCrop=True,shareableTargetOnScreen=True,
                      independentTargetAndDisplayAgree=True,linkedToNativeTarget=True,nativeTargetTime=self.frames[12]["displayTime"],
                      sampleRequested=10.112,sampleReturned=10.115)
        self.data["physical"].update(presentationReviewVersion=2,terminalTarget=terminal)
        proof=self.result()
        self.assertTrue(proof["subchecks"]["streamingTargetMatched"])
        self.assertTrue(proof["subchecks"]["independentTerminalTargetMatched"])
        self.assertEqual(proof["status"],"PASS")
        # A matching post-stop screenshot cannot replace the continuous stream's colored destination.
        for r in self.frames:r["matchesTarget"]=False
        proof=self.result()
        self.assertEqual(proof["status"],"UNKNOWN")
        self.assertEqual(proof["subchecks"]["continuousVisibleLight"],"PASS")
        self.assertFalse(proof["subchecks"]["streamingTargetMatched"])
        for r in self.frames:r["matchesTarget"]=r["visible"]=="target"
        for patch in ({"independentTargetAndDisplayAgree":False},{"eligible":False},{"linkedToNativeTarget":False},{"sampleReturned":10.123},{"nativeTargetTime":10.119}):
            data=copy.deepcopy(self.data);data["physical"]["terminalTarget"].update(patch)
            self.assertEqual(self.result(data)["status"],"UNKNOWN")
        self.frames[12]["safe"]=False
        self.assertEqual(self.result()["status"],"UNKNOWN")

    @unittest.skipUnless(os.environ.get("NEARPANE_P0_ARCHIVED_PRESENTATIONS"),"requires the separately archived installed display-pair/ten-01 receipts")
    def test_preserved_real_windowserver_presentation_replay(self):
        attempt=Path(os.environ["NEARPANE_P0_ARCHIVED_PRESENTATIONS"]).resolve()
        with tempfile.TemporaryDirectory() as temp:
            dest=Path(temp).resolve()/"review.json"
            review=visual.replay(attempt,dest);result=review["review"]
            self.assertEqual(review["originalVisual"]["status"],"UNKNOWN")
            self.assertEqual((review["originalNavigation"],result["status"]),("PASS","UNKNOWN"))
            self.assertEqual(result["subchecks"]["continuousVisibleLight"],"PASS")
            self.assertFalse(result["subchecks"]["streamingTargetMatched"])
            self.assertEqual(result["coverage"]["samples"],167)
            self.assertAlmostEqual(result["coverage"]["maxGapMS"],33.334125,places=5)
            self.assertEqual(result["displayProbe"]["targetCompleteColorCounts"]["matchingNeither"],17)
            self.assertEqual(result["displayProbe"]["auxiliaryRequestCount"],13)
            self.assertEqual(result["coverage"]["uncoveredIntervals"],[])
            with self.assertRaises(FileExistsError):visual.replay(attempt,dest)
            with self.assertRaises(ValueError):visual.replay(attempt,attempt/"result.json")

    def test_filtered_window_video_or_displays_without_isolation_are_unknown(self):
        for change in (dict(armed=False), dict(censusAfter=False), dict(error=True), dict(filter="windowGroup")):
            trial = copy.deepcopy(self.data)
            trial["physical"].update(change)
            self.assertEqual(self.result(trial)["status"], "UNKNOWN")
    def test_a_dark_crop_cannot_claim_black_display(self):
        self.frames[7].update(lit=False)
        self.assertEqual(self.result()["status"], "UNKNOWN")
        self.frames[7].update(status=2)
        self.assertEqual(self.result()["status"], "FAIL")
    def test_private_occluder_unavailable_metadata_and_missed_presentation(self):
        for diff in (dict(safe=False), dict(displayTime=None), dict(callback=11.0), dict(status=3)):
            trial = copy.deepcopy(self.data)
            trial["physical"]["frames"][7].update(diff)
            self.assertEqual(self.result(trial)["status"], "UNKNOWN")
        trial = copy.deepcopy(self.data)
        del trial["physical"]["frames"][3:9]
        self.assertEqual(self.result(trial)["status"], "UNKNOWN")
    def test_recycled_owners_and_unknown_target_are_never_pass(self):
        self.data["changed"] = True
        self.assertEqual(self.result()["status"], "UNKNOWN")
        self.data["changed"] = False
        for f in self.frames:
            f["matchesTarget"] = False
        self.assertEqual(self.result()["status"], "UNKNOWN")
        for f in self.frames:
            f.update(matchesTarget=True, visible="appleWallpaper")
        self.assertEqual(self.result()["status"], "UNKNOWN")
    def test_refused_press_and_unobserved_end_never_pass(self):
        self.assertEqual(self.result(press=0,end=0)["status"], "UNKNOWN")
        self.assertEqual(self.result(end=10.128)["status"], "UNKNOWN")
    def test_foreign_paths_and_symlinks_refused_before_io(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp).resolve()
            (path/"owned").write_text("fixture")
            (path/"alias").symlink_to(path/"owned")
            with self.assertRaises(ValueError):
                visual.read(path/"alias")
            with self.assertRaises(ValueError):
                visual.kit_paths(path)
    def test_diagnostics_survive_the_temporary_enrollment_and_must_match_the_attempt(self):
        with tempfile.TemporaryDirectory() as tmp:
            attempt=Path(tmp).resolve();work=attempt/"calibration";work.mkdir()
            data=dict(nonce="one",sourceSpace=4,targetSpace=5,failed=["wallpaper outside sealed system directories"])
            visual.write(work/"admission.json",data)
            self.assertEqual(visual.enrollment_admission(work,attempt,self.request,"one"),data)
            self.assertEqual(visual.read(attempt/"visual-calibration.json"),data)
            with self.assertRaises(ValueError):visual.enrollment_admission(work,attempt,self.request,"two")
    def test_actual_physical_source_readiness_is_required_despite_a_ready_movie(self):
        self.data["physical"]["sourceFrameReadyBeforePress"]=False
        self.assertEqual(self.result()["status"],"UNKNOWN")
        self.data["physical"]["admission"]={"failed":["missing endpoint calibration"]}
        self.assertEqual(self.result()["reason"],"missing endpoint calibration")
    @unittest.skipUnless(os.environ.get("NEARPANE_P0_VISUAL_BINARY"),"requires the compiled macOS metadata reader")
    def test_private_asset_and_nonimage_never_enter_the_receipt(self):
        executable=os.environ["NEARPANE_P0_VISUAL_BINARY"]
        with tempfile.TemporaryDirectory() as tmp:
            personal=Path(tmp)/"private-image-sentinel.heic";personal.touch()
            run=subprocess.run([executable,"--test-wallpaper-file",str(personal)],text=True,capture_output=True,check=True)
            self.assertFalse(json.loads(run.stdout)["qualified"])
            self.assertNotIn(personal.name,run.stdout);self.assertNotIn(str(personal.parent),run.stdout)
        live=json.loads(subprocess.check_output([executable,"--wallpaper-metadata"],text=True))["screens"]
        for screen in live:
            if screen["qualified"]:
                self.assertIn(screen["source"],["systemDesktopPictures","systemWallpapers"])
                self.assertTrue(all(screen[key] for key in ("rootOwned","regularFile","sameSystemVolume","readOnlyVolume","recognizedImage")))
    def test_endpoint_binding_survives_reverse_and_refuses_reassigned_windows(self):
        p = dict(topology={"current": 4, "display": "test", "records": [4,5]}, target=5,
                 sourceWindow=dict(pid=7, birth=10, number=20, identifier="a", hash="one"),
                 targetWindow=dict(pid=8, birth=11, number=21, identifier="b", hash="two"))
        reverse = dict(p, topology=dict(p["topology"], current=5), target=4,
                       sourceWindow=p["targetWindow"].copy(), targetWindow=p["sourceWindow"].copy())
        self.assertEqual(visual.pair_id(p), visual.pair_id(reverse))
        reverse["sourceWindow"]["birth"] += 1
        self.assertNotEqual(visual.pair_id(p), visual.pair_id(reverse))


if __name__ == "__main__":
    unittest.main()
