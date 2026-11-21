"""Classify numeric readback independently of the action helper's terminal reply."""
import math
import re
import uuid

MAX_GAP = .45  # Same WindowServer budget as the existing P0 trajectory contract.
POST_CONFIRMATION = 10.


def normalized_uuid(value):
    return str(uuid.UUID(str(value))).upper()


def finite(v):
    return type(v) in (int, float) and math.isfinite(v) and v >= 0


def action_record(record):
    intent, reply = record['intent'], record['result']
    ident = normalized_uuid(intent['id'])
    d = intent['display']
    trace = reply.get('switchTrace') or {}
    t = trace.get('phasesMachTicks') or []
    created, issued, confirmed = (intent.get('createdAtUptime'),reply.get('issuedAtUptime'),reply.get('confirmedAtUptime'))
    if (normalized_uuid(reply['id']) != ident or intent.get('action') != 'select' or reply.get('state') != 'confirmed'
        or reply.get('submittedSteps') != 1 or trace.get('adapter') != 27 or len(t) != 3
        or not all(type(v) is int and v > 0 for v in t) or not t[0]<t[1]<t[2]
        or not all(map(finite,(created,issued,confirmed))) or not created<=issued<=confirmed
        or reply.get('currentBefore',{}).get(d)!=intent.get('source') or reply.get('currentAfter',{}).get(d)!=intent.get('target')
        or not any(v.get('currents',{}).get(d)==intent.get('target') for v in trace.get('observations',[]))):
        return None
    src,dst=int(intent['source']),int(intent['target'])
    src_uuid,dst_uuid=normalized_uuid(intent['sourceUUID']),normalized_uuid(intent['targetUUID'])
    if min(src,dst)<=0 or src==dst or src_uuid==dst_uuid: return None
    win=intent.get('window')
    if win is not None and not all(type(win.get(k)) is int and win[k]>0 for k in ('pid','birth','number')): return None
    return dict(operation=ident,display=normalized_uuid(d),source=src,target=dst,sourceUUID=src_uuid,targetUUID=dst_uuid,
                window={k:win[k] for k in ('pid','birth','number')} if win else None,created=created,issued=issued,confirmed=confirmed)


def signed(p):
    return (isinstance(p,dict) and p.get('identityKnown') is True and
            all(type(p.get(k)) is int and p[k]>0 for k in ('pid','birth')) and
            all(isinstance(p.get(k),str) and p[k] for k in ('bundle','signingIdentifier')) and
            isinstance(p.get('cdhash'),str) and bool(re.fullmatch('[0-9a-fA-F]{40}',p['cdhash'])))


def system_identity(sample):
    return all(signed(sample.get(k)) and sample[k]['signingIdentifier']==bundle and sample[k]['bundle']==bundle
               for k,bundle in [('dock','com.apple.dock'),('windowManager','com.apple.WindowManager')])


def exact_focus(sample,w):
    focus=sample.get('focus') or {}; p=sample.get('foreground')
    return (w is not None and signed(p) and signed(focus.get('process')) and sample.get('foregroundStable') is True
            and sample.get('focusStable') is True and all(focus.get(k)==v for k,v in w.items())
            and all(p[k]==w[k] for k in ('pid','birth')) and p==focus['process']
            and focus.get('spaces')==[sample['current']])


def observed_identity(sample):
    window=sample.get('focus') or {}
    target={k:window.get(k) for k in ('pid','birth','number')}
    owner=sample.get('foreground')
    spaces=window.get('spaces')
    if (not sample.get('spaceStable') or not sample.get('topologyHash') or not system_identity(sample) or
        not all(type(n) is int and n>0 for n in target.values()) or
        not (sample.get('foregroundStable') and sample.get('focusStable') and signed(owner) and owner==window.get('process') and
             owner['pid']==target['pid'] and owner['birth']==target['birth'] and isinstance(spaces,list) and spaces and
             all(type(n) is int and n>0 for n in spaces))):
        return None
    return dict(window=target,spaces=spaces,foregroundCDHash=owner['cdhash'],topology=sample['topologyHash'],
                agents=[{k:sample[role][k] for k in ('pid','birth','cdhash')} for role in ('dock','windowManager')])


def checkpoint_identity(sample):
    observed=observed_identity(sample)
    return observed if observed and observed['spaces']==[sample['current']] else None


