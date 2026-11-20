#!/usr/bin/env python3
"""Exercise the native fullscreen tiling menu for two leased documents and read the installed sidebar."""
import argparse
import contextlib
import shutil
import json
import math
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import time
import uuid

from acceptance import encode, identity, wait_state
from installed_profile import APP, PROFILE, installed_pid, owns_profile
from space_scope import LEDGERS, private_file
import split_fullscreen


def require(value, reason):
    if not value:
        raise ValueError(reason)


def document(path):
    return json.loads(private_file(path))


def read(command, *, payload=None, timeout=5):
    raw = subprocess.check_output(list(map(str, command)), input=json.dumps(payload) if payload is not None else None,
                                  text=True, timeout=timeout, stderr=subprocess.DEVNULL)
    return json.loads(raw)


def lease_identity(path, target):
    require(path.name == 'created.json' and path.parent.name == 'provision' and
            path.parent.parent.parent == LEDGERS and not path.with_name('removed.json').exists()
            and not path.with_name('remove-intent.json').exists(), 'expectedActivePrivateWorkspaceLease')
    made = document(path)
    intent = document(path.with_name('create-intent.json'))
    boot = subprocess.check_output(['/usr/sbin/sysctl', '-n', 'kern.bootsessionuuid'], text=True).strip()
    key = str(target)
    require(made['intent'] == intent and intent['boot'] == boot and 0 <= time.monotonic() - intent['issuedUptime'] < 900
            and made['target'] == key and key not in intent['initial']['sideOrder'], 'wrongExpiredOrChangedLease')
    after = made['after']
    protected = after['spaceUUIDs']
    require([k for k in after['sideOrder'] if k != key] == intent['initial']['sideOrder'] and
            after['sideOrder'].count(key) == 1 and key not in after['fullscreenIDs'] and
            set(after['sideOrder']) == set(protected) and len({uuid.UUID(s) for s in protected.values()}) == len(protected)
            and all(protected[k] == v for k, v in intent['initial']['spaceUUIDs'].items()), 'unprovenOrdinarySpaceCreation')
    return intent['display'], protected


def rect(value):
    return (isinstance(value, list) and len(value) == 4 and
            all(isinstance(v, (int, float)) and not isinstance(v, bool) and math.isfinite(v) for v in value)
            and value[2] > 0 and value[3] > 0)


def system_pair(state, lease):
    sid = state.get('space')
    if not (state.get('type') == 4 and sid != lease and state.get('newFullscreenIDs') == [sid] and
            state.get('memberships') == [[sid], [sid]] and state.get('forward') == [True, True] and
            state.get('drawn') == [True, True] and state.get('axStandard') == [True, True] and
            state.get('foreignVisibleMembers') == 0 and state.get('unknownVisibleMembers') == 0):
        return False
    cg, ax, screen = state.get('cgFrames', []), state.get('axFrames', []), state.get('displayFrame')
    if len(cg) != 2 or len(ax) != 2 or not all(map(rect, [*cg, *ax, screen])):
        return False
    if any(abs(x-y) > 2 for f, g in zip(cg, ax) for x, y in zip(f, g)):
        return False
    l, r = sorted(cg, key=lambda f: f[0])
    gap = r[0] - (l[0]+l[2])
    return (abs(l[0]-screen[0]) <= 2 and abs(r[0]+r[2]-screen[0]-screen[2]) <= 2 and
            0 <= gap <= 24 and abs(l[1]-r[1]) <= 2 and abs(l[3]-r[3]) <= 2 and
            0 <= l[1]-screen[1] <= screen[3]*.10 and
            abs(l[1]+l[3]-(screen[1]+screen[3])) <= 2)


def host_layout(state):
    if state.get('hostPanelPresent') is not True or state.get('hostGroupCount') != 1 or state.get('hostMemberCounts') != [1, 1]:
        return False
    group = state.get('hostGroupFrame')
    pictures = state.get('hostPaneFrames', [])
    if not rect(group) or len(pictures) != 2 or not all(map(rect, pictures)):
        return False
    src = state['displayFrame']
    scale = group[2]/src[2]
    if not 0 < scale < 1:
        return False
    allowed = 2  # AX rounds points on both the display and small sidebar.
    for actual, frame in zip(pictures, state['cgFrames']):
        expected = [group[0]+(frame[0]-src[0])*scale, group[1]+(frame[1]-src[1])*scale,
                    frame[2]*scale, frame[3]*scale]
        if any(abs(a-e)>allowed for a,e in zip(actual,expected)):
            return False
    return True


def signature(state):
    return [state.get(k) for k in ('display','space','spaceUUID','cgFrames','axFrames',
                                   'hostGroupFrame','hostPaneFrames')]


