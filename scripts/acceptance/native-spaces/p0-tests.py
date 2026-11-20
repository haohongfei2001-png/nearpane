"""Offline regression of installed-journal correlation and fail-closed stage gates."""
import importlib.util
from pathlib import Path
import unittest

p = Path(__file__).with_name('p0-cards.py')
spec = importlib.util.spec_from_file_location('p0_cards',p)
runner = importlib.util.module_from_spec(spec);spec.loader.exec_module(runner)


class GateTests(unittest.TestCase):
    display='81003808-1D22-41E2-B86D-A721C1709294'
    uuids=['C4051EB7-67CF-4F62-A737-B0DE9E73EDA2','5C9D440D-85FC-4EE1-A0A6-0CC3C1D60BCD']
    operation='6D76AE37-CE2F-4781-8C7E-8746E5AE170A'
    def setUp(self):
        self.rows=[dict(id=i+4,type=0,uuid=u) for i,u in enumerate(self.uuids)]
        self.top=dict(display=self.display,current=4,records=self.rows)
        self.win=dict(pid=89,birth=10011,number=77)
        self.req=dict(topology=self.top,target=5,targetWindow=self.win,hid=[8])
        self.ax=dict(issued=True,axError=0)
        self.intent=dict(action='select',id=self.operation,display=self.display,source='4',target='5',sourceUUID=self.uuids[0],targetUUID=self.uuids[1],window=self.win.copy(),createdAtUptime=10.1)
        self.reply=dict(id=self.operation,state='confirmed',submittedSteps=1,currentBefore={self.display:'4'},currentAfter={self.display:'5'},issuedAtUptime=10.2,confirmedAtUptime=11.3,
                        switchTrace=dict(adapter=27,phasesMachTicks=[3,6,9],observations=[dict(currents={self.display:'5'})]))
    def proof(self): return runner.match_receipt(dict(intent=self.intent,result=self.reply),self.operation+'.json',self.req,10)
    def samples(self):return [dict(uptime=10+i*.1,topology=dict(self.top,current=4 if i<3 else 5),hid=[8]) for i in range(26)]
    def score(self,samples,proof):return runner.assess(samples,self.req,10,proof,self.ax)[0]
    def test_journal_and_independent_landing_required(self):
        self.assertEqual(self.score(self.samples(),self.proof()),'PASS')
        self.assertEqual(self.score(self.samples(),None),'UNKNOWN')
    def test_clip_delayed_coverage(self): self.assertEqual(self.score(self.samples()[:5],self.proof()),'UNKNOWN')
    def test_detects_reversal_even_when_terminal_claims_pass(self):
        v=self.samples();v[-1]['topology']['current']=4;self.assertEqual(self.score(v,self.proof()),'FAIL')
    def test_foreign_landing_before_correct_arrival(self):
        v=self.samples();v[1]['topology']['current']=9;self.assertEqual(self.score(v,self.proof()),'FAIL')
    def test_gap_or_physical_input_keeps_sample_unknown(self):
        v=self.samples();self.assertEqual(self.score(v[:3]+v[15:],self.proof()),'UNKNOWN');v[-1]['hid']=[9];self.assertEqual(self.score(v,self.proof()),'UNKNOWN')
    def test_reused_window_number_with_different_birth_denied(self):
        self.intent['window']['birth']+=1
        with self.assertRaises(ValueError):self.proof()
    def test_out_of_order_phase_not_dispatch_evidence(self):
        self.reply['switchTrace']['phasesMachTicks']=[4,8,5];self.assertFalse(self.proof()['phaseEvidence'])
    def test_topology_insertion_cannot_reorder_private_spaces(self):
        extra=dict(id=99,type=4,uuid=self.operation)
        self.assertEqual(runner.owned_insertion(self.top,dict(self.top,records=[*self.rows,extra]),4),99)
        with self.assertRaises(ValueError):runner.owned_insertion(self.top,dict(self.top,records=[*reversed(self.rows),extra]),4)
    def test_system_assigned_ordinary_requires_both_exact_window_memberships(self):
        original=dict(self.top,records=[dict(self.rows[0],type=4),self.rows[1]])
        assigned=dict(original,current=5)
        claims=[dict(number=n,standard=True,forward=True,reverse=[5]) for n in (77,78)]
        self.assertTrue(runner.assigned_ordinary(original,assigned,[77,78],claims))
        self.assertFalse(runner.assigned_ordinary(original,original,[77,78],claims))
        claims[1]['reverse']=[4,5]
        self.assertFalse(runner.assigned_ordinary(original,assigned,[77,78],claims))
    def test_registered_targets_must_be_new_and_physically_consecutive(self):
        first=dict(id=81,uuid=self.operation,type=0)
        second=dict(id=82,uuid='5EBBD09D-DF27-4DFB-8771-0D3C2B4B8E6B',type=0)
        inserted=dict(self.top,records=[*self.rows,first])
        self.assertEqual(runner.confirm_lease_pair(self.top,inserted,dict(self.top,records=[*self.rows,first,second])),(81,82))
        with self.assertRaises(ValueError):
            runner.confirm_lease_pair(self.top,inserted,dict(self.top,records=[self.rows[0],second,self.rows[1],first]))
    def test_stops_before_larger_stage_and_exact_nearest_rank(self):
        self.assertEqual(runner.gate_status([dict(status='PASS')],2),'BLOCKED');self.assertEqual(runner.gate_status([dict(status='PASS'),dict(status='FAIL')],2),'FAIL')
        self.assertEqual(runner.gate_status([dict(status='PASS')]*10,10),'PASS');self.assertEqual(runner.percentile(list(range(1,51)),.95),48)
    def test_missing_physical_visual_does_not_prevent_one_round_trip_but_blocks_fifty(self):
        first=dict(samples=[dict(status='PASS')]*2,blankScreen='UNKNOWN')
        runner.evaluate_gate(first,'roundTrip',2);self.assertEqual(first['status'],'PASS')
        ten=dict(samples=[dict(status='PASS')]*10,blankScreen='UNKNOWN')
        runner.evaluate_gate(ten,'ten',10);self.assertEqual((ten['navigationStatus'],ten['status']),('PASS','BLOCKED'))
    def test_real_black_fails_without_misrepresenting_navigation(self):
        ten=dict(samples=[dict(status='PASS',navigationStatus='PASS',blankScreen='PASS') for _ in range(10)])
        runner.evaluate_gate(ten,'ten',10);self.assertEqual(ten['status'],'PASS')
        ten['samples'][-1].update(status='FAIL',blankScreen='FAIL')
        runner.evaluate_gate(ten,'ten',10);self.assertEqual((ten['navigationStatus'],ten['blankScreen'],ten['status']),('PASS','FAIL','FAIL'))


if __name__=='__main__':unittest.main()
