import importlib
import json
from pathlib import Path
import tempfile
import unittest
import uuid

probe=importlib.import_module("p3-installed-qualification")


class InstalledDraftEligibility(unittest.TestCase):
    def test_marker_does_not_authorize_an_account(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp).resolve()
            sid=str(uuid.uuid4()); folder=root/sid; folder.mkdir(mode=0o700)
            (folder/"session.json").write_text(json.dumps({"session":sid.upper()}))
            bundle=folder/"chrome-profile";bundle.mkdir(mode=0o700)
            (bundle/"fixture.json").write_text(json.dumps(dict(version=1,session=sid,purpose="isolated-native-draft")))
            self.assertEqual(probe.markers(root,None),dict(disposableMarkers=1,authorizedMarker=False))
            self.assertTrue(probe.markers(root,sid)["authorizedMarker"])
            (bundle/"fixture.json").unlink();(bundle/"fixture.json").symlink_to(folder/"session.json")
            self.assertFalse(probe.markers(root,sid)["authorizedMarker"])

    def test_signed_old_host_cannot_be_measured_by_external_helper(self):
        self.assertEqual(probe.host_result(Path("/never/invoke"),{"readOnlyProbePackaged":False})["status"],"BLOCKED")
        self.assertEqual(probe.host_result(None,{"readOnlyProbePackaged":True})["status"],"NOT_RUN")
