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
from paired_preview_audit import PairedWindowAudit
from paired_preview_metrics import summarize
from preview_support import copy_witnesses, overview, with_current_streams, surface_checkpoint


def read(args, timeout=6):
    return json.loads(subprocess.check_output([str(a) for a in args], text=True, timeout=timeout))


def collect(command, proof, folder, retain=False):
    proc = subprocess.Popen([command, folder], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                            text=True, start_new_session=True,env={**os.environ,"NEARPANE_PAIRED_EVIDENCE":"1" if retain else "0"})
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


ERRORS=(ValueError,KeyError,OSError,RuntimeError,subprocess.SubprocessError)
INVARIANT=("hostPID","hostBirth","hostHash","display","space","panel")
PROOF_KEYS=("ready","reason","present","kinds","ordinaryCount","panel","hostCardCount","windowCensus","sourceProven",
            "launchServices","fixtureBirth","numbers","hostBirth","space")

def measured(action):
    try:return action()
    except ERRORS as error:return {"status":"BLOCKED","reason":str(error)[:200]}

def casework(kit,output,folder,query,host,host_hash,profile,before,budget,witness,cross_space,result,save,audit,independent_source=None):
    def fresh():
        value=read(query)
        if any(value.get(k)!=before[k] for k in INVARIANT if k!="panel") or not owns_profile(host,profile):
            raise ValueError("hostOrDesktopChanged")
        return value
    def required(*,cards=False,sterile=False):
        proof=fresh()
        if not proof.get("sourceProven"):raise ValueError(proof.get("reason","enrolledVisibleSourcesUnproven"))
        if sterile and (proof.get("hardware")!=before.get("hardware") or not proof.get("windowCensus",{}).get("admitted")):
            raise ValueError("controlledCensusContainsUnverifiedOwnersOrDocumentsOrNewInput")
        if cards and not proof.get("ready"):raise ValueError(proof.get("reason","productionCardsUnproven"))
        return proof
    attempts=[];result["geometryReads"]=attempts;deadline=time.monotonic()+8
    proof={};last_error=None
    while deadline-time.monotonic()>.45:
        try:
            sample=read(query, min(5,deadline-time.monotonic()))
            attempts.append({k:sample[k] for k in PROOF_KEYS if k in sample})
            proof=sample
            if sample.get("ready") and sample.get("kinds")==["窗口画面","窗口画面"]:break
            if not sample.get("ready") and sample.get("reason") not in ("missingOrUnexpectedSidebarCard","boundPictureGeometryUnavailable",
                    "activeSpaceContainsUnexpectedMembers","fixtureLaunchServicesRegistrationUnconfirmed","ordinaryWindowCensusIncomplete"):break
        except ERRORS as error:
            last_error=type(error).__name__;attempts.append({"readError":last_error})
        time.sleep(.15)
    save()
    if audit:result["auditBeforeSampling"]=measured(lambda:audit.evidence("before-sampling"))
    events=[];batches=[]
    try:
        if not proof.get("ready"):raise ValueError(proof.get("reason") or last_error or "noBoundSourceAndSidebarGeometry")
        proof=required(cards=True);result["binding"]=proof;result["captureAttempted"]=True;save()
        events,exit_code,timed_out=collect(kit/"paired-capture",proof,folder,witness)
        batches=[e["batch"] for e in events if "batch" in e];result["samples"]=batches
        result["sampler"]={"exit":exit_code,"timedOut":timed_out,"events":[e for e in events if "batch" not in e]}
        result["metrics"]=summarize(batches)
        after=required(cards=True);result["finalBinding"]=after
        keys=(*INVARIANT,"numbers","fixtureBirth","fixtureHash","fixturePID","sources","pictures")
        if any(after.get(k)!=proof[k] for k in keys):raise ValueError("finalIdentityOrGeometryChanged")
        if witness:
            result["witnessFiles"]=copy_witnesses(folder,output,events,batches,after)
        if exit_code or timed_out or not any(e.get("completedBatches")==len(batches) for e in events):
            reasons=[e["refusal"] for e in events if "refusal" in e]
            raise ValueError(reasons[-1] if reasons else "samplerDidNotComplete")
        result["status"]=result["metrics"]["status"];result["sampler"]["status"]=result["status"]
    except ERRORS as error:
        result["reason"]=str(error)[:220]
        result.setdefault("sampler",{})["status"]="BLOCKED"
        if "metrics" not in result:
            result["metrics"]=summarize([]);result["metrics"]["status"]="NOT_MEASURED"
            result["metrics"]["sampling"]["samePanelFrame"]=None
    save()
    host_id={"pid":host,"codeHash":host_hash}
    if witness or budget:
        result["twoCardSurface"]=measured(lambda:surface_checkpoint(kit,host_id,before["space"],False,2));save()
    if witness:
        result["overview"]=measured(lambda:overview(kit,folder,output,required(cards=True)));save()
    if budget:
        def hidden():
            value=required(cards=True,sterile=True)
            if value.get("kinds")!=["窗口画面","窗口画面"]:raise ValueError("bothInstalledCardsAreNotLive")
            return with_current_streams(kit,host_id,lambda:owns_profile(host,profile),fresh,output/"hidden")
        result["hiddenBudget"]=measured(hidden);save()
    if cross_space:
        def switch():
            source=independent_source() if independent_source else required(sterile=True)
            result["systemSwitchAdmission"]=source
            return cross_space(source)
        result["systemDesktopSwitch"]=measured(switch);save()

