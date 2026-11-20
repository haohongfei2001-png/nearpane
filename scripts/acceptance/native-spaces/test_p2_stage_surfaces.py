import copy
import json
from pathlib import Path
from unittest import TestCase
from unittest.mock import Mock, patch

from contract_workspace import empty_system_desktop
from p2_stage_surfaces import CATEGORY, fresh_ordinary_reader, lease_enrollment
from space_scope import ScopeError


class StageSurfaceTests(TestCase):
    def setUp(self):
        self.ws = Mock(boot="boot-1", display="display-1", host={"pid":51,"codeHash":"a"*40}, host_birth=1001)
        self.key = dict(space=9, spaceUUID="space-9")
        self.rows = [dict(number=i, pid=81, ownerBirth=1100, bounds=box, admitted=True, category=CATEGORY,
                          listedAsOwnDocument=False, publicOnscreen=False, pixels=0)
                     for i,box in ((117,[1355,446,99,97]), (19015,[1352,446,103,97]))]
        self.on = [dict(uptime=t, ordinary=0, unresolved=0, inactiveStageSurfaces=copy.deepcopy(self.rows)) for t in (1,2)]
        self.enrolled = self.enroll()
        self.members = [dict(pid=r["pid"],number=r["number"]) for r in self.rows]
        self.observer = Path("/private/tmp/nearpane-d01.fixture/observe")
        self.ws.check.return_value = dict(current=9)
        self.ws.read.side_effect = [dict(uptime=t, scopedMembers={"9":dict(ordinary=self.members, unresolved=0,
                                                     otherDetails=[], otherMembers=0)}) for t in (3,4)]

    def enroll(self):
        return lease_enrollment(self.ws, 9, "space-9", True, self.on)

    def reply(self, present=None, clock=5):
        ids = [r["number"] for r in self.rows]
        present = ids if present is None else present
        return dict(status="READ",scope=self.enrolled["key"],stageEnabled=False,uptime=clock,pixels=0,
                    surfaces=[dict(**r, cgOnscreenListed=False, appKitListed=False, forwardAndReverse=True)
                              for r in self.rows if r["number"] in present],
                    departed=sorted(set(ids)-set(present)))

    @staticmethod
    def proc(reply):
        return Mock(returncode=0, stdout=json.dumps(reply))

    def test_capture_pid_on_two_stage_on_reads_using_existing_reader(self):
        # Existing signed binary verifies the request's manager PID, originally omitted it from its response.
        def old_reader(cmd, *, input, **kwargs):
            self.assertEqual(cmd[-1],"inactive-stage-surface")
            q=json.loads(input)
            return json.dumps({k:v for k,v in next(r for r in self.rows if r["number"]==q["number"]).items() if k!="pid"})
        self.ws.kit=Path("/private/tmp/old-kit")
        with patch("contract_workspace.subprocess.check_output",side_effect=old_reader), patch("contract_workspace.time.sleep"):
            evidence = empty_system_desktop(self.ws, 9)
        fresh = lease_enrollment(self.ws, 9, "space-9", True, evidence)
        self.assertEqual(fresh["surfaces"],self.enrolled["surfaces"])

    def test_off_revalidates_every_member_twice_in_new_signed_reader(self):
        record=Mock()
        check=fresh_ordinary_reader(self.ws,self.key,self.enrolled,self.observer,record)
        with patch("p2_stage_surfaces.subprocess.run",side_effect=[self.proc(self.reply(clock=5)),self.proc(self.reply(clock=6))]) as native, patch("contract_workspace.time.sleep"):
            result=empty_system_desktop(self.ws,9,check_ordinary=check)
        self.assertEqual(len(result),2)
        self.assertEqual(record.call_count,2)
        for call in native.call_args_list:
            self.assertEqual(call.args[0],[self.observer,"p2-stage-surface"])
            q=json.loads(call.kwargs["input"])
            self.assertEqual(q["enrolled"],self.enrolled["surfaces"])
            self.assertEqual(q["present"],[117,19015])
            self.assertNotIn("CFFIXED_USER_HOME",call.kwargs["env"])
        self.assertTrue(all(r["ordinary"]==0 and len(r["inactiveStageSurfaces"])==2 for r in result))

    def test_fails_before_reading_an_unenrolled_member(self):
        with patch("p2_stage_surfaces.subprocess.run") as native:
            for members, enrollment in (([{"number":999,"pid":81}],self.enrolled),
                                        ([{"number":117,"pid":82}],self.enrolled),
                                        (self.members,None),(self.members*2,self.enrolled)):
                with self.subTest(members=members),self.assertRaises(ScopeError):
                    fresh_ordinary_reader(self.ws,self.key,enrollment,self.observer)(members)
            native.assert_not_called()

    def test_original_on_proof_must_bind_same_owner_bounds_clock_lease_and_host(self):
        for field,val in (("pid",99),("ownerBirth",77),("bounds",[1355,446.25,99,97]),("number",312),
                          ("listedAsOwnDocument",True),("publicOnscreen",True)):
            with self.subTest(field=field):
                changed=copy.deepcopy(self.on)
                changed[1]["inactiveStageSurfaces"][0][field]=val
                with self.assertRaises(ScopeError):lease_enrollment(self.ws,9,"space-9",True,changed)
        for key,val in (("boot","boot-2"),("hostBirth",777),("hostPID",99),("hostHash","changed"),("space",10),
                        ("spaceUUID","changed"),("display","changed")):
            changed=copy.deepcopy(self.enrolled);changed["key"][key]=val
            with self.subTest(key=key),self.assertRaises(ScopeError):fresh_ordinary_reader(self.ws,self.key,changed,self.observer)
        with self.assertRaises(ScopeError):lease_enrollment(self.ws,9,"space-9",False,self.on)
        with self.assertRaises(ScopeError):lease_enrollment(self.ws,9,"space-9",True,[self.on[0]]*2)

    def test_rejects_native_unknown_pid_birth_bounds_ax_and_either_public_visibility(self):
        for field,val in (("pid",91),("ownerBirth",3001),("bounds",[1355,446,99.5,97]),("number",1),
                          ("cgOnscreenListed",True),("appKitListed",True),("listedAsOwnDocument",True),
                          ("publicOnscreen",True),("forwardAndReverse",False)):
            changed=self.reply();changed["surfaces"][0][field]=val
            with self.subTest(field=field),patch("p2_stage_surfaces.subprocess.run",return_value=self.proc(changed)),self.assertRaises(ScopeError):
                fresh_ordinary_reader(self.ws,self.key,self.enrolled,self.observer)(self.members)
        failure={"status":"BLOCKED","reason":"windowManagerAXNumberUnavailable"}
        record=Mock()
        with patch("p2_stage_surfaces.subprocess.run",return_value=self.proc(failure)),self.assertRaisesRegex(ScopeError,"AXNumberUnavailable"):
            fresh_ordinary_reader(self.ws,self.key,self.enrolled,self.observer,record)(self.members)
        record.assert_called_once_with("P2-stage-off-ordinary-census",**failure)

    def test_no_stage_on_reference_only_allows_a_genuinely_empty_desktop(self):
        response=self.reply(present=[]);response["departed"]=[]
        with patch("p2_stage_surfaces.subprocess.run",return_value=self.proc(response)):
            self.assertEqual(fresh_ordinary_reader(self.ws,self.key,None,self.observer)([]),[])

    def test_positive_departure_only_after_independent_absence_and_two_equal_reads(self):
        departed=self.reply(present=[117])
        with patch("p2_stage_surfaces.subprocess.run",return_value=self.proc(departed)):
            kept=fresh_ordinary_reader(self.ws,self.key,self.enrolled,self.observer)(self.members[:1])
        self.assertEqual([r["number"] for r in kept],[117])
        changed=copy.deepcopy(departed);changed["departed"]=[]
        with patch("p2_stage_surfaces.subprocess.run",return_value=self.proc(changed)),self.assertRaises(ScopeError):
            fresh_ordinary_reader(self.ws,self.key,self.enrolled,self.observer)(self.members[:1])
        self.ws.read.side_effect=[dict(uptime=t,scopedMembers={"9":dict(ordinary=members,unresolved=0,otherMembers=0,otherDetails=[])})
                                  for t,members in ((3,self.members),(4,self.members[:1]))]
        check=fresh_ordinary_reader(self.ws,self.key,self.enrolled,self.observer)
        with patch("p2_stage_surfaces.subprocess.run",side_effect=[self.proc(self.reply(clock=4)),self.proc(departed)]),patch("contract_workspace.time.sleep"),self.assertRaisesRegex(ScopeError,"surfaces changed"):
            empty_system_desktop(self.ws,9,check_ordinary=check)

    def test_replayed_native_clock_or_stage_on_is_not_admitted(self):
        response=self.reply()
        check=fresh_ordinary_reader(self.ws,self.key,self.enrolled,self.observer)
        with patch("p2_stage_surfaces.subprocess.run",return_value=self.proc(response)):
            check(self.members)
            with self.assertRaisesRegex(ScopeError,"staleStageSurfaceCensus"):check(self.members)
        response["stageEnabled"]=True
        with patch("p2_stage_surfaces.subprocess.run",return_value=self.proc(response)),self.assertRaises(ScopeError):
            fresh_ordinary_reader(self.ws,self.key,self.enrolled,self.observer)(self.members)
