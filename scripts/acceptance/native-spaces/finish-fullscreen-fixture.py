#!/usr/bin/env python3
"""Confirm normal fullscreen exit and close only a held synthetic fixture. No fullscreen, keyboard or Space action."""
import argparse
import importlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import time
import uuid

from installed_profile import APP, PROFILE, installed_pid, owns_profile
from space_scope import private_file, require
from split_fullscreen import fixture_only_aux, host_window_numbers, resume_lease, stable_shell

driver=importlib.import_module('split-view')


def completed_exit(v,s,req):
    lease=req['lease']
    return (s.get('numbers')==req['numbers'] and s.get('pid')==req['fixturePID'] and s.get('birth')==req['fixtureBirth'] and
            s.get('session')==req['session'] and s.get('fullscreen')==[False,False] and v.get('ready') is True and
            v.get('kernelCodeIdentitiesVerified') is True and v.get('space')==lease and v.get('spaceUUID')==req['protected'][str(lease)] and
            v.get('type')==0 and v.get('newFullscreenIDs')==[] and v.get('memberships')==[[lease],[lease]] and v.get('forward')==[True,True] and
            v.get('axStandard')==[True,True] and v.get('axFullscreen')==[False,False] and v.get('foreignVisibleMembers')==0 and
            v.get('unknownVisibleMembers')==0 and stable_shell(v) and fixture_only_aux(v.get('leaseWindowCensus',{})))


def main(kit,prior,workspace,out,close):
    os.umask(0o077);out.mkdir(mode=0o700,parents=True,exist_ok=False)
    result=dict(status='BLOCKED',fullscreenRequests=0,spaceActions=0,pixelsRead=0,closeIssued=False)
    save=lambda:driver.save_receipt(out,result)
    save()
    try:
        old=json.loads(private_file(prior/'result.json',limit=8_000_000));held=old['cleanup'];ident=old['fixture'];n=old['lease']['id']
        require(old['fullscreen'].get('entry')=='PASS' and held.get('reason')=='ownedFixtureRetainedUntilVerifiedNormalExit' and
                any(r.get('index')==0 and r.get('issued') is True for r in old['fullscreenExit']['requests']),'noEnrolledLiveFixtureAfterRequestedNormalExit')
        folder=Path(held['directory']);base=folder.parent
        require(folder.resolve()==folder and base.parent==Path('/private/tmp') and base.name.startswith('nearpane-split-view.') and
                str(uuid.UUID(folder.name))==folder.name and all(p.stat().st_uid==os.getuid() and p.stat().st_mode&0o077==0 for p in (base,folder)) and
                (base/'retain-for-owned-exit').is_file() and (folder/'normal-fullscreen-exit').is_file(),'retainedPrivateFixtureDirectoryChanged')
        display,protected=resume_lease(workspace,n)
        require(old['lease']==dict(display=display,id=n,uuid=protected[str(n)]) and held['fixturePID']==ident['pid'],'originalLeaseOrHeldPIDChanged')
        host=installed_pid();require(host and owns_profile(host,Path.home()/PROFILE),'restoredDailySignedHostNotRunning')
        executable=kit/'Split Notes.app/Contents/MacOS/SplitNotes'
        for code in (APP,executable.parents[2],kit/'split-view-read',kit/'observe',kit/'system-workspace'):
            subprocess.run(['codesign','--verify','--strict',code],check=True,capture_output=True,timeout=5)
        host_hash=driver.identity(APP)['CDHash']
        require(host_hash==old['install']['cdHash'] and driver.identity(executable)['CDHash']==ident['cdHash'],'installedOrFixtureCodeChanged')
        host_birth=int(subprocess.check_output([kit/'system-workspace','birth',str(host)],timeout=4))
        req=dict(hostPID=host,hostBirth=host_birth,hostHash=host_hash,fixturePID=ident['pid'],fixtureBirth=ident['birth'],
                 fixtureHash=ident['cdHash'],fixturePath=str(executable),numbers=ident['numbers'],session=folder.name,display=display,lease=n,protected=protected)
        summaries=[];result['reads']=summaries
        def global_read():
            return json.loads(subprocess.check_output([kit/'observe'],env={**os.environ,'NEARPANE_CONTRACT_SPACE_IDS':str(n)},timeout=6))
        for _ in range(2):
            o=global_read();top=o['scopes'][0];occupants=o['scopedMembers'][str(n)]
            require(len(o['scopes'])==1 and top['current']==n and top['scope']==display and
                    {str(r['id']):r['uuid'] for r in top['records']}==protected and o['host']['pid']==host,'actualHostDisplayOrSpaceChanged')
            req.update(observedStage=o['stageManager'],protectedTypes={str(r['id']):r['type'] for r in top['records']},
                       enrolledHostWindows=host_window_numbers(occupants.get('otherDetails',[]),host,n))
            v=driver.read([kit/'split-view-read','compare-roster','fullscreen-read'],payload=req,timeout=7)
            own=json.loads(private_file(folder/'windows.json'))
            summary={k:v.get(k) for k in ('space','spaceUUID','newFullscreenIDs','memberships','forward','axStandard','axFullscreen','foreignVisibleMembers','unknownVisibleMembers','windowManagement','leaseWindowCensus')}
            summary.update(ownedFullscreen=own.get('fullscreen'),verified=completed_exit(v,own,req))
            summaries.append(summary);save()
            require(summary['verified'],'ownedDocumentsOrHiddenAuxiliaryUnconfirmed')
            if len(summaries)==2:require(summaries[0]==summaries[1],'normalExitReadbacksChanged')
            time.sleep(.24)
        result.update(exitVerified=True,status='PASS' if not close else 'UNKNOWN');save()
        if not close:return 0
        require(owns_profile(host,Path.home()/PROFILE) and installed_pid()==host and not (folder/'close').exists(),'dailyHostChangedOrPriorCloseExists')
        result.update(closeIssued=None,closeIntentFixturePID=ident['pid']);save()
        fd=os.open(folder/'close',os.O_WRONLY|os.O_EXCL|os.O_NOFOLLOW|os.O_CREAT,0o600);os.close(fd)
        result['closeIssued']=True;save()
        deadline=time.monotonic()+9;stable=0
        while time.monotonic()<deadline:
            try:
                os.kill(ident['pid'],0)
                birth=subprocess.run([kit/'system-workspace','birth',str(ident['pid'])],capture_output=True,text=True,timeout=3)
                gone=birth.returncode==0 and int(birth.stdout)!=ident['birth']
            except ProcessLookupError:gone=True
            absence=driver.read([kit/'observe','absence',*ident['numbers']]).get('allGone') is True
            top=global_read()['scopes'][0];same=top['current']==n and top['scope']==display and {str(r['id']):r['uuid'] for r in top['records']}==protected
            stable=stable+1 if gone and absence and same else 0
            if stable>=2:
                result.update(status='PASS',processGenerationGone=True,bothWindowNumbersGone=True,leaseStillCurrent=True,protectedTopologyRestored=True)
                save();shutil.rmtree(base);return 0
            time.sleep(.22)
        raise ValueError('normalCloseOrWindowAbsenceUnconfirmed')
    except (OSError,ValueError,TypeError,KeyError,subprocess.SubprocessError) as error:
        result['reason']=str(error)[:220];save();return 2


if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__)
    for name in ('kit','prior','workspace','output'):p.add_argument(name,type=Path)
    p.add_argument('--close',action='store_true',help='normally close the signed fixture after two current independent proofs')
    a=p.parse_args();raise SystemExit(main(a.kit.resolve(),a.prior.resolve(),a.workspace.resolve(),a.output.resolve(),a.close))
