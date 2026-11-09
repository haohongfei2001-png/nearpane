import importlib.util
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location("study", Path(__file__).with_name("replay-parking-study.py"))
study = importlib.util.module_from_spec(spec)
spec.loader.exec_module(study)


def sample(t):
    return dict(event="sample", uptime=t, frontPID=10, baselinePID=10, axWindowReadable=True,
                sameAXFocusedWindow=True, active=False, windows=[dict(number=1, key=False, main=False, responder="mock")])


class FocusTests(unittest.TestCase):
    def test_valid(self):
        self.assertAlmostEqual(study.verify_focus([sample(1), sample(1.1)], 10), .1)

    def test_missing_or_changed_external_focus(self):
        for fields in [dict(frontPID=11), dict(axWindowReadable=False), dict(sameAXFocusedWindow=False)]:
            with self.subTest(fields=fields), self.assertRaises(ValueError):
                study.verify_focus([sample(1), dict(sample(1.1), **fields)], 10)

    def test_target_window_or_responder_changed(self):
        for fields in [dict(key=True), dict(main=True), dict(responder="changed")]:
            end = sample(1.1)
            end["windows"][0].update(fields)
            with self.subTest(fields=fields), self.assertRaises(ValueError):
                study.verify_focus([sample(1), end], 10)

    def test_event_and_sampling_gap(self):
        for end in [sample(2), sample(.9), dict(sample(1.1), event="NSApplicationDidBecomeActiveNotification")]:
            with self.subTest(end=end), self.assertRaises(ValueError):
                study.verify_focus([sample(1), end], 10)


if __name__ == "__main__":
    unittest.main()
