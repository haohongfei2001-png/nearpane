"""Normal AppKit entry and exit for the two registered synthetic Split Notes windows."""
import hashlib
import json
import math
import os
from pathlib import Path
import subprocess
import time
import uuid

from space_scope import private_file, require


def resume_lease(workspace, target):
    original=json.loads(private_file(workspace/'original.json'))
    boot=subprocess.check_output(['/usr/sbin/sysctl','-n','kern.bootsessionuuid'],text=True).strip()
    require(boot==original['boot'] and len(original['scopes'])==1 and len(original['displays'])==1,
            'priorBootOrSingleDisplayUnavailable')
    scope=original['scopes'][0]
    display=scope['scope']
    order=[str(v['id']) for v in scope['records']]
    protected={str(v['id']):v['uuid'] for v in scope['records']}
    require(original['displays'][0]['uuid']==display and str(target) not in protected,'protectedOriginalCannotBeFixtureLease')
    active=[];ledger_root=None
    for ref_path in sorted(workspace.glob('desktop-*.json'),key=lambda p:int(p.stem.split('-')[-1])):
        ref=json.loads(private_file(ref_path));path=Path(ref['receipt'])
        raw=private_file(path)
        anchor=path.parent.parent.parent
        require(path.name=='created.json' and path.parent.name=='provision' and
                str(uuid.UUID(path.parent.parent.name))==path.parent.parent.name and anchor.name=='secondary-route-followup' and
                anchor.parent.name=='verification' and anchor.parent.parent.name=='build' and
                (ledger_root is None or anchor==ledger_root) and hashlib.sha256(raw).hexdigest()==ref['sha256'] and
                not path.with_name('removed.json').exists() and not path.with_name('remove-intent.json').exists(),'inactiveOrUnrecognizedOriginalLease')
        ledger_root=anchor
        made=json.loads(raw);intent=json.loads(private_file(path.with_name('create-intent.json')))
        n=made['target'];after=made['after'];initial=intent['initial']
        require(made['intent']==intent and intent['boot']==boot and intent['display']==display and
                initial['sideOrder']==order and initial['spaceUUIDs']==protected and
                n not in order and n not in after['fullscreenIDs'] and [v for v in after['sideOrder'] if v!=n]==order and
                after['sideOrder'].count(n)==1 and set(after['sideOrder'])==set(after['spaceUUIDs']) and
                all(after['spaceUUIDs'][k]==v for k,v in protected.items()),'invalidOriginalLeaseChain')
        order=after['sideOrder'];protected=after['spaceUUIDs'];active.append(int(n))
    require(target in active and len(set(protected.values()))==len(protected),'expectedActiveEnrolledDesktop')
    return display,protected


def host_window_numbers(layers,host,lease):
    return sorted(v['number'] for v in layers if v.get('installedHost')==1 and v.get('pid')==host and
                  v.get('layer')==0 and v.get('forward')==[lease] and v.get('reverse')==[lease])


def request(folder,fixture,verb,index):
    nonce=str(uuid.uuid4());tmp=folder/'next.json'
    tmp.write_text(json.dumps(dict(nonce=nonce,action=verb,index=index)))
    tmp.replace(folder/'request.json')
    until=time.monotonic()+3
    while time.monotonic()<until:
        state=fixture()
        if state.get('lastCommand')==nonce:return
        time.sleep(.09)
    raise ValueError('fixtureAppKitRequestAcknowledgementUnavailable')


def ordinary(state, fixture, lease):
    return (state.get('ready') is True and state.get('space')==lease and state.get('type')==0 and
            state.get('newFullscreenIDs')==[] and state.get('onlyTwoInLease') is True and
            state.get('memberships')==[[lease],[lease]] and state.get('forward')==[True,True] and
            state.get('axStandard')==[True,True] and state.get('foreignVisibleMembers')==0 and state.get('unknownVisibleMembers')==0 and
            fixture.get('fullscreen')==[False,False])


def source_member(state,fixture,lease,index):
    extras=state.get('newFullscreenIDs')
    if not isinstance(extras,list) or len(extras)!=1:return False
    full=extras[0];members=state.get('memberships',[]);flags=fixture.get('fullscreen',[])
    return (len(flags)==len(members)==2 and flags[index] is True and members[index]==[full] and
            all(s in ([full],[lease]) for s in members) and state.get('space') in (full,lease) and
            state.get('foreignVisibleMembers')==0 and state.get('unknownVisibleMembers')==0 and
            state.get('fullscreenForward')==[s==[full] for s in members] and
            state.get('leaseWindowCensus',{}).get('admitted') is True)