def observer_coverage(events):
    samples=[r for r in events if r.get('event')=='sample']
    continuous=0.; longest=0.; maximum_gap=0.; previous=None
    full=0
    for r in samples:
        gap=r['uptime']-previous['uptime'] if previous else 0.
        maximum_gap=max(maximum_gap,gap,r['uptime']-r['began'])
        qualified=observed_identity(r) is not None
        if qualified:full+=1
        contiguous=(previous and qualified and observed_identity(previous) is not None and 0<gap<=MAX_GAP and
                    0<=r['uptime']-r['began']<=MAX_GAP and previous['hid']==r['hid'] and previous['additionalHID']==r['additionalHID'])
        continuous=continuous+gap if contiguous else 0.
        longest=max(longest,continuous);previous=r
    lost=any(r.get('event') in ('notificationLoss','readUnavailable','userSuperseded') for r in events)
    complete=(events and events[0].get('event')=='started' and events[-1].get('event')=='ended' and events[-1].get('reason') in ('duration','driverClosed') and
              [r.get('seq') for r in events]==list(range(len(events))) and len({r.get('session') for r in events})==1)
    return dict(status='PASS' if complete and not lost and longest>=POST_CONFIRMATION and maximum_gap<=MAX_GAP else 'UNKNOWN',
                signedFocusAndMembershipReads=full,systemSamples=len(samples),longestQualifiedSeconds=round(longest,6),
                maxSampleGapSeconds=round(maximum_gap,6),inputOrReadLoss=lost,actionEvidence=False)

def correlate(change,sample,drift,notifications):
    proc=sample.get('foreground') or {}
    census=sample.get('ownerWindows') or {}
    same_owner=(signed(proc) and sample.get('foregroundStable') is True and
                all(census.get(k)==proc.get(k) for k in ('pid','birth')) and finite(census.get('at')) and
                0<=sample['uptime']-census['at']<=1.5)
    spaces=census.get('spaces') if same_owner else None
    change['foregroundIdentity']=proc if signed(proc) else None
    focus=sample.get('focus') or {}
    change['focusedWindow']=({k:focus.get(k) for k in ('pid','birth','number','spaces')}
                             if signed(proc) and sample.get('focusStable') is True and focus.get('process')==proc else None)
    elsewhere=sorted(set(spaces)-{sample['current']}) if isinstance(spaces,list) else []
    change['ownedOtherSpaces']=elsewhere if elsewhere or (same_owner and census.get('complete') is True) else None
    if not drift:return
    change['laterDriftMatchesOwnedSpace']=(drift['current'] in elsewhere if elsewhere or
                                                  (same_owner and census.get('complete') is True) else None)
    change['systemAgentActivationsBeforeDrift']=[{k:n[k] for k in ('uptime','process')} for n in notifications
        if n.get('kind')=='didActivateApplication' and change['uptime']<=n['uptime']<=drift['uptime']
        and signed(n.get('process')) and any(n['process']==sample.get(k) for k in ('dock','windowManager'))]
    # A notification or temporal order alone cannot name the initiator of a Space change.


