import subprocess
import tempfile
import unittest
from pathlib import Path


class WindowSwitchPixels(unittest.TestCase):
    def test_only_a_continuous_attributed_transition_passes(self):
        here = Path(__file__).resolve().parent
        with tempfile.TemporaryDirectory() as folder:
            replay = Path(folder) / "motion-replay"
            subprocess.run(["xcrun", "swiftc", "-parse-as-library", here / "pair-switch-pixels.swift",
                            here / "test-pair-switch-pixels.swift", "-o", replay], check=True)
            self.assertEqual(subprocess.check_output([replay], text=True).strip(), "PASS")
