import copy
import unittest
from evaluate import ENGINE_CHECKS, LIFECYCLE_CHECKS, SYSTEM_CHECKS, attach_lifecycle, evaluate


class EvidenceTests(unittest.TestCase):
    def setUp(self):
        self.engine = {"status": "FOREIGN_ENGINE_PASS", "cleanup": True, "foreignProcesses": True, "windowWrites": 12,
                       "targetEnvironment": {"kernelBuild": "26A428", "sipEnabled": True, "exactTarget": True},
                       "checks": {name: {"status": "PASS"} for name in ENGINE_CHECKS}}

    def test_own_window_and_no_dispatch_never_become_foreign(self):
        for key, value in (("status", "OWN_FIXTURE_PASS"), ("foreignProcesses", False), ("foreignProcesses", 1), ("windowWrites", 0)):
            record = dict(self.engine, **{key: value})
            self.assertNotEqual(evaluate(record)["engine"], "PASS")

    def test_runner_os_and_sip_do_not_substitute_for_exact_target(self):
        for patch in ({"kernelBuild": "25G332"}, {"sipEnabled": False}, {"exactTarget": False},
                      {"sipEnabled": 1}, {"exactTarget": 1}):
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
        product.update({key: "PASS" for key in SYSTEM_CHECKS})
        self.assertEqual(evaluate(self.engine, product)["overall"], "PASS")
        for key in SYSTEM_CHECKS:
            for unconfirmed in ("FAIL", "BLOCKED", "NOT_RUN", "UNKNOWN"):
                self.assertEqual(evaluate(self.engine, dict(product, **{key: unconfirmed}))["overall"], "INCOMPLETE")
        self.assertFalse(evaluate(self.engine, product)["qualificationGranted"])

    def test_platform_foreign_roundtrip_cannot_promote_the_engine_or_product(self):
        platform = {"status": "PLATFORM_FOREIGN_PASS", "scope": "platform-only-mechanism",
                    "cleanup": True, "foreignProcesses": True, "completedForeignCycles": 2,
                    "windowWrites": 4, "createdSpace": 20, "numericHome": 1, "qualificationGranted": False,
                    "engineStateMachine": "NOT_RUN", "R4ProductPath": "NOT_RUN"}
        result = evaluate({"status": "BLOCKED"}, platform_diagnostic=platform)
        self.assertEqual(result["platformForeignMechanism"], "PASS")
        self.assertEqual(result["engine"], "BLOCKED")
        self.assertEqual(result["R4ProductPath"], "NOT_RUN")
        self.assertEqual(result["exactTargetEngine"], "NOT_PROVEN")
        self.assertEqual(result["overall"], "INCOMPLETE")
        self.assertFalse(result["qualificationGranted"])
        for key, value in (("cleanup", False), ("foreignProcesses", 1), ("completedForeignCycles", 1),
                           ("windowWrites", 0), ("engineStateMachine", "PASS")):
            malformed = dict(platform, **{key: value})
            self.assertEqual(evaluate({"status": "BLOCKED"}, platform_diagnostic=malformed)["platformForeignMechanism"], "UNKNOWN")

    def test_later_card_success_does_not_replace_failed_automatic_creation(self):
        main = {"status": "PRODUCT_R4_PASS", "cleanup": True, "actualR4Inputs": 9, "foreignWindowReadback": True,
                **{key: "PASS" for key in SYSTEM_CHECKS if key not in LIFECYCLE_CHECKS}}
        later = {"purpose": "lifecycle", "status": "FAIL", "cleanup": True, "actualR4Inputs": 6,
                 "foreignWindowReadback": True, "newWindowLifecycle": "FAIL", "windowCloseLifecycle": "PASS",
                 "applicationExitLifecycle": "PASS", "lifecycleAutomaticArrival": "FAIL", "lifecycleNewCardSwitch": "PASS"}
        combined = attach_lifecycle(main, later, {"exit": 1})
        self.assertEqual(combined["actualR4Inputs"], 9)
        self.assertEqual(combined["newWindowLifecycle"], "FAIL")
        self.assertEqual(combined["windowCloseLifecycle"], "PASS")
        self.assertEqual(evaluate(self.engine, combined)["R4ProductPath"], "PASS")
        self.assertEqual(evaluate(self.engine, combined)["overall"], "INCOMPLETE")
        inconsistent = attach_lifecycle(main, dict(later, newWindowLifecycle="PASS"), {"exit": 1})
        self.assertEqual(inconsistent["newWindowLifecycle"], "UNKNOWN")

    def test_lifecycle_requires_terminal_cleanup_and_preserves_prior_r4_failure(self):
        later = {"purpose": "lifecycle", "status": "PRODUCT_LIFECYCLE_PASS", "cleanup": True,
                 "actualR4Inputs": 6, "foreignWindowReadback": True, "lifecycleAutomaticArrival": "PASS",
                 "lifecycleNewCardSwitch": "PASS", **{key: "PASS" for key in LIFECYCLE_CHECKS}}
        prior = {"status": "FAIL", "cleanup": True, "reason": "R4SwitchReadbackFailed", "hostCrashRecovery": "NOT_RUN"}
        combined = attach_lifecycle(prior, later, {"exit": 0})
        self.assertEqual(combined["status"], "FAIL")
        self.assertEqual(combined["reason"], prior["reason"])
        self.assertEqual(combined["hostCrashRecovery"], "NOT_RUN")
        self.assertEqual(evaluate(self.engine, combined)["R4ProductPath"], "FAIL")
        for receipt, process in ((dict(later, cleanup=False), {"exit": 0}), (later, {"exit": -9}), (later, {})):
            incomplete = attach_lifecycle(prior, receipt, process)
            self.assertTrue(all(incomplete[key] == "UNKNOWN" for key in LIFECYCLE_CHECKS))


if __name__ == "__main__":
    unittest.main()
