import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

from run import confirmed_r4_press, execute, selection_preparation_start


class LifecycleRunnerTests(unittest.TestCase):
    def test_startup_sample_survives_failure_before_any_r4_input(self):
        result, startup, press, selection, calls = self.run_sampled_host(request_press=False)
        self.assertEqual(result["exit"], 2)
        self.assertEqual(result["status"], "FAIL")
        self.assertEqual(startup["status"], "COMPLETE")
        self.assertEqual(startup["trigger"], "startup")
        self.assertEqual(startup["durationSeconds"], 1)
        self.assertEqual(press["status"], "NOT_RUN")
        self.assertEqual(press["reason"], "successfulR4PressNotObserved")
        self.assertEqual(selection["status"], "NOT_RUN")
        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0][1], str(startup["pid"]))

    def test_startup_sample_preserves_separate_first_r4_input_sample(self):
        result, startup, press, selection, calls = self.run_sampled_host(request_press=True)
        self.assertEqual(result["exit"], 0)
        self.assertEqual(startup["status"], "COMPLETE")
        self.assertEqual(press["status"], "COMPLETE")
        self.assertEqual(press["trigger"], "firstConfirmedExternalAXPress")
        self.assertEqual(press["durationSeconds"], 3)
        self.assertEqual(startup["pid"], press["pid"])
        self.assertEqual(selection["status"], "COMPLETE")
        self.assertEqual(selection["trigger"], "firstGroupSelectionJob")
        self.assertEqual(selection["actualPressUptime"], press["actualPressUptime"])
        self.assertLessEqual(press["requestObservedMonotonic"], press["receiptObservedMonotonic"])
        self.assertLessEqual(press["sampleLaunchMonotonic"], press["receiptObservedMonotonic"])
        self.assertLessEqual(press["receiptObservedMonotonic"], press["triggerObservedMonotonic"])
        self.assertEqual(press["sharedWith"], "host-selection-preparation-main-thread")
        self.assertEqual(press["sampleFile"], selection["sampleFile"])
        self.assertEqual(press["sampleLaunchMonotonic"], selection["sampleLaunchMonotonic"])
        self.assertEqual(press["reapedMonotonic"], selection["reapedMonotonic"])
        self.assertIn("reapedMonotonic", press)
        self.assertNotIn("finishedMonotonic", press)
        self.assertEqual(len(calls), 2)
        self.assertEqual({Path(call[-1]).name for call in calls},
                         {"host-startup-main-thread.sample.txt", "host-selection-preparation-main-thread.sample.txt"})

    def test_press_and_selection_observed_in_the_same_poll_share_one_sampler(self):
        result, startup, press, selection, calls = self.run_sampled_host(request_press=True, mode="together")
        self.assertEqual(result["exit"], 0)
        self.assertEqual(press["status"], "COMPLETE")
        self.assertEqual(selection["status"], "COMPLETE")
        self.assertNotIn("sharedWith", press)
        self.assertEqual(selection["sharedWith"], "host-main-thread")
        self.assertEqual(selection["sampleFile"], press["sampleFile"])
        self.assertEqual(selection["sampleLaunchMonotonic"], press["sampleLaunchMonotonic"])
        self.assertEqual(selection["reapedMonotonic"], press["reapedMonotonic"])
        self.assertEqual(selection["trigger"], "firstGroupSelectionJob")
        self.assertIn("selectionStartUptime", selection)
        self.assertEqual(press["trigger"], "firstConfirmedExternalAXPress")
        self.assertIn("receiptObservedMonotonic", press)
        self.assertLessEqual(press["receiptObservedMonotonic"], press["sampleLaunchMonotonic"])
        self.assertEqual(len(calls), 2)
        self.assertEqual({Path(call[-1]).name for call in calls},
                         {"host-startup-main-thread.sample.txt", "host-main-thread.sample.txt"})

    def test_later_press_opens_a_new_window_after_the_prior_sampler_exits(self):
        result, startup, press, selection, calls = self.run_sampled_host(request_press=True, mode="prior-ended")
        self.assertEqual(result["exit"], 0)
        self.assertEqual(press["status"], "COMPLETE")
        self.assertEqual(selection["status"], "COMPLETE")
        self.assertNotIn("sharedWith", press)
        self.assertNotIn("sharedWith", selection)
        self.assertNotEqual(press["sampleFile"], selection["sampleFile"])
        self.assertLess(selection["sampleLaunchMonotonic"], press["sampleLaunchMonotonic"])
        self.assertLessEqual(press["receiptObservedMonotonic"], press["sampleLaunchMonotonic"])
        self.assertEqual(len(calls), 3)
        self.assertEqual({Path(call[-1]).name for call in calls},
                         {"host-startup-main-thread.sample.txt", "host-main-thread.sample.txt", "host-selection-preparation-main-thread.sample.txt"})

    def test_only_a_complete_matching_successful_press_receipt_is_input_evidence(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            (output / "config.json").write_text(json.dumps({"nonce": "fixture"}))
            result = output / "r4-press-test.result.json"
            request = {"schema": 1, "nonce": "fixture", "host": {"pid": 123}, "result": str(result)}
            (output / "r4-press-test.request.json").write_text(json.dumps(request))
            seen = {}
            with patch("run.time.monotonic", return_value=10):
                for partial in ["", '{"schema":1,"status":"ISSUED"']:
                    result.write_text(partial)
                    self.assertIsNone(confirmed_r4_press(output, 123, seen))
            valid = {"schema": 1, "nonce": "fixture", "status": "ISSUED", "issued": True,
                     "axError": 0, "inputUptime": 12, "uptime": 13}
            for field, value in [("status", "BLOCKED"), ("issued", False), ("axError", -25200), ("nonce", "other"),
                                 ("inputUptime", float("nan")), ("uptime", 11)]:
                result.write_text(json.dumps(dict(valid, **{field: value})))
                self.assertIsNone(confirmed_r4_press(output, 123, seen))
            result.write_text(json.dumps(valid))
            self.assertIsNone(confirmed_r4_press(output, 124, seen))
            with patch("run.time.monotonic", return_value=20):
                receipt = confirmed_r4_press(output, 123, seen)
            self.assertEqual(receipt["requestObservedMonotonic"], 10)
            self.assertEqual(receipt["actualPressUptime"], 12)
            self.assertEqual(receipt["pressReceiptUptime"], 13)
            self.assertEqual(receipt["receiptObservedMonotonic"], 20)

    def test_selection_trigger_waits_for_a_complete_host_log_line(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "host.stderr.log"
            event = json.dumps({"event": "independentStageProduct", "phase": "group-job-start", "uptime": 14,
                                "current": True, "window": 54})
            path.write_text("not JSON\n" + event[:20])
            with path.open() as reader:
                partial, evidence = selection_preparation_start(reader, "")
                self.assertIsNone(evidence)
                with path.open("a") as writer:
                    writer.write(event[20:] + "\n")
                partial, evidence = selection_preparation_start(reader, partial)
            self.assertEqual(partial, "")
            self.assertEqual(evidence["selectionStartUptime"], 14)
            self.assertEqual(evidence["selectionWindow"], 54)

    def run_sampled_host(self, request_press, mode="selection-first"):
        # The Host waits for observable diagnostic files rather than a scheduling
        # delay; only /usr/bin/sample is substituted on non-macOS test hosts.
        observer = """
from pathlib import Path
import json, os, sys, time
output = Path(sys.argv[1])
(output / 'config.json').write_text(json.dumps({'nonce': 'fixture'}))
def wait_for(name):
    deadline = time.monotonic() + 4
    while time.monotonic() < deadline:
        if (output / name).exists():
            return
        time.sleep(.01)
    sys.exit(1)
wait_for('host-startup-main-thread.sample.txt')
if sys.argv[2] != 'no':
    result = output / 'r4-press-first.result.json'
    request = {'schema': 1, 'nonce': 'fixture', 'host': {'pid': os.getpid()}, 'result': str(result)}
    (output / 'r4-press-first.request.json').write_text(json.dumps(request))
    result.touch()  # Production creates this path before discovery, not atomically at completion.
    pressed = time.monotonic()
    event = {'event': 'independentStageProduct', 'phase': 'group-job-start', 'uptime': pressed + .001,
             'window': 54, 'current': True}
    if sys.argv[2] != 'together':
        print(json.dumps(event), file=sys.stderr, flush=True)
        wait_for('host-selection-preparation-main-thread.sample.txt')
        assert not (output / 'host-main-thread.sample.txt').exists()
        if sys.argv[2] == 'prior-ended':
            (output / 'prior-sampler-ended').touch()
    result.write_text(json.dumps({'schema': 1, 'nonce': 'fixture', 'status': 'ISSUED', 'issued': True,
                                 'axError': 0, 'inputUptime': pressed, 'uptime': time.monotonic()}))
    if sys.argv[2] == 'together':
        print(json.dumps(event), file=sys.stderr, flush=True)
        (output / 'both-triggers-ready').touch()
    wait_for('press-receipt-observed')
else:
    sys.exit(2)
"""
        real_popen = subprocess.Popen
        calls = []
        samplers = []

        class Sampler:
            # A controlled process lifetime makes overlap deterministic. The
            # real Host still writes the receipts and complete stderr events.
            def __init__(self, command):
                self.path = Path(command[-1])
                self.returncode = None
                self.wait_calls = 0
                self.path.write_text("sample")

            def poll(self):
                if self.path.name == "host-selection-preparation-main-thread.sample.txt" and (self.path.parent / "prior-sampler-ended").exists():
                    self.returncode = 0
                return self.returncode

            def wait(self, timeout):
                self.wait_calls += 1
                self.returncode = 0
                return 0

        def popen(command, **kwargs):
            if command[0] == "/usr/bin/sample":
                calls.append(command)
                sampler = Sampler(command)
                samplers.append(sampler)
                return sampler
            return real_popen(command, **kwargs)

        def observe_press(directory, host_pid, seen):
            if mode == "together" and not (directory / "both-triggers-ready").exists():
                return None
            receipt = confirmed_r4_press(directory, host_pid, seen)
            if receipt is not None:
                (directory / "press-receipt-observed").touch()
            return receipt

        def observe_selection(reader, partial):
            if mode == "together" and not (output / "both-triggers-ready").exists():
                return partial, None
            return selection_preparation_start(reader, partial)

        with tempfile.TemporaryDirectory() as directory, patch("run.subprocess.Popen", side_effect=popen), \
                patch("run.confirmed_r4_press", side_effect=observe_press), \
                patch("run.selection_preparation_start", side_effect=observe_selection):
            output = Path(directory)
            result = execute([sys.executable, "-c", observer, directory, mode if request_press else "no"],
                             output, "sampled-host", dict(os.environ), 5, sample_host=output)
            startup = json.loads((output / "host-startup-main-thread-sample.json").read_text())
            press = json.loads((output / "host-main-thread-sample.json").read_text())
            selection = json.loads((output / "host-selection-preparation-main-thread-sample.json").read_text())
            self.assertEqual([sampler.wait_calls for sampler in samplers], [1] * len(samplers))
            for report in (startup, press, selection):
                if report["status"] == "COMPLETE":
                    self.assertTrue((output / report["sampleFile"]).is_file())
        return result, startup, press, selection, calls

    def test_exited_fixture_is_reaped_while_the_acceptance_host_observes_it(self):
        fixture = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(.1)"])
        observer = """
import os, sys, time
pid = int(sys.argv[1])
deadline = time.monotonic() + 3
while time.monotonic() < deadline:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        sys.exit(0)
    time.sleep(.02)
sys.exit(1)
"""
        try:
            with tempfile.TemporaryDirectory() as directory:
                result = execute([sys.executable, "-c", observer, str(fixture.pid)], Path(directory),
                                 "lifecycle-owner-exit", dict(os.environ), 5, reap_children=(fixture,))
                self.assertEqual(result["exit"], 0)
                self.assertEqual(fixture.returncode, 0)
        finally:
            if fixture.poll() is None:
                fixture.terminate()
            fixture.wait(timeout=3)


if __name__ == "__main__":
    unittest.main()
