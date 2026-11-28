#!/usr/bin/env python3
"""Clean up the inactive journalled preview desktops, after an independent return to the original Space."""
import argparse
import json
import os
from pathlib import Path
import subprocess

from contract_workspace import Workspace, row, write_owned
from installed_profile import PROFILE, installed_pid, owns_profile
from space_scope import private_file, require


def run(kit, previous, checkout, output, apply, previous_archive=None, install_receipt=None):
    os.umask(0o077);output.mkdir(mode=0o700,parents=True,exist_ok=False)
    result={'status':'BLOCKED','mode':'apply' if apply else 'inspect','navigationRequested':False,'productActions':0}
    def log(event,**info):
        with (output/'events.jsonl').open('a') as f:
            f.write(json.dumps(dict(event=event,**info))+'\n');f.flush();os.fsync(f.fileno())
    try:
        ledgers=checkout/'build/verification/secondary-route-followup'
        require(ledgers.is_dir() and ledgers.resolve()==ledgers,'unrecognizedOriginalPrivateLedgerRoot')
        home=json.loads(private_file(previous/'original.json'));origin=row(home)['current']
        for name in ('system-workspace','observe'):subprocess.run(['codesign','--verify','--strict',kit/name],check=True,timeout=5)
        current=json.loads(subprocess.check_output([kit/'observe'],timeout=7));observed=row(current)
        result.update(origin=origin,initialCurrent=observed['current'])
        require(observed['scope']==row(home)['scope'] and observed['current']==origin and
                any(v['id']==origin and v['uuid']==next(k['uuid'] for k in row(home)['records'] if k['id']==origin) for v in observed['records']),
                'originalProtectedSpaceMustAlreadyBeCurrentBeforeAnyRemoval')
        host=installed_pid()
        require(host and owns_profile(host,Path.home()/PROFILE) and current.get('host',{}).get('pid')==host,'signedDailyHostRequired')
        ws=Workspace(kit,previous,log,resume=True,original_ledgers=ledgers,
                     previous_archive=previous_archive,install_receipt=install_receipt)
        state=ws.check(ws.read())
        require(state['current']==origin==ws.cleanup_current==ws.home and ws.host['pid']==host,'currentOriginalHostOrSpaceChanged')
        scans=ws.read();scoped=scans.get('scopedMembers',{})
        from contract_workspace import inactive_empty
        result['inactiveLeases']=[dict(space=n,emptyWithSignedInvisibleSystemOnly=inactive_empty(scoped.get(str(n),{}),n,system_surfaces=True),
            ordinaryCount=len(scoped.get(str(n),{}).get('ordinary',[])),unresolved=scoped.get(str(n),{}).get('unresolved'),
            nonDocumentLayers=scoped.get(str(n),{}).get('otherMembers')) for n in ws.ids()]
        if apply:
            # Workspace journals the single Apple AXRemoveDesktop and its independent
            # postcondition for each inactive lease, newest first.
            result['cleanup']=ws.cleanup(inactive_system_surfaces=True)
            require(result['cleanup'].get('topologyRestored') and result['cleanup'].get('outstanding')==[] and
                    not result['cleanup'].get('errors'),'normalInactiveRemovalOrFinalTopologyUnconfirmed')
        result['status']='PASS' if apply else 'INSPECTED'
    except (OSError,KeyError,ValueError,TypeError,subprocess.SubprocessError) as error:
        result['reason']=str(error)[:200]
    write_owned(output/'result.json',result)
    return 0 if result['status'] in ('PASS','INSPECTED') else 2


if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__)
    for n in ('kit','workspace','original_checkout','output'):p.add_argument(n,type=Path)
    p.add_argument('--apply',action='store_true',help='remove only proven empty inactive created desktops using their actual Apple controls')
    p.add_argument('--previous-archive',type=Path)
    p.add_argument('--install-receipt',type=Path)
    a=p.parse_args();raise SystemExit(run(a.kit.resolve(),a.workspace.resolve(),a.original_checkout.resolve(),a.output.resolve(),
                                          a.apply,a.previous_archive,a.install_receipt))
