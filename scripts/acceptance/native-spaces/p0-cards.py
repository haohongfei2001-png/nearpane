"""Installed P0. Exactly one genuine background-window card press per attempt."""
import argparse
import functools
import importlib.util
import json
import math
import os
from pathlib import Path
import plistlib
import queue
import select
import signal
import subprocess
import sys
import tempfile
import threading
import time
import uuid

from acceptance import identity
from contract_workspace import Workspace
from installed_profile import APP, PROFILE, installed_pid, owns_profile, validate_home
from space_scope import require


GATES = (("roundTrip", 2), ("ten", 10), ("fifty", 50))
SETTLE_SECONDS = 2.0
MAX_GAP = .45


def store(path, obj):
    tmp = path.with_suffix(path.suffix + '.new')
    tmp.write_text(json.dumps(obj, ensure_ascii=False, indent=2, sort_keys=True) + '\n')
    tmp.replace(path)


def cmd(tool, *args, body=None, timeout=8):
    result = subprocess.run([str(tool), *map(str, args)], input=json.dumps(body) if body is not None else None,
                            capture_output=True, text=True, timeout=timeout)
    if result.stdout.strip():
        return json.loads(result.stdout)
    raise RuntimeError(f'{tool.name} returned {result.returncode} without a machine receipt')


def until(read, predicate, why, timeout=7):
    end, last = time.monotonic() + timeout, None
    while time.monotonic() < end:
        try:
            last = read()
            if predicate(last): return last
        except (FileNotFoundError, json.JSONDecodeError): pass
        time.sleep(.14)
    raise ValueError(why)


def percentile(values, probability):
    return sorted(values)[math.ceil(len(values) * probability) - 1]


def owned_insertion(before, after, which):
    require(after['display'] == before['display'], 'physical display changed')
    old = before['records']; new = after['records']
    extra = [r for r in new if r['id'] not in {s['id'] for s in old}]
    require(len(extra) == 1 and extra[0]['type'] == which and extra[0]['uuid'] not in {s['uuid'] for s in old}
            and [s for s in new if s != extra[0]] == old, 'native topology did not show exactly one new endpoint and identical original UUID order')
    return extra[0]['id']


def compatible(topology, a, b):
    ids = [s['id'] for s in topology['records']]
    return a in ids and b in ids and abs(ids.index(a) - ids.index(b)) == 1

def assigned_ordinary(original, candidate, numbers, claims):
    require(original['display']==candidate['display'] and original['records']==candidate['records'],
            'original Space UUIDs or order changed while the owner activated its own window')
    current=candidate['current']
    return (any(row['id']==current and row['type']==0 for row in original['records'])
            and len(numbers)==len(claims) and all(p.get('number')==n and p.get('standard') and p.get('forward')
            and p.get('reverse')==[current] for n,p in zip(numbers,claims)))

def confirm_lease_pair(original, one, both):
    a=owned_insertion(original,one,0)
    b=owned_insertion(one,both,0)
    require(compatible(both,a,b),'the two newly inserted ordinary Spaces are not consecutive')
    return a,b

def census_facts(report,target):
    membership=report.get(str(target),{})
    ordinary=membership.get('ordinary')
    facts={key:membership.get(key) for key in ('desktopElements','verifiedSharedOverlays','verifiedHostPanels','systemMenuSurfaces','otherMembers','unresolved')}
    facts['ordinaryCount']=len(ordinary) if isinstance(ordinary,list) else None
    facts['ordinaryMembers']=[{key:w[key] for key in ('pid','number','ownerClass') if key in w} for w in (ordinary or []) if isinstance(w,dict)]
    classes={}
    for member in membership.get('otherDetails',[]):
        code=member.get('code') or {}
        label='installed Host' if member.get('installedHost') else ('Apple '+str(code.get('identifier')) if code.get('apple') is True else 'other')
        key=(label,member.get('layer'));classes[key]=classes.get(key,0)+1
    facts['otherOwnerClasses']=[dict(category=key[0],layer=key[1],count=count) for key,count in classes.items()]
    facts['unavailable']=membership.get('unavailable') or report.get('unavailable')
    facts['sessionChanged']=report.get('sessionChanged',False)
    facts['empty']=isinstance(ordinary,list) and not ordinary and facts['otherMembers']==0 and facts['unresolved']==0 and not facts['unavailable']
    return facts


def stable_empty_census(read,save,before,initial,top,target,timeout=6):
    admitted=dict(top,current=before['topology']['current']);start=None;streak=0;samples=[]
    deadline=time.monotonic()+timeout
    while time.monotonic()<deadline:
        first,second,census=read()
        evidence=census_facts(census,target)
        evidence['observations']=[]
        for state in (first,second):
            t=state.get('topology',{});current=t.get('current');row=next((x for x in t.get('records',[]) if x['id']==current),{})
            hid=state.get('hid');initial_hid=initial['hid']
            observation=dict(uptime=state.get('uptime'),frontPID=state.get('frontPID'),current=current,currentType=row.get('type'),
                             currentUUID=row.get('uuid'),currentChanged=current!=admitted['current'],fullscreen=row.get('type')==4,
                             inputChanged=hid!=initial_hid,frontChanged=state.get('frontPID')!=before.get('frontPID'),
                             orderOrDisplayChanged=t.get('display')!=admitted['display'] or t.get('records')!=admitted['records'])
            if isinstance(hid,list) and len(hid)==len(initial_hid):
                observation['hidDelta']=[v-base for v,base in zip(hid,initial_hid)]
            evidence['observations'].append(observation)
        samples.append(evidence);save(samples)
        if evidence['sessionChanged']:raise ValueError('signed Host, console or leased desktop identity changed during native target census')
        if any(s['inputChanged'] for s in evidence['observations']):raise ValueError('physical HID changed before native target census completed')
        if any(s['orderOrDisplayChanged'] or s['currentChanged'] for s in evidence['observations']):raise ValueError('source Space, UUID order or display changed during native target census')
        if any(s['frontChanged'] for s in evidence['observations']):raise ValueError('foreground owner changed during native target census')
        timestamp=second.get('uptime')
        if evidence['empty'] and isinstance(timestamp,(int,float)):
            if streak==0:start=timestamp
            streak+=1
            if streak>=3 and timestamp-start>=.45:return
        else:start=None;streak=0
        time.sleep(.15)
    raise ValueError('native target census did not continuously verify vacancy across three readbacks of the same leased ordinary Space')


