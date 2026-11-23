#!/usr/bin/env python3
"""Run one signed internal Host read, bracketed by observations of the untouched daily Host."""
import argparse
from datetime import datetime, timezone
import hashlib
import importlib
import json
import os
from pathlib import Path
import subprocess
import sys

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parents[1] / 'native-spaces'))
import installed_profile

permissions = importlib.import_module('installed-permissions')
recovery = importlib.import_module('daily-recovery')


def save(path, data):
    with path.open('x') as stream:
        json.dump(data, stream, indent=2)
        stream.write('\n')


def ownership():
    # Hash the existing ownership files only. Do not read a user's window or interpret old geometry.
    root = recovery.owned(recovery.PROFILE / 'generations')
    paths = []
    for folder in root.iterdir():
        directory = recovery.owned(folder)
        for rel in ('Nearpane/stage-visibility-v1.json', 'WorkRect/ordinary/journal.json'):
            p = directory / rel
            if os.path.lexists(p):
                paths.append(p)
        paths.extend((directory / 'Nearpane/.corner-guardians').glob('*/*'))
    digests = {}
    for path in sorted(paths):
        if not recovery.owned(path).is_file():
            raise ValueError('unexpected recovery artifact')
        name = hashlib.sha256(os.fsencode(path.relative_to(root))).hexdigest()
        with path.open('rb') as stream:
            digests[name] = hashlib.file_digest(stream, 'sha256').hexdigest()
    shared = recovery.SHARED
    holders = []
    if os.path.lexists(shared):
        if recovery.owned(shared).stat().st_mode & 0o077:
            raise ValueError('unexpected shared lock directory')
        proc = subprocess.run(['/usr/sbin/lsof', '-nP', '-Fpn', '+d', shared], capture_output=True, timeout=30)
        if proc.stderr or proc.returncode not in (0, 1) or (proc.returncode == 1 and proc.stdout):
            raise ValueError('incomplete shared lock census')
        holders = [hashlib.sha256(line).hexdigest() for line in proc.stdout.splitlines()]
    return dict(fileSHA256=digests, sharedHolders=holders)


def daily(path):
    measured = permissions.sample()
    save(path, measured)
    req = measured.get('subject') or {}
    config = installed_profile.daily_state()
    if (measured['status'] != 'PASS' or not config or installed_profile.installed_pid() != req.get('pid') or
            not req.get('birth') or not req.get('cdhash') or type(measured.get('permissions')) is not dict):
        raise ValueError('daily Host, actual permissions or configuration unconfirmed')
    return dict(pid=req['pid'], birth=req['birth'], cdhash=req['cdhash'], image=measured['installed'],
                permissions=measured['permissions'], config=config, ownership=ownership())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('package_receipt', type=Path)
    parser.add_argument('output', type=Path, help='fresh private evidence directory')
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument('--visible-recovery', action='store_true', help='measure only the return of one still-visible signed fixture')
    mode.add_argument('--corner-readback', action='store_true', help='read a registered window on the product worker without starting Guardian')
    parser.add_argument('--abrupt-visible-exit', action='store_true', help='bypass Host teardown only in the internal visible fixture drill')
    a = parser.parse_args()
    if a.abrupt_visible_exit and not a.visible_recovery:
        parser.error('--abrupt-visible-exit requires --visible-recovery')
    out = a.output.resolve()
    out.mkdir(mode=0o700, exist_ok=False)
    seal = json.loads(a.package_receipt.read_bytes())
    result = dict(status='BLOCKED', guardianSurvival='NOT_RUN', normalOrCrashRecovery='NOT_RUN',
                  singleWindowHideRestore='NOT_RUN', stageGroupCycle='NOT_RUN', ten='NOT_RUN', fifty='NOT_RUN',
                  productionQualified=False, recordedUTC=datetime.now(timezone.utc).isoformat())
    try:
        app = Path(seal['app'])
        if (seal.get('status') != 'PASS' or seal.get('protocol') != 1 or not seal.get('deepStrictAllArchitectures')
                or seal['host']['Identifier'] != 'com.holdsnow.nearpane.host'
                or seal['host']['TeamIdentifier'] != 'ZB9D4T66QB'
                or (a.visible_recovery and seal.get('visibleRecoveryProtocol') != 1)
                or (a.abrupt_visible_exit and seal.get('abruptFixtureExitProtocol') != 1)):
            raise ValueError('expected a signed internal package receipt')
        result['source'] = seal['source']
        result['dailyBefore'] = daily(out / 'before-permissions.json')
        run = subprocess.run([sys.executable, '-B', HERE / 'sample-membership.py', app, out / 'session.json',
                              '--internal-host', '--visible-recovery' if a.visible_recovery else
                              '--corner-readback' if a.corner_readback else '--guardian-survival', '--expected-source', seal['source'],
                              '--expected-cdhash', seal['host']['CDHash'],
                              *(['--abrupt-visible-exit'] if a.abrupt_visible_exit else [])], timeout=180, check=False)
        session = json.loads((out / 'session.json').read_bytes())
        post = session.get('postExitGuardian') or {}
        result.update(status=session['status'], reason=session.get('reason'), sessionExit=run.returncode,
                      postExitRead=post.get('status', 'NOT_RUN'),
                      cleanup=session['probeResources'], rawSession='session.json')
        if a.corner_readback:
            result['cornerParkAccess'] = session.get('cornerParkAccess')
            result['productWindowRead'] = session.get('cornerWindowReadback') or {'status': 'NOT_RUN'}
        elif session.get('hostReadback'):
            host = json.loads((out / session['hostReadback']).read_bytes())
            principal = (host.get('preflight') or {}).get('guardianPrincipal') or {}
            result['principalMatchesSignedPackage'] = bool(principal.get('cdhash') and principal['cdhash'] ==
                seal['components']['Contents/Helpers/NearpaneCornerGuardian']['CDHash'])
        proved = (result['productWindowRead']['status'] == 'PASS' if a.corner_readback else
                  result.get('principalMatchesSignedPackage') is True and result['postExitRead'] == 'PASS')
        if result['status'] == 'PASS' and (run.returncode or not proved or not result['cleanup']['clear']):
            result.update(status='UNKNOWN', reason='incompleteReadOrCleanup')
    except (OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        result.update(status='UNKNOWN', reason=str(error)[:400])
    finally:
        try:
            result['dailyAfter'] = daily(out / 'after-permissions.json')
            result['dailyPreserved'] = result['dailyAfter'] == result.get('dailyBefore')
            if not result['dailyPreserved']:
                result.update(status='UNKNOWN', preservationError='dailyWitnessChangedOrUnavailable')
        except (OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
            result.update(status='UNKNOWN', preservationError=str(error)[:320])
        if a.visible_recovery:
            result['abruptExitVisibleReturn' if a.abrupt_visible_exit else 'normalExitVisibleReturn'] = result['status']
        elif result.get('postExitRead') in ('PASS', 'FAIL', 'UNKNOWN'):
            result['guardianSurvival'] = result['status']
        save(out / 'result.json', result)
    print(json.dumps({k: result.get(k) for k in ('status', 'reason', 'guardianSurvival', 'dailyPreserved')}))
    return 0 if result['status'] == 'PASS' else 2


if __name__ == '__main__':
    raise SystemExit(main())
