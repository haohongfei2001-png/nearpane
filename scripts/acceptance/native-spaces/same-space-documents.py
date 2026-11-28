"""Exercise W01 on a single ordinary desktop without provisioning unused extra Spaces."""
import argparse
import os
from pathlib import Path

from acceptance import Receipt, controlled_window, manifest
from contract_document import run as try_documents
from contract_workspace import Workspace, row
from installed_profile import PROFILE, installed_pid, owns_profile
from space_scope import require


def run(kit, output):
    require(owns_profile(installed_pid(),Path(os.environ['NEARPANE_TEST_HOME'])/PROFILE),'isolated production profile required')
    rec=Receipt(output); ws=None
    try:
        ws=Workspace(kit,output,rec.log);first=ws.original;topology=row(first);current=topology['current']
        require(any(s['id']==current and s['type']==0 for s in topology['records']), 'ordinary starting Space required')
        frozen=manifest(first,kit/'metrics');require(frozen['signatureValid'] and frozen['loadedMatchesInstalled'],'signed installed controls required');rec.write('manifest.json',frozen)
        outcome=try_documents(ws,rec,current);rec.scenarios['W01']=outcome
        if outcome['status']=='BLOCKED' and outcome['issued']==0:
            partial=Receipt(output/'owned-documents');why=controlled_window(kit/'observe',first,frozen,partial,2);partial.finish();rec.attempts.extend(partial.attempts)
            rec.summary['fixtureEvidence']=why
            if any(t['status']=='FAIL' for t in partial.attempts):rec.scenarios['W01']={'status':'FAIL','reason':why}
    finally:
        if ws:rec.summary['cleanup']=ws.cleanup()
        rec.finish()
    return 0 if rec.scenarios['W01']['status']=='PASS' else 2


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('kit',type=Path);parser.add_argument('output',type=Path);args=parser.parse_args();os.umask(0o077);raise SystemExit(run(args.kit.resolve(),args.output.resolve()))
