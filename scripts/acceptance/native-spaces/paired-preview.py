#!/usr/bin/env python3
"""Measure a signed installed Host's actual simultaneous live thumbnails on a clean ordinary Space."""
import argparse
import json
import os
from pathlib import Path
import plistlib
import signal
import subprocess
import tempfile
import time
import uuid

from acceptance import encode, identity, wait_state
from installed_profile import APP, PROFILE, installed_pid, owns_profile
from paired_preview_metrics import summarize


def read(args, timeout=6):
    return json.loads(subprocess.check_output([str(a) for a in args], text=True, timeout=timeout))


def collect(command, proof, folder):
    proc = subprocess.Popen([command, folder], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                            text=True, start_new_session=True)
    try:
        raw, _ = proc.communicate(input=json.dumps(proof), timeout=32)
        timed_out = False
    except subprocess.TimeoutExpired:
        if proc.poll() is None and os.getpgid(proc.pid)==proc.pid:
            os.killpg(proc.pid, signal.SIGKILL)
        raw, _ = proc.communicate(timeout=3)
        timed_out = True
    records=[]
    for line in raw.splitlines():
        try: records.append(json.loads(line))
        except ValueError: records.append({'refusal':'incompleteSamplerReply'})
    return records,proc.returncode,timed_out


def run(kit, output, preflight_only=False, expected_space=None):
    output.mkdir(mode=0o700, parents=True, exist_ok=False)
    result={'status':'BLOCKED','scope':'two synthetic ordinary documents, same active Space, actual installed Host sidebar',
            'preflightOnly':preflight_only,'fixtureLaunched':False,'captureAttempted':False,'cleanup':{'status':'NOT_RUN'},
            'nativeStageManagerComparison':{'status':'NOT_MEASURED','latencyMs':None},'samples':[]}
    receipt=output/'result.json'
    def save():
        temporary=output/'result.next';temporary.write_text(encode(result));os.replace(temporary,receipt)
    save()
    try:
        if kit.parent!=Path('/private/tmp') or not kit.name.startswith('nearpane-d01.') or kit.stat().st_uid!=os.getuid() or kit.stat().st_mode&0o077:
            raise ValueError('unqualifiedBuildDirectory')
        app=kit/'Field Notes.app'; fixture=app/'Contents/MacOS/FieldNotes'
        subprocess.run(['codesign','--verify','--strict','--deep','-R=identifier "com.holdsnow.nearpane.alpha"',APP],check=True,timeout=8)
        subprocess.run(['codesign','--verify','--strict','-R=identifier "net.example.spaces-document"',app],check=True,timeout=6)
        plist=plistlib.loads((APP/'Contents/Info.plist').read_bytes()); host=installed_pid(); host_hash=identity(APP)['CDHash']
        result['installed']={'bundle':plist['CFBundleIdentifier'],'build':plist['CFBundleVersion'],'source':plist.get('NearpaneSourceRevision'),'cdHash':host_hash,'pid':host}
        if not host or not host_hash: raise ValueError('installedHostUnavailable')
        cmd=[kit/'paired-scope',host,host_hash]
        before=read(cmd);result['preflight']=before;save()
        if not before.get('ready'):raise ValueError(before.get('reason','incompletePreflight'))
        if expected_space is not None and before['space']!=expected_space:raise ValueError('unexpectedActiveDesktop')
        if preflight_only:
            result.update(status='READY',reason='physical run not requested');return 0
        test_home=os.environ.get('NEARPANE_TEST_HOME');profile=Path(test_home)/PROFILE if test_home else None
        if not profile or not owns_profile(host,profile):raise ValueError('installedHostMustOwnIsolatedProfile')
        fixture_hash=identity(fixture)['CDHash']
        with tempfile.TemporaryDirectory(prefix='nearpane-preview-pair.',dir='/private/tmp') as temporary:
            folder=Path(temporary)/str(uuid.uuid4());folder.mkdir(mode=0o700)
            home=Path(temporary)/'home';home.mkdir(mode=0o700)
            proc=subprocess.Popen([fixture,folder,'2'],env={**os.environ,'HOME':str(home),'CFFIXED_USER_HOME':str(home),
                                  'NP_FIXTURE_PRESENTATION':'paired-preview'},
                                  stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
            result['fixtureLaunched']=True;result['cleanup']={'status':'UNKNOWN'};numbers=[]
            try:
                state=wait_state(folder/'windows.json',lambda s:s.get('pid')==proc.pid and s.get('session')==folder.name and
                                 s.get('presentation')=='paired-preview' and (s.get('birth') or 0)>0 and len(set(s.get('numbers',[])))==2
                                 and s.get('visible')==[True,True],time.monotonic()+5)
                if not state:raise ValueError('twoOwnedSourceWindowsUnavailable')
                numbers=state['numbers']; result['fixture']={k:state[k] for k in ('pid','birth','numbers','presentation')}
                query=cmd+[proc.pid,state['birth'],fixture_hash,fixture,*numbers,before['space']]
                deadline=time.monotonic()+8;proof={}; attempts=[];result['geometryReads']=attempts
                while deadline-time.monotonic()>.3:
                    proof=read(query, min(5,deadline-time.monotonic()))
                    attempts.append({k:proof[k] for k in ('ready','reason','present','kinds','ordinaryCount','panel') if k in proof})
                    if proof.get('ready'):break
                    if proof.get('reason') not in ('missingOrUnexpectedSidebarCard','boundPictureGeometryUnavailable','activeSpaceContainsUnexpectedMembers'):break
                    time.sleep(.15)
                if not proof.get('ready'):raise ValueError(proof.get('reason','noBoundSourceAndSidebarGeometry'))
                invariant=('hostPID','hostBirth','hostHash','display','space','panel')
                if any(proof[k]!=before[k] for k in invariant) or not owns_profile(host,profile):raise ValueError('hostOrDesktopChanged')
                result['binding']=proof;result['captureAttempted']=True;save()
                events,exit_code,timed_out=collect(kit/'paired-capture',proof,folder)
                batches=[e['batch'] for e in events if 'batch' in e];result['samples']=batches
                result['sampler']={'exit':exit_code,'timedOut':timed_out,'events':[e for e in events if 'batch' not in e]}
                result['metrics']=summarize(batches);save()
                after=read(query);result['finalBinding']=after
                keys=(*invariant,'numbers','fixtureBirth','fixtureHash','fixturePID','sources','pictures')
                if not after.get('ready') or any(after.get(k)!=proof[k] for k in keys) or not owns_profile(host,profile):raise ValueError('finalIdentityOrGeometryChanged')
                if exit_code or not any(e.get('completedBatches')==len(batches) for e in events):
                    reasons=[e['refusal'] for e in events if 'refusal' in e];raise ValueError(reasons[-1] if reasons else 'samplerDidNotComplete')
                result['status']=result['metrics']['status']
            finally:
                (folder/'close').touch();forced=False
                try:proc.wait(4)
                except subprocess.TimeoutExpired:
                    forced=True;proc.terminate();proc.wait(3)
                gone=None
                if numbers:
                    stop=time.monotonic()+3;gone=False
                    while time.monotonic()<stop:
                        if read([kit/'observe','absence',*numbers],3).get('allGone') is True:gone=True;break
                        time.sleep(.12)
                result['cleanup']={'status':'PASS' if proc.returncode==0 and not forced and (gone is True or not numbers) else 'FAIL',
                                   'fixtureExitCode':proc.returncode,'forced':forced,'windowNumbersGone':gone}
                save()
    except (ValueError,KeyError,OSError,RuntimeError,subprocess.SubprocessError) as error:
        result['reason']=str(error)[:200]
        if result['status']=='PASS':result['status']='INCONCLUSIVE'
    finally:
        if result['cleanup']['status']=='FAIL':result['status']='FAIL'
        if result['fixtureLaunched'] and result['cleanup']['status']=='UNKNOWN':result['status']='INCONCLUSIVE'
        save()
    return 0 if result['status'] in ('READY','PASS') else 2


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('kit',type=Path);parser.add_argument('output',type=Path)
    parser.add_argument('--preflight-only',action='store_true',help='read installed sidebar visibility and current sterile ordinary Space without launching any fixture')
    parser.add_argument('--expected-space',type=int,help='require this exact already-active ordinary Space')
    args=parser.parse_args();raise SystemExit(run(args.kit.resolve(),args.output.resolve(),args.preflight_only,args.expected_space))
