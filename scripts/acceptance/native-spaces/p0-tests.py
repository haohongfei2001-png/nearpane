"""Offline regression of installed-journal correlation and fail-closed stage gates."""
import importlib.util
import hashlib
import json
import tarfile
from pathlib import Path
import tempfile
import unittest
from unittest import mock

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
        self.source=dict(pid=72,birth=10004,number=41)
        self.req=dict(topology=self.top,target=5,sourceWindow=self.source,targetWindow=self.win,hid=[8])
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
    def test_vacancy_requires_three_consecutive_clean_cross_checked_readbacks(self):
        admitted=dict(topology=self.top,frontPID=89,hid=[8])
        empty={'5':dict(ordinary=[],otherMembers=0,unresolved=0)}
        occupied={'5':dict(ordinary=[dict(pid=2,number=27,ownerClass='unclassified')],otherMembers=0,unresolved=0)}
        events=[]
        for index,census in enumerate([empty,empty,occupied,empty,empty,empty]):
            sample=dict(admitted,uptime=10+index*.3);events.append((sample,sample,census))
        it=iter(events);receipts=[]
        with mock.patch.object(runner.time,'sleep'):
            runner.stable_empty_census(lambda:next(it),lambda rows:receipts.append(list(rows)),admitted,admitted,self.top,5)
        self.assertEqual(len(receipts[-1]),6);self.assertEqual(receipts[-1][2]['ordinaryCount'],1)
    def test_no_vacancy_retry_after_physical_input_even_if_last_report_is_empty(self):
        admitted=dict(topology=self.top,frontPID=89,hid=[8],uptime=10)
        recorded=[]
        with self.assertRaisesRegex(ValueError,'physical HID'):
            runner.stable_empty_census(lambda:(admitted,dict(admitted,hid=[9]),{'5':dict(ordinary=[],otherMembers=0,unresolved=0)}),
                lambda rows:recorded.extend(rows),admitted,admitted,self.top,5)
        self.assertEqual(recorded[0]['observations'][-1]['hidDelta'],[1])
    def test_enrollment_requires_two_real_current_controls_without_an_intervening_absence(self):
        identifier='current-desktop-window:89:77'
        hit=dict(present=True,matches=1,id=identifier,space=4)
        sequence=[dict(hit,uptime=10.0),dict(hit,uptime=10.2,matches=0),dict(hit,uptime=10.4),dict(hit,uptime=10.7)]
        it=iter(sequence);retained=[]
        with mock.patch.object(runner.time,'sleep'):
            runner.confirmed_current_cards(lambda:next(it),lambda samples:retained.append(list(samples)),identifier,4)
        self.assertEqual(retained[-1],sequence)
    def test_current_control_read_error_cannot_be_counted(self):
        stored=[]
        with self.assertRaisesRegex(ValueError,'original'):
            runner.confirmed_current_cards(lambda:dict(error='original window changed'),lambda samples:stored.extend(samples),'current-desktop-window:89:77',4)
        self.assertEqual(len(stored),1)
    def test_stops_before_larger_stage_and_exact_nearest_rank(self):
        self.assertEqual(runner.gate_status([dict(status='PASS')],2),'BLOCKED');self.assertEqual(runner.gate_status([dict(status='PASS'),dict(status='FAIL')],2),'FAIL')
        self.assertEqual(runner.gate_status([dict(status='PASS')]*10,10),'PASS');self.assertEqual(runner.percentile(list(range(1,51)),.95),48)
    def test_missing_physical_visual_blocks_the_round_trip_and_larger_gates(self):
        first=dict(samples=[dict(status='PASS',retainedTargetFocus=dict(status='PASS'))]*2,blankScreen='UNKNOWN')
        runner.evaluate_gate(first,'roundTrip',2);self.assertEqual(first['status'],'BLOCKED')
        ten=dict(samples=[dict(status='PASS',retainedTargetFocus=dict(status='PASS'))]*10,blankScreen='UNKNOWN')
        runner.evaluate_gate(ten,'ten',10);self.assertEqual((ten['navigationStatus'],ten['status']),('PASS','BLOCKED'))
    def test_actual_system_focus_overrides_a_stale_workspace_owner(self):
        held=dict(held=True,pid=89,number=77,topology=self.top,hid=[8])
        sample=dict(topology=self.top,hid=[8],frontPID=89,systemFocus=dict(pid=34,number=20))
        self.assertFalse(runner.focus_tools.exact_focus(sample,held))
        self.assertTrue(runner.focus_tools.exact_focus(dict(sample,systemFocus=dict(pid=89,number=77)),held))
        self.assertEqual(runner.focus_tools.restore_context(dict(sample,hid=[9]),held),(False,None))
        self.assertEqual(runner.focus_tools.restore_context(dict(sample,topology=dict(self.top,current=5)),held),(True,5))
        full=dict(self.top,current=5,records=[self.rows[0],dict(self.rows[1],type=4)])
        self.assertEqual(runner.focus_tools.restore_context(dict(sample,topology=full),dict(held,topology=dict(full,current=4))),(False,None))
        self.assertIsNone(runner.focus_tools.kit_for(['ordinary-acceptance.py','/tmp']))
    def test_daily_restoration_preserves_user_input_since_the_newer_snapshot(self):
        with tempfile.TemporaryDirectory() as tmp:
            tools=runner.focus_tools;daily=object.__new__(tools.DailyFocus);daily.file=Path(tmp)/'focus.json';daily.original_host=0
            original=dict(topology=self.top,hid=[8],systemFocus=dict(pid=9,number=10))
            held=dict(held=True,pid=15,number=22,topology=self.top,hid=[9])
            handle=mock.Mock();daily.anchors={'newerUser':(handle,held)}
            daily.info={'original':{'independent':original},'status':'UNKNOWN'}
            daily.state=lambda:dict(original,hid=[10],systemFocus=dict(pid=39,number=36))
            daily.finish(True)
            self.assertEqual(daily.info['status'],'NEWER_INPUT_PRESERVED');handle.finish.assert_called_once_with(False)
    def test_ten_visual_admission_blocks_without_issuing_and_preserves_round_trip(self):
        trial=dict(navigationStatus="NOT_RUN",status="BLOCKED",reason="missing source",axIssued=False,visualAdmissionBlocked=True)
        gate=dict(samples=[trial]);runner.evaluate_gate(gate,"ten",10)
        self.assertEqual((gate["status"],gate["navigationStatus"],gate["navigationDispatched"]),("BLOCKED","NOT_RUN",0))
        partial=dict(samples=[dict(status="UNKNOWN",navigationStatus="PASS",axIssued=True,blankScreen="UNKNOWN",reason="physical coverage gap")])
        runner.evaluate_gate(partial,"ten",10)
        self.assertEqual((partial["status"],partial["navigationConfirmed"],partial["reason"]),("UNKNOWN",1,"physical coverage gap"))
        trip=dict(samples=[dict(status="PASS",navigationStatus="PASS",axIssued=True,blankScreen="PASS",continuousClassification="settled",retainedTargetFocus=dict(status="PASS"))]*2)
        runner.evaluate_gate(trip,"roundTrip",2);self.assertEqual(trip["status"],"PASS")
        qualified=dict(status="READY",ready=True,physicalReady=True,physicalAdmission={"sourceSpace":4,"targetSpace":5,"failed":[],
                       "physicalStreamArmed":True,"sourceFrameReadyBeforePress":True,"endpointCalibration":{"sourceEnrolled":True,"targetEnrolled":True}})
        self.assertTrue(runner.physical_admission(qualified,self.req)[0])
        self.assertFalse(runner.physical_admission(dict(qualified,physicalReady=False),self.req)[0])
        self.assertFalse(runner.physical_admission(qualified,dict(self.req,target=8))[0])
    def test_missing_visual_source_stops_before_the_watch_and_product_input(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp).resolve();recorder=mock.Mock();recorder.start.return_value=dict(status="UNKNOWN",reason="missing endpoint")
            recorder.finish.return_value=dict(status="UNKNOWN");keeper=mock.Mock();keeper.call.return_value={"ready":True}
            with mock.patch.object(runner,"visual_module",return_value=recorder),mock.patch.object(runner,"Watch",side_effect=AssertionError("product action not allowed")):
                item=runner.attempt(root/"p0-card",self.req,root/"ten-01",root/"journal",lambda *args,**kwargs:None,"ten",keeper)
            self.assertEqual((item["status"],item["navigationStatus"],item["axIssued"]),("BLOCKED","NOT_RUN",False))
            self.assertEqual([call.args[0] for call in keeper.call.call_args_list],["inspect"])
    def test_host_audit_preserves_exact_complete_metadata_records_only(self):
        with tempfile.TemporaryDirectory() as tmp:
            audit=object.__new__(runner.InstalledWindowAudit);audit.stream=Path(tmp)/'p0-window-audit.jsonl';audit.host={'pid':23}
            row=b'{"writerPID":23,"revision":77,"uptime":123, "stage":"published","windows":[{"number":66}]}'
            private=b'{"other":{"windowTitle":"fixture-text-sentinel"}}'
            raw=row+b'\n'+private+b'\n'+row.replace(b'"writerPID":23',b'"writerPID":12')+b'\n{"partial":'
            audit.stream.write_bytes(raw);audit.stream.chmod(0o600)
            records,meta=audit.read()
            self.assertEqual([r[2] for r in records],[row]);self.assertEqual(meta['withheldNonMetadataLines'],1);self.assertEqual(meta['unmatchedHostEnvelopeLines'],1)
            self.assertEqual(meta['trailingIncompleteBytes'],len(b'{"partial":'));self.assertEqual(meta['sourceSHA256'],hashlib.sha256(raw).hexdigest())
            alias=Path(tmp)/'alias';alias.symlink_to(audit.stream);audit.stream=alias
            with self.assertRaises(OSError):audit.read()
    def detailed(self, stamp, space, window):
        return dict(uptime=stamp,topology=dict(self.top,current=space),hid=[8],frontPID=window['pid'],
                    workspaceFrontPID=window['pid'],focusedNumber=window['number'],systemFocus=window.copy())

    def test_foreground_pid_alone_or_wrong_exact_window_or_birth_never_qualifies(self):
        rows=[self.detailed(10+i*.1,5,self.win) for i in range(25)]
        self.assertEqual(runner.retained_target_focus(rows,self.req,10)['status'],'PASS')
        for mismatch in ({'number':89},{'birth':111},{'pid':76}):
            v=[*rows];v[12]=dict(v[12],systemFocus=dict(self.win,**mismatch))
            proof=runner.retained_target_focus(v,self.req,10)
            self.assertEqual(proof['status'],'UNKNOWN')
            self.assertEqual(proof['firstLoss']['uptime'],v[12]['uptime'])
        lost=[*rows];lost[3]=dict(lost[3],systemFocus=None)
        self.assertEqual(runner.retained_target_focus(lost,self.req,10)['firstLoss']['uptime'],10.3)
        legacy=[{k:v for k,v in s.items() if k in ('uptime','topology','frontPID','hid')} for s in rows]
        self.assertIsNone(runner.retained_target_focus(legacy,self.req,10)['firstExactUptime'])
        self.assertEqual(runner.retained_target_focus(legacy,self.req,10)['status'],'UNKNOWN')

    def test_next_card_refusal_retains_actual_and_expected_numbers_and_never_invokes_driver(self):
        mismatched=self.detailed(13,9,dict(pid=91,birth=345,number=881))
        mismatched.update(hid=[30],privateTitle='excluded',systemFocus=dict(mismatched['systemFocus'],title='excluded'))
        admission=runner.admission_sample(mismatched,self.req)
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp).resolve();folder=root/'ten-02'
            with mock.patch.object(runner,'Watch',side_effect=AssertionError('refused input cannot start')), \
                 mock.patch.object(runner,'cmd',side_effect=AssertionError('no further read needed for immediate refusal')):
                trial=runner.attempt(root/'tool',self.req,folder,root/'journal',lambda *a,**kw:None,'ten',admission=admission)
            recorded=json.loads((folder/'admission-before.json').read_text())
        self.assertEqual((trial['status'],trial['navigationStatus'],trial['axIssued'],trial['hostIssued']),('BLOCKED','NOT_RUN',False,False))
        self.assertEqual((recorded['actual']['topology']['current'],recorded['expected']['topology']['current']),(9,4))
        self.assertEqual((recorded['actual']['hid'],recorded['expected']['hid']),([30],[8]))
        self.assertEqual(recorded['mismatches'],['topology','hid','sourceDocumentFocus'])
        self.assertEqual(recorded['actual']['systemFocus'],dict(pid=91,birth=345,number=881))
        self.assertNotIn('excluded',json.dumps(recorded))

    def test_read_only_watcher_spans_visual_finalization_without_extending_movie_interval(self):
        foreign=dict(pid=92,birth=10720,number=45)
        input_rows=[self.detailed(9.95,4,self.source)]
        for i in range(1,36):
            source=i<2
            focused=self.source if source else (foreign if i==26 else self.win)
            input_rows.append(self.detailed(10+i*.1,4 if source else 5,focused))

        class FakeWatch:
            def __init__(self):self.samples=[];self.closed=False;self.seq=iter(input_rows)
            def __enter__(self):return self
            def __exit__(self,*args):self.closed=True
            def next(self):
                row=next(self.seq);self.samples.append(row);return row

        watch=FakeWatch();keeper=mock.Mock();recorder=mock.Mock()
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp).resolve();folder=root/'ten-01';journal=root/'journal';journal.mkdir()
            def call(mode,body):
                if mode=='inspect':return dict(ready=True)
                self.assertEqual(mode,'press')
                runner.store(journal/(self.operation+'.json'),dict(intent=self.intent,result=self.reply))
                return dict(issued=True,axError=0,uptime=10)
            def finish(module,kit,path,pressed,ended,*args):
                self.assertFalse(watch.closed)
                self.assertLess(ended,12.6)
                return 'PASS'
            keeper.call.side_effect=call
            monitor=mock.Mock()
            monitor.before.return_value={'state':'observed'}
            monitor.after.return_value={'classification':'settled'}
            with mock.patch.object(runner,'Watch',return_value=watch),mock.patch.object(runner,'visual_module',return_value=recorder), \
                 mock.patch.object(runner,'physical_admission',return_value=(True,None)), \
                 mock.patch.object(runner,'finish_visual',side_effect=finish), \
                 mock.patch.object(runner,'cmd',return_value=self.detailed(13.03,5,self.win)):
                trial=runner.attempt(root/'tool',self.req,folder,journal,lambda *a,**kw:None,'ten',keeper,
                                     admission=runner.admission_sample(input_rows[0],self.req),observer=monitor)
            primary=[json.loads(l) for l in (folder/'windowserver.jsonl').read_text().splitlines()]
            tail=[json.loads(l) for l in (folder/'windowserver-finalization.jsonl').read_text().splitlines()]
        self.assertTrue(watch.closed)
        self.assertEqual((trial['navigationStatus'],trial['blankScreen'],trial['status']),('PASS','PASS','UNKNOWN'))
        self.assertAlmostEqual(trial['retainedTargetFocus']['firstLoss']['secondsAfterPress'],2.6)
        self.assertLess(primary[-1]['uptime'],12.6);self.assertGreaterEqual(tail[-1]['uptime'],13.03)
        self.assertEqual([v.args[0] for v in keeper.call.call_args_list],['inspect','press'])

    def test_eighteenth_archived_trajectory_stops_after_foreground_loss(self):
        directory=p.parents[3]/'engineering/verification/native-spaces/5.22-p0/18-late-space-change'
        manifest=json.loads((directory/'original-receipts-manifest.json').read_text())
        archive=directory/manifest['archive']
        self.assertEqual(hashlib.sha256(archive.read_bytes()).hexdigest(),manifest['archiveSHA256'])
        hashes={r['file']:r['sha256'] for r in manifest['files']}
        with tarfile.open(archive,'r:gz') as tar:
            def read(name):
                data=tar.extractfile(name).read()
                self.assertEqual(hashlib.sha256(data).hexdigest(),hashes[name])
                if name.endswith('.jsonl'):return [json.loads(l) for l in data.splitlines()]
                return json.loads(data)
            req=read('ten-01/identity.json');ax=read('ten-01/ax-dispatch.json');samples=read('ten-01/windowserver.jsonl')
            old=read('ten-01/result.json');name=old['hostJournalFile'];next_card=read('ten-02/result.json')
            proof=runner.match_receipt(read('ten-01/'+name),name,req,ax['uptime'])
        self.assertEqual((old['status'],old['navigationStatus'],old['blankScreen']),('PASS','PASS','PASS'))
        self.assertEqual(runner.assess(samples,req,ax['uptime'],proof,ax)[0],'PASS')
        focus=runner.retained_target_focus(samples,req,ax['uptime'])
        self.assertEqual(focus['status'],'UNKNOWN')
        self.assertAlmostEqual(focus['firstTargetOwnerUptime']-ax['uptime'],.16582,places=5)
        self.assertIsNone(focus['firstExactUptime'])
        self.assertAlmostEqual(focus['firstLoss']['secondsAfterPress'],2.37752,places=5)
        self.assertEqual((focus['firstLoss']['current'],focus['firstLoss']['frontPID']),(req['target'],63480))
        self.assertEqual((next_card['status'],next_card['axIssued']),('BLOCKED',False))
        self.assertNotIn('actual',next_card)
        stage=dict(samples=[dict(old,retainedTargetFocus=focus)])
        runner.evaluate_gate(stage,'ten',10)
        self.assertEqual((stage['status'],stage['navigationConfirmed']),('UNKNOWN',1))

    def test_visual_pass_is_bound_to_actual_frames_nonce_pair_and_press(self):
        started=dict(ready=True,nonce=self.operation)
        receipt=dict(status='PASS',nonce=self.operation,pressed=10,ended=12.1,frameLog='frames.json',source=4,target=5)
        module=mock.Mock();module.finish.return_value=receipt
        with tempfile.TemporaryDirectory() as tmp:
            folder=Path(tmp).resolve();(folder/'visual').mkdir()
            runner.store(folder/'visual/receipt.json',receipt)
            runner.store(folder/'visual/frames.json',dict(nonce=self.operation))
            check=lambda:runner.finish_visual(module,folder,folder,10,12.1,self.req,started,{})
            self.assertEqual(check(),'PASS')
            runner.store(folder/'visual/frames.json',dict(nonce='stale'));self.assertEqual(check(),'UNKNOWN')
            runner.store(folder/'visual/frames.json',dict(nonce=self.operation))
            receipt['target']=4;runner.store(folder/'visual/receipt.json',receipt);self.assertEqual(check(),'UNKNOWN')
    def test_real_black_fails_without_misrepresenting_navigation(self):
        ten=dict(samples=[dict(status='PASS',navigationStatus='PASS',blankScreen='PASS',continuousClassification='settled',retainedTargetFocus=dict(status='PASS')) for _ in range(10)])
        runner.evaluate_gate(ten,'ten',10);self.assertEqual(ten['status'],'PASS')
        ten['samples'][-1].update(status='FAIL',blankScreen='FAIL')
        runner.evaluate_gate(ten,'ten',10);self.assertEqual((ten['navigationStatus'],ten['blankScreen'],ten['status']),('PASS','FAIL','FAIL'))


if __name__=='__main__':unittest.main()