def direct_setup(kit,ws,output,initial,top,source,target,log,method):
    state=lambda:cmd(kit/'p0-card','state')
    before=state()
    store(output/f'setup-census-admission-{target}.json',dict(source=source,target=target,observed=before,
          admittedHID=initial['hid'],hidEvents=['leftDown','rightDown','otherDown','keyDown','scroll','leftDrag','rightDrag','otherDrag']))
    require(before.get('hid')==initial['hid'],'physical HID changed before direct native setup')
    require(before.get('topology')==dict(top,current=source),'foreground Space, physical display or complete UUID order changed before direct native setup')
    current=ws.read();system=ws.check(current)
    require(system['records']==top['records'] and system['current']==source and target in ws.ids(),'signed creation ledger or native UUID order differs')
    census_path=output/f'setup-census-{target}.json'
    @functools.lru_cache(maxsize=24)
    def apple_code(executable,code_hash):
        return subprocess.run(['/usr/bin/codesign','--verify','--strict','-R=anchor apple',executable],capture_output=True,timeout=2).returncode==0
    def owner_class(pid):
        if pid==ws.host['pid']:return 'installed Host'
        try:
            live=cmd(kit/'p0-card','process',pid,timeout=2)
            executable=live.get('executable','')
            if (executable.startswith('/System/Library/') or executable.startswith('/System/Applications/')) and apple_code(executable,live['hash']):
                return 'Apple '+live['identifier']
            if executable.startswith(str(kit)+'/') and live.get('identifier') in ('net.example.spaces-document','net.example.spaces-route-witness','org.nearpane.acceptance.LifecycleWindow'):
                return 'owned acceptance fixture'
        except (OSError,ValueError,KeyError,subprocess.SubprocessError):pass
        return 'unclassified'
    def read_census():
        first=state()
        if (first.get('hid')!=initial['hid'] or first.get('topology')!=dict(top,current=source) or first.get('frontPID')!=before.get('frontPID')):
            return first,first,{}
        observation=ws.read();membership=observation.get('scopedMembers') or {}
        try:
            if ws.check(observation)!=system:membership={'unavailable':'inventory disagreed with the independently admitted UUID roster','sessionChanged':True}
        except ValueError as error:membership={'unavailable':str(error),'sessionChanged':True}
        ordinary=membership.get(str(target),{}).get('ordinary') or []
        owners={w['pid'] for w in ordinary if 'pid' in w}
        if len(owners)<=4:
            classes={p:owner_class(p) for p in owners}
            for w in ordinary:w['ownerClass']=classes.get(w.get('pid'),'unclassified')
        return first,state(),membership
    stable_empty_census(read_census,lambda samples:store(census_path,samples),before,initial,top,target)
    log('consecutive-empty-census',target=target,source=source,evidence=census_path.name)
    request=dict(command='select',display=ws.display,records=system['records'],current=source,original=ws.home,owned=ws.ids(),
                 target=target,hostPID=ws.host['pid'],hostHash=ws.host['codeHash'],hostBirth=ws.host_birth,hid=ws.hardware())
    require(state().get('hid')==initial['hid'],'physical input changed before opening Mission Control')
    if source!=target:
        log('direct-mission-control-intent',source=source,target=target,setupOnly=True,method=method)
        proof=cmd(kit/'p0-mission',*(['native-click'] if method=='click' else []),body=request,timeout=20);store(output/f'setup-press-{target}.json',proof);log('direct-mission-control-reply',source=source,target=target,proof=proof)
        transport=(proof.get('action')=='AXPress' and proof.get('acknowledged') is True) or (proof.get('action')=='native thumbnail click' and proof.get('clickPosted') is True)
        require(proof.get('issued') and transport and not proof.get('error') and proof.get('overviewDismissed'),
                proof.get('error','native AXPress or owned Mission Control dismissal not confirmed'))
    stable=0
    def reached(sample):
        nonlocal stable
        t=sample['topology'];require(sample['hid']==initial['hid'] and t['records']==top['records'] and t['display']==top['display']
                                    and t['current'] in (source,target),'new input, external desktop, or topology change during native setup')
        stable=stable+1 if t['current']==target else 0
        return stable>=3
    after=until(state,reached,'direct Mission Control AXPress acknowledged but the leased UUID never became stably current',5)
    store(output/f'setup-arrival-{target}.json',after);log('independent-setup-arrival',source=source,target=target,setupOnly=True)
def journal_files(root):
    if not root.exists(): return set()
    require(root.is_dir() and not root.is_symlink() and root.resolve() == root, 'unexpected Host journal directory')
    files = set()
    for f in root.glob('*.json'):
        if f.name != 'pending.json' and str(uuid.UUID(f.stem)).lower() == f.stem.lower(): files.add(f.name)
    return files


def journal_read(f):
    require(f.is_file() and f.resolve() == f and f.stat().st_nlink == 1 and f.stat().st_uid == os.getuid()
            and 0 < f.stat().st_size < 2_000_000, 'invalid isolated Host journal entry')
    return f.read_bytes()


