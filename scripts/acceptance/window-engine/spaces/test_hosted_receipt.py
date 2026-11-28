import importlib.util
from pathlib import Path
import unittest
from types import SimpleNamespace

spec = importlib.util.spec_from_file_location("hosted_spaces", Path(__file__).with_name("run-hosted.py"))
hosted = importlib.util.module_from_spec(spec)
spec.loader.exec_module(hosted)


class HostedReceipt(unittest.TestCase):
    def test_linker_stderr_persists_symbol_exit_and_normalizes_build_path(self):
        result = SimpleNamespace(returncode=1, stderr="Undefined _IsSecureEventInputEnabled in /Users/test/private/CORNER.o\n")
        receipt = hosted.build_receipt(result, ["/Users/test/private"])
        self.assertEqual(receipt["exit"],1)
        self.assertIn("_IsSecureEventInputEnabled",receipt["stderr"])
        self.assertNotIn("/Users/test",receipt["stderr"])

    def sample(self, **changes):
        end = dict(status="OWN_FIXTURE_PASS", originalMembershipAndCleanup=True, originalSpaceSetRestored=True)
        end.update(changes)
        return [dict(event="targetPreflight", exactTarget=False, sipEnabled=True, kernelBuild="comparison"), end]

    def test_comparison_result_retains_actual_system(self):
        route = hosted.received(self.sample(), 0)
        self.assertTrue(hosted.completed({"classic": route}, ["classic"]))
        self.assertFalse(route["target"]["exactTarget"])
        self.assertEqual(route["target"]["kernelBuild"], "comparison")

    def test_requested_routes_must_all_complete(self):
        route = hosted.received(self.sample(), 0)
        self.assertFalse(hosted.completed({"bridged": route}, ["bridged", "classic"]))
        self.assertTrue(hosted.completed({"bridged": route, "classic": route}, ["bridged", "classic"]))

    def test_nonzero_exit_and_incomplete_cleanup_refuse_success(self):
        for rows, code in [(self.sample(), 2), (self.sample(), None), (self.sample(originalMembershipAndCleanup=False), 0),
                           (self.sample(originalSpaceSetRestored=False), 0), ([], 0)]:
            route = hosted.received(rows, code)
            self.assertFalse(hosted.completed({"classic": route}, ["classic"]))

    def test_unsupported_or_unmeasured_readback_retains_cause(self):
        route = hosted.received([dict(status="BLOCKED", reason="existingAccessibilityUnavailable")], 2)
        self.assertEqual((route["status"], route["reason"], route["receipts"]),
                         ("BLOCKED", "existingAccessibilityUnavailable", 0))

if __name__ == "__main__":
    unittest.main()
