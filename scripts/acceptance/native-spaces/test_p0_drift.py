import copy
import importlib.util
from pathlib import Path
import unittest
import tempfile
import json

from p0_drift_classification import classify, action_record, checkpoint_identity, observer_coverage

src=Path(__file__).with_name('p0-drift.py')
spec=importlib.util.spec_from_file_location('p0_drift',src)
monitor=importlib.util.module_from_spec(spec);spec.loader.exec_module(monitor)
DISPLAY='00CB7536-5776-4DB9-A269-B47DC16582EF'
A='00CB7536-5776-4DB9-A269-B47DC16582E0'
B='00CB7536-5776-4DB9-A269-B47DC16582E1'
C='00CB7536-5776-4DB9-A269-B47DC16582E2'
W={'pid':41,'birth':999,'number':430}
INTENT=dict(operation=C,display=DISPLAY,source=1,target=2,sourceUUID=A,targetUUID=B,window=W,
            created=101.,issued=101.05,confirmed=101.95)
def process(pid,born,bundle):
    return dict(pid=pid,birth=born,identityKnown=True,bundle=bundle,signingIdentifier=bundle,cdhash='a'*40)
P=process(41,999,'net.example.target');OTHER=process(52,700,'net.example.external')
DOCK=process(12,9,'com.apple.dock');WM=process(22,67,'com.apple.WindowManager')

def sample(t,space=2,p=P):
    return dict(event='sample',uptime=t,began=t-.02,hid=[0]*8,additionalHID=[0]*8,spaceStable=True,
                display=DISPLAY,current=space,spaceUUID={1:A,2:B,3:C}[space],topologyHash='same',
                workspaceFrontPID=p['pid'],foreground=dict(p),foregroundStable=True,focusStable=True,
                focus=dict(pid=p['pid'],birth=p['birth'],number=W['number'] if p==P else 555,
                           spaces=[space] if p==P else [3],process=dict(p)),
                ownerWindows=dict(pid=p['pid'],birth=p['birth'],spaces=[space] if p==P else [3],complete=True,at=t-.01),
                dock=dict(DOCK),windowManager=dict(WM))

def events(rows):
    return [dict(row,session=A,seq=i) for i,row in enumerate(rows)]

def trace(last=113):
    return [sample(100.95,1)]+[sample(101.15+i*0.2) for i in range(round((last-101.15)/.2)+1)]

