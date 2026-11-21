import json
import os
import tempfile
import unittest
import uuid
from pathlib import Path
from unittest.mock import patch

from paired_preview_audit import PairedWindowAudit


class EnrolledTrace(unittest.TestCase):
    def test_signed_target_binding_only_requests_the_trace_on_explicit_opt_in(self):
        with tempfile.TemporaryDirectory() as folder:
            home = Path(folder).resolve()
            audit = object.__new__(PairedWindowAudit)
            audit.home = audit.output = home
            audit.request = home / "manifest"
            audit.host = dict(pid=12, birth=34, hash="11" * 20, identifier="com.holdsnow.nearpane.alpha",
                              executable="/Applications/Nearpane.app/Contents/MacOS/NearpaneHost")
            fixture = dict(pid=50, birth=75, hash="22" * 20, identifier="net.example.spaces-document", executable="fixture")
            with patch.dict(os.environ, {"NEARPANE_PREVIEW_DIAGNOSTICS": "", "NEARPANE_TEST_HOME": str(home)}):
                audit.bind(fixture, fixture, [20, 21])
                self.assertNotIn("previewTrace", audit.manifest)
            audit.request.unlink()
            with patch.dict(os.environ, {"NEARPANE_PREVIEW_DIAGNOSTICS": "1", "NEARPANE_TEST_HOME": str(home)}):
                audit.bind(fixture, fixture, [20, 21])
            request = audit.manifest["previewTrace"]
            self.assertEqual((request["hostHash"], request["fixtureHash"]), (audit.host["hash"], fixture["hash"]))
            self.assertEqual(audit.transitions("disabled")["status"], "UNAVAILABLE")
            row = dict(stage="preview-transition", token=request["token"].upper(), feed=str(uuid.uuid4()), epoch=str(uuid.uuid4()),
                       writerPID=12, hostBirth=34, ordinal=1, uptime=audit.registeredAt+1, revision=32,
                       window=audit.targets[1], lane="stream", reason="blank", streamEpoch=3)
            log = home / "p0-preview-transitions.jsonl"
            log.write_text(json.dumps(row)+"\n"); log.chmod(0o600)
            self.assertEqual(audit.transitions("reported")["count"], 1)
            self.assertEqual(json.loads((home/"reported-preview-transitions.json").read_bytes()), [row])
            for change in (dict(hostBirth=0), dict(token=str(uuid.uuid4())), dict(window=dict(audit.targets[0], birth=900)),
                           dict(ordinal=2), dict(title="out of scope"), dict(reason="unrecognized private text")):
                log.write_text(json.dumps(dict(row, **change))+"\n")
                with self.assertRaises(ValueError):
                    audit.transitions("refused")
                self.assertFalse((home/"refused-preview-transitions.json").exists())
