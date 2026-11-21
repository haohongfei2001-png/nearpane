import copy
import hashlib
import json
from pathlib import Path
import tempfile
import unittest
from contextlib import ExitStack
from unittest.mock import Mock, patch

import contract_workspace as base
import lease_visit as v
from space_scope import ScopeError


class LeaseVisitOriginTests(unittest.TestCase):
    """Use the archived 6 -> [5094, 5095] shape and this visit's independent Space 4 origin."""
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.checks = ExitStack()
        self.addCleanup(self.checks.close)
        self.ledger_base = self.root / "build/verification/secondary-route-followup"
        self.wsdir = self.root / "workspace"
        self.wsdir.mkdir()
        self.display = dict(uuid="37D8832A-2D66-02CA-B9F7-8F30A301B230", bounds=[0, 0, 1470, 956], rotation=0, scale=2)
        self.records = [dict(id=n, type=0, uuid=u) for n, u in (
            (4, "0695C8A7-8344-4AEC-A780-2FE0562E63B9"), (6, "6E560DD4-C1B2-A5BA-DA23-02241E918293"),
            (5094, "ADDB79D9-E850-D8A6-8BF2-3D05595DAB68"), (5095, "745BC7CD-E201-1B68-D003-AB00E5D30C9D"))]
        self.hid = [5816, 71, 0, 3051, 140014, 3051, 113, 5816, 71, 0, 19224, 36, 0]
        self.events = []
        self.host = dict(pid=51, codeHash="fixture")
        baseline = self.snapshot(6, 2)
        base.write_owned(self.wsdir / "original.json", dict(baseline, boot="boot"))
        for offset, space in enumerate((5094, 5095), 2):
            folder = self.ledger_base / str(space) / "provision"
            folder.mkdir(parents=True)
            before, after = self.snapshot(6, offset), self.snapshot(6, offset+1)
            intent = dict(boot="boot", display=self.display["uuid"], initial=base.stats(base.row(before),self.display))
            made = dict(intent=intent, target=str(space), after=base.stats(base.row(after),self.display))
            path = folder / "created.json"
            base.write_owned(path, made)
            base.write_owned(folder / "create-intent.json", intent)
            base.write_owned(self.wsdir / f"desktop-{offset-1}.json", dict(receipt=str(path), sha256=hashlib.sha256(path.read_bytes()).hexdigest()))
        self.daily = dict(ready=True, pid=311, birth=1010, number=7, hid=self.hid,
                          topology=dict(display=self.display["uuid"], current=4, records=self.records))
        self.focus = Mock()
        self.focus.read.return_value = copy.deepcopy(self.daily)
        self.checks.enter_context(patch.object(v,"FocusReader", return_value=self.focus))
        self.checks.enter_context(patch.object(v,"instruments",return_value=(None, "fixture", {})))
        held = Mock()
        held.reply.return_value = dict(self.daily, held=True)
        self.checks.enter_context(patch.object(v.FOCUS,"OriginalFocus",return_value=held))
        self.read = self.checks.enter_context(patch.object(base.Workspace,"read",return_value=self.snapshot(4)))
        self.hardware = self.checks.enter_context(patch.object(base.Workspace,"hardware",return_value=self.hid[:5]))
        self.checks.enter_context(patch.object(base,"checked",side_effect=lambda cmd, **kw: "boot" if "sysctl" in cmd[0] else "42"))
        self.plan = dict(visitDailyOriginal=self.daily, visitFocusLeaseKit=str(self.root), focusLease=dict(
            expectedSpace=5095, workspace=str(self.wsdir), originalCheckout=str(self.root), originArchive=str(self.root), stageKit=str(self.root)))
        self.visit = v.NativeVisit(self.plan, dict(NEARPANE_TEST_GENERATION="/fixture/test"), None,
                                   lambda stage,**fields: self.events.append(dict(stage=stage,**fields)))
        self.visit.bind_profile = Mock()
        self.visit.paired_sample = Mock(return_value=dict(originExact=True))

    def snapshot(self, current, count=4):
        return dict(displays=[self.display], host=self.host, installedHostCount=1, observerAX=True,
                    scopes=[dict(scope=self.display["uuid"],current=current, records=copy.deepcopy(self.records[:count]))])

    def test_stable_live_four_binds_before_and_after_ledger_resume(self):
        self.assertEqual(self.visit.construct(), (4,5095))
        ws = self.visit.ws
        self.assertEqual(base.row(ws.original)["current"],6)
        self.assertEqual(ws.cleanup_current,4)
        self.assertEqual([e["observedCurrent"] for e in self.events if e["stage"]=="visitWorkspaceRead"],[4,4])
        self.assertEqual(self.events[-1]["source"],4)

    def test_either_init_read_on_historical_six_or_an_inactive_lease_blocks_before_ui(self):
        for wrong,index in [(6,0),(6,1),(5094,0),(5095,1)]:
            with self.subTest(wrong=wrong,index=index):
                self.events.clear()
                sequence = [self.snapshot(4),self.snapshot(4)]
                sequence[index] = self.snapshot(wrong)
                self.read.side_effect = sequence
                with self.assertRaisesRegex(ScopeError,"visitCurrentOutsideEnrolledRoute"):
                    self.visit.construct()
                self.visit.paired_sample.assert_not_called()
                last=self.events[-1]
                self.assertEqual((last["read"],last["enrolledOrigin"],last["observedCurrent"]),(index+1,4,wrong))
                self.assertFalse(last["targetIssued"])

    def test_scope_or_hardware_change_rejected_in_constructor_with_specific_diagnostic(self):
        for change,reason in (("physical","visitPhysicalOrInventoryDisplayUUIDChanged"),
                              ("scoped","visitPhysicalOrInventoryDisplayUUIDChanged"),("uuid","visitOrderedSpaceIdentityChanged"),
                              ("order","visitOrderedSpaceIdentityChanged"),("additional","visitPhysicalDisplayCountChanged")):
            with self.subTest(change=change):
                x=copy.deepcopy(self.snapshot(4))
                if change=="physical": x["displays"][0]["uuid"]=self.records[0]["uuid"]
                if change=="scoped": x["scopes"][0]["scope"]=self.records[0]["uuid"]
                if change=="uuid": x["scopes"][0]["records"][3]["uuid"]=self.records[0]["uuid"]
                if change=="order": x["scopes"][0]["records"].reverse()
                if change=="additional": x["displays"]*=2
                self.read.side_effect=[self.snapshot(4),x]
                with self.assertRaisesRegex(ScopeError,reason):
                    self.visit.construct()
                self.assertEqual(self.events[-1]["reason"],reason)
        self.read.side_effect=None
        self.hardware.return_value=[999,*self.hid[1:5]]
        with self.assertRaisesRegex(ScopeError,"newHumanInput"): self.visit.construct()
        self.assertEqual(self.events[-1]["stage"],"visitHardwareChanged")

    def test_full_13_hid_and_exact_foreground_must_match_before_loading_workspace(self):
        for field in ("hid","topology","number"):
            sample=copy.deepcopy(self.daily)
            if field=="hid": sample["hid"][-1]+=1
            if field=="topology": sample["topology"]["current"]=6
            if field=="number": sample["number"]+=1
            self.focus.read.return_value=sample
            with self.assertRaisesRegex(ScopeError,"dailyForegroundOrInputChangedDuringHostExchange"):
                self.visit.construct()
            self.assertEqual(self.events[-1]["stage"],"visitOriginCompared")
            self.read.assert_not_called()

    def test_after_enrollment_only_actual_receipt_can_admit_exact_target_and_never_another_space(self):
        self.visit.construct(); ws=self.visit.ws
        for n in (6,5094,5095):
            with self.assertRaisesRegex(ScopeError,"visitCurrentOutsideEnrolledRoute"):
                ws.check(self.snapshot(n),check_current=False)
        ws.record("system-AX-tile-result",source=4,target=5095,proof=dict(issued=False))
        with self.assertRaises(ScopeError): ws.check(self.snapshot(5095))
        ws.record("system-AX-tile-result",source=4,target=5094,proof=dict(issued=True))
        with self.assertRaises(ScopeError): ws.check(self.snapshot(5095))
        ws.record("system-AX-tile-result",source=4,target=5095,proof=dict(issued=True))
        self.assertEqual(ws.check(self.snapshot(5095))["current"],5095)
        for n in (6,5094):
            with self.assertRaises(ScopeError): ws.check(self.snapshot(n))
        self.assertEqual(ws.check(self.snapshot(4))["current"],4)
