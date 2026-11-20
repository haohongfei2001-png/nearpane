"""Compile and replay the display observer's numeric evidence without capturing a screen."""
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

HERE = Path(__file__).resolve().parent


class PointerVisualReplay(unittest.TestCase):
    def test_synthetic_frames_and_physical_ordering(self):
        with tempfile.TemporaryDirectory() as output:
            tool = Path(output) / "pair-visual-replay"
            sources = ["screen-presentation-clock.swift", "pair-pointer-palette.swift",
                       "pair-pointer-visual.swift", "pair-pointer-visual-checks.swift"]
            subprocess.run(["xcrun", "swiftc", "-D", "PAIR_VISUAL_REPLAY", "-parse-as-library",
                            *(str(HERE / name) for name in sources), "-o", str(tool)], check=True)
            result = json.loads(subprocess.check_output([tool]))
            self.assertEqual(result["status"], "PASS")
            self.assertGreaterEqual(len(result["checks"]), 60)
            self.assertTrue({
                "foreignOrdinaryInFrontDisjointAccepted",
                "opaqueDocumentHidesIntersectingAndUnknownBackground",
                "partialForegroundCoverageRefused",
                "unknownForegroundBoundsRefused",
                "missingEnrolledOwnerBehindOpaqueRefused",
                "overlayMovesInFrontOfKnownSurfaceRefused",
                "realBufferScaleAndCleanAperture",
                "terminalStackCannotSubstituteForWrongPicture",
                "broadOrderedBracketRetainsItsUncertainty",
            }.issubset(result["checks"]))


if __name__ == "__main__":
    unittest.main()
