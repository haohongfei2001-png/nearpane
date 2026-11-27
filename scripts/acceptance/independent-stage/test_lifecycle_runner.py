import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

from run import execute


class LifecycleRunnerTests(unittest.TestCase):
    def test_startup_sample_survives_failure_before_any_r4_input(self):
        result, startup, press, calls = self.run_sampled_host(request_press=False)
        self.assertEqual(result["exit"], 2)
        self.assertEqual(result["status"], "FAIL")
        self.assertEqual(startup["status"], "COMPLETE")
        self.assertEqual(startup["trigger"], "startup")
        self.assertEqual(startup["durationSeconds"], 1)
        self.assertEqual(press["status"], "NOT_RUN")
        self.assertEqual(press["reason"], "firstR4RequestNotObserved")
        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0][1], str(startup["pid"]))

    def test_startup_sample_preserves_separate_first_r4_input_sample(self):
        result, startup, press, calls = self.run_sampled_host(request_press=True)
        self.assertEqual(result["exit"], 0)
        self.assertEqual(startup["status"], "COMPLETE")
        self.assertEqual(press["status"], "COMPLETE")
        self.assertEqual(press["trigger"], "firstR4Request")
        self.assertEqual(press["durationSeconds"], 3)
        self.assertEqual(startup["pid"], press["pid"])
        self.assertEqual(len(calls), 2)
        self.assertEqual({Path(call[-1]).name for call in calls},
                         {"host-startup-main-thread.sample.txt", "host-main-thread.sample.txt"})

    def run_sampled_host(self, request_press):
        # The Host waits for observable diagnostic files rather than a scheduling
        # delay; only /usr/bin/sample is substituted on non-macOS test hosts.
        observer = """
from pathlib import Path
import sys, time
output = Path(sys.argv[1])
def wait_for(name):
    deadline = time.monotonic() + 4
    while time.monotonic() < deadline:
        if (output / name).exists():
            return
        time.sleep(.01)
    sys.exit(1)
wait_for('host-startup-main-thread.sample.txt')
if sys.argv[2] == 'yes':
    (output / 'r4-press-first.request.json').write_text('{}')
    wait_for('host-main-thread.sample.txt')
else:
    sys.exit(2)
"""
        real_popen = subprocess.Popen
        calls = []

        def popen(command, **kwargs):
            if command[0] == "/usr/bin/sample":
                calls.append(command)
                command = [sys.executable, "-c", "from pathlib import Path; import sys; Path(sys.argv[1]).write_text('sample')", command[-1]]
            return real_popen(command, **kwargs)

        with tempfile.TemporaryDirectory() as directory, patch("run.subprocess.Popen", side_effect=popen):
            output = Path(directory)
            result = execute([sys.executable, "-c", observer, directory, "yes" if request_press else "no"],
                             output, "sampled-host", dict(os.environ), 5, sample_host=output)
            startup = json.loads((output / "host-startup-main-thread-sample.json").read_text())
            press = json.loads((output / "host-main-thread-sample.json").read_text())
        return result, startup, press, calls

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