def run(kit, output, preflight_only=False, expected_space=None, witness=False, budget=False, cross_space=None):
    os.umask(0o077)
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
        if (witness or budget or cross_space) and before.get('stageManager') is not False:raise ValueError('stageOffForThisAcceptanceUnverified')
        if expected_space is not None and before['space']!=expected_space:raise ValueError('unexpectedActiveDesktop')
        if preflight_only:
            result.update(status='READY',reason='physical run not requested');return 0
        test_home=os.environ.get('NEARPANE_TEST_HOME');profile=Path(test_home)/PROFILE if test_home else None
        if not profile or not owns_profile(host,profile):raise ValueError('installedHostMustOwnIsolatedProfile')
        fixture_hash=identity(fixture)['CDHash']
        with tempfile.TemporaryDirectory(prefix='nearpane-preview-pair.',dir='/private/tmp') as temporary:
            folder=Path(temporary)/str(uuid.uuid4());folder.mkdir(mode=0o700)
            home=Path(temporary)/'home';home.mkdir(mode=0o700)
            proc=subprocess.Popen(["/usr/bin/open","-n","-W","-g","-a",str(app),"--env","HOME="+str(home),
                                   "--env","CFFIXED_USER_HOME="+str(home),"--env","NP_FIXTURE_PRESENTATION=paired-preview",
                                   "--args",str(folder),"2"],stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
            result["fixtureLaunched"]=True;result["cleanup"]={"status":"UNKNOWN"};numbers=[];state={};audit=None;expected=None
            try:
                state=wait_state(folder/"windows.json",lambda s:s.get("session")==folder.name and s.get("bundle")=="net.example.spaces-document"
                                 and s.get("presentation")=="paired-preview" and (s.get("pid") or 0)>1 and (s.get("birth") or 0)>0
                                 and len(set(s.get("numbers",[])))==2 and s.get("visible")==[True,True],time.monotonic()+7)
                if not state:raise ValueError("twoOwnedLaunchServicesSourceWindowsUnavailable")
                fixture_pid=state["pid"];numbers=state["numbers"]
                expected=dict(pid=fixture_pid,birth=state["birth"],identifier="net.example.spaces-document",executable=str(fixture),hash=fixture_hash)
                observed=read([kit/"p0-card","process",fixture_pid])
                if observed!=expected:raise ValueError("launchServicesFixtureKernelGenerationMismatch")
                result["fixture"]={k:state[k] for k in ("pid","birth","numbers","presentation","key","main")}
                result["fixture"].update(launcher="Apple Launch Services new instance",kernelGenerationMatches=True)
                try:
                    installed=read([kit/"p0-card","process",host])
                    if (installed.get("pid"),installed.get("birth"),installed.get("hash"))!=(host,before["hostBirth"],host_hash):
                        raise ValueError("installedHostGenerationChangedBeforeAudit")
                    audit=PairedWindowAudit(Path(test_home),output,kit,installed)
                    audit.bind(observed,expected,numbers)
                except ERRORS as error:
                    result["hostAudit"]={"status":"UNAVAILABLE","reason":str(error)[:200]};audit=None
                query=cmd+[fixture_pid,state["birth"],fixture_hash,fixture,*numbers,before["space"]]
                def independent_source():
                    current=read([kit/"preview-surface","members",host,host_hash,fixture_pid,state["birth"],fixture_hash,*numbers,before["space"]])
                    census=current.get("sourceCensus",{})
                    result["systemSwitchAdmissionRead"]=current
                    if (not current.get("available") or current.get("hostBirth")!=before["hostBirth"] or not owns_profile(host,profile)
                            or current.get("hardware")!=before.get("hardware") or current.get("current")!=before["space"]
                            or not current.get("fixtureRegularRegistered") or current.get("numbers")!=numbers or current.get("reverse")!=[[before["space"]]]*2
                            or not census.get("admitted")):raise ValueError("independentTwoDocumentCleanDesktopBeforeSwitchUnconfirmed")
                    return dict(hostBirth=before["hostBirth"],hostPID=host,space=before["space"],fixturePID=fixture_pid,fixtureBirth=state["birth"],
                                fixtureHash=fixture_hash,numbers=numbers,sourceProven=True,windowCensus=census)
                casework(kit,output,folder,query,host,host_hash,profile,before,budget,witness,cross_space,result,save,audit,independent_source)
            finally:
                if audit:result["hostAudit"]=measured(lambda:audit.evidence("final",release=True))
                (folder/"close").touch();forced=False;fixture_terminated=False
                try:proc.wait(5)
                except subprocess.TimeoutExpired:
                    forced=True
                    if expected and measured(lambda:read([kit/"p0-card","process",expected["pid"]]))==expected:
                        try:os.kill(expected["pid"],signal.SIGTERM);fixture_terminated=True
                        except ProcessLookupError:pass
                    try:proc.wait(2)
                    except subprocess.TimeoutExpired:proc.terminate();proc.wait(2)
                gone=None;generation_gone=None
                if numbers:
                    stop=time.monotonic()+4;gone=False
                    while time.monotonic()<stop:
                        if read([kit/"observe","absence",*numbers],3).get("allGone") is True:gone=True;break
                        time.sleep(.12)
                    try:os.kill(state["pid"],0);generation_gone=False
                    except ProcessLookupError:generation_gone=True
                result["cleanup"]={"status":"PASS" if proc.returncode==0 and not forced and gone is True and generation_gone is True else "FAIL",
                                   "launcherExitCode":proc.returncode,"fixtureProcessAbsent":generation_gone,"forced":forced,"forcedFixtureTermination":fixture_terminated,"windowNumbersGone":gone}
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
    parser.add_argument('--witness',action='store_true',help='retain only fully verified synthetic color patches and eligible preview media')
    parser.add_argument('--hidden-budget',action='store_true',help='reuse the one-minute installed status-menu contract while these same two windows exist')
    args=parser.parse_args();raise SystemExit(run(args.kit.resolve(),args.output.resolve(),args.preflight_only,args.expected_space,args.witness,args.hidden_budget))