def match_receipt(record, filename, request, press_time):
    intent, result = record['intent'], record['result']; ident = str(uuid.UUID(filename[:-5]))
    top, source, target = request['topology'], request['topology']['current'], request['target']
    display = top['display']; rows = {s['id']:s for s in top['records']}
    window = request['targetWindow']
    require(ident == str(uuid.UUID(intent['id'])) == str(uuid.UUID(result['id'])), 'Host intent UUID mismatch')
    require(intent['action'] == 'select' and intent['display'].upper() == display.upper() and intent['source'] == str(source) and intent['target'] == str(target)
            and intent['sourceUUID'].upper() == rows[source]['uuid'].upper() and intent['targetUUID'].upper() == rows[target]['uuid'].upper()
            and intent['window'] == {k:window[k] for k in ('pid','birth','number')} and intent.get('createdAtUptime', -1) >= press_time,
            'Host journal does not bind this card, process birth, target and display')
    trace = result.get('switchTrace') or {}; phases = trace.get('phasesMachTicks') or []
    actual = result.get('submittedSteps') == 1 and trace.get('adapter') == 27 and len(phases) == 3 and all(type(t) is int and t > 0 for t in phases) and phases == sorted(phases) and phases[0] < phases[-1]
    confirmed = (actual and result.get('state') == 'confirmed' and result.get('currentBefore',{}).get(display) == str(source)
                 and result.get('currentAfter',{}).get(display) == str(target) and result.get('confirmedAtUptime',0) >= result.get('issuedAtUptime',math.inf)
                 and result.get('issuedAtUptime',0) >= press_time and any(o.get('currents',{}).get(display) == str(target) for o in trace.get('observations',[])))
    return dict(id=ident, phaseEvidence=actual, confirmed=bool(confirmed), terminal=result.get('state'), submittedSteps=result.get('submittedSteps'))


def assess(samples, request, pressed_at, host_proof, ax):
    observed = [s for s in samples if s.get('uptime',0) >= pressed_at]
    if not ax.get('issued'): return 'BLOCKED', ax.get('error','background card not issued'), None
    if ax.get('axError') != 0: return 'UNKNOWN','installed AX delivery incomplete',None
    source, target, first, last = request['topology']['current'], request['target'], None, None
    if observed and observed[0]['uptime'] - pressed_at > MAX_GAP:
        return 'UNKNOWN','first independent read arrived late',None
    for s in observed:
        if 'error' in s or not s.get('topology'): return 'UNKNOWN','independent read unavailable',None
        top = s['topology']
        if s['hid'] != request['hid']: return 'UNKNOWN','human input changed during the observation window',None
        if top['display'] != request['topology']['display'] or top['records'] != request['topology']['records']: return 'UNKNOWN','topology changed during the observation window',None
        if last is not None and s['uptime'] - last > MAX_GAP: return 'UNKNOWN','independent sampling gap',None
        last = s['uptime']; current = top['current']
        if current not in (source,target): return 'FAIL','unexpected third Space observed',None
        if first is not None and current != target: return 'FAIL','returned to source after reaching target',None
        if current == target and first is None: first = last
    if not host_proof or not host_proof['phaseEvidence']:
        return ('FAIL' if host_proof and host_proof['terminal']=='failed' else 'UNKNOWN'), 'no verified one-step dispatch from the installed Host',None
    if first is None:
        if observed and observed[-1]['uptime'] - pressed_at >= 7: return 'FAIL','target never reached during the bounded readback',None
        return 'UNKNOWN','insufficient landing observations',None
    if not host_proof['confirmed'] or last - first < SETTLE_SECONDS:
        return 'UNKNOWN','Host confirmation or delayed landing evidence incomplete',None
    return 'PASS','one exact installed action and independently stable adjacent destination',round((first - pressed_at)*1000,2)


class Watch:
    def __init__(self, tool): self.tool = tool; self.samples = []; self.q = queue.Queue()
    def __enter__(self):
        self.proc = subprocess.Popen([self.tool,'watch'],stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,text=True)
        def consume():
            try:
                for line in self.proc.stdout: self.q.put(json.loads(line))
            finally: self.q.put(None)
        self.thread = threading.Thread(target=consume,daemon=True); self.thread.start()
        return self
    def next(self):
        sample = self.q.get(timeout=2)
        require(sample is not None,'independent WindowServer watcher stopped')
        self.samples.append(sample); return sample
    def __exit__(self,*exc):
        if self.proc.poll() is None: self.proc.terminate()
        self.proc.wait(timeout=3); self.thread.join(timeout=2); self.proc.stdout.close()


@functools.lru_cache(maxsize=1)
def visual_module():
    script=Path(__file__).with_name('p0-visual.py')
    if not script.is_file():return None
    spec=importlib.util.spec_from_file_location('p0_visual_receipts',script)
    module=importlib.util.module_from_spec(spec);sys.modules[spec.name]=module;spec.loader.exec_module(module)
    return module

def finish_visual(module,kit,folder,pressed,ended,request,started,observer_options):
    result=module.finish(kit,folder,pressed,ended,**observer_options)
    file=folder/'visual'/'receipt.json'
    if result.get('status') in ('PASS','FAIL') and file.is_file() and file.resolve()==file:
        archived=json.loads(file.read_bytes())
        frames=folder/'visual'/'frames.json'
        nonce=started.get('nonce') if started else None
        if (nonce and started.get('ready') is True and result==archived and archived.get('nonce')==nonce
                and (archived.get('pressed'),archived.get('ended'))==(pressed,ended) and 0<pressed<ended
                and (archived.get('source'),archived.get('target'))==(request['topology']['current'],request['target'])
                and archived.get('frameLog')==frames.name and frames.resolve()==frames and frames.is_file()
                and json.loads(frames.read_bytes()).get('nonce')==nonce):
            return result['status']
    return 'UNKNOWN'

