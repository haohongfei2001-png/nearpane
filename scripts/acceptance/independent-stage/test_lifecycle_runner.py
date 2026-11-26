import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

from run import execute


class LifecycleRunnerTests(unittest.TestCase):
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
