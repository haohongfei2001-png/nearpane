"""Run with python3 scripts/acceptance/native-spaces/test_space_trials.py. No GUI actions."""
from copy import deepcopy
import hashlib
import json
from pathlib import Path
import tempfile
import unittest
import uuid
from unittest.mock import patch

import space_scope as gates
from space_trials import observed_order, scenarios

def uid():
    return str(uuid.uuid4()).upper()

def private(path, data):
    path.write_text(json.dumps(data))
    path.chmod(0o600)
    return path

class SpaceLeaseTests(unittest.TestCase):
    def setUp(self):
        home = tempfile.TemporaryDirectory()
        self.addCleanup(home.cleanup)
        self.root = Path(home.name).resolve()
        self.ledgers = self.root / "native-creation-ledgers"
        monkey = patch.object(gates, "LEDGERS", self.ledgers)
        monkey.start()
        self.addCleanup(monkey.stop)
        self.display, self.boot = uid(), uid()
        host = dict(pid=100, launch=50.25, codeHash="a"*40)
        self.scope = dict(schema=1, session=uid(), host=host, display=self.display, spaces=[], witnesses=[],
                          boot=self.boot, expiresUptime=150)
        self.path = self.root / "trial.json"
        self.records = []
        def record(n, kind):
            self.records.append(dict(id=n, uuid=uid(), type=kind))
        record(40, 4)  # unrelated fullscreen Space before all leased destinations
        record(30, 0)  # user's original ordinary Space
        def ledger_state():
            return dict(sideOrder=[str(r["id"]) for r in self.records],
                        spaceUUIDs={str(r["id"]):r["uuid"] for r in self.records}, fullscreenIDs=["40"],
                        geometry=[self.display+":{{0, 0}, {800, 1280}}:90.0:2.0"], primaryScope=None)
        for n in (41, 42, 43):
            before = ledger_state()
            record(n, 0)
            intent = dict(display=self.display, operation=uid(), source=before["sideOrder"][-1],
                          issuedUptime=n, initial=before, boot=self.boot)
            ledger = self.ledgers / uid() / "provision"
            ledger.mkdir(parents=True)
            private(ledger/"create-intent.json", intent)
            made = private(ledger/"created.json", dict(target=str(n), intent=intent, after=ledger_state()))
            self.scope["spaces"].append(dict(id=n, uuid=self.records[-1]["uuid"], receipt=str(made),
                                             sha256=hashlib.sha256(made.read_bytes()).hexdigest()))
        self.obs = dict(host=host, installedHostCount=1, observerAX=True, windowListAvailable=True, uptime=100,
                        scopes=[dict(scope=self.display, current=41, records=self.records)],
                        displays=[dict(uuid=self.display,bounds=[0,0,800,1280],rotation=90,scale=2,main=True)],
                        otherLayerZeroMemberships=dict(unresolved=0,counts={}),
                        sidebar=dict(rows=[dict(identifier=f"native-space-row:{self.display}:{r['id']}", matches=1,
                                                 currentLabel=r["id"]==41) for r in self.records]))
    def load(self):
        return gates.load_scope(private(self.path, self.scope), self.obs, self.boot, 100)

    def test_contiguous_leases_with_unrelated_fullscreen_and_personal_desktop(self):
        scope = self.load()
        self.assertEqual(gates.validate_live(scope, self.obs, scope["host"]), 41)
        self.assertEqual([s["id"] for s in scope["spaces"]], [41, 42, 43])

    def test_cannot_authorize_existing_space_by_substituting_its_uuid_and_id(self):
        self.scope["spaces"][0].update(id=30, uuid=self.records[1]["uuid"])
        with self.assertRaisesRegex(gates.ScopeError, "new Space"):
            self.load()

    def test_scope_requires_original_private_creation_evidence(self):
        self.scope["spaces"][0]["sha256"] = "0"*64
        with self.assertRaisesRegex(gates.ScopeError, "digest"):
            self.load()

    def test_replaced_host_unknown_window_and_reordered_space_refused(self):
        scope = self.load()
        for event in ("host", "window", "order", "expired", "geometry", "unknown-member", "user"):
            with self.subTest(event=event):
                sample = deepcopy(self.obs)
                if event == "host":
                    sample["host"]["launch"] += 1
                elif event == "window":
                    sample["otherLayerZeroMemberships"]["counts"]["43"]=1
                elif event == "order":
                    sample["scopes"][0]["records"].reverse()
                elif event == "expired":
                    sample["uptime"] = scope["expiresUptime"]
                elif event == "geometry":
                    sample["displays"][0]["rotation"] = 0
                elif event == "unknown-member":
                    sample["otherLayerZeroMemberships"]["unresolved"]=1
                else:
                    sample["scopes"][0]["current"]=30
                with self.assertRaises(gates.ScopeError):
                    gates.validate_live(scope,sample,scope["host"])

    def test_test_space_entered_removal_cannot_be_reused(self):
        private(Path(self.scope["spaces"][1]["receipt"]).with_name("remove-intent.json"), {})
        with self.assertRaisesRegex(gates.ScopeError, "removal"):
            self.load()

    def test_witness_cannot_be_redeclared_on_empty_desktop(self):
        self.scope["witnesses"]=[dict(number=42, pid=22, birth=7, space=42, bundleID="net.example.spaces-document",
                                      bundlePath="/private/tmp/run/Field Notes.app", codeHash="b"*40)]
        with self.assertRaisesRegex(gates.ScopeError, "attestation"):
            self.load()

    def test_fullscreen_or_gap_among_leased_spaces_rejects_before_input(self):
        self.records[-2]["type"] = 4
        with self.assertRaisesRegex(gates.ScopeError, "inventory"):
            self.load()
        self.records[-2]["type"] = 0
        self.scope["spaces"].pop(1)
        with self.assertRaises(gates.ScopeError):
            self.load()

    def test_s03_allows_only_reorders_inside_original_leased_slots(self):
        scope = self.load()
        own = deepcopy(self.obs)
        rows = own["scopes"][0]["records"]
        rows[2], rows[3] = rows[3], rows[2]
        self.assertNotEqual(observed_order(scope, own), scope["_shape"])
        rows[0], rows[2] = rows[2], rows[0]
        with self.assertRaisesRegex(gates.ScopeError, "non-test Space"):
            observed_order(scope, own)

    def test_all_transitions_and_rapid_group_denominators(self):
        ids=[4,5,6]
        single, rapid=scenarios(ids)
        self.assertEqual(len(single),50)
        self.assertEqual(set(zip([4]+single[:-1],single)),{(x,y) for x in ids for y in ids if x!=y})
        self.assertEqual(single[-1],4)
        self.assertEqual(len(rapid),20)
        prev=4
        for n, group in enumerate(rapid):
            self.assertEqual(len(group),3+n%3)
            self.assertNotEqual(prev,group[-1])
            self.assertTrue(all(x!=y for x,y in zip([prev]+group[:-1],group)))
            prev=group[-1]

if __name__ == "__main__":
    unittest.main()