def attempt(tool,p,folder,journal,log,visual_stage=None,keeper=None):
    folder.mkdir(mode=0o700); store(folder/'identity.json',p)
    item = dict(status='UNKNOWN',axIssued=False,hostIssued=False,blankScreen='UNKNOWN',screenshotTaken=False,lateObservationSeconds=SETTLE_SECONDS)
    action = {}; holder = None; host = None; watch = None; recorder = None; called = False; started = None
    observer_options={'window_witness':lambda windows:keeper.call('windows',windows)} if keeper else {}
    try:
        require(not (journal/'pending.json').exists(),'installed adapter already has an unresolved transition')
        before = journal_files(journal)
        # Feed refresh and first SwiftUI AX layout can finish asynchronously. This is a read-only wait.
        inspect = None; end = time.monotonic() + 5
        while time.monotonic() < end:
            inspect = keeper.call('inspect',p) if keeper else cmd(tool,'inspect',body=p)
            if inspect.get('ready'): break
            if inspect.get('error','').startswith('official background card'): time.sleep(.18); continue
            break
        store(folder/'card-before.json',inspect)
        require(inspect.get('ready'),inspect.get('error','installed background card unavailable'))
        if visual_stage in ('roundTrip','ten'):
            try:
                recorder=visual_module()
                if recorder and visual_stage=='roundTrip':
                    store(folder/'visual-enrollment.json',recorder.enroll(tool.parent,folder,p,**observer_options))
                elif recorder:
                    called=True;started=recorder.start(tool.parent,folder,p,**observer_options);store(folder/'visual-start.json',started)
            except (OSError,ValueError,RuntimeError,subprocess.SubprocessError,ImportError,AttributeError,TypeError) as error:
                store(folder/('visual-enrollment.json' if visual_stage=='roundTrip' else 'visual-start.json'),dict(status='UNKNOWN',reason=str(error)))
        with Watch(tool) as watch:
            first = watch.next(); require(first.get('topology') == p['topology'] and first.get('hid') == p['hid'],'source changed before dispatch')
            log('card-intent',space=p['target'],number=p['targetWindow']['number'],folder=folder.name)
            item['status']='UNKNOWN'; item['invokedDriver']=True; store(folder/'result.json',item)
            action=keeper.call('press',p) if keeper else cmd(tool,'press',body=p,timeout=10); store(folder/'ax-dispatch.json',action); item['axIssued']=action.get('issued',False)
            if not item['axIssued']:
                item.update(status='BLOCKED',reason=action.get('error','official input refused before AXPress'));return item
            stamp=action['uptime']; end=time.monotonic()+9; landed=None; terminal_time=None
            while time.monotonic()<end:
                s=watch.next()
                if s.get('uptime',0)<stamp:continue
                top=s.get('topology',{}); now=s['uptime']; actual=top.get('current')
                if actual == p['target'] and landed is None: landed=now
                wrong = actual not in (p['target'],p['topology']['current']) or (landed is not None and actual!=p['target'])
                changed = top.get('records')!=p['topology']['records'] or s.get('hid')!=p['hid']
                if holder is None:
                    created=journal_files(journal)-before
                    require(len(created)<=1,'multiple new formal Host actions observed')
                    if created:
                        holder=created.pop(); raw=journal_read(journal/holder); (folder/holder).write_bytes(raw)
                        host=match_receipt(json.loads(raw),holder,p,stamp); terminal_time=now
                # Keep taking observations after terminal reply and after landing. A refusal is never replayed.
                # Stop accepting success on any anomaly, but let an already-issued action
                # write its terminal Host receipt. This only observes; the gate cannot retry.
                if (wrong or changed) and terminal_time is not None: break
                if terminal_time is not None and landed is not None and now-max(terminal_time,landed)>=SETTLE_SECONDS:break
                if terminal_time is not None and host['terminal']=='failed' and not host['phaseEvidence']:break
            item['hostProof']=host; item['hostIssued']=bool(host and host['phaseEvidence'])
            status,reason,ms=assess(watch.samples,p,stamp,host,action); item.update(status=status,reason=reason,latencyMS=ms)
            if (journal/'pending.json').exists():
                (folder/'pending.json').write_bytes(journal_read(journal/'pending.json'))
                if item['status']=='PASS': item.update(status='UNKNOWN',reason='installed adapter retained an unresolved transition')
            if host: item['hostJournalFile']=holder
    except (ValueError,OSError,RuntimeError,KeyError,TypeError,queue.Empty,subprocess.SubprocessError) as e:
        item.update(status='UNKNOWN' if item.get('invokedDriver') else 'BLOCKED',reason=str(e) or type(e).__name__)
    finally:
        item['navigationStatus']=item['status']
        if called:
            end=max((s.get('uptime',0) for s in (watch.samples if watch else [])),default=0)
            try:
                item['blankScreen']=finish_visual(recorder,tool.parent,folder,action.get('uptime',0) if action.get('issued') else 0,end,p,started,observer_options)
            except (OSError,ValueError,RuntimeError,subprocess.SubprocessError,KeyError,TypeError) as error:
                item['visualReason']=str(error)
            if item['blankScreen']=='FAIL':
                item.update(status='FAIL',reason='visual observer reported a black physical display during this action')
        if watch:
            with (folder/'windowserver.jsonl').open('w') as f:
                for s in watch.samples: f.write(json.dumps(s,separators=(',',':'))+'\n')
        if (journal/'pending.json').is_file() and not (folder/'pending.json').exists():
            (folder/'pending.json').write_bytes(journal_read(journal/'pending.json'))
        store(folder/'result.json',item); log('card-outcome',**item)
    return item


