import copy
from pathlib import Path
import json
import subprocess
import tempfile
import types
import unittest
from unittest.mock import Mock

import lease_visit as v
from contract_workspace import stats
from space_scope import ScopeError


def receipt():
    return dict(status="BLOCKED",entry="NOT_RUN",childStarted=False,restoration="NOT_NEEDED")

class VisitTests(unittest.TestCase):
    def test_only_independently_arrived_lease_runs_child_and_both_routes_are_distinct(self):
        n=Mock(); events=[]
        for m in ("construct","make_anchor","enter","restore","finish_readers"):
            getattr(n,m).side_effect=lambda *a,m=m:events.append(m)
        def product(): events.append("product"); return 2
        result=v.journey(n,product,receipt(),lambda:None)
        self.assertEqual(events,["construct","make_anchor","enter","product","restore","finish_readers"])
        self.assertEqual((result["status"],result["childExit"],result["restoration"]),("PASS",2,"PASS"))

    def test_unbound_daily_generation_permits_zero_gestures(self):
        n=Mock();n.construct.side_effect=ScopeError("dailyHostWindowWillChangeProcessGeneration")
        result=v.journey(n,lambda:self.fail("child"),receipt(),lambda:None)
        self.assertEqual(result["reason"],"dailyHostWindowWillChangeProcessGeneration")
        n.make_anchor.assert_not_called();n.enter.assert_not_called();n.restore.assert_not_called()

    def test_failed_apple_list_is_retained_and_never_replayed(self):
        n=Mock();n.enter.side_effect=ScopeError("first-list: signed single-display system desktop list count 0")
        result=v.journey(n,lambda:self.fail("child"),receipt(),lambda:None)
        self.assertEqual((result["status"],result["reason"],result["restoration"]),("BLOCKED","signedAppleDesktopListUnavailable","PASS"))
        n.enter.assert_called_once();n.restore.assert_called_once()

    def test_unreturned_or_superseded_focus_cannot_pass(self):
        for reason in ("newHumanInput","unclassifiedSpaceOrNewForegroundPreserved","exactOriginalFocusDidNotReturn"):
            n=Mock();n.restore.side_effect=ScopeError(reason)
            result=v.journey(n,lambda:0,receipt(),lambda:None)
            self.assertEqual((result["status"],result["childExit"],result["returnReason"]),("UNKNOWN",0,reason))
            n.restore.assert_called_once();n.retire_after_refusal.assert_called_once()

    def test_failed_child_launch_still_returns_to_original(self):
        n=Mock()
        out=v.journey(n,Mock(side_effect=OSError("spawn failed")),receipt(),lambda:None)
        self.assertEqual(out["status"],"BLOCKED");self.assertEqual(out["restoration"],"PASS")
        n.restore.assert_called_once()

    def test_descendant_with_lease_is_not_raced_by_recovery(self):
        n=Mock();s=receipt()
        with self.assertRaises(subprocess.TimeoutExpired):
            v.journey(n,Mock(side_effect=subprocess.TimeoutExpired("owned trial",1)),s,lambda:None)
        self.assertEqual(s["restoration"],"UNKNOWN")
        n.restore.assert_not_called()

    def test_return_can_only_address_registered_target_then_exact_origin(self):
        n=v.NativeVisit({}, {}, None, Mock());n.origin=6;n.target=5095;n.process=Mock();n.process.poll.return_value=None
        n.authenticated=Mock();n.close_owned=Mock();n.anchor_focus=Mock();n.original=Mock()
        a,b=n.anchor_focus,n.original
        a.finish.return_value=b.finish.return_value={"issued":True,"restored":True}
        n.ws=types.SimpleNamespace(host={"pid":55},host_birth=20)
        def reading(space,which):
            return dict(current=space,originBound=True,primaryAnchorExact=which=="anchor",anchorExact=which=="anchor",originExact=which=="original",
                        appleIdle=which=="idle",anchors=2,systemFocus={"pid":607,"birth":10,"number":None})
        target,anchor,original=reading(5095,"idle"),reading(6,"anchor"),reading(6,"original")
        n.paired_sample=Mock(side_effect=[target,anchor,anchor,original,original]);n.restore()
        a.finish.assert_called_once_with(True,5095,expected=target)
        b.finish.assert_called_once_with(True,expected=anchor)
        n.close_owned.assert_called_once()
        for unsafe in [reading(5094,"idle"),reading(5095,"outside")]:
            n.anchor_focus=a;n.original=b;n.paired_sample=Mock(return_value=unsafe)
            with self.assertRaises(ScopeError):n.restore()
        self.assertEqual(a.finish.call_count,1);self.assertEqual(b.finish.call_count,1)

    def test_return_after_refused_entry_never_dispatches_cross_space_activation(self):
        n=v.NativeVisit({}, {}, None, Mock());n.origin=6;n.target=5095;n.process=Mock()
        n.authenticated=Mock();n.close_owned=Mock();n.anchor_focus=Mock();n.original=Mock();n.ws=types.SimpleNamespace(host={},host_birth=0)
        current=dict(current=6,originExact=True,primaryAnchorExact=False,anchorExact=False,appleIdle=False,anchors=0)
        n.paired_sample=Mock(return_value=current);n.restore()
        n.original.finish.assert_not_called();n.anchor_focus.finish.assert_not_called()

    def test_both_local_anchor_windows_must_be_exclusively_on_the_actual_origin_before_activation(self):
        a=dict(pid=9,birth=500,number=41,standard=True,forward=True,reverse=[4])
        b=dict(a,number=42);self.assertTrue(v.ordinary_anchor_rows([a,b],(9,500),[41,42],4))
        for change in (dict(reverse=[4,6]),dict(forward=False),dict(birth=501),dict(standard=False),dict(number=41)):
            self.assertFalse(v.ordinary_anchor_rows([a,{**b,**change}],(9,500),[41,42],4))
        self.assertFalse(v.ordinary_anchor_rows([a,b],(9,500),[41,42],6))

    def test_historical_reference_distinguishes_anchor_return_from_exact_focus_restore(self):
        bundle,h=v.archive_anchor()
        self.assertEqual(bundle.name,"Lifecycle Window.app");self.assertEqual(len(h),40)
        rows=[json.loads(l) for l in (v.REFERENCE/"actions.jsonl").read_text().splitlines()]
        self.assertEqual(next(r["source"] for r in rows if r["event"]=="owned-ordinary-source"),6)
        restored=json.loads((v.REFERENCE/"results.json").read_bytes())["cleanup"]["originalFocusRestoration"]
        self.assertTrue(restored["issued"])

    def test_report_does_not_publish_native_unclassified_member_metadata(self):
        why=v.safe_reason(ScopeError('WindowServer could not establish an empty desktop: {"private":"secret"}'))
        self.assertEqual(why,"nativeDestinationCensusNotEmpty")
        self.assertNotIn("secret",v.safe_reason(OSError("/secret")))

    def test_full_pair_chain_holds_order_requires_both_permissions_and_no_removal(self):
        display=dict(uuid="00000000-0000-0000-0000-000000000001",bounds=[0,0,100,100],rotation=0,scale=1)
        records=[dict(id=n,type=0,uuid="00000000-0000-0000-0000-"+str(n).zfill(12)) for n in (4,6,5094,5095)]
        def live(count):return {"scopes":[dict(scope=display["uuid"],current=6,records=records[:count])],"displays":[display]}
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp).resolve();paths=[]
            for i in (2,3):
                p=root/str(i)/"created.json";p.parent.mkdir()
                intent=dict(boot="sameBoot",display=display["uuid"],initial=stats(live(i)["scopes"][0],display))
                e=dict(intent=intent,target=str(records[i]["id"]),after=stats(live(i+1)["scopes"][0],display))
                for file,entry in ((p,e),(p.with_name("create-intent.json"),intent)):
                    file.write_text(json.dumps(entry));file.chmod(0o600)
                paths.append(p)
            ws=types.SimpleNamespace(closed=[],ledgers=paths,ids=lambda:[5094,5095],original=live(2),boot="sameBoot",display=display["uuid"])
            self.assertEqual(v.verify_chain(ws,live(4),5095),[5094,5095])
            changed=copy.deepcopy(live(4));changed["scopes"][0]["records"].reverse()
            with self.assertRaises(ScopeError): v.verify_chain(ws,changed,5095)
            paths[-1].with_name("remove-intent.json").touch()
            with self.assertRaises(ScopeError): v.verify_chain(ws,live(4),5095)

if __name__ == "__main__": unittest.main()
