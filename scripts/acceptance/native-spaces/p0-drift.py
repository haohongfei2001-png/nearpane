#!/usr/bin/env python3
"""Persistent read-only observation, explicit admission checkpoints and offline P0 replay."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import re
import stat
import subprocess
import sys
import time
import threading
import uuid

from p0_drift_classification import MAX_GAP, action_record, checkpoint_identity, classify, observer_coverage

ROOT=Path(__file__).resolve().parents[3]
HISTORY=ROOT/'engineering/verification/native-spaces/5.22-p0'


def require(ok, message):
    if not ok: raise ValueError(message)


def write(path, data):
    t=path.with_name(path.name+'.'+str(uuid.uuid4())+'.next')
    with t.open('x') as f:
        json.dump(data,f,ensure_ascii=False,indent=2,sort_keys=True)
        f.write('\n');f.flush();os.fsync(f.fileno())
    os.replace(t,path)


def read_rows(path):
    # A concurrent checkpoint can encounter the tail while the writer is emitting it.
    with path.open('rb') as f:
        return [json.loads(line) for line in f if line.endswith(b'\n')]


def course(events, actions, checkpoints):
    results=[]
    ordered=sorted(actions,key=lambda a:a['created'])
    for i,a in enumerate(ordered):
        next_intent=ordered[i+1]['created'] if i+1<len(ordered) else None
        later=[r for r in checkpoints if r['requestedUptime']>a['created'] and
               (next_intent is None or r['requestedUptime']<=next_intent)]
        boundary=min((r['requestedUptime'] for r in later),default=next_intent)
        outcome=classify(events,a,boundary)
        outcome['nextAdmissionEvidence']=('callerCheckpoint' if later else
                                          ('nextFormalIntentOnly' if next_intent is not None else 'endOfMonitor'))
        if (next_intent is not None and not later) or (later and min(later,key=lambda r:r['requestedUptime']).get('state')!='observed'):
            outcome['issues'].append('nextPreActionAdmissionUnconfirmed')
            if outcome['classification']=='settled':
                outcome['classification']='unknown';outcome['postConfirmationTenSeconds']=False
        results.append(outcome)
    return results


def journal_files(directory):
    if not directory.is_dir():return []
    require(directory.resolve()==directory and directory.stat().st_uid==os.getuid(), 'unexpectedHostJournalDirectory')
    return [p for p in directory.glob('*.json') if re.fullmatch(r'[0-9a-fA-F-]{36}',p.stem)]


def journal_value(path):
    with os.fdopen(os.open(path,os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK),'rb') as f:
        info=os.fstat(f.fileno())
        require(stat.S_ISREG(info.st_mode) and info.st_uid==os.getuid() and info.st_nlink==1 and
                0<info.st_size<2_000_000, 'ineligibleHostJournalRecord')
        raw=f.read(2_000_000)
        require(len(raw)==info.st_size, 'incompleteHostJournalRecord')
    return json.loads(raw),hashlib.sha256(raw).hexdigest()


def capture(kit,out,seconds,managed=False):
    from acceptance import identity
    from installed_profile import APP, PROFILE, installed_pid, owns_profile, validate_home
    require(12<=seconds<=3600,'diagnosticDurationMustBe12To3600Seconds')
    require(kit.parent==Path('/private/tmp') and kit.name.startswith('nearpane-p0-drift.') and kit.is_dir() and
            kit.resolve()==kit and kit.stat().st_uid==os.getuid() and not kit.stat().st_mode&0o077,'unqualifiedReadOnlyKit')
    reader=kit/'p0-drift-reader'
    require(reader.is_file() and reader.resolve()==reader,'monitorExecutableUnavailable')
    out.mkdir(mode=0o700,parents=True,exist_ok=False)
    for name in ('admissions','operations'):(out/name).mkdir(mode=0o700)
    started=time.monotonic()
    summary=dict(mode='readOnlyContinuousObserver',status='NOT_RUN',confirmedOperations=0,actionsSubmitted=0,
                 restorationActions=0,physicalInputsPosted=0,observations=[],nextFifty='NOT_RUN')
    write(out/'result.json',summary)
    proc=None;watchdog=None;timeout=threading.Event();events=[];checks=[];actions=[];invalid={};ignored=[];baseline=set();session=None;latest_state={}
    try:
        home=Path(os.environ['NEARPANE_TEST_HOME'])
        require(home.is_dir(),'existingIsolatedHomeRequired')
        validate_home(home)
        host=installed_pid()
        require(host and owns_profile(host,home/PROFILE),'installedHostMustOwnExistingIsolatedProfile')
        subprocess.run(['/usr/bin/codesign','--verify','--strict','--deep',APP],check=True,
                       stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,timeout=15)
        signed=identity(APP);info=plistlib.loads((APP/'Contents/Info.plist').read_bytes())
        require((info.get('CFBundleShortVersionString'),info.get('CFBundleVersion'),signed.get('TeamIdentifier'))==
                ('5.22','90','ZB9D4T66QB'),'outsideInstalledCandidateContract')
        generation=json.loads(subprocess.check_output([reader,'host-generation',str(host)],timeout=3))
        require(generation.get('pid')==host and generation.get('cdhash')==signed.get('CDHash'),'installedSignedGenerationMismatch')
        build=subprocess.check_output(['/usr/sbin/sysctl','-n','kern.osversion'],text=True).strip()
        journal=home/'Library/Application Support/Nearpane/NativeSwitch'/('dock-v1-'+build)
        require(not (journal/'pending.json').exists(),'preexistingPendingIntent')
        baseline={p.name for p in journal_files(journal)}
        summary['host']={**generation,'source':info.get('NearpaneSourceRevision'),'osBuild':build}
        known=set(baseline)
        def scan():
            for path in journal_files(journal):
                if path.name in known:continue
                try:
                    j,digest=journal_value(path);a=action_record(j)
                    require(str(uuid.UUID(path.stem)).upper()==str(uuid.UUID(j['intent']['id'])).upper(),'filenameIntentMismatch')
                    if a and a['created']>=started:
                        a['journalSHA256']=digest;actions.append(a);write(out/'operations'/path.name,a)
                    else:
                        ignored.append({'id':path.stem,'reason':'noNewConfirmedSingleStepSelect'})
                    known.add(path.name);invalid.pop(path.name,None)
                except (OSError,KeyError,TypeError,ValueError):
                    invalid[path.name]='incompleteOrMalformedHostJournal'
        with (out/'events.jsonl').open('x') as log:
            proc=subprocess.Popen([reader,str(seconds),str(host),str(generation['birth']),generation['cdhash'],*(['managed'] if managed else [])],
                                  stdin=subprocess.PIPE if managed else subprocess.DEVNULL,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,text=True)
            def watch_time():
                if proc.poll() is None:
                    timeout.set();proc.kill()
            watchdog=threading.Timer(seconds+8,watch_time)
            watchdog.daemon=True;watchdog.start()
            scanned=started
            revision=0
            for line in proc.stdout:
                r=json.loads(line);events.append(r);log.write(json.dumps(r,separators=(',',':'))+'\n');log.flush()
                if r.get('event')=='started':
                    session=r['session'];initial_inputs=(r['hid'],r['additionalHID'])
                if managed and not proc.stdin.closed and (out/'finish.json').is_file():
                    if json.loads((out/'finish.json').read_bytes()).get('session')==session:
                        proc.stdin.close()
                if r.get('event') in ('workspaceNotification','notificationLoss','readUnavailable'):
                    revision+=1
                    latest_state.update(open=False,revision=revision,reason=r['event'])
                    write(out/'active.json',latest_state)
                if r.get('event')=='sample' and r.get('session')==session:
                    scan()
                    pending=(journal/'pending.json').exists()
                    binding=checkpoint_identity(r)
                    if binding!=latest_state.get('binding'):
                        revision+=1
                    latest_state=dict(session=session,writer=os.getpid(),reader=proc.pid,
                        seq=r['seq'],uptime=r['uptime'],spaceStable=r['spaceStable'],current=r['current'],display=r['display'],
                        spaceUUID=r['spaceUUID'],hid=r['hid'],additionalHID=r['additionalHID'],
                        pendingInstalledIntent=pending,unresolvedJournalCount=len(invalid),
                        binding=binding,revision=revision,host=generation,
                        open=binding is not None and (r['hid'],r['additionalHID'])==initial_inputs and not pending and not invalid)
                    write(out/'active.json',latest_state)
                if r.get('event') in ('ended','userSuperseded','refused','readUnavailable'):
                    latest_state.update(session=session,writer=os.getpid(),open=False,reason=r.get('reason',r['event']),stopUptime=r.get('uptime'))
                    if r.get('event')=='userSuperseded':
                        latest_state.update(hid=r.get('hid'),additionalHID=r.get('additionalHID'))
                    write(out/'active.json',latest_state)
                if time.monotonic()-scanned>=.35:
                    scanned=time.monotonic();os.fsync(log.fileno())
            proc.stdout.close();summary['exitCode']=proc.wait(timeout=3)
            os.fsync(log.fileno())
        scan()
        for p in (out/'admissions').glob('*.json'):
            candidate=json.loads(p.read_bytes())
            if candidate.get('session')==session:checks.append(candidate)
        samples=[r for r in events if r.get('event')=='sample']
        stable=sum(r.get('spaceStable') is True for r in samples)
        intact=stable>0 and not timeout.is_set() and proc.returncode==0 and owns_profile(host,home/PROFILE) and session and events and events[-1].get('event')=='ended'
        summary.update(confirmedOperations=len(actions),incompleteJournals=invalid,otherOperations=ignored,
                       observerSession=session,eventCount=len(events),stableSpaceReads=stable,admissionCount=len(checks),readerTimedOut=timeout.is_set(),
                       stopReason=events[-1].get('reason') if events else 'noEvents',observationComplete=bool(intact),
                       observations=course(events,actions,checks),observerCoverage=observer_coverage(events))
        if not intact or invalid:summary['status']='UNKNOWN'
        elif actions:
            summary['status']='OBSERVED'
            if any(o['classification']=='userSuperseded' for o in summary['observations']):summary['status']='userSuperseded'
        else:
            summary['reason']='No independently bound confirmed installed selection occurred during this observation.'
    except (KeyError,OSError,ValueError,TypeError,RuntimeError,subprocess.SubprocessError) as error:
        summary['status']='UNKNOWN';summary['reason']=str(error)[:180]
    finally:
        if watchdog:watchdog.cancel()
        if proc and proc.poll() is None:
            proc.terminate();proc.wait(timeout=5)
        latest_state.update(open=False,session=session,reason=latest_state.get('reason','observationEnded'))
        write(out/'active.json',latest_state)
        write(out/'result.json',summary)
    return summary


def admission(out):
    require(out.is_dir() and out.resolve()==out and out.stat().st_uid==os.getuid() and not out.stat().st_mode&0o077,
            'privateActiveDiagnosticDirectoryRequired')
    requested=time.monotonic();state=json.loads((out/'active.json').read_bytes());session=state.get('session')
    id=str(uuid.uuid4())
    value=dict(id=id,session=session,requestedUptime=requested,sourceSequence=state.get('seq'),
               observedUptime=state.get('uptime'),display=state.get('display'),current=state.get('current'),spaceUUID=state.get('spaceUUID'),
               binding=state.get('binding'),host=state.get('host'),revision=state.get('revision'),
               dispatchAuthorized=False,state='pending')
    latest=state.get('uptime')
    if (not state.get('open') or not state.get('binding') or not isinstance(session,str) or state.get('spaceStable') is not True or
        type(latest) not in (int,float) or not 0<=requested-latest<=MAX_GAP):
        value.update(state='refused',reason=state.get('reason','observerUnavailableOrSuperseded'))
        write(out/'admissions'/(id+'.json'),value);return value
    try:
        os.kill(state['writer'],0);os.kill(state['reader'],0)
    except (KeyError,TypeError,OSError):
        value.update(state='refused',reason='monitorProcessUnavailable')
        write(out/'admissions'/(id+'.json'),value);return value
    # Publish the admission before any caller could act. The independent observer stays running.
    write(out/'admissions'/(id+'.json'),value)
    deadline=time.monotonic()+MAX_GAP;last=state
    while time.monotonic()<deadline:
        last=json.loads((out/'active.json').read_bytes())
        if not last.get('open') or last['session']!=session or last.get('uptime',0)>=requested:break
        time.sleep(.02)
    valid=(last.get('open') and last['session']==session and last.get('uptime',0)>=requested and last.get('spaceStable') and
           all(state[k]==last.get(k) for k in ('current','display','spaceUUID','hid','additionalHID','host','binding','revision')))
    value['state']='observed' if valid else 'refused'
    value['closingSequence']=last.get('seq')
    prior=[json.loads(path.read_bytes()) for path in (out/'operations').glob('*.json')]
    prior=[a for a in prior if a['created']<requested]
    if valid and prior:
        verdict=classify(read_rows(out/'events.jsonl'),max(prior,key=lambda a:a['created']),requested)
        value['precedingClassification']=verdict['classification']
        if verdict['classification']!='settled':
            value['state']='refused';value['reason']='precedingDiagnosticDidNotSettle'
    write(out/'admissions'/(id+'.json'),value)
    return value


def history():
    spec=importlib.util.spec_from_file_location('archived_p0',Path(__file__).with_name('verify-p0-receipts.py'))
    reader=importlib.util.module_from_spec(spec);spec.loader.exec_module(reader)
    cases={}
    for name in ('11-adjacent-round-trip','18-late-space-change'):
        directory=HISTORY/name
        validated=reader.verify(directory);digest,_,data=reader.read_archive(directory);verified=[]
        for folder in sorted({p.split('/')[0] for p in data if p.endswith('/windowserver.jsonl')}):
            local=json.loads(data[folder+'/result.json']);file=local.get('hostJournalFile')
            if not file:continue
            action=action_record(json.loads(data[folder+'/'+file]))
            require(action,'archivedFormalJournalBindingFailed')
            rows=[]
            for line in data[folder+'/windowserver.jsonl'].splitlines():
                r=json.loads(line);top=r['topology'];rec=next(v for v in top['records'] if v['id']==top['current'])
                rows.append(dict(event='sample',spaceStable=True,display=top['display'].upper(),current=top['current'],spaceUUID=rec['uuid'].upper(),
                                 workspaceFrontPID=r.get('frontPID'),hid=r.get('hid'),uptime=r['uptime']))
            quality=classify(rows,action,historical=True)
            pressed=json.loads(data[folder+'/ax-dispatch.json'])['uptime']
            for event in quality['events']:
                event['secondsAfterAXPress']=round(event['uptime']-pressed,6)
            verified.append(dict(folder=folder,historicalNavigation=local.get('navigationStatus',local['status']),
                                 historicalVisual=local.get('blankScreen'),**quality))
        item=dict(archiveSHA256=digest,archiveVerified=validated['verification'],historicalGate=validated['recordedStatus'],
                  actualConfirmedArchivedCount=len(verified),classifications=verified)
        if name.startswith('18-'):
            late=json.loads((directory/'late-change-readback.json').read_bytes())
            refused=json.loads(data['ten-02/result.json']);last=next(x for x in verified if x['folder']=='ten-01')
            require(not refused['axIssued'] and not refused['hostIssued'] and last['operation'].lower()==late['acceptedSignedOperation']['uuid'],
                    'lateChangeOrRefusalDoesNotBelongToThisOperation')
            item['afterLastTen01Sample']=dict(nextPressIssued=False,nextAdmissionStoredNumericSample=False,
                nextPressRefusedAt=late['nextPress']['stoppedAt'],lastIndependentRead=late['acceptedSignedOperation']['lastStableIndependentRead'],
                laterDocumentedSpace=late['afterStop']['ordinarySpace'],unchangedLegacyCounters=late['afterStop']['eightInputCountersEqual'],
                exactTransitionTime=None,externalSignedProcess=None,causalAttribution='UNKNOWN',
                sourceSHA256=hashlib.sha256((directory/'late-change-readback.json').read_bytes()).hexdigest())
        cases[name]=item
    return dict(mode='offlineImmutableHistoricalReplay',liveTrigger='NOT_RUN',productionGestures=0,dependentFifty='NOT_RUN',
                legacyCannotProveTenSecondsOrContinuousNextAdmission=True,cases=cases)


if __name__=='__main__':
    os.umask(0o077)
    p=argparse.ArgumentParser(description=__doc__);subs=p.add_subparsers(dest='mode',required=True)
    h=subs.add_parser('replay');h.add_argument('--output',type=Path)
    live=subs.add_parser('observe');live.add_argument('kit',type=Path);live.add_argument('output',type=Path)
    live.add_argument('--seconds',type=float,default=45)
    live.add_argument('--managed',action='store_true')
    marker=subs.add_parser('admission');marker.add_argument('output',type=Path)
    inspect=subs.add_parser('summarize');inspect.add_argument('output',type=Path)
    a=p.parse_args()
    if a.mode=='replay':
        value=history()
        if a.output:write(a.output,value)
    elif a.mode=='observe':value=capture(a.kit.resolve(),a.output.resolve(),a.seconds,a.managed)
    elif a.mode=='summarize':
        folder=a.output.resolve();log=read_rows(folder/'events.jsonl')
        session=next((r.get('session') for r in log if r.get('event')=='started'),None)
        operations=[json.loads(p.read_bytes()) for p in (folder/'operations').glob('*.json')]
        checkpoints=[json.loads(p.read_bytes()) for p in (folder/'admissions').glob('*.json')]
        value=dict(mode='offlineRecordedMonitor',confirmedOperations=len(operations),observations=course(
            log,operations,[r for r in checkpoints if r.get('session')==session]),physicalInputsPosted=0)
    else:value=admission(a.output.resolve())
    print(json.dumps(value,ensure_ascii=False,indent=2))
    if (a.mode=='observe' and value['status']=='UNKNOWN') or (a.mode=='admission' and value['state']!='observed'):sys.exit(2)
