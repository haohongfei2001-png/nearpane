"""Measure installed sidebar actions on three still-live, signed-install-session fixture desktops."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import time

from acceptance import APP, catalog_match, checked, encode, identity
from installed_profile import PROFILE, installed_pid, owns_profile
from space_scope import private_file, require


def counts(trials):
    return {
        'intents': len(trials),
        'issued': sum(trial.get('issued') is True for trial in trials),
        'passed': sum(trial['status'] == 'PASS' for trial in trials),
        'failed': sum(trial['status'] == 'FAIL' for trial in trials),
        'unknown': sum(trial['status'] == 'UNKNOWN' for trial in trials),
    }


def completed(totals):
    return totals['intents'] == totals['issued'] == totals['passed'] == 50


def run(args):
    out=args.output.resolve();out.mkdir(mode=0o700,parents=True,exist_ok=False)
    host=installed_pid();require(owns_profile(host,Path(os.environ['NEARPANE_TEST_HOME'])/PROFILE),'isolated production profile required')
    digest=identity(APP)['CDHash']; boot=checked(['/usr/sbin/sysctl','-n','kern.bootsessionuuid']).strip()
    leases={};scope=None
    for reference in args.references:
        ref=json.loads(private_file(reference.resolve()));p=Path(ref['receipt']);raw=private_file(p)
        require(p.parent.parent.parent==args.ledger_root.resolve() and p.name=='created.json' and p.parent.name=='provision' and hashlib.sha256(raw).hexdigest()==ref['sha256'] and not p.with_name('removed.json').exists(),'unbound or already recovered creation')
        created=json.loads(raw);n=created['target'];intent=created['intent'];before=intent['initial'];after=created['after'];display=intent['display']
        require(intent['boot']==boot and (scope is None or scope==display) and n not in before['sideOrder'] and [v for v in after['sideOrder'] if v!=n]==before['sideOrder'] and n not in after['fullscreenIDs'],'invalid ordinary new Space identity')
        scope=display;leases[int(n)]=after['spaceUUIDs'][n]
    require(len(leases)==3,'need three distinct owned desktops')
    def read():
        o=json.loads(checked([args.kit/'observe']));s=next((s for s in o['scopes'] if s['scope']==scope),None)
        require(s and len(o['scopes'])==1 and (o.get('host') or {}).get('pid')==host and o['host'].get('codeHash')==digest and all(any(row['id']==n and row['uuid']==u and row['type']==0 for row in s['records']) for n,u in leases.items()),'owned topology/Host changed')
        return s['current'],catalog_match(o)['highlightMatchesSystem'],o.get('frontmostPID'),o.get('focusedNumber')
    trials=[];data={'scope':'installed sidebar input and WindowServer arrival only','fullContract':False,'leased':leases,'hostCDHash':digest,'trials':trials}
    def save(): (out/'results.json').write_text(encode(data))
    with (out/'actions.jsonl').open('x') as log:
        def event(**v):log.write(json.dumps(v,separators=(',',':'))+'\n');log.flush();os.fsync(log.fileno())
        try:
            initial,hi,anchor,win=read();nums=list(leases)
            def press(i,source,target,mode):
                t=time.monotonic();entry=dict(index=i,source=source,target=target,t0=t,mode=mode,status='UNKNOWN');trials.append(entry);event(event='intent',**entry)
                reply=json.loads(checked([args.kit/'leased-row',str(host),digest,scope,str(source),str(target),*[f'{n}={u}' for n,u in leases.items()],mode]));entry.update(reply);event(event='dispatch',index=i,reply=reply)
                end=time.monotonic()+2.3;last=None;streak=0
                while time.monotonic()<end:
                    current,highlight,front,focus=read();entry.update(actual=current,highlight=highlight)
                    if current==target and highlight and current==last:streak+=1
                    else:streak=0
                    if streak>=1:
                        entry['status']='PASS' if reply.get('issued') and reply.get('axError')==0 else 'UNKNOWN';break
                    if current not in (source,target):
                        entry.update(status='FAIL',foreignArrival=True);break
                    last=current;time.sleep(.08)
                if reply.get('issued') and reply.get('axError')==0 and entry['status']=='UNKNOWN' and entry.get('actual')==source:entry['status']='FAIL'
                entry['seconds']=round(time.monotonic()-t,3);event(event='readback',**entry);save();return entry
            data['initial']=initial;save()
            anchorMode=f'anchor,{anchor},{win}'
            if initial not in leases:
                first=press(0,initial,nums[0],anchorMode)
                require(not first.get('foreignArrival'),'setup arrived outside the requested pair')
            for i in range(1,51):
                source,highlight,front,focus=read()
                anchor_still_front=source==initial and bool(anchor and win) and front==anchor and focus==win
                require(source in leases or anchor_still_front,'a different Space or user window became current; subsequent inputs stopped')
                target=nums[(nums.index(source)+(1 if i%4 else 2))%3] if source in leases else nums[i%3]
                mode='trial' if source in leases else anchorMode
                trial=press(i,source,target,mode);require(not trial.get('foreignArrival'),'independent reader observed a third Space')
        except (ValueError, OSError, subprocess.SubprocessError,RuntimeError) as e:data['reason']=str(e)
        finally:
            scored = counts([trial for trial in trials if trial['index'] > 0])
            data.update(scored)
            data['setup'] = counts([trial for trial in trials if trial['index'] == 0])
            data['allIssuedIncludingSetup'] = counts(trials)['issued']
            save()
    return 0 if completed(scored) else 2


if __name__=='__main__':
    ap=argparse.ArgumentParser(description=__doc__);ap.add_argument('kit',type=Path);ap.add_argument('ledger_root',type=Path);ap.add_argument('output',type=Path);ap.add_argument('references',nargs=3,type=Path);raise SystemExit(run(ap.parse_args()))