def ordinary_control(state, target):
    if state.get('reason'):
        return state['reason']
    checks=(
        ('systemReadUnavailable',state.get('ready') is True),
        ('ordinaryLeaseIsNoLongerCurrent',state.get('space')==target and state.get('type')==0 and state.get('newFullscreenIDs')==[]),
        ('leaseDoesNotContainExactlyTwoEnrolledDocuments',state.get('onlyTwoInLease') is True),
        ('foreignVisibleWindowOnLeasedDesktop',state.get('foreignVisibleMembers')==0),
        ('visibleWindowNativeMembershipUnresolved',state.get('unknownVisibleMembers')==0),
        ('oneOrBothDocumentsHaveDifferentNativeMembership',state.get('memberships')==[[target],[target]]),
        ('notTwoLiveStandardAXDocuments',state.get('axStandard')==[True,True]),
        ('ordinaryWindowsAlreadyShownAsNativeSplit',state.get('hostGroupCount')==0))
    return next((name for name,ok in checks if not ok),None)


def wait_ordinary_control(sample, target, *, deadline):
    # Inventory and AX publication can lag the fixture's own windows.json. Repeat reads
    # only, retain their real denials, and never dispatch anything while a check is unresolved.
    transient={'exactWindowIdentityOrMembershipUnavailable','leaseDoesNotContainExactlyTwoEnrolledDocuments',
               'notTwoLiveStandardAXDocuments','oneOrBothDocumentsHaveDifferentNativeMembership','installedHostAXHandleUnavailable'}
    baseline=None
    while True:
        state=sample()
        require(baseline is None or state.get('hardware')==baseline,'physicalInputChangedWhileWaitingForOrdinaryDocuments')
        baseline=state.get('hardware')
        reason=ordinary_control(state,target)
        if reason is None:return state
        if reason not in transient or time.monotonic()>=deadline:raise ValueError(reason)
        time.sleep(.15)


@contextlib.contextmanager
def fixture_directory():
    tmp=Path(tempfile.mkdtemp(prefix='nearpane-split-view.',dir='/private/tmp'))
    try:yield tmp
    finally:
        if not (tmp/'retain-for-owned-exit').exists():shutil.rmtree(tmp)


def fullscreen_admission(kit,host,host_hash,display,target,protected):
    """Only the leased ordinary Space is inspected for ordinary documents."""
    last=None;types=None;host_numbers=None
    for _ in range(2):
        raw=subprocess.check_output([kit/'observe'],env={**os.environ,'NEARPANE_CONTRACT_SPACE_IDS':str(target)},
                                    timeout=6,stderr=subprocess.DEVNULL)
        view=json.loads(raw);installed=view.get('host') or {};scopes=view.get('scopes') or []
        require(len(scopes)==len(view.get('displays',[]))==1 and view.get('installedHostCount')==1 and
                installed.get('pid')==host and installed.get('codeHash')==host_hash,'installedHostOrDisplayIdentityChanged')
        scope=scopes[0];kind={str(r['id']):r['uuid'] for r in scope['records']}
        current_types={str(r['id']):r['type'] for r in scope['records']}
        require(types is None or current_types==types,'protectedSpaceTypesChangedDuringAdmission')
        types=current_types
        require(scope.get('scope')==display and scope.get('current')==target and protected==kind and
                any(r['id']==target and r['type']==0 for r in scope['records']),'sourceIsNotEnrolledCurrentOrdinarySpace')
        c=(view.get('scopedMembers') or {}).get(str(target),{});layers=c.get('otherDetails',[])
        permitted={'com.apple.dock','com.apple.WindowManager','com.apple.WindowServer'}
        require(c.get('ordinary')==[] and c.get('unresolved')==0 and c.get('otherMembers')==len(layers) and all(
            v.get('installedHost')==1 or (v.get('code',{}).get('apple') is True and v['code'].get('identifier') in permitted)
            for v in layers),'leasedFullscreenSourceNotIndependentlyEmpty')
        witnessed=split_fullscreen.host_window_numbers(layers,host,target)
        require(host_numbers is None or witnessed==host_numbers,'isolatedHostSurfaceChangedDuringAdmission')
        host_numbers=witnessed
        stage=view.get('stageManager')
        require(isinstance(stage,bool) and (last is None or stage==last),'stagePreferenceUnstable')
        last=stage;time.sleep(.18)
    birth=int(subprocess.check_output([kit/'system-workspace','birth',str(host)],timeout=4))
    return dict(hostBirth=birth,stageManager=last,protectedTypes=types,enrolledHostWindows=host_numbers)


