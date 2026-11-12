#!/usr/bin/env python3
"""Synthetic file-protocol checks. No WindowServer connection or OS input."""
from argparse import Namespace
import datetime as dt
import importlib.util
from pathlib import Path
import tempfile
from threading import Thread
import time
import unittest
import uuid

spec = importlib.util.spec_from_file_location("space_checkpoint", Path(__file__).with_name("space-checkpoint.py"))
ctl = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ctl)


class TestCheckpoint(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.folder = Path(temp.name)
        self.run = str(uuid.uuid4()).upper()
        self.origin = dict(sessionID=self.run, separateSpaces=True, scopes=[
            dict(displayID="main", records=[dict(id="1", isCurrent=True)]),
            dict(displayID="side", records=[dict(id="10", isCurrent=True), dict(id="11", isCurrent=False)])])
        self.put("scope-snapshot-1.json", self.origin)
        self.put("console-scope.json", dict(run=self.run, boot="test", securityID=1, secondaryDisplay="side"))
        self.request("unattended-consent")
        now = dt.datetime.now(dt.timezone.utc)
        self.args = Namespace(source="10", target="11", starts=ctl.format_utc(now - dt.timedelta(seconds=1)),
                              ends=ctl.format_utc(now + dt.timedelta(minutes=3)))

    def put(self, name, data):
        ctl.publish(self.folder / name, data)

    def request(self, name):
        self.put("request-" + name + ".json", dict(run=self.run, checkpoint=name, afterRevision="2"))

    def test_three_plus_one_cannot_grant_console_trial(self):
        self.origin["scopes"][1]["records"].pop()
        self.origin["scopes"][0]["records"] += [dict(id="2", isCurrent=False), dict(id="3", isCurrent=False)]
        with self.assertRaises(ctl.Refusal):
            ctl.check_order(self.origin, "side", "10", "11")

    def test_expired_interval_cannot_release(self):
        self.args.ends = self.args.starts
        with self.assertRaises(ctl.Refusal):
            ctl.grant(self.folder, self.run, self.args)
        self.assertFalse((self.folder / "unattended-consent.ready").exists())

    def test_fullscreen_requires_its_own_grant_and_current_blank_source_only(self):
        self.args.fullscreen_only = True
        self.args.target = None
        with self.assertRaises(ctl.Refusal):
            ctl.grant(self.folder, self.run, self.args)
        (self.folder / "console-scope.json").unlink()
        self.put("console-scope.json", dict(run=self.run, boot="test", securityID=1, secondaryDisplay="side", procedure="fullscreen"))
        self.args.source = "11"
        with self.assertRaises(ctl.Refusal):
            ctl.grant(self.folder, self.run, self.args)
        self.args.source = "10"
        ctl.grant(self.folder, self.run, self.args)
        grant = ctl.load(self.folder / "unattended-consent.ready")
        self.assertTrue(grant["permitsSingleWindowFullscreen"])
        self.assertFalse(grant["permitsCalibrationAndThreeRoundTrips"])
        self.assertEqual(grant["target"], "")

    def test_chord_conflicting_with_order_and_missing_click_rejected(self):
        ctl.grant(self.folder, self.run, self.args)
        self.request("enroll-B")
        with self.assertRaises(ctl.Refusal):
            ctl.ack(self.folder, self.run, Namespace(checkpoint="enroll-B", observed_chord="left"))
        self.assertFalse((self.folder / "enroll-B.observe").exists())
        self.request("enroll-A")
        with self.assertRaises(FileNotFoundError):
            ctl.ack(self.folder, self.run, Namespace(checkpoint="enroll-A", observed_chord=None))

    def handoff(self, alteration):
        ctl.grant(self.folder, self.run, self.args)
        name = "enroll-B"
        self.request(name)

        def witness():
            request = self.folder / (name + ".observe")
            for _ in range(200):
                if request.is_file():
                    break
                time.sleep(.01)
            readback = dict(ctl.load(request), endpoint="11", revision="4")
            readback.update(alteration)
            self.put("attested-" + name + ".json", readback)

        thread = Thread(target=witness)
        thread.start()
        try:
            ctl.ack(self.folder, self.run, Namespace(checkpoint=name, observed_chord="right"), timeout=2)
        finally:
            thread.join()

    def test_directional_ack_requires_correlated_live_readback(self):
        self.handoff({})
        ready = ctl.load(self.folder / "enroll-B.ready")
        self.assertEqual(ready["demonstratedControlArrow"], "right")
        self.assertEqual(ready["token"], ctl.load(self.folder / "attested-enroll-B.json")["token"])
        self.assertEqual(ctl.pending(self.folder, self.run), "waiting")

    def test_replayed_observation_rejected(self):
        with self.assertRaises(ctl.Refusal):
            self.handoff(dict(token=str(uuid.uuid4())))
        self.assertFalse((self.folder / "enroll-B.ready").exists())

    def test_stale_observation_rejected(self):
        with self.assertRaises(ctl.Refusal):
            self.handoff(dict(revision="2"))
        self.assertFalse((self.folder / "enroll-B.ready").exists())

    def test_wrong_endpoint_rejected(self):
        with self.assertRaises(ctl.Refusal):
            self.handoff(dict(endpoint="10"))
        self.assertFalse((self.folder / "enroll-B.ready").exists())


if __name__ == "__main__":
    unittest.main()
