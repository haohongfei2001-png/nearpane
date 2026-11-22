import hashlib
import importlib
import json
from pathlib import Path
import tempfile
import unittest

import membership_trace


class MembershipTraceTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.work = Path(directory.name)
        self.header = dict(event="bound", challenge="trial", pid=20, birth=50, window=80, cdhash="abc", home=4)
        events = [("willHideWindow", 10), ("hideResponse", 11), ("willReturnWindow", 20), ("returnResponse", 21)]
        self.report = dict(challenge="trial", ownerStart=dict(pid=20, birth=50, window=80), fixture=dict(CDHash="abc"),
                           independentTraceExit=0, fixtureJournal=dict(status="PASS", sameBoot=True, archive=dict(
                               originalSpace=4, knownActions=[dict(event=e, uptime=t, space=19 if t < 20 else 4,
                                                                  owner="signedOrdinaryFixture") for e, t in events])))
        self.samples = [dict(event="sample", start=t, end=t+.1, space=s, spaceHits=1, homeHits=int(s == 4))
                        for t,s in [(6,4),(7,4),(12,19),(13,19),(22,4),(23,4)]]

    def evaluate(self, samples):
        raw = b"".join(json.dumps(x).encode() + b"\n" for x in
                       [self.header, *samples, dict(event="closed", samples=len(samples))])
        (self.work / "independent-membership.jsonl").write_bytes(raw)
        self.report["independentTraceSHA256"] = hashlib.sha256(raw).hexdigest()
        return membership_trace.evaluate(self.work, self.report)

    def test_independent_park_reads_must_precede_real_return_intent(self):
        self.assertEqual(self.evaluate(self.samples)["status"], "PASS")
        self.assertEqual(self.evaluate([s for s in self.samples if s["space"] != 19])["status"], "UNKNOWN")
        self.samples[3].update(start=19.99, end=20.01)
        self.assertEqual(self.evaluate(self.samples)["status"], "UNKNOWN")

    def test_reused_window_or_disagreement_cannot_supply_membership(self):
        self.header["birth"] = 51
        self.assertEqual(self.evaluate(self.samples)["status"], "UNKNOWN")
        self.header["birth"] = 50
        self.samples[3].update(space=4, homeHits=1)
        self.assertEqual(self.evaluate(self.samples)["status"], "FAIL")
        self.samples[3].update(space=19, homeHits=1)
        self.assertEqual(self.evaluate(self.samples)["status"], "UNKNOWN")

    def test_transparent_round_trip_never_proves_visible_window_or_input_isolation(self):
        self.evaluate(self.samples)
        snapshot = dict(status="PASS", scope={"status":"PASS"}, membership={"status":"PASS"}, dock={"pid":1},
                        cgFrame=[0,0,10,10], axFrame=[0,0,10,10], samples=[dict(managedRows=[4])]*2,
                        focus=dict(workspacePID=7,birth=5,cgWindowID=3))
        self.report.update(status="PASS", independentBefore=snapshot, independentAfter=snapshot)
        importlib.import_module("sample-membership").finish_membership_cycle(self.work, self.report)
        self.assertEqual(self.report["thirdPartyMembershipRoundTrip"], "PASS")
        self.assertEqual(self.report["singleWindowHideRestore"], "NOT_RUN")

    def test_boolean_cannot_impersonate_windowserver_count(self):
        self.samples[3]["spaceHits"] = True
        self.assertEqual(self.evaluate(self.samples)["status"], "UNKNOWN")