class Documents:
    def __init__(self, kit, scratch, log): self.kit=kit; self.scratch=scratch; self.log=log; self.processes=[]
    def launch(self, name):
        lifecycle=name=='Lifecycle Window'; group=self.scratch/str(uuid.uuid4());group.mkdir(mode=0o700)
        bundle=self.kit/(name+'.app'); executable=bundle/'Contents/MacOS'/('Lifecycle' if lifecycle else 'FieldNotes')
        subprocess.run(['/usr/bin/codesign','--verify','--strict',bundle],check=True,timeout=10)
        env=dict(os.environ,NP_FIXTURE_PRESENTATION='contract')
        process=subprocess.Popen([executable,group,*(() if lifecycle else ('1',))],env=env,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        doc={'proc':process,'folder':group,'windows':[]};self.processes.append(doc)
        state=until(lambda:json.loads((group/'windows.json').read_bytes()),lambda d:d.get('pid')==process.pid and len(set(d.get('numbers',[])))==(2 if lifecycle else 1),'owned fixture did not open exact real documents')
        live=cmd(self.kit/'p0-card','process',process.pid)
        require(live.get('executable')==str(executable) and live.get('hash')==identity(bundle)['CDHash'],'owned bundle path or signed fixture differs')
        doc['windows']=[dict(live,number=n,ownerFile=None if lifecycle else str(group/'p0-generations.json')) for n in state['numbers']]
        self.log('fixture-opened',windows=doc['windows']);return doc
    def control(self,doc,action,index):
        req=dict(nonce=str(uuid.uuid4()),action=action,index=index)
        store(doc['folder']/'request.json',req);self.log('system-fixture-command',**req)
        return until(lambda:json.loads((doc['folder']/'windows.json').read_bytes()),lambda st:st.get('lastCommand')==req['nonce'],'owned AppKit window did not acknowledge '+action)
    def close(self):
        problems=[]
        for doc in reversed(self.processes):
            proc=doc['proc']
            if proc.poll() is None:
                (doc['folder']/'close').touch()
                try:proc.wait(timeout=8)
                except subprocess.TimeoutExpired:
                    # Popen is our still-unreaped child. This cannot signal a user app or reused PID.
                    proc.terminate()
                    try: proc.wait(timeout=5)
                    except subprocess.TimeoutExpired: problems.append(f'owned document process {proc.pid} did not exit')
        return problems


def freeze(kit,out):
    home=Path(os.environ['NEARPANE_TEST_HOME']);validate_home(home)
    pid=installed_pid();require(owns_profile(pid,home/PROFILE),'installed Host does not own the isolated profile writer lock')
    info=plistlib.loads((APP/'Contents/Info.plist').read_bytes());signed=identity(APP)
    subprocess.run(['/usr/bin/codesign','--verify','--strict','--deep',APP],check=True,timeout=30)
    host=cmd(kit/'p0-card','process',pid)
    require((info['CFBundleShortVersionString'],info['CFBundleVersion'])==('5.22','90') and host.get('hash')==signed.get('CDHash')
            and signed.get('TeamIdentifier')=='ZB9D4T66QB' and host.get('identifier')==info['CFBundleIdentifier']=='com.holdsnow.nearpane.alpha'
            and host.get('executable')==str(APP/'Contents/MacOS/NearpaneHost'), 'installed signed candidate differs from 5.22 (90)')
    osbuild=subprocess.check_output(['/usr/sbin/sysctl','-n','kern.osversion'],text=True).strip();require(osbuild=='26A428','P0 gate is not qualified on this build')
    revision=info.get('NearpaneSourceRevision');require(isinstance(revision,str) and len(revision)==40,'signed source revision unavailable')
    candidate=dict(path=str(APP),source=revision,osbuild=osbuild,version='5.22',build='90',host=host,team=signed['TeamIdentifier'],isolatedProfile=True)
    store(out/'installed.json',candidate)
    return host,home/'Library/Application Support/Nearpane/NativeSwitch'/('dock-v1-'+osbuild)


def guard_setup(state,initial,permitted,fronts):
    require(state.get('hid')==initial.get('hid'),'physical input changed while preparing owned windows')
    require(state['topology']['display']==initial['topology']['display'] and state['topology']['current'] in permitted,'unexpected active Space before fixture operation')
    require(state.get('frontPID') in fronts,'unrelated foreground app appeared before fixture operation')


def confirmed_current_cards(read,save,control,space,timeout=10):
    observed=[]
    deadline=time.monotonic()+timeout
    previous=None
    while time.monotonic()<deadline:
        item=read();observed.append(item);save(observed)
        if item.get('error'):
            raise ValueError('current card witness could not be read: '+item['error'])
        matches=(item.get('present') is True and item.get('matches')==1 and item.get('id')==control and item.get('space')==space)
        if matches and previous is not None and item.get('uptime',0)-previous>=.16: return
        previous=item.get('uptime') if matches else None
        time.sleep(.20)
    raise ValueError('the signed installed Host did not expose the exact current-desktop window card twice before leaving its Space')

def gate_status(items,expected):
    bad=next((x['status'] for x in items if x['status']!='PASS'),None)
    return bad or ('PASS' if len(items)==expected else 'BLOCKED')

def evaluate_gate(stage, name, expected):
    samples=stage['samples']
    navigation=gate_status([{'status':s.get('navigationStatus',s['status'])} for s in samples],expected)
    stage['navigationStatus']=navigation
    if any(s.get('blankScreen')=='FAIL' for s in samples):
        stage.update(status='FAIL',blankScreen='FAIL',reason='black physical display observed during a navigation');return
    if name=='ten':
        stage['blankScreen']='PASS' if len(samples)==expected and all(s.get('blankScreen')=='PASS' for s in samples) else 'UNKNOWN'
    if name=='ten' and navigation=='PASS' and stage['blankScreen']!='PASS':
        stage.update(status='BLOCKED',reason='10 independent navigations confirmed; absence of a black physical display was not witnessed')
    else:stage['status']=navigation

class OwnedKeeper:
    def __init__(self,tool):
        self.proc=subprocess.Popen([tool,'keeper'],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,text=True)
    def call(self,mode,body,**extra):
        self.proc.stdin.write(json.dumps(dict(mode=mode,body=body,**extra))+'\n');self.proc.stdin.flush()
        if not select.select([self.proc.stdout],[],[],10)[0]:raise RuntimeError('independent enrolled AX keeper timed out; no action replay')
        line=self.proc.stdout.readline()
        require(line,'independent enrolled AX keeper exited');return json.loads(line)
    def close(self):
        self.proc.stdin.close()
        try:self.proc.wait(timeout=3)
        except subprocess.TimeoutExpired:self.proc.terminate();self.proc.wait(timeout=3)
        self.proc.stdout.close()

class OriginalFocus:
    def __init__(self,tool):
        self.proc=subprocess.Popen([tool,'hold-original'],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,text=True)
    def reply(self,timeout=3):
        if not select.select([self.proc.stdout],[],[],timeout)[0]:return {'error':'original AX reference timed out'}
        line=self.proc.stdout.readline()
        return json.loads(line) if line else {'error':'original AX reference unavailable'}
    def finish(self,restore,ordinary=None):
        try:
            if self.proc.poll() is None:
                self.proc.stdin.write((('restore '+str(ordinary) if ordinary else 'restore') if restore else 'release')+'\n');self.proc.stdin.flush()
                return self.reply(timeout=7) if restore else {'issued':False}
            return {'issued':False}
        finally:
            self.proc.stdin.close();self.proc.stdout.close()
            if self.proc.poll() is None:
                try:self.proc.wait(timeout=2)
                except subprocess.TimeoutExpired:self.proc.terminate();self.proc.wait(timeout=3)


def run(args):
    out=args.output.resolve();out.mkdir(mode=0o700,parents=True,exist_ok=False);tool=args.kit/'p0-card'
    result={'status':'BLOCKED','stages':{n:{'status':'NOT_RUN','navigationStatus':'NOT_RUN','blankScreen':'UNKNOWN','requested':c,'samples':[]} for n,c in GATES},'blankScreen':'UNKNOWN','privateContentCaptured':False}
    report=lambda:store(out/'results.json',result)
    def log(event,**data):
        with (out/'actions.jsonl').open('a') as f:
            f.write(json.dumps({'event':event,'monotonic':time.monotonic(),**data},ensure_ascii=False)+'\n');f.flush();os.fsync(f.fileno())
    report();ws=None;initial=None;rootdoc=None;lease=None;top=None;a=b=None;host=None;focus=None;held={};staging=None;keeper=None
    with tempfile.TemporaryDirectory(dir='/private/tmp',prefix='nearpane-p0-owned-') as tmp:
        documents=Documents(args.kit,Path(tmp),log)
        state=lambda:cmd(tool,'state')
        def witnesses(windows): return (keeper.call('windows',windows) if keeper else cmd(tool,'windows',body=windows)).get('windows',[])
        def anchored(windows,places):
            proof=witnesses(windows)
            return len(proof)==len(places) and all(r.get('standard') and r.get('forward') and r['reverse']==[place] for r,place in zip(proof,places))
        def checkpoint(name):
            own=[]
            for doc in documents.processes:
                f=doc['folder']/'windows.json'
                if not f.is_file():continue
                observed=json.loads(f.read_bytes())
                own.append({k:observed[k] for k in ('pid','numbers','fullscreen','zoomed','key','main','visible','minimized') if k in observed})
            w=[w for doc in documents.processes for w in doc['windows']]
            view=dict(system=state(),owners=own,witnesses=[keeper.call('windows',[win]) if keeper else cmd(tool,'windows',body=[win]) for win in w])
            store(out/f'fixture-{name}.json',view)
        try:
            host,journal=freeze(args.kit,out);require(not (journal/'pending.json').exists(),'unresolved installed switch already present')
            initial=state();require(initial.get('observerAX') and initial.get('topology'),'independent metadata or AX permission unavailable');store(out/'original.json',initial)
            focus=OriginalFocus(tool);held=focus.reply();store(out/'original-focus.json',held)
            if held.get('held'):
                require((initial['frontPID'],initial['focusedNumber'],initial['topology'],initial['hid'])==(held['pid'],held['number'],held['topology'],held['hid']),'original focus or user input changed at admission')
            user=initial['topology'];user_space=user['current'];row=next(s for s in user['records'] if s['id']==user_space)
            require(row['type'] in (0,4),'unsupported type for original foreground Space')
            before=state();guard_setup(before,initial,{user_space},{initial['frontPID']});require(before['topology']==user,'original UUID order changed')
            rootdoc=documents.launch('Lifecycle Window');first,second=rootdoc['windows']
            before=state();require(before.get('hid')==initial['hid'] and before['topology']['records']==user['records'] and before['topology']['display']==user['display'],
                                   'human input or topology changed while launching the dedicated document owner')
            if before['topology']['current']!=user_space:
                # A new regular app can already have brought its existing ordinary Space forward.
                require(assigned_ordinary(user,before['topology'],[first['number'],second['number']],witnesses([first,second])),
                        'unrelated foreground or Space arrived before the owned activation')
            documents.control(rootdoc,'activate',0)
            def confirmed_source(s):
                require(s['hid']==initial['hid'] and s['topology']['records']==user['records'] and s['topology']['display']==user['display'],
                        'human input or topology changed while macOS activated the own ordinary document')
                if s.get('frontPID')!=first['pid'] or s.get('focusedNumber')!=first['number']:return False
                return assigned_ordinary(user,s['topology'],[first['number'],second['number']],witnesses([first,second]))
            owned=until(state,confirmed_source,'normal AppKit activation did not place both owned documents and exact focus together on an ordinary Space',9)
            origin=owned['topology'];a=origin['current'];staging=a;store(out/'owned-source.json',dict(origin=origin,originalUserSpace=user_space,owned=first,witnesses=witnesses([first,second])))
            log('owned-ordinary-source',source=a,originalUserSpace=user_space,macOSAssigned=a!=user_space)
            route='ordinary' if args.route=='auto' else args.route
            result['setupRoute']=route;report()
            guard_setup(owned,initial,{a},{first['pid']})
            if route=='ordinary':
                keeper=OwnedKeeper(tool)
                lease=out/'ordinary-lease';lease.mkdir(mode=0o700);ws=Workspace(args.kit,lease,log)
                require(ws.home==staging,'ordinary lease origin changed')
                a=ws.create();one=state();require(owned_insertion(origin,one['topology'],0)==a,'first lease mismatch')
                checkpoint('first-lease')
                require(one['hid']==initial['hid'] and one['topology']['current'] in (staging,a),'new human input or unrelated foreground Space after first insertion')
                overview=until(lambda:cmd(args.kit/'system-workspace','overview-state'),
                               lambda s:s.get('stable') is True and s.get('visible') is False,
                               'signed Dock did not independently confirm closure of the first owned overview; second desktop was not requested',4)
                log('first-overview-closed-before-second-create',**overview)
                require(state().get('hid')==initial['hid'],'new physical input before second ordinary desktop creation')
                b=ws.create();both=state();top=both['topology']
                require(confirm_lease_pair(origin,one['topology'],top)==(a,b) and top['current'] in (staging,a,b),'new lease pair differs from the registered Spaces')
                checkpoint('second-lease')
                direct_setup(args.kit,ws,out,initial,top,top['current'],a,log,args.setup_input)
                first=documents.launch('Field Notes')['windows'][0]
                def placed(window,space):
                    return until(state,lambda s:s.get('hid')==initial['hid'] and s.get('topology')==dict(top,current=space)
                                 and s.get('frontPID')==window['pid'] and s.get('focusedNumber')==window['number'] and anchored([window],[space]),
                                 'owned ordinary document was not independently placed and focused on its leased Space')
                def admit(window,space,name):
                    placed(window,space)
                    evidence=out/f'retained-{name}.json'
                    def enroll():
                        receipt=keeper.call('enroll',window,space=space)
                        store(evidence,receipt);return receipt
                    until(enroll,lambda v:v.get('enrolled'),f'{name} foreground generation enrollment failed; see {evidence.name}')
                    path=out/f'current-card-{name}.json'
                    confirmed_current_cards(
                        lambda:keeper.call('current-card',window,hostPID=host['pid'],hostBirth=host['birth'],hostHash=host['hash'],hid=initial['hid']),
                        lambda samples:store(path,samples),f"current-desktop-window:{window['pid']}:{window['number']}",space)
                    log('installed-current-card-seen-twice',space=space,ownedWindow=window['number'],evidence=path.name)
                    checkpoint(name+'-document')
                admit(first,a,'first')
                direct_setup(args.kit,ws,out,initial,top,a,b,log,args.setup_input)
                second=documents.launch('Route Notes')['windows'][0]
                admit(second,b,'second')
                require(anchored([first,second],[a,b]),'the two ordinary documents did not remain on their separate leased Spaces')
                initial_source=b
            else:
                documents.control(rootdoc,'fullscreen',1)
                def ready(s):
                    t=s.get('topology',{});new=[r for r in t.get('records',[]) if r not in origin['records']]
                    return len(new)==1 and new[0]['type']==4 and t['current']==new[0]['id'] and anchored([first,second],[a,new[0]['id']])
                full=until(state,ready,'AppKit fullscreen did not produce one new Space with both exact owned window memberships',9)
                b=owned_insertion(origin,full['topology'],4);result['createdFullscreen']=b;store(out/'fixture-fullscreen.json',full);report()
                require(compatible(full['topology'],a,b),'the system placed the owned fullscreen beyond a private Space; no product press permitted')
                guard_setup(full,initial,{b},{first['pid']});documents.control(rootdoc,'activate',0)
                until(state,lambda s:s.get('topology',{}).get('current')==a and s.get('frontPID')==first['pid'] and s.get('focusedNumber')==first['number'],
                      'return to the owned ordinary source through AppKit setup was not independently confirmed',6)
                initial_source=a
            enrolled={a:first,b:second};start=state();top=start['topology']
            guard_setup(start,initial,{initial_source},{enrolled[initial_source]['pid']});require(compatible(top,a,b),'owned endpoints not adjacent')
            store(out/'enrolled.json',dict(topology=top,windows={str(k):v for k,v in enrolled.items()},witnesses=witnesses([first,second])))
            source=initial_source
            for gate,how_many in GATES:
                stage=result['stages'][gate];stage['status']='BLOCKED';report()
                for n in range(1,how_many+1):
                    sample=state();target=b if source==a else a
                    req=dict(topology={**top,'current':source},sourceWindow=enrolled[source],targetWindow=enrolled[target],target=target,
                             hostPID=host['pid'],hostBirth=host['birth'],hostHash=host['hash'],hid=initial['hid'])
                    if sample.get('topology')!=req['topology'] or sample.get('hid')!=initial['hid']:
                        trial=dict(status='BLOCKED',reason='new input or topology changed before the next sample',hostIssued=False,axIssued=False)
                        sample_dir=out/f'{gate}-{n:02}';sample_dir.mkdir();store(sample_dir/'result.json',trial);log('card-not-issued',**trial)
                    else:trial=attempt(tool,req,out/f'{gate}-{n:02}',journal,log,visual_stage=gate,keeper=keeper)
                    stage['samples'].append(dict(index=n,source=source,target=target,**trial));evaluate_gate(stage,gate,how_many);report()
                    if gate=='ten':result['blankScreen']=stage['blankScreen'];result['blankScreenScope']='ten'
                    if trial['status']!='PASS':break
                    source=target
                if stage['status']!='PASS':
                    result['status']=stage['status']
                    if gate=='ten':result['stages']['fifty']['reason']='10-switch gate did not pass every required subcheck'
                    break
                if gate=='fifty':
                    times=[x['latencyMS'] for x in stage['samples']];stage['latencyMS']={k:percentile(times,p) for k,p in [('p50',.50),('p95',.95),('p99',.99)]}
                    stage['latencyDefinition']='AXPress dispatch uptime to first independent target observation, nearest-rank statistics';result['status']='PASS'
                report()
        except (OSError,RuntimeError,ValueError,KeyError,TypeError,subprocess.SubprocessError) as e:
            result['reason']=str(e);log('stopped',reason=str(e))
            try:checkpoint('stopped')
            except (ValueError,OSError,KeyError,subprocess.SubprocessError) as diagnostic:log('fixture-diagnostics-unavailable',reason=str(diagnostic))
            if result['stages']['roundTrip']['status']=='NOT_RUN':
                result['stages']['roundTrip'].update(status='BLOCKED',reason=str(e))
        finally:
            problems=[];clean={}
            # Only a positively held fixture may return its own document to its original ordinary Space.
            if rootdoc and initial and top and a and b:
                try:
                    live=state(); current=live['topology']['current']
                    if current in (a,b) and current!=staging and live['topology']['records']==top['records'] and live['hid']==initial['hid'] and live['frontPID'] in {d['proc'].pid for d in documents.processes}:
                        documents.control(rootdoc,'activate',0);until(state,lambda s:s.get('topology',{}).get('current')==staging,'own staging document did not return to its original desktop',5)
                except (ValueError,OSError,KeyError,subprocess.SubprocessError) as e:problems.append(str(e))
            if keeper:keeper.close();keeper=None
            problems.extend(documents.close());nums=[w['number'] for d in documents.processes for w in d['windows']];clean['ownedAppsExited']=all(d['proc'].poll() is not None for d in documents.processes)
            if nums:
                try:until(lambda:cmd(tool,'absence',*nums),lambda x:x.get('absence')==[True]*len(nums),'owned CG window numbers still present',8);clean['ownedWindowsGone']=True
                except (ValueError,OSError,subprocess.SubprocessError) as e:problems.append(str(e));clean['ownedWindowsGone']=False
            if ws and lease:
                try:
                    # Recovery binds the now-current unrelated foreground if the user moved during the run.
                    live=state();recovery=Workspace(args.kit,lease,log,resume=True)
                    if live.get('hid')!=initial['hid'] and live.get('topology',{}).get('current') in recovery.ids():
                        clean['ordinary']={'outstanding':recovery.ids(),'reason':'latest human input on a leased desktop; foreground preserved'}
                    else:clean['ordinary']=recovery.cleanup()
                    if clean['ordinary']['outstanding']:problems.append('ordinary lease still outstanding')
                except (ValueError,OSError,subprocess.SubprocessError) as e:problems.append(str(e))
            if initial:
                try:
                    last=state();deadline=time.monotonic()+7
                    while last.get('topology',{}).get('records')!=initial['topology']['records'] and time.monotonic()<deadline:time.sleep(.15);last=state()
                    needs_focus=(last.get('frontPID'),last.get('focusedNumber'),last.get('topology'))!=(initial.get('frontPID'),initial.get('focusedNumber'),initial.get('topology'))
                    if focus:
                        end=last.get('topology',{})
                        same_inventory=end.get('display')==initial['topology']['display'] and end.get('records')==initial['topology']['records']
                        safe=bool(held.get('held') and needs_focus and same_inventory and end.get('current') in (initial['topology']['current'],staging) and last.get('hid')==initial['hid'])
                        clean['originalFocusRestoration']=focus.finish(safe,staging if end.get('current')!=initial['topology']['current'] else None);focus=None
                        if safe:last=state()
                    store(out/'final.json',last);end=last.get('topology',{})
                    clean.update(originalOrderAndUUIDsRestored=end.get('records')==initial['topology']['records'] and end.get('display')==initial['topology']['display'],
                                 originalCurrentRestored=end.get('current')==initial['topology']['current'],originalForegroundRestored=last.get('frontPID')==initial.get('frontPID'),
                                 originalFocusedWindowRestored=last.get('focusedNumber')==initial.get('focusedNumber') if initial.get('focusedNumber') else None,
                                 newerHumanInput=last.get('hid')!=initial.get('hid'))
                    if not clean['originalOrderAndUUIDsRestored']:problems.append('original Space topology was not restored')
                    if not clean['newerHumanInput'] and (not clean['originalCurrentRestored'] or not clean['originalForegroundRestored'] or clean['originalFocusedWindowRestored'] is False):problems.append('automatic restoration of original current, foreground or exact focus unconfirmed')
                except (ValueError,OSError,KeyError,subprocess.SubprocessError) as e:problems.append(str(e))
            if focus:focus.finish(False)
            clean['errors']=problems;clean['status']='UNKNOWN' if problems else 'PASS';result['cleanup']=clean
            if problems and result['status']=='PASS':result['status']='UNKNOWN'
            report()
    return 0 if result['status']=='PASS' else 2


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('kit',type=lambda s:Path(s).resolve());parser.add_argument('output',type=Path)
    parser.add_argument('--route',choices=['auto','ordinary','fullscreen'],default='auto')
    parser.add_argument('--setup-input',choices=['ax','click'],default='ax',help='choose one native setup input before the run; never replay an issued input')
    args=parser.parse_args();os.umask(0o077)
    def terminate(signum,frame):raise RuntimeError('received termination signal '+str(signum))
    signal.signal(signal.SIGTERM,terminate);raise SystemExit(run(args))
