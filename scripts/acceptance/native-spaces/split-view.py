#!/usr/bin/env python3
"""Exercise the native fullscreen tiling menu for two leased documents and read the installed sidebar."""
import argparse
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


def run(kit, output, target):
    output.mkdir(mode=0o700, parents=True, exist_ok=False)
    result = {'status':'BLOCKED','fixtureLaunched':False, 'tile':{'issued':False}, 'pair':{'issued':False},
              'systemPair':'NOT_RUN','installedLayout':'NOT_RUN','cleanup':{'status':'NOT_RUN'},
              'observations':[], 'physicalSource':'two synthetic documents only', 'pixelsRead':0}
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
        display, protected = lease_identity(Path(os.environ['NEARPANE_SPLIT_LEASE']), target)
        host_hash = identity(APP)['CDHash']
        clean = read([kit/'paired-scope',host,host_hash])
        require(clean.get('ready') and clean.get('stageManager') is False and clean.get('display')==display
                and clean.get('space')==target and clean['ordinaryCount']==0, 'isolatedStageOffEmptyOrdinaryDesktopUnavailable')
        info = plistlib.loads((APP/'Contents/Info.plist').read_bytes())
        result['install'] = dict(pid=host,birth=clean['hostBirth'],cdHash=host_hash,source=info.get('NearpaneSourceRevision'),
                                 build=info.get('CFBundleVersion'))
        result['lease']=dict(display=display,id=target,uuid=protected[str(target)])
        fixture_hash=identity(fixture)['CDHash']
        with tempfile.TemporaryDirectory(prefix='nearpane-split-view.',dir='/private/tmp') as tmp:
            session=str(uuid.uuid4())
            folder=Path(tmp)/session;folder.mkdir(mode=0o700)
            fixture_home=Path(tmp)/'home';fixture_home.mkdir(mode=0o700)
            proc=subprocess.Popen([fixture,folder],env={**os.environ,'HOME':str(fixture_home),'CFFIXED_USER_HOME':str(fixture_home)},
                                  stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
            result.update(fixtureLaunched=True,cleanup={'status':'UNKNOWN'})
            numbers=[]; save()
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
                before=wait_ordinary_control(sample,target,deadline=time.monotonic()+4)
                req['hardware']=before['hardware']
                request=str(uuid.uuid4())
                tmp_request=folder/'next.json';tmp_request.write_text(json.dumps(dict(nonce=request,action='activate',index=0)))
                os.replace(tmp_request, folder/'request.json')
                require(wait_state(folder/'windows.json',lambda s:s.get('lastCommand')==request and s.get('key')==numbers[0],
                                   time.monotonic()+4), 'firstFixtureDocumentCouldNotBeFocused')
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
                    require(picker.get('ready'),picker.get('reason','uniqueOwnedSystemPickerUnavailable'))
                    result['pair']={'issued':None};save()
                    pair=sample('pair')
                    result['pair']={k:pair[k] for k in ('issued','axError','mouseEvents','reason','labelMatches','route') if k in pair};save()
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
                if (result['pair'].get('issued') is not False or result['tile'].get('issued') is None
                    or result['tile'].get('axError',0)!=0):
                    result['status']='UNKNOWN'
            finally:
                try:
                    (folder/'close').touch()
                    forced=False
                    try: proc.wait(timeout=7)
                    except subprocess.TimeoutExpired:
                        forced=True;proc.terminate();proc.wait(timeout=4)
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
                            if all(restoration.values()):break
                        time.sleep(.18)
                    result['cleanup']=dict(status='PASS' if restoration and all(restoration.values()) and proc.returncode==0 and not forced else 'FAIL',
                                           exit=proc.returncode,forced=forced,**restoration)
                    save()
                except (OSError,ValueError,KeyError,TypeError,RuntimeError,subprocess.SubprocessError) as error:
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
    args=parser.parse_args()
    os.umask(0o077)
    raise SystemExit(run(args.kit.resolve(),args.output.resolve(),args.expected_space))