def classify(log, action, boundary=None, historical=False):
    out=dict(operation=action['operation'],classification='unknown',events=[],issues=[],coverage={},
             causalAttribution='UNKNOWN',postConfirmationTenSeconds=False)
    issued,confirmed=action['issued'],action['confirmed']
    samples=[r for r in log if r.get('event')=='sample' and finite(r.get('uptime'))]
    baseline=next((r for r in reversed(samples) if r['uptime']<=issued),None)
    if baseline is None or not finite(issued) or not finite(confirmed):
        out['issues'].append('missingIndependentPreActionSample');return out
    end=boundary if boundary is not None else max((r.get('uptime',0) for r in log if finite(r.get('uptime'))),default=0.)
    check=[r for r in samples if issued<=r['uptime']<=end]
    # For a checkpoint, include the first actual sample after its timestamp as the independent closing edge.
    if boundary is not None:
        edge=next((r for r in samples if r['uptime']>=end),None)
        if edge and all(edge is not r for r in check):check.append(edge)
    events=out['events'];issues=out['issues']
    def issue(key):
        if key not in issues:issues.append(key)
    def event(kind,r,**extra):
        data=dict(kind=kind,uptime=r['uptime'],current=r.get('current'),**extra);events.append(data);return data
    relevant=[r for r in log if baseline['uptime']<=r.get('uptime',-1)<=max(end,check[-1]['uptime'] if check else end)]
    if not historical:
        sessions={r.get('session') for r in log}
        if len(sessions)!=1 or None in sessions or [r.get('seq') for r in log]!=list(range(len(log))):issue('observerSessionOrSequenceGap')
    if any(r.get('event') in ('readUnavailable','notificationLoss') for r in relevant):issue('independentReadOrNotificationLost')
    if (not baseline.get('spaceStable') or baseline.get('display')!=action['display'] or
        (baseline.get('current'),baseline.get('spaceUUID'))!=(action['source'],action['sourceUUID'])):issue('preActionDisplayOrSpaceUnconfirmed')
    if not historical and not baseline.get('topologyHash'):issue('missingTopologyIdentity')
    hid=baseline.get('hid');other=baseline.get('additionalHID')
    if not isinstance(hid,list) or len(hid)!=8 or not all(type(n)is int and n>=0 for n in hid):issue('missingPhysicalInputBaseline')
    if not historical and (not isinstance(other,list) or len(other)!=8):issue('missingAdditionalInputBaseline')
    previous=baseline; first=None; first_focus=None; wrong_focus=None; changed=None; drift=None; superseded=None
    largest=max(0.,issued-baseline['uptime'])
    expected=action['window']
    captured=[]
    for s in check:
        now=s['uptime'];began=s.get('began',now)
        span=now-previous['uptime'];largest=max(largest,span)
        if span<=0 or span>MAX_GAP or not finite(began) or began>now or now-began>MAX_GAP:issue('samplingGap')
        previous=s
        raw=s.get('hid'); extra=s.get('additionalHID')
        if not isinstance(raw,list) or len(raw)!=8 or (not historical and (not isinstance(extra,list) or len(extra)!=8)):
            issue('inputReadUnavailable')
        elif isinstance(hid,list) and (raw!=hid or (not historical and isinstance(other,list) and extra!=other)):
            superseded=event('userSuperseded',s);break
        if (not s.get('spaceStable') or s.get('display')!=action['display'] or
            (baseline.get('topologyHash') and baseline['topologyHash']!=s.get('topologyHash'))):
            issue('displayOrTopologyChanged');continue
        dest=(s.get('current'),s.get('spaceUUID'))==(action['target'],action['targetUUID'])
        src=(s.get('current'),s.get('spaceUUID'))==(action['source'],action['sourceUUID'])
        if not first and dest:first=event('landed',s)
        if not dest and not src and not first:issue('thirdSpaceBeforeTarget')
        if first and not dest and not drift:drift=event('unexpectedSpaceDrift',s,spaceUUID=s.get('spaceUUID'))
        if not first or not dest:continue
        captured.append(s)
        p=s.get('foreground') or {}
        seen_pid=s.get('workspaceFrontPID')
        if expected is None:
            issue('noExactTargetDocumentInIntent')
            continue
        if (seen_pid==expected['pid'] and (historical or (s.get('foregroundStable') and p.get('birth')==expected['birth']))) and first_focus is None:
            first_focus=now
        if first_focus is not None and changed is None and seen_pid and (seen_pid!=expected['pid'] or
                (s.get('foregroundStable') and p.get('birth') is not None and p['birth']!=expected['birth'])):
            if historical or s.get('foregroundStable') is True:
                changed=(event('unexpectedForegroundHandoff',s,foregroundPID=seen_pid),s)
        if now>=confirmed and not exact_focus(s,expected) and wrong_focus is None:wrong_focus=now
        if not historical and now>=confirmed and not system_identity(s):issue('systemAgentIdentityUnavailable')
    explicit=next((r for r in relevant if r.get('event')=='userSuperseded'),None)
    if explicit and superseded is None:superseded=event('userSuperseded',explicit)
    last=check[-1]['uptime'] if check else baseline['uptime']
    if boundary is not None and (last<boundary or last-boundary>MAX_GAP):issue('nextAdmissionNotContinuouslyCovered')
    if boundary is None and end-last>MAX_GAP:issue('missingEndOfObservation')
    if first is None:issue('targetNotIndependentlyObserved')
    if historical:issue('legacyTraceLacksSignedForegroundWindowMembershipAndNotifications')
    if wrong_focus is not None:issue('confirmedTargetDocumentFocusNotRetainedOrUnreadable')
    if changed:
        correlate(changed[0],changed[1],drift,[r for r in relevant if r.get('event')=='workspaceNotification'])
    transient=None
    if not historical and not changed and expected and first_focus is not None:
        for notification in relevant:
            if notification.get('kind')!='didActivateApplication' or notification['uptime']<first_focus:
                continue
            owner=notification.get('process')
            if not signed(owner):
                issue('activationNotificationIdentityUnconfirmed')
            elif (owner['pid'],owner['birth'])!=(expected['pid'],expected['birth']):
                transient=event('activatedOtherApplication',notification,foregroundIdentity=owner)
                break
    out['coverage']=dict(fromUptime=baseline['uptime'],throughUptime=last,maxGapSeconds=round(largest,6),
                         afterConfirmationSeconds=round(max(0,last-confirmed),6),nextAdmissionUptime=boundary,
                         activeSpaceChangeNotifications=[r['uptime'] for r in relevant if r.get('kind')=='activeSpaceDidChange'])
    if superseded:out['classification']='userSuperseded'
    elif drift:out['classification']='unexpectedSpaceDrift'
    elif changed or transient:out['classification']='unexpectedForegroundHandoff'
    elif issues:out['classification']='unknown'
    elif first and last>=max(confirmed,first['uptime'])+POST_CONFIRMATION and captured:
        out['classification']='settled';out['postConfirmationTenSeconds']=True;event('settled',captured[-1])
    elif first:out['classification']='landed'
    return out
