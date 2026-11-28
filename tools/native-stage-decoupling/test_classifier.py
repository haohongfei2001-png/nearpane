"""Evidence classification guards: these prevent false claims of native separation."""
import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock, patch

spec = importlib.util.spec_from_file_location("route_a_lab", Path(__file__).with_name("run.py"))
lab = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lab)


def sample():
    return {"nativeEnabled": True, "displays": [{"bounds": [0, 0, 1440, 900]}],
            "managers": [{"ax": {"complete": True, "strips": [{"items": [
                {"frame": [2, 200, 160, 100], "windows": [42]}]}]}}],
            "windows": [{"id": 42, "onscreen": True, "alpha": 1,
                         "bounds": [2, 200, 160, 100]}]}


class EvidenceTests(unittest.TestCase):
    def test_ax_and_compositor_confirm_native_strip(self):
        self.assertEqual(lab.classify([sample()])["status"], "REJECTED_RENDERER_SEPARATION")

    def test_ax_empty_and_inaccessible_are_never_a_pass(self):
        for managers in ([], [{"ax": {"complete": False, "strips": []}}]):
            s = sample()
            s["managers"] = managers
            self.assertEqual(lab.classify([s])["status"], "INCONCLUSIVE")

    def test_logical_ax_frame_is_not_proof_of_rendering(self):
        s = sample()
        s["windows"][0]["onscreen"] = False
        self.assertEqual(lab.classify([s])["status"], "INCONCLUSIVE")

    def test_full_size_live_window_does_not_count_as_thumbnail(self):
        s = sample()
        s["windows"][0]["bounds"] = [150, 200, 900, 600]
        self.assertEqual(lab.classify([s])["status"], "INCONCLUSIVE")

    def test_offscreen_native_surface_does_not_count_as_rendered(self):
        s = sample()
        s["windows"][0]["bounds"] = [-200, 200, 160, 100]
        self.assertEqual(lab.classify([s])["status"], "INCONCLUSIVE")

    def test_native_disabled_cannot_qualify_route_a(self):
        s = sample()
        s["nativeEnabled"] = False
        self.assertEqual(lab.classify([s])["status"], "NOT_RUN")

    def test_fixture_cleanup_failure_does_not_skip_preference_or_pointer_restore(self):
        with tempfile.TemporaryDirectory() as directory:
            subject = Mock(output=Path(directory))
            subject.cleanup_fixtures.side_effect = OSError("fixture stop failed")
            subject.probe.side_effect = lambda operation, *args: {"GloballyEnabled": None} if operation == "preferences" else {}
            with patch.object(lab.time, "sleep"):
                result = lab.restore_environment(subject, {"GloballyEnabled": None}, {"GloballyEnabled": True},
                                                 {"pointer": [4, 8], "frontPID": 0})
            self.assertEqual(result["status"], "RESTORE_INCOMPLETE")
            self.assertTrue(any("fixture stop failed" in error for error in result["errors"]))
            subject.preferences.assert_called_once_with({"GloballyEnabled": None}, "preferences-restoring.json")
            subject.probe.assert_any_call("move-pointer", 4, 8)
            subject.probe.assert_any_call("snapshot")
            self.assertTrue((Path(directory) / "restore-result.json").exists())

    def test_preference_failure_still_restores_pointer_and_does_not_activate_reused_pid(self):
        with tempfile.TemporaryDirectory() as directory:
            subject = Mock(output=Path(directory))
            subject.cleanup_fixtures.return_value = {"allExited": True}
            subject.preferences.side_effect = OSError("preference restore failed")
            subject.probe.side_effect = lambda operation, *args: {"birth": 99} if operation == "process" else {}
            with patch.object(lab.time, "sleep"):
                result = lab.restore_environment(subject, {"AutoHide": None}, {"AutoHide": True},
                                                 {"pointer": [3, 7], "frontPID": 123, "frontBirth": 42})
            self.assertEqual(result["status"], "RESTORE_INCOMPLETE")
            self.assertTrue(any("preference restore failed" in error for error in result["errors"]))
            subject.probe.assert_any_call("move-pointer", 3, 7)
            subject.probe.assert_any_call("snapshot")
            self.assertFalse(any(call.args[0] == "activate" for call in subject.probe.call_args_list))


if __name__ == "__main__":
    unittest.main()