def run(kit, output, target, *, fullscreen_roundtrip=False, resume_workspace=None):
    output.mkdir(mode=0o700, parents=True, exist_ok=False)
    result = {'status':'BLOCKED','fixtureLaunched':False, 'tile':{'issued':False}, 'pair':{'issued':False},
              'systemPair':'NOT_RUN','installedLayout':'NOT_RUN','cleanup':{'status':'NOT_RUN'},
              'observations':[], 'physicalSource':'two synthetic documents only', 'pixelsRead':0}
    if fullscreen_roundtrip:
        result.update(mode='fullscreen-roundtrip',fullscreen={'status':'NOT_RUN'},systemPair='NOT_RUN',installedLayout='NOT_RUN')
    save = lambda: save_receipt(output, result)
    save()
    try:
        require(kit.parent==Path('/private/tmp') and kit.name.startswith('nearpane-d01.') and
                kit.stat().st_uid==os.getuid() and not kit.stat().st_mode & 0o077, 'unqualifiedBuildDirectory')
        home = Path(os.environ['NEARPANE_TEST_HOME'])
        fixture = kit/'Split Notes.app/Contents/MacOS/SplitNotes'
        host = installed_pid()
        require(host and owns_profile(host, home/PROFILE), 'installedIsolatedHostRequired')
        for app, identifier in [(APP, 'com.holdsnow.nearpane.alpha'), (fixture.parents[2], 'net.example.spaces-split-documents')]:
            subprocess.run(['codesign','--verify','--strict','--deep','-R=identifier "'+identifier+'"',app],
                           check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=5)
        if resume_workspace:
            require(fullscreen_roundtrip,'resumeOnlyForOwnedSingleWindowFullscreen')
            display,protected=split_fullscreen.resume_lease(resume_workspace,target)
        else:
            display,protected=lease_identity(Path(os.environ['NEARPANE_SPLIT_LEASE']),target)
        host_hash = identity(APP)['CDHash']
        if fullscreen_roundtrip:
            clean=fullscreen_admission(kit,host,host_hash,display,target,protected)
        else:
            clean = read([kit/'paired-scope',host,host_hash])
            require(clean.get('ready') and clean.get('stageManager') is False and clean.get('display')==display
                    and clean.get('space')==target and clean['ordinaryCount']==0, 'isolatedStageOffEmptyOrdinaryDesktopUnavailable')
        info = plistlib.loads((APP/'Contents/Info.plist').read_bytes())
        result['install'] = dict(pid=host,birth=clean['hostBirth'],cdHash=host_hash,source=info.get('NearpaneSourceRevision'),
                                 build=info.get('CFBundleVersion'))
        result['lease']=dict(display=display,id=target,uuid=protected[str(target)])
        fixture_hash=identity(fixture)['CDHash']
        with fixture_directory() as tmp:
            session=str(uuid.uuid4())
            folder=Path(tmp)/session;folder.mkdir(mode=0o700)
            (folder/'normal-fullscreen-exit').touch(mode=0o600)
            fixture_home=Path(tmp)/'home';fixture_home.mkdir(mode=0o700)
            proc=subprocess.Popen([fixture,folder],env={**os.environ,'HOME':str(fixture_home),'CFFIXED_USER_HOME':str(fixture_home)},
                                  stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
            result.update(fixtureLaunched=True,cleanup={'status':'UNKNOWN'})
            numbers=[]; read_full=None; own=None; save()
            try:
                state=wait_state(folder/'windows.json',lambda s:s.get('pid')==proc.pid and s.get('session')==session and
                                 (s.get('birth') or 0)>0 and len(set(s.get('numbers',[])))==2, time.monotonic()+7)
                require(state,'fixtureEnrollmentUnavailable')
                numbers=state['numbers']
                req=dict(hostPID=host,hostBirth=clean['hostBirth'],hostHash=host_hash,fixturePID=proc.pid,
                         fixtureBirth=state['birth'],fixtureHash=fixture_hash,fixturePath=str(fixture),numbers=numbers,
                         session=session,display=display,lease=target,protected=protected)
                result['fixture']=dict(pid=proc.pid,birth=state['birth'],cdHash=fixture_hash,numbers=numbers)
                def sample(verb='read'):
                    require(owns_profile(host,home/PROFILE) and proc.poll() is None,'enrolledProcessesChanged')
                    v=read([kit/'split-view-read','compare-roster',verb],payload=req,timeout=9)
                    result['observations'].append({k:x for k,x in v.items() if k!='hardware'})
                    save()
                    return v
                def own():
                    f=json.loads(private_file(folder/'windows.json'))
                    require(f.get('pid')==proc.pid and f.get('birth')==req['fixtureBirth'] and f.get('session')==session
                            and f.get('numbers')==numbers and proc.poll() is None,'registeredFixtureGenerationChanged')
                    return f
                if fullscreen_roundtrip:
                    req.update(observedStage=clean['stageManager'],protectedTypes=clean['protectedTypes'],
                               enrolledHostWindows=clean['enrolledHostWindows'])
                    result['enrolledHostWindows']=clean['enrolledHostWindows'];save()
                def read_full():
                    v=sample('fullscreen-read')
                    hardware=v.get('hardware')
                    if 'hardware' in req:
                        expected=req['hardware']
                        if result['pair'].get('mouseEvents')==2:
                            allowed=expected.copy();allowed[1]=(allowed[1]+1)&0xffffffff
                        else:allowed=expected
                        require(hardware in (expected,allowed),'hardwareChangedDuringFixtureFullscreenLifecycle')
                    return v
                if fullscreen_roundtrip:
                    first=read_full()
                    require(isinstance(first.get('hardware'),list),'controlledHardwareBaselineUnavailable')
                    req['hardware']=first['hardware']
                    before=split_fullscreen.dwell(read_full,own,lambda s,f:split_fullscreen.ordinary(s,f,target),6)
                else:before=wait_ordinary_control(sample,target,deadline=time.monotonic()+4)
                req['hardware']=before['hardware']
                request=str(uuid.uuid4())
                tmp_request=folder/'next.json';tmp_request.write_text(json.dumps(dict(nonce=request,action='activate',index=0)))
                os.replace(tmp_request, folder/'request.json')
                require(wait_state(folder/'windows.json',lambda s:s.get('lastCommand')==request and s.get('key')==numbers[0],
                                   time.monotonic()+4), 'firstFixtureDocumentCouldNotBeFocused')
                if fullscreen_roundtrip:
                    split_fullscreen.enter(folder,own,read_full,target,result['fullscreen'],save)
                else:
                    # Each system action is delivered at most once. A lost reply is an unknown outcome.
                    result['tile']={'issued':None};save()
                    tile=sample('tile');result['tile']={k:tile[k] for k in ('issued','axError','reason','menuMatches') if k in tile};save()
                    require(tile.get('issued') is True and tile.get('axError')==0,tile.get('reason','nativeLeftMenuDeliveryUnconfirmed'))
                    deadline=time.monotonic()+8; picker={}
                    while time.monotonic()<deadline:
                        picker=sample('picker')
                        if picker.get('ready') or picker.get('alreadyTogether') or picker.get('hardware')!=req['hardware']:break
                        time.sleep(.18)
                    if picker.get('alreadyTogether'):
                        result['pair']={'issued':False,'systemCompletedPairWithoutFurtherInput':True}
                    else:
                        if not picker.get('ready'):
                            result['pair']={k:picker[k] for k in ('reason','pickerReason','route','labelMatches','pickerEvidence') if k in picker}
                            result['pair']['issued']=False
                            save()
                        require(picker.get('ready'),picker.get('reason','uniqueOwnedSystemPickerUnavailable'))
                        result['pair']={'issued':None};save()
                        pair=sample('pair')
                        result['pair']={k:pair[k] for k in ('issued','axError','mouseEvents','reason','labelMatches','route','pickerEvidence','recheckEvidence') if k in pair};save()
                        require(pair.get('issued') is True and pair.get('axError',0)==0,pair.get('reason','secondDocumentDeliveryUnconfirmed'))
                    result.update(status='UNKNOWN',systemPair='UNKNOWN',installedLayout='UNKNOWN')
                    deadline=time.monotonic()+12; last=None; verified=0
                    while time.monotonic()<deadline:
                        actual=sample()
                        if system_pair(actual,target):
                            result['systemPair']='PASS'
                            if host_layout(actual):
                                verified=verified+1 if last==signature(actual) else 1
                                last=signature(actual)
                                if verified>=2:
                                    result.update(status='PASS',installedLayout='PASS')
                                    break
                            else: last=None;verified=0
                        else: last=None;verified=0
                        time.sleep(.24)
                    if result['status']!='PASS':
                        result['reason']='systemPairEstablishedButInstalledGeometryUnconfirmed' if result['systemPair']=='PASS' else 'twoSystemTiledDocumentsUnconfirmed'
            except (OSError,ValueError,KeyError,TypeError,RuntimeError,subprocess.SubprocessError) as error:
                result['reason']=str(error)[:220]
                if ((fullscreen_roundtrip and 'entryIssued' in result['fullscreen']) or result['pair'].get('issued') is not False or result['tile'].get('issued') is None
                    or result['tile'].get('axError',0)!=0):
                    result['status']='UNKNOWN'
            finally:
                exit_proof={}
                if (fullscreen_roundtrip and result['fullscreen'].get('entryIssued','not-attempted')!='not-attempted') or result['tile'].get('issued') is not False:
                    result['fullscreenExit']=exit_proof
                    try:
                        split_fullscreen.unwind(folder,own,read_full,target,exit_proof,save)
                    except (ValueError, OSError, KeyError, TypeError, subprocess.SubprocessError) as error:
                        exit_proof.update(status='UNKNOWN',reason=str(error)[:220])
                    save()
                if fullscreen_roundtrip and result['fullscreen'].get('entry')=='PASS':
                    result['fullscreen']['status']='PASS' if exit_proof.get('status')=='PASS' else 'UNKNOWN'
                    result['status']=result['fullscreen']['status']
                try:
                    if exit_proof and exit_proof.get('status')!='PASS' and proc.poll() is None:
                        (Path(tmp)/'retain-for-owned-exit').touch(mode=0o600)
                        result['cleanup']=dict(status='UNKNOWN',reason='ownedFixtureRetainedUntilVerifiedNormalExit',
                                               directory=str(folder),fixturePID=proc.pid,forced=False)
                        raise ValueError('ownedFixtureRetainedUntilVerifiedNormalExit')
                    (folder/'close').touch()
                    forced=False
                    try: proc.wait(timeout=7)
                    except subprocess.TimeoutExpired:
                        (Path(tmp)/'retain-for-owned-exit').touch(mode=0o600)
                        result['cleanup']=dict(status='UNKNOWN',reason='ownedFixtureRetainedUntilVerifiedNormalExit',
                                               directory=str(folder),fixturePID=proc.pid,forced=False)
                        raise ValueError('ownedFixtureDidNotConfirmNormalClose')
                    restoration={}; until=time.monotonic()+9
                    while time.monotonic()<until:
                        observation=read([kit/'observe'])
                        scopes=observation.get('scopes') or []
                        if len(scopes)==1:
                            s=scopes[0]
                            live={str(v['id']):v['uuid'] for v in s['records']}
                            restoration=dict(onlyOriginalRecords=live==protected,ordinaryLeaseIsCurrent=s['current']==target,
                                             sameDisplay=s['scope']==display,fixtureProcessExited=proc.returncode is not None,
                                             windowsGone=(not numbers or read([kit/'observe','absence',*numbers]).get('allGone') is True))
                            if fullscreen_roundtrip:
                                restoration['protectedTypesRestored']={str(r['id']):r['type'] for r in s['records']}==clean['protectedTypes']
                            if all(restoration.values()):break
                        time.sleep(.18)
                    result['cleanup']=dict(status='PASS' if restoration and all(restoration.values()) and proc.returncode==0 and not forced and exit_proof.get('status','PASS')=='PASS' else 'FAIL',
                                           exit=proc.returncode,forced=forced,**restoration)
                    save()
                except (OSError,ValueError,KeyError,TypeError,RuntimeError,subprocess.SubprocessError) as error:
                    if result['cleanup'].get('reason')!='ownedFixtureRetainedUntilVerifiedNormalExit':
                        result['cleanup']={'status':'FAIL','reason':str(error)[:220]}
                    save()
    except (OSError,ValueError,KeyError,TypeError,RuntimeError,subprocess.SubprocessError) as error:
        result['reason']=str(error)[:220]
        if result['pair'].get('issued') is not False or result['tile'].get('issued') is None:
            result['status']='UNKNOWN'
    finally:
        if result['cleanup']['status'] in ('FAIL','UNKNOWN'):result['status']='FAIL'
        save()
    return 0 if result['status']=='PASS' else 2


def save_receipt(output, result):
    tmp=output/'result.next'
    tmp.write_text(encode(result))
    os.replace(tmp,output/'result.json')


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('kit',type=Path);parser.add_argument('output',type=Path)
    parser.add_argument('--expected-space',type=int,required=True)
    parser.add_argument('--fullscreen-roundtrip',action='store_true',help='verify the real AppKit fullscreen entry and normal exit of document A')
    parser.add_argument('--resume-workspace',type=Path,help='validate the live original workspace and its durable creation ledgers before the fullscreen roundtrip')
    args=parser.parse_args()
    os.umask(0o077)
    raise SystemExit(run(args.kit.resolve(),args.output.resolve(),args.expected_space, fullscreen_roundtrip=args.fullscreen_roundtrip,
                         resume_workspace=args.resume_workspace.resolve() if args.resume_workspace else None))
