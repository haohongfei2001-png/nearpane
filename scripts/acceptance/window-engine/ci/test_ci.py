"""Offline CI classification, including the real hosted runner's archived missing UUID reads."""

from copy import deepcopy
from importlib.util import module_from_spec, spec_from_file_location
import json
import os
from pathlib import Path
from types import SimpleNamespace
import tempfile
import unittest
from unittest.mock import patch


def module(file):
    spec = spec_from_file_location(file.replace("-", "_"), Path(__file__).with_name(file + ".py"))
    result = module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


source = module("source-tests")
scope = module("hosted_scope")


class WindowEngineCITests(unittest.TestCase):
    def setUp(self):
        before = scope.ROOT / "engineering/verification/window-engine/runs/44885716283/corner/result.json"
        archived = json.loads(before.read_bytes())["nativeScopeReads"]
        # The archived normalised UUIDs were null. Supply the new schema's source-type markers,
        # console bits and clock only as test inputs; the old record did not retain these fields.
        rows = [
            dict(
                row,
                console=True,
                displayQuerySucceeded=True,
                inventoryAvailable=True,
                uptime=i + 5.0,
                currentUUIDField="missing",
                matchedUUIDField="missing",
            )
            for i, row in enumerate(archived)
        ]
        self.raw = {
            "schema": 1,
            "scope": "readOnlyHostedDesktop",
            "systemWrites": 0,
            "windowTrials": "NOT_RUN",
            "reads": rows,
        }

    def test_archived_double_null_is_an_environment_block(self):
        self.assertEqual(scope.disposition(self.raw), ("BLOCKED", "independentOrdinarySpaceUUIDMissingTwice"))

    def test_stable_present_but_unusable_uuid_on_real_hosted_runner(self):
        for form in ("malformed", "emptyString", "zeroUUID"):
            raw = deepcopy(self.raw)
            for row in raw["reads"]:
                row.update(currentUUIDField=form, matchedUUIDField=form)
            self.assertEqual(scope.disposition(raw), ("BLOCKED", "ordinaryUUIDFieldsPresentButUnusableTwice"))
            raw["reads"][0]["matchedUUIDField"] = "valid"
            self.assertEqual(scope.disposition(raw)[0], "UNKNOWN")

    def test_explicit_final_commit_line_or_checked_manual_input_required(self):
        marker = "[window-engine-hosted-scope]"
        self.assertTrue(scope.requested("workflow_dispatch", "1", ""))
        self.assertTrue(scope.requested("push", "1", "Check engine\n\n" + marker + "\n"))
        for event, enabled, text in (
            ("push", "1", "mentions " + marker),
            ("push", "1", marker + "\nbody"),
            ("workflow_dispatch", "0", marker),
            ("pull_request", "1", marker),
            ("push", "1", ""),
            ("push", "0", marker),
        ):
            self.assertFalse(scope.requested(event, enabled, text))

    def test_one_read_changed_display_or_unproved_id_is_unknown(self):
        for change in (
            {"currentID64": 88},
            {"directWindowServerHome": 0},
            {"read": 1},
            {"uptime": 4.0},
            {"physicalDisplayUUID": "not-a-display"},
            {"console": False},
            {"matchedUUID": "11111111-1111-1111-1111-111111111111"},
            {"inventoryAvailable": False},
            {"currentUUIDField": "malformed"},
            {"matchedUUIDField": None},
        ):
            raw = deepcopy(self.raw)
            raw["reads"][1].update(change)
            self.assertEqual(scope.disposition(raw)[0], "UNKNOWN", change)

    def test_confirmed_identity_requires_the_same_independent_number_and_uuid_twice(self):
        ident = "11111111-1111-1111-1111-111111111111"
        for row in self.raw["reads"]:
            row.update(
                currentUUID=ident,
                matchedUUID=ident,
                currentUUIDField="valid",
                matchedUUIDField="valid",
                reason="confirmed",
                bound=dict(
                    native=row["directWindowServerHome"], display=row["physicalDisplayUUID"], space=ident
                ),
            )
        self.assertEqual(scope.disposition(self.raw)[0], "OBSERVED")
        self.raw["reads"][0]["bound"]["native"] += 1
        self.assertEqual(scope.disposition(self.raw)[0], "UNKNOWN")

    def test_true_failure_unknown_and_unexpected_writes_remain_unsuccessful(self):
        for state in ("FAIL", "UNKNOWN"):
            self.assertEqual(scope.disposition(dict(self.raw, status=state))[0], state)
        for update in ({"systemWrites": 1}, {"windowTrials": "PASS"}):
            self.assertEqual(scope.disposition(dict(self.raw, **update))[0], "FAIL")
        for update in ({"reads": []}, {"schema": 2}):
            self.assertEqual(scope.disposition(dict(self.raw, **update))[0], "UNKNOWN")

    def test_absent_console_and_nonordinary_desktop_are_named(self):
        absent = deepcopy(self.raw)
        for row in absent["reads"]:
            row.update(console=False)
        self.assertEqual(scope.disposition(absent), ("BLOCKED", "noUnlockedHostedGUIForRunner"))
        for row in self.raw["reads"]:
            row.update(currentType=4, matchedType=4, reason="currentRecordNotConfirmedOrdinary")
        self.assertEqual(scope.disposition(self.raw), ("BLOCKED", "currentDesktopIsNotOrdinary"))

    def test_zero_or_partial_suites_cannot_pass(self):
        for log in ("", "test result: ok. 0 passed; 0 failed;", "test result: ok. 4 passed; 0 failed;"):
            with self.assertRaises(ValueError):
                source.rust_count(log)
        with self.assertRaises(ValueError):
            source.python_count("Ran 0 tests in 0s\n\nOK\n")

    def test_swift_xunit_requires_each_named_case_without_duplicates_skips_or_failures(self):
        with tempfile.TemporaryDirectory() as temp:
            xml = Path(temp) / "swift.xml"

            def write(cases):
                xml.write_text("<testsuites><testsuite>" + cases + "</testsuite></testsuites>")

            case = '<testcase classname="Nearpane.Only" name="a"></testcase>'
            write(case)
            self.assertEqual(source.swift_count(xml, ["Only"])["passed"], 1)
            with self.assertRaises(ValueError):
                source.swift_count(xml, ["Only", "Missing"])
            for invalid in (
                "",
                case * 2,
                *(
                    case.replace("</testcase>", "<" + tag + "/></testcase>")
                    for tag in ("failure", "error", "skipped")
                ),
            ):
                write(invalid)
                with self.assertRaises(ValueError):
                    source.swift_count(xml, ["Only"])

    def test_c_abi_requires_observed_denial_and_zero_owned(self):
        packet = dict(submit=0, poll=0, status=3, flags=0, owned=0, refusedWithoutOwnership=True)
        report = dict(
            unreviewedEvidenceRefused=True,
            wrongExecutableCannotCreateProbeToken=True,
            closedWithoutOwnedResources=True,
            passiveHostLaunch=packet,
            passiveHostCleanup=packet,
            physicalWindowOperations=0,
        )
        self.assertEqual(source.abi_result(json.dumps(report))["readback"], report)
        with self.assertRaises(ValueError):
            source.abi_result(json.dumps(dict(report, passiveHostCleanup=dict(packet, owned=1))))

    def hosted_cli(self, compiler_exit, reader_exit=0, data=None):
        commands = []

        def fake_run(command, **kwargs):
            commands.append(command)
            if len(commands) == 1:
                return SimpleNamespace(returncode=compiler_exit)
            kwargs["stdout"].write(json.dumps(data))
            return SimpleNamespace(returncode=reader_exit)

        opts = {
            "GITHUB_EVENT_NAME": "workflow_dispatch",
            "NP_HOSTED_SCOPE_ONLY": "1",
            "GITHUB_ACTIONS": "true",
            "RUNNER_ENVIRONMENT": "github-hosted",
            "RUNNER_OS": "macOS",
        }
        with tempfile.TemporaryDirectory() as temp:
            out = Path(temp) / "result"
            with (
                patch.dict(os.environ, opts),
                patch.object(scope.pwd, "getpwuid", return_value=SimpleNamespace(pw_name="runner")),
                patch.object(os, "getuid", return_value=501),
                patch.object(scope.subprocess, "run", side_effect=fake_run),
                patch.object(scope.subprocess, "check_output", return_value="a" * 40),
                patch("sys.argv", ["hosted", str(out)]),
            ):
                code = scope.main()
            return code, json.loads((out / "summary.json").read_bytes()), commands

    def test_compiler_error_is_red_and_never_invokes_native_reader(self):
        code, report, calls = self.hosted_cli(71)
        self.assertEqual((code, report["status"], report["buildExit"], len(calls)), (1, "FAIL", 71, 1))
        self.assertEqual(report["productTrials"], "NOT_RUN")

    def test_return_code_and_native_unknown_cannot_be_absorbed_by_environment_block(self):
        code, report, _ = self.hosted_cli(0, 12, self.raw)
        self.assertEqual((code, report["status"], report["readerExit"]), (1, "UNKNOWN", 12))
        code, report, _ = self.hosted_cli(0, 0, dict(self.raw, status="FAIL"))
        self.assertEqual((code, report["status"]), (1, "FAIL"))
        code, report, _ = self.hosted_cli(0, 0, self.raw)
        self.assertEqual((code, report["status"], report["qualificationGranted"]), (0, "BLOCKED", False))