def full_geometry(state):
    def rect(v):
        return isinstance(v,list) and len(v)==4 and all(type(n) in (int,float) and math.isfinite(n) for n in v) and v[2]>0 and v[3]>0
    display=state.get('displayFrame')
    cg=(state.get('cgFrames') or [None])[0];ax=(state.get('axFrames') or [None])[0]
    if not all(map(rect,(display,cg,ax))) or any(abs(a-b)>2 for a,b in zip(cg,ax)):return False
    x,y,w,h=display;a,b,c,d=cg
    return abs(a-x)<=2 and abs(w-c)<=3 and -2<=b-y<=h*.10 and abs(b+d-y-h)<=3


def stable_shell(state):
    x=state.get('windowManagement',{})
    return (x.get('animating') is False and x.get('sameCurrent') is True and x.get('signedDock') is True and
            x.get('signedWindowManager') is True and x.get('exposedRoots')==0 and type(x.get('dockBirth')) is int and
            type(x.get('managerBirth')) is int)


def dwell(read_state,fixture,qualifies,timeout):
    end=time.monotonic()+timeout;last=None;last_t=None;latest={}
    while time.monotonic()<end:
        latest=read_state();own=fixture()
        if qualifies(latest,own) and stable_shell(latest):
            x=latest['windowManagement']
            identity=(latest['space'],latest['spaceUUID'],latest['memberships'],x['dockBirth'],x['managerBirth'])
            if identity==last and time.monotonic()-last_t>=.23:return latest
            if last!=identity:last=identity;last_t=time.monotonic()
        else:last=None;last_t=None
        time.sleep(.12)
    raise ValueError('twoStableIndependentFullscreenReadsUnavailable')


def enter(folder,fixture,read_state,lease,report,save):
    initial=dwell(read_state,fixture,lambda s,f:ordinary(s,f,lease),5)
    require(initial.get('frontIsFixture') is True and initial.get('focusedFixtureNumber')==fixture()['numbers'][0],
            'ownedAIsNotTheFrontmostExactDocument')
    report.update(status='UNKNOWN',entryIssued=None);save()
    request(folder,fixture,'fullscreen',0);report['entryIssued']=True;save()
    def entered(s,f):
        return (source_member(s,f,lease,0) and s.get('type')==4 and s['space']==s['newFullscreenIDs'][0] and
                s['memberships'][1]==[lease] and f['fullscreen'][1] is False and s.get('drawn',[False])[0] is True and
                (s.get('axFullscreen') or [False])[0] is True and full_geometry(s))
    actual=dwell(read_state,fixture,entered,9)
    report.update(entry='PASS',fullscreenSpace=actual['space'],entryWindow=fixture()['numbers'][0]);save()


def fixture_only_aux(census):
    if census.get('admitted') is True:return True
    count=census.get('extraClasses',{}).get('fixtureAuxiliary/unverifiedOrdinary')
    details=[x for x in census.get('extraEvidence',[]) if x.get('category')=='unverifiedOrdinary']
    return (type(count) is int and 0<count==len(details)==census.get('unknown') and
            census.get('unresolved')==0 and census.get('expectedProven') is True and census.get('otherLayersAdmitted') is True and
            all(x.get('owner')=='fixtureAuxiliary' and x.get('singleSpace') is True and x.get('onscreen') is False and
                x.get('drawn') is False and x.get('inPublicCurrent') is False and x.get('inPublicAll') is False and
                x.get('fixtureAXStandard') is False and x.get('fixtureAXWindowRole') is False for x in details))


def returned(state,own,lease):
    if ordinary(state,own,lease):return True
    if state.get('axFullscreen')!=[False,False] or state.get('kernelCodeIdentitiesVerified') is not True:return False
    if not fixture_only_aux(state.get('leaseWindowCensus',{})):return False
    return ordinary({**state,'onlyTwoInLease':True},own,lease)


def unwind(folder,fixture,read_state,lease,report,save):
    report.update(status='UNKNOWN',requests=[]);save()
    issued=set()
    deadline=time.monotonic()+15;last_reason='ownerOrFullscreenSpaceUnconfirmed'
    while time.monotonic()<deadline:
        state=read_state();own=fixture()
        if returned(state,own,lease):
            final=dwell(read_state,fixture,lambda s,f:returned(s,f,lease),max(.4,deadline-time.monotonic()))
            report.update(status='PASS',returnedSpace=final['space'],bothOrdinary=True,windowManagement=final['windowManagement'])
            save();return
        # Always try the former left document first. B can need its own exit if
        # macOS leaves it separately fullscreen after removing A from a real pair.
        for i in range(2):
            if i in issued or not source_member(state,own,lease,i):continue
            item=dict(index=i,window=own['numbers'][i],source=state['newFullscreenIDs'][0],issued=None)
            if i==1 and 0 in issued and own['fullscreen'][0] is True:continue
            report['requests'].append(item);issued.add(i);save()
            request(folder,fixture,'ordinary',i);item['issued']=True;save()
            last_reason='ownedAppKitExitDidNotRestoreOrdinaryMembership'
            break
        time.sleep(.14)
    raise ValueError(last_reason)
