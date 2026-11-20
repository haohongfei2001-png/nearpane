"""Headless tests for timing, privacy admission and conservative P0 visual verdicts."""
import copy
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
                         physical=dict(armed=True, censusAfter=True, filter="display-excluding-other-apps", frames=self.frames))
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
    def test_guarded_static_crops_keep_acquisition_uncertainty_in_the_gap_budget(self):
        for r in self.frames:
            r.update(origin="guarded-current-display-crop", **{"from": r["displayTime"]-.002, "to": r["displayTime"]+.002})
        result = self.result()
        self.assertEqual(result["status"], "PASS")
        self.assertAlmostEqual(result["coverage"]["maxGapMS"], 14)
        self.frames[5]["to"] += .060
        self.assertEqual(self.result()["status"], "UNKNOWN")

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
