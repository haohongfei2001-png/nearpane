"""Offline fixtures for isolated creation, exact occupancy and crash-safe recovery."""
from copy import deepcopy
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock

from contract_workspace import Workspace, addition, write_owned
from core_contract import occupancy_matches
from space_scope import ScopeError


class WorkspaceTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()
        self.display = "display"
        self.originals = [dict(id=4,type=0,uuid="A"),dict(id=2000,type=4,uuid="B"),dict(id=5,type=0,uuid="C")]
        self.extra = dict(id=4829,type=0,uuid="D")
        self.live = self.snapshot([*self.originals,self.extra], 5)
        self.ledger = self.root / "created.json"
        write_owned(self.ledger, dict(target="4829",after={"spaceUUIDs":{"4829":"D"}}))
        w = Workspace.__new__(Workspace)
        w.output = self.root / "results"
        w.home, w.display, w.record, w.host = 2000, self.display, Mock(), self.live["host"]
        w.original = self.snapshot(self.originals, 2000)
        w.protected = w.original["scopes"][0]["records"]
        w.closed, w.ledgers, w.boot = [], [self.ledger], "boot-fixture"
        w.cleanup_current, w.cleanup_focus, w.recovering = 5, self.live, False
        w.read = lambda: deepcopy(self.live)
        w.select = Mock(side_effect=AssertionError("must preserve newer protected foreground"))
        self.ws = w

    def snapshot(self, records, current):
        return dict(scopes=[dict(scope=self.display,records=deepcopy(records),current=current)],
                    displays=[dict(uuid=self.display)],host=dict(pid=112,codeHash="abc"),
                    frontmostPID=32, focusedNumber=19,
                    scopedMembers={"4829":dict(ordinary=[],otherMembers=0,unresolved=0)})

    def test_fullscreen_interior_origin_preserves_arbitrary_personal_desktop_order(self):
        new=[*self.originals[:2],self.extra,self.originals[2]]
        self.assertEqual(addition(self.originals, new), self.extra)
        with self.assertRaises(ScopeError):
            addition(self.originals, list(reversed(new)))
        with self.assertRaises(ScopeError):
            addition(self.originals, [*self.originals, {**self.extra,"uuid":"B"}])

    def test_unknown_elsewhere_does_not_erase_positive_target_member_evidence(self):
        sample=deepcopy(self.live)
        sample["otherLayerZeroMemberships"]={"unresolved":97}
        self.assertTrue(occupancy_matches(sample,{4829:[]}))
        for key, value in [("ordinary",[{"number":990,"pid":400}]),("unresolved",1),("otherMembers",2)]:
            c=deepcopy(sample); c["scopedMembers"]["4829"][key]=value
            self.assertFalse(occupancy_matches(c,{4829:[]}))

    def test_cleanup_preserves_latest_personal_order_and_rejects_reused_ids(self):
        live=self.snapshot([self.originals[1],self.originals[0],self.originals[2],self.extra], 5)
        self.ws.bind_protected_order(live)
        self.assertEqual([r["id"] for r in self.ws.protected],[2000,4,5])
        self.ws.check(live)
        damaged=deepcopy(live)
        damaged["scopes"][0]["records"][-1]["uuid"]="different"
        with self.assertRaisesRegex(ScopeError,"reused"):
            self.ws.bind_protected_order(damaged)

    def test_unknown_dispatched_removal_is_not_replayed(self):
        pending=self.root/"remove-intent.json"
        write_owned(pending, dict(target=4829,boot=self.ws.boot,operation="00000000-0000-4000-8000-000000000002",expected=self.originals))
        self.ws.command=Mock(side_effect=AssertionError("never issue a duplicate removal"))
        result=self.ws.cleanup()
        self.assertEqual(result["outstanding"],[4829])
        self.assertIn("unknown delivery",result["errors"][0])
        self.assertEqual(result["cleanupCurrent"],5)
        self.ws.command.assert_not_called()

    def test_privately_owned_or_unclassified_member_blocks_all_mutation(self):
        self.live["scopedMembers"]["4829"]["otherMembers"]=1
        self.ws.command=Mock()
        result=self.ws.cleanup()
        self.assertFalse(result["topologyRestored"])
        self.assertTrue(result["retainedUserSelectedSpace"])
        self.ws.command.assert_not_called()

    def test_already_completed_removal_reconciles_without_input(self):
        self.live["scopes"][0]["records"]=deepcopy(self.originals)
        pending=self.root/"remove-intent.json"
        write_owned(pending,dict(target=4829,boot="boot-fixture",operation="00000000-0000-4000-8000-000000000001",expected=self.originals))
        self.ws.command=Mock()
        result=self.ws.cleanup()
        self.assertTrue(result["topologyRestored"])
        self.assertEqual(result["removed"],1)
        self.assertEqual(result["outstanding"],[])
        self.ws.command.assert_not_called()
        self.assertTrue(json.loads((self.root/"removed.json").read_text())["recovered"])


if __name__ == "__main__":
    unittest.main()