class DriftTests(unittest.TestCase):
    def test_activation_between_matching_window_reads_survives_a_return_to_target(self):
        rows=trace()
        rows.insert(12,dict(event='workspaceNotification',kind='didActivateApplication',uptime=103.20,process=OTHER))
        observed=classify(events(rows),INTENT)
        self.assertEqual(observed['classification'],'unexpectedForegroundHandoff')
        self.assertFalse(observed['postConfirmationTenSeconds'])
        rows[12].pop('process')
        self.assertEqual(classify(events(rows),INTENT)['classification'],'unknown')

    def test_next_press_binds_both_signed_generations_full_window_and_space(self):
        from p0_session import matches_source
        host=dict(pid=93,birth=932,cdhash='b'*40)
        request=dict(hostPID=93,hostBirth=932,hostHash=host['cdhash'],sourceWindow=dict(W,hash=P['cdhash']),
                     topology=dict(display=DISPLAY,current=2,records=[dict(id=2,uuid=B)]))
        check=dict(state='observed',current=2,spaceUUID=B,display=DISPLAY,host=host,binding=checkpoint_identity(sample(105)))
        self.assertTrue(matches_source(check,request))
        for mutate in [lambda c:c['host'].update(birth=933),lambda c:c.update(spaceUUID=C),
                       lambda c:c['binding']['window'].update(number=999),lambda c:c.update(state='refused')]:
            stale=copy.deepcopy(check);mutate(stale)
            self.assertFalse(matches_source(stale,request))

    def test_external_foreground_with_unchanged_hid_cannot_authorize_off_space_focus(self):
        rows=trace(114)
        for r in rows:
            r['focus']['spaces']=[3]
        log=events([dict(event='started'),*rows,dict(event='ended',reason='duration')])
        self.assertEqual(observer_coverage(log)['status'],'PASS')
        self.assertIsNone(checkpoint_identity(rows[-1]))
        rows[-1]['focus']['spaces']=[2]
        self.assertEqual(checkpoint_identity(rows[-1])['window'],W)
        rows[-1]['focus']['process']=OTHER
        self.assertIsNone(checkpoint_identity(rows[-1]))
        self.assertEqual(observer_coverage(events([*log[:-1],dict(event='notificationLoss'),log[-1]]))['status'],'UNKNOWN')
    def test_landed_is_distinct_from_ten_seconds_after_confirmation(self):
        small=classify(events(trace(106)),INTENT);self.assertEqual(small['classification'],'landed')
        self.assertFalse(small['postConfirmationTenSeconds'])
        enough=classify(events(trace(113)),INTENT);self.assertEqual(enough['classification'],'settled')
        self.assertTrue(enough['postConfirmationTenSeconds'])
    def test_handoff_preserves_target_and_binds_only_verified_external_window(self):
        rows=trace(104);rows[-2:]=[sample(rows[-2]['uptime'],p=OTHER),sample(rows[-1]['uptime'],p=OTHER)]
        result=classify(events(rows),INTENT)
        self.assertEqual(result['classification'],'unexpectedForegroundHandoff')
        self.assertNotIn('unexpectedSpaceDrift',[e['kind'] for e in result['events']])
        handoff=result['events'][-1];self.assertEqual(handoff['current'],2)
        self.assertEqual(handoff['foregroundIdentity'],OTHER);self.assertEqual(handoff['ownedOtherSpaces'],[3])
        self.assertEqual(handoff['focusedWindow']['number'],555)
    def test_later_drift_and_dock_correlation_do_not_assign_causality(self):
        rows=trace(103);t=rows[-1]['uptime']
        rows+=[sample(t+.1,p=OTHER),dict(event='workspaceNotification',kind='didActivateApplication',process=DOCK,uptime=t+.15),
               dict(event='workspaceNotification',kind='activeSpaceDidChange',uptime=t+.18),sample(t+.23,space=3,p=OTHER)]
        result=classify(events(rows),INTENT);self.assertEqual(result['classification'],'unexpectedSpaceDrift')
        self.assertEqual([e['kind'] for e in result['events']],['landed','unexpectedForegroundHandoff','unexpectedSpaceDrift'])
        hand=result['events'][1];self.assertTrue(hand['laterDriftMatchesOwnedSpace'])
        self.assertEqual(hand['systemAgentActivationsBeforeDrift'][0]['process'],DOCK)
        self.assertEqual(result['causalAttribution'],'UNKNOWN')
    def test_unsigned_handoff_yields_no_process_or_window_attribution(self):
        rows=trace(103)
        s=sample(rows[-1]['uptime']+.1,p=OTHER);s['foreground']={'pid':52,'birth':700,'identityKnown':False}
        rows.append(s);event=classify(events(rows),INTENT)['events'][-1]
        self.assertIsNone(event['foregroundIdentity']);self.assertIsNone(event['ownedOtherSpaces']);self.assertIsNone(event['focusedWindow'])
    def test_reused_pid_cannot_inherit_target_or_background_ownership(self):
        rows=trace(103);changed=process(41,123,'net.example.replacement')
        s=sample(rows[-1]['uptime']+.1,p=changed);s['ownerWindows']['birth']=999
        rows.append(s);r=classify(events(rows),INTENT)
        self.assertEqual(r['classification'],'unexpectedForegroundHandoff');self.assertIsNone(r['events'][-1]['ownedOtherSpaces'])
    def test_superseded_terminates_even_when_it_arrives_between_samples(self):
        rows=trace(103);t=rows[-1]['uptime'];rows.append(dict(event='userSuperseded',uptime=t+.04))
        self.assertEqual(classify(events(rows),INTENT)['classification'],'userSuperseded')
        rows=trace(103);rows[-1]['additionalHID'][0]=1
        self.assertEqual(classify(events(rows),INTENT)['classification'],'userSuperseded')
        rows=trace(103);rows[-1].pop('hid')
        self.assertEqual(classify(events(rows),INTENT)['classification'],'unknown')
    def test_sampling_or_notification_gaps_and_focus_ambiguity_cannot_settle(self):
        for changes in ('gap','focus','missingSystem','lost','renumber','time','noSource'):
            rows=trace()
            if changes=='gap':del rows[15:20]
            if changes=='focus':rows[18]['focusStable']=False
            if changes=='missingSystem':rows[12]['windowManager']=None
            if changes=='lost':rows.append(dict(event='notificationLoss',uptime=rows[-1]['uptime'],count=2))
            if changes=='renumber':rows[12]['topologyHash']='different'
            if changes=='time':rows[16]['uptime']=rows[15]['uptime']
            if changes=='noSource':rows=rows[1:]
            with self.subTest(changes=changes):self.assertEqual(classify(events(rows),INTENT)['classification'],'unknown')
    def test_next_admission_needs_an_independent_closing_edge_and_cannot_use_following_switch(self):
        rows=trace(113);t=rows[-1]['uptime'];rows += [sample(t+.12),sample(t+.27,space=1)]
        self.assertEqual(classify(events(rows),INTENT,t+.10)['classification'],'settled')
        self.assertEqual(classify(events(rows),INTENT,t+1)['classification'],'unexpectedSpaceDrift')
        self.assertIn('nextAdmissionNotContinuouslyCovered',classify(events(rows),INTENT,t+1)['issues'])
    def test_confirmed_requires_one_real_phase_triplet_and_matching_receipt_fields(self):
        record=dict(intent=dict(id=A,display=DISPLAY,source='1',target='2',sourceUUID=A,targetUUID=B,
                                createdAtUptime=101,window=W,action='select'),result=dict(id=A,state='confirmed',
                    submittedSteps=1,issuedAtUptime=101.05,confirmedAtUptime=101.9,currentBefore={DISPLAY:'1'},
                    currentAfter={DISPLAY:'2'},switchTrace={'adapter':27,'phasesMachTicks':[10,11,12],'observations':[{'currents':{DISPLAY:'2'}}]}))
        self.assertIsNotNone(action_record(record))
        for field,bad in [('submittedSteps',0),('currentAfter',{DISPLAY:'1'}),('state','failed'),('confirmedAtUptime',100)]:
            modified=copy.deepcopy(record);modified['result'][field]=bad;self.assertIsNone(action_record(modified))
    def test_refused_admission_is_persisted_with_its_actual_current_space(self):
        with tempfile.TemporaryDirectory() as t:
            base=Path(t).resolve();(base/'admissions').mkdir()
            monitor.write(base/'active.json',dict(open=False,reason='userSuperseded',session=A,current=3,spaceUUID=C))
            r=monitor.admission(base)
            stored=json.loads(next((base/'admissions').glob('*.json')).read_bytes())
            self.assertEqual(r,stored);self.assertEqual(r['state'],'refused')
            self.assertEqual(r['current'],3);self.assertFalse(r['dispatchAuthorized'])
    def test_missing_next_admission_prevents_claiming_a_complete_cross_action_run(self):
        later={**INTENT,'operation':A,'created':112.23,'issued':112.35,'confirmed':113.25}
        rows=events(trace(114))
        missing=monitor.course(rows,[INTENT,later],[])[0]
        self.assertEqual(missing['nextAdmissionEvidence'],'nextFormalIntentOnly')
        self.assertEqual(missing['classification'],'unknown')
        self.assertEqual(monitor.course(rows,[INTENT,later],[dict(requestedUptime=112.2,state='observed')])[0]['classification'],'settled')
        self.assertEqual(monitor.course(rows,[INTENT,later],[dict(requestedUptime=112.2,state='refused')])[0]['classification'],'unknown')
    def test_historical_replay_preserves_two_boundaries(self):
        replay=monitor.history()['cases'];full=replay['18-late-space-change'];case=next(x for x in full['classifications'] if x['folder']=='ten-01')
        self.assertEqual(case['classification'],'unexpectedForegroundHandoff')
        change=case['events'][-1];self.assertEqual(change['secondsAfterAXPress'],2.377519)
        self.assertIsNone(change['foregroundIdentity']);self.assertEqual(change['current'],5020)
        self.assertEqual(full['afterLastTen01Sample']['laterDocumentedSpace'],6)
        self.assertFalse(full['afterLastTen01Sample']['nextPressIssued'])
        self.assertTrue(all(not a['postConfirmationTenSeconds'] for a in replay['11-adjacent-round-trip']['classifications']))
if __name__=='__main__':unittest.main()
