import copy
import unittest
from evaluate import ENGINE_CHECKS, evaluate


class EvidenceTests(unittest.TestCase):
    def setUp(self):
        self.engine = {"status": "FOREIGN_ENGINE_PASS", "cleanup": True, "foreignProcesses": True, "windowWrites": 12,
                       "targetEnvironment": {"kernelBuild": "26A428", "sipEnabled": True, "exactTarget": True},
                       "checks": {name: {"status": "PASS"} for name in ENGINE_CHECKS}}

    def test_own_window_and_no_dispatch_never_become_foreign(self):
        for key, value in (("status", "OWN_FIXTURE_PASS"), ("foreignProcesses", False), ("windowWrites", 0)):
            record = dict(self.engine, **{key: value})
            self.assertNotEqual(evaluate(record)["engine"], "PASS")

    def test_runner_os_and_sip_do_not_substitute_for_exact_target(self):
        for patch in ({"kernelBuild": "25G332"}, {"sipEnabled": False}, {"exactTarget": False}):
            record = copy.deepcopy(self.engine)
            record["targetEnvironment"].update(patch)
            result = evaluate(record)
            self.assertEqual(result["engine"], "PASS")
            self.assertEqual(result["exactTargetEngine"], "NOT_PROVEN")

    def test_cleanup_and_each_window_observation_are_required(self):
        for key in ENGINE_CHECKS:
            record = copy.deepcopy(self.engine)
            record["checks"][key] = {"status": "NOT_RUN"}
            self.assertNotEqual(evaluate(record)["engine"], "PASS")
        self.assertNotEqual(evaluate(dict(self.engine, cleanup=False))["engine"], "PASS")

    def test_compilation_or_engine_success_cannot_prove_r4(self):
        result = evaluate(self.engine, {"status": "PRODUCT_R4_PASS", "cleanup": True, "actualR4Inputs": 0,
                                        "foreignWindowReadback": True})
        self.assertEqual(result["engine"], "PASS")
        self.assertNotEqual(result["R4ProductPath"], "PASS")
        self.assertEqual(result["overall"], "INCOMPLETE")

    def test_whole_product_requires_the_system_interaction_receipts(self):
        product = {"status": "PRODUCT_R4_PASS", "cleanup": True, "actualR4Inputs": 3, "foreignWindowReadback": True}
        self.assertEqual(evaluate(self.engine, product)["overall"], "INCOMPLETE")
        product.update(missionControl="PASS", desktopGestures="PASS", fullScreenSplitView="PASS")
        self.assertEqual(evaluate(self.engine, product)["overall"], "PASS")
        self.assertFalse(evaluate(self.engine, product)["qualificationGranted"])


if __name__ == "__main__":
    unittest.main()
