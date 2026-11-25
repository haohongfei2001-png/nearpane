"""Evidence classification guards: these prevent false claims of native separation."""
import importlib.util
from pathlib import Path
import unittest

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


if __name__ == "__main__":
    unittest.main()
