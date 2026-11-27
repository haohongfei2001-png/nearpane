import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

from run import (confirmed_r4_press, delayed_directory_task, execute, main, observe_capture_markers,
                 observe_directory_task, runtime_checks, selection_preparation_start)


class LifecycleRunnerTests(unittest.TestCase):
    def test_startup_sample_survives_failure_before_any_r4_input(self):
        result, startup, press, selection, calls, late = self.run_sampled_host(request_press=False)
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
        self.assertEqual(late["status"], "NOT_RUN")

    def test_startup_sample_preserves_separate_first_r4_input_sample(self):
        result, startup, press, selection, calls, _ = self.run_sampled_host(request_press=True)
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
        result, startup, press, selection, calls, _ = self.run_sampled_host(request_press=True, mode="together")
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
        result, startup, press, selection, calls, _ = self.run_sampled_host(request_press=True, mode="prior-ended")
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

    def test_later_selection_gets_a_new_capture_after_press_capture_completes_before_process_exit(self):
        result, _, press, selection, calls, _ = self.run_sampled_host(True, mode="press-first-capture-ended")
        self.assertEqual(result["exit"], 0)
        self.assertEqual((press["status"], selection["status"]), ("COMPLETE", "COMPLETE"))
        self.assertNotIn("sharedWith", selection)
        self.assertNotEqual(press["sampleFile"], selection["sampleFile"])
        self.assertLessEqual(press["captureCompletionObservedMonotonic"], selection["sampleLaunchMonotonic"])
        self.assertEqual(len(calls), 3)

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

    def test_queue_watchdog_correlates_both_session_and_revision_without_mixing_clocks(self):
        pending = {}
        created = {"phase": "desktop-read-task-created", "readSession": "feed-a", "requestRevision": 1,
                   "dispatching": True, "taskCreatedUptime": 100, "creatorPriority": 25}
        with patch("run.time.monotonic", return_value=10):
            observe_directory_task(dict(created, dispatching=False), pending)
            self.assertFalse(pending)
            observe_directory_task(created, pending)
            observe_directory_task(dict(created, readSession="feed-b"), pending)
        with patch("run.time.monotonic", return_value=10.1):
            observe_directory_task(created, pending)  # Duplicate creation cannot postpone the threshold.
            observe_directory_task({"phase": "desktop-read-task-started", "readSession": "feed-a",
                                    "requestRevision": 2, "taskStartedUptime": 101}, pending)
        self.assertIsNone(delayed_directory_task(pending, 10.24))
        delayed = delayed_directory_task(pending, 10.25)
        self.assertEqual(delayed["readSession"], "feed-a")
        self.assertEqual(delayed["pendingForObservedMS"], 250)
        with patch("run.time.monotonic", return_value=10.3):
            observe_directory_task({"phase": "desktop-read-task-started", "readSession": "feed-b",
                                    "requestRevision": 1, "taskStartedUptime": 102}, pending)
        self.assertIs(delayed_directory_task(pending, 10.4), delayed)
        with patch("run.time.monotonic", return_value=10.5):
            observe_directory_task({"phase": "desktop-read-task-started", "readSession": "feed-a",
                                    "requestRevision": 1, "taskStartedUptime": 103, "taskPriority": 25}, pending)
        self.assertFalse(pending)
        self.assertEqual(delayed["taskQueueMS"], 3000)
        self.assertEqual(delayed["taskStartedObservedMonotonic"], 10.5)
        self.assertEqual(delayed["taskStartPriority"], 25)

    def test_trace_reader_consumes_task_events_after_selection_and_waits_for_complete_start_line(self):
        pending = {}
        selection = {"event": "independentStageProduct", "phase": "group-job-start", "uptime": 11}
        created = {"event": "independentStageProduct", "phase": "desktop-read-task-created", "readSession": "feed",
                   "requestRevision": 1, "taskCreatedUptime": 12, "dispatching": True}
        started = json.dumps({"event": "independentStageProduct", "phase": "desktop-read-task-started",
                              "readSession": "feed", "requestRevision": 1, "taskStartedUptime": 13})
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "host.stderr.log"
            path.write_text(json.dumps(selection) + "\n" + json.dumps(created) + "\n" + started[:30])
            with path.open() as reader:
                partial, evidence = selection_preparation_start(reader, "", lambda event: observe_directory_task(event, pending))
                self.assertEqual(evidence["selectionStartUptime"], 11)
                self.assertEqual(len(pending), 1)
                with path.open("a") as writer:
                    writer.write(started[30:] + "\n")
                partial, evidence = selection_preparation_start(reader, partial, lambda event: observe_directory_task(event, pending))
                self.assertEqual(partial, "")
                self.assertIsNone(evidence)
                self.assertFalse(pending)

    def test_capture_completion_is_observed_from_a_complete_marker_not_process_reaping(self):
        report = {"reapedMonotonic": 90}
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "sample.stderr.log"
            path.write_text("Sampling process 123 for 3 seconds\nSampling completed, processing")
            with path.open() as reader:
                with patch("run.time.monotonic", return_value=20):
                    partial = observe_capture_markers(reader, "", report)
                self.assertEqual(report["captureStartObservedMonotonic"], 20)
                self.assertNotIn("captureCompletionObservedMonotonic", report)
                with path.open("a") as writer:
                    writer.write(" symbols...\n")
                with patch("run.time.monotonic", return_value=30):
                    partial = observe_capture_markers(reader, partial, report)
                self.assertEqual(partial, "")
                self.assertEqual(report["captureCompletionObservedMonotonic"], 30)
                self.assertEqual(report["reapedMonotonic"], 90)

    def test_queued_read_gets_one_late_capture_after_completion_while_original_process_is_alive(self):
        result, _, press, selection, calls, late = self.run_sampled_host(True, mode="queue")
        self.assertEqual(result["exit"], 0)
        self.assertEqual(late["status"], "COMPLETE")
        self.assertNotIn("sharedWith", late)
        self.assertEqual(late["trigger"], "directoryReadQueuedAtLeast250MS")
        task = late["queueObservation"]
        self.assertEqual((task["readSession"], task["requestRevision"]), ("first-feed", 7))
        self.assertGreaterEqual(task["pendingForObservedMS"], 250)
        self.assertGreater(task["taskStartedUptime"], task["taskCreatedUptime"])
        self.assertLessEqual(selection["captureCompletionObservedMonotonic"], late["sampleLaunchMonotonic"])
        self.assertEqual(press["sampleFile"], selection["sampleFile"])
        self.assertEqual(len(calls), 3)
        self.assertEqual(sum(Path(call[-1]).name == "host-read-queue-main-thread.sample.txt" for call in calls), 1)

    def test_started_read_cancels_late_capture_while_original_sampling_continues(self):
        result, _, _, _, calls, late = self.run_sampled_host(True, mode="queue-resolved")
        self.assertEqual(result["exit"], 0)
        self.assertEqual(late["status"], "NOT_RUN")
        self.assertEqual(late["reason"], "queuedReadStartedBeforeAdditionalSample")
        self.assertIn("taskStartedUptime", late["queueObservation"])
        self.assertEqual(len(calls), 2)

    def test_cli_sampling_opt_out_reaches_runtime_and_default_stays_enabled(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            archive = root / "engine.a"
            archive.touch()
            for disabled in (False, True):
                output = root / ("disabled" if disabled else "enabled")
                argv = ["run.py", str(output), "--scope", "runtime", "--archive", str(archive),
                        "--product-host", str(root / "Nearpane.app")]
                if disabled:
                    argv.append("--no-host-sampling")
                with patch.object(sys, "argv", argv), patch("run.platform.system", return_value="Darwin"), \
                        patch("run.os.umask"), patch("run.select_toolchain", return_value={"status": "AVAILABLE"}), \
                        patch("run.subprocess.check_output", return_value="fixture-revision\n"), \
                        patch("run.runtime_checks", return_value={"status": "PASS", "R4ProductPath": "PASS"}) as runtime, \
                        patch("builtins.print"):
                    self.assertEqual(main(), 0)
                self.assertEqual(runtime.call_args.kwargs["host_sampling"], not disabled)
                receipt = json.loads((output / "summary.json").read_text())
                self.assertEqual(receipt["hostSampling"], "disabledByRequest" if disabled else "enabled")

    def test_disabled_sampling_runs_the_product_command_and_records_explicit_disabled_receipts(self):
        real_popen = subprocess.Popen
        product_sampling = []
        fixture_pids = iter((601, 602))

        def popen(command, **kwargs):
            self.assertNotEqual(str(command[0]), "/usr/bin/sample")
            if command[0] in ("fixture-a", "fixture-b"):
                return type("Fixture", (), {"pid": next(fixture_pids)})()
            return real_popen(command, **kwargs)

        def prepared_fixture(directory, child, nonce, count):
            return {"pid": child.pid, "birth": 1, "windows": [{"number": index + 1} for index in range(count)]}

        def run_process(command, out, name, env, *args, **kwargs):
            if name == "engine":
                config = json.loads((out / "config.json").read_text())
                (out / "engine-result.json").write_text(json.dumps({"status": "PASS", "cleanup": True, "nonce": config["nonce"]}))
                return {"status": "PASS"}
            self.assertEqual(name, "product")
            product_sampling.append(kwargs["sample_host"])
            return execute(command, out, name, env, *args, **kwargs)

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            host = root / "controlled-product"
            host.write_text("#!" + sys.executable + "\n" + """
from pathlib import Path
import json, sys
config = json.loads(Path(sys.argv[-1]).read_text())
output = Path(config['output'])
(output / 'product-action-ran').write_text('controlled action executed')
(output / 'product-result.json').write_text(json.dumps({'status': 'FAIL', 'cleanup': True,
    'nonce': config['nonce'], 'reason': 'controlledProductActionCompleted'}))
""")
            host.chmod(0o700)
            apps = {name: {"executable": executable} for name, executable in
                    (("FixtureA", "fixture-a"), ("FixtureB", "fixture-b"),
                     ("Controller", "controller"), ("SplitViewHelper", "split-helper"))}
            with patch("run.build", return_value=apps), patch("run.wait_fixture", side_effect=prepared_fixture), \
                    patch("run.close_fixture", return_value={"exit": 0}), patch("run.candidate_copy", return_value=host), \
                    patch("run.execute", side_effect=run_process), patch("run.subprocess.Popen", side_effect=popen):
                result = runtime_checks(root / "runtime", {}, root / "engine.a", host, 1, "fixture-revision", host_sampling=False)
            self.assertEqual(product_sampling, [None])
            self.assertTrue((root / "runtime/product/product-action-ran").is_file())
            self.assertEqual(result["hostSampling"], "disabledByRequest")
            self.assertEqual(result["productReceipt"]["reason"], "controlledProductActionCompleted")
            self.assertEqual(result["productReceipt"]["hostSampling"], "disabledByRequest")
            receipts = list((root / "runtime/product").glob("host-*-sample.json"))
            self.assertEqual(len(receipts), 4)
            for path in receipts:
                receipt = json.loads(path.read_text())
                self.assertEqual((receipt["status"], receipt["reason"]), ("NOT_RUN", "diagnosticsDisabled"))
            self.assertFalse(list((root / "runtime/product").glob("*.sample.txt")))

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
    if sys.argv[2] not in ('together', 'press-first-capture-ended'):
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
    elif sys.argv[2] == 'press-first-capture-ended':
        wait_for('host-main-thread.sample.txt')
        (output / 'finish-capture').touch()
        wait_for('capture-completion-observed')
        event['uptime'] = time.monotonic()
        print(json.dumps(event), file=sys.stderr, flush=True)
        wait_for('host-selection-preparation-main-thread.sample.txt')
    wait_for('press-receipt-observed')
    if sys.argv[2] in ('queue', 'queue-resolved'):
        def task_event(phase, session='first-feed', revision=7):
            event = {'event': 'independentStageProduct', 'phase': 'desktop-read-task-' + phase,
                     'readSession': session, 'requestRevision': revision, 'dispatching': True,
                     'creatorPriority': 25, 'taskPriority': 25}
            event['taskCreatedUptime' if phase == 'created' else 'taskStartedUptime'] = time.monotonic()
            print(json.dumps(event), file=sys.stderr, flush=True)
        task_event('created')
        wait_for('queued-read-overdue')
        if sys.argv[2] == 'queue-resolved':
            task_event('started')
            wait_for('queued-read-start-observed')
        (output / 'finish-capture').touch()
        if sys.argv[2] == 'queue':
            wait_for('host-read-queue-main-thread.sample.txt')
            task_event('started')
            wait_for('queued-read-start-observed')
            task_event('created', 'later-feed', 7)
            wait_for('later-read-created-observed')
            # Let a second queue cross the diagnostic threshold after the first
            # late capture has completed. It must not create another sample.
            time.sleep(.35)
            task_event('started', 'later-feed', 7)
            wait_for('later-read-start-observed')
        wait_for('capture-completion-observed')
else:
    sys.exit(2)
"""
        real_popen = subprocess.Popen
        calls = []
        samplers = []

        class Sampler:
            # A controlled process lifetime makes overlap deterministic. The
            # real Host still writes the receipts and complete stderr events.
            def __init__(self, command, stderr):
                self.path = Path(command[-1])
                self.stderr = stderr
                self.returncode = None
                self.wait_calls = 0
                self.capture_completed = False
                self.stderr.write("Sampling process 123 for 3 seconds\n")
                self.stderr.flush()
                self.path.write_text("sample")
                if self.path.name == "host-read-queue-main-thread.sample.txt":
                    self.complete_capture()

            def complete_capture(self):
                if not self.capture_completed:
                    self.stderr.write("Sampling completed, processing symbols...\n")
                    self.stderr.flush()
                    self.capture_completed = True

            def poll(self):
                if self.path.name == "host-selection-preparation-main-thread.sample.txt" and (self.path.parent / "prior-sampler-ended").exists():
                    self.returncode = 0
                return self.returncode

            def wait(self, timeout):
                self.wait_calls += 1
                self.complete_capture()
                self.returncode = 0
                return 0

        def popen(command, **kwargs):
            if command[0] == "/usr/bin/sample":
                if mode == "press-first-capture-ended" and Path(command[-1]).name == "host-selection-preparation-main-thread.sample.txt":
                    previous = next(s for s in samplers if s.path.name == "host-main-thread.sample.txt")
                    self.assertIsNone(previous.returncode)
                    self.assertTrue(previous.capture_completed)
                if Path(command[-1]).name == "host-read-queue-main-thread.sample.txt":
                    # Completion of acquisition, not process exit, admits the
                    # extra capture. The original is still processing symbols.
                    previous = next(s for s in samplers if s.path.name == "host-selection-preparation-main-thread.sample.txt")
                    self.assertIsNone(previous.returncode)
                    self.assertTrue(previous.capture_completed)
                calls.append(command)
                sampler = Sampler(command, kwargs["stderr"])
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

        def observe_selection(reader, partial, on_event=None):
            if mode == "together" and not (output / "both-triggers-ready").exists():
                return partial, None
            return selection_preparation_start(reader, partial, on_event)

        def observe_task(event, pending):
            observe_directory_task(event, pending)
            if event.get("phase") == "desktop-read-task-started":
                marker = "later-read-start-observed" if event.get("readSession") == "later-feed" else "queued-read-start-observed"
                (output / marker).touch()
            elif event.get("phase") == "desktop-read-task-created" and event.get("readSession") == "later-feed":
                (output / "later-read-created-observed").touch()

        def observe_delay(pending, now):
            delayed = delayed_directory_task(pending, now)
            if delayed is not None:
                (output / "queued-read-overdue").touch()
            return delayed

        def observe_capture(reader, partial, report):
            # Acquisition completes independently of callers polling process
            # liveness, including after a queued task has already started.
            if (output / "finish-capture").exists():
                next(s for s in samplers if s.path.name == report["sampleFile"]).complete_capture()
            partial = observe_capture_markers(reader, partial, report)
            if report.get("durationSeconds") == 3 and "captureCompletionObservedMonotonic" in report:
                (output / "capture-completion-observed").touch()
            return partial

        with tempfile.TemporaryDirectory() as directory, patch("run.subprocess.Popen", side_effect=popen), \
                patch("run.confirmed_r4_press", side_effect=observe_press), \
                patch("run.selection_preparation_start", side_effect=observe_selection), \
                patch("run.observe_directory_task", side_effect=observe_task), \
                patch("run.delayed_directory_task", side_effect=observe_delay), \
                patch("run.observe_capture_markers", side_effect=observe_capture):
            output = Path(directory)
            result = execute([sys.executable, "-c", observer, directory, mode if request_press else "no"],
                             output, "sampled-host", dict(os.environ), 5, sample_host=output)
            startup = json.loads((output / "host-startup-main-thread-sample.json").read_text())
            press = json.loads((output / "host-main-thread-sample.json").read_text())
            selection = json.loads((output / "host-selection-preparation-main-thread-sample.json").read_text())
            late = json.loads((output / "host-read-queue-main-thread-sample.json").read_text())
            self.assertEqual([sampler.wait_calls for sampler in samplers], [1] * len(samplers))
            for report in (startup, press, selection, late):
                if report["status"] == "COMPLETE":
                    self.assertTrue((output / report["sampleFile"]).is_file())
        return result, startup, press, selection, calls, late

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
