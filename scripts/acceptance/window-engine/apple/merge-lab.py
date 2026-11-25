#!/usr/bin/env python3
"""Prepare a nonce-sealed isolated R4 Host; the separate run command never posts a gesture."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import platform
import stat
import subprocess
import time
import uuid

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[3]
TEAM = 'ZB9D4T66QB'
HOST = 'com.holdsnow.nearpane.host'
spec = importlib.util.spec_from_file_location('development_seal', HERE.parent / 'probe-development-host.py')
dev = importlib.util.module_from_spec(spec)
spec.loader.exec_module(dev)


def call(*args, cwd=ROOT, timeout=100):
    return subprocess.run(list(map(str, args)), cwd=cwd, check=True, text=True, capture_output=True, timeout=timeout).stdout


def save(path, obj):
    with path.open('x') as f:
        json.dump(obj, f, indent=2, sort_keys=True)
        f.write('\n')


def safe_root(root):
    st = root.lstat()
    if (root.resolve(strict=True) != root or root.parent != Path('/private/tmp') or st.st_uid != os.getuid()
            or not stat.S_ISDIR(st.st_mode) or stat.S_IMODE(st.st_mode) != 0o700):
        raise ValueError('unsafe lab directory')
    prefix = 'nearpane-apple-merge.'
    nonce = str(uuid.UUID(root.name.removeprefix(prefix)))
    if root.name != prefix + nonce:
        raise ValueError('noncanonical lab nonce')
    return nonce


def prepare(source):
    source = Path(source).absolute()
    if source.resolve(strict=True) != source or ROOT / 'build' not in source.parents or source.name != 'Nearpane.app':
        raise ValueError('use a normal debug build under this checkout')
    plist = plistlib.loads((source / 'Contents/Info.plist').read_bytes())
    revision = call('git','rev-parse','HEAD').strip()
    if (plist['CFBundleIdentifier'] != HOST or plist.get('NearpaneReadOnlyGuardianProtocol') is not None
            or plist.get('NearpaneNativeMergeFixtureProtocol') is not None
            or plist.get('NearpaneStageEngineSourceRevision') != revision
            or plist.get('NearpaneStageEngineSourceState') != 'clean'):
        raise ValueError('current clean ordinary debug source required')
    nonce = str(uuid.uuid4())
    root = Path('/private/tmp') / ('nearpane-apple-merge.' + nonce)
    root.mkdir(mode=0o700)
    safe_root(root)
    app = root / 'Nearpane.app'
    call('/usr/bin/ditto','--rsrc','--extattr','--qtn',source,app)
    dev.seal(app, False)
    p = app / 'Contents/Info.plist'
    plist = plistlib.loads(p.read_bytes())
    plist.update(NearpaneNativeMergeFixtureProtocol=1, NearpaneNativeMergeNonce=nonce)
    p.write_bytes(plistlib.dumps(plist))
    identity = dev.signing.product_fingerprint(dev.checked('/usr/bin/security','find-identity','-v','-p','codesigning'))
    binary = root / 'fixture-image'
    call('/usr/bin/clang','-fobjc-arc','-framework','AppKit',HERE/'merge-fixture.m','-o',binary)
    hashes = {}
    for letter in ('A','B'):
        name='Merge '+letter
        identifier='com.holdsnow.stageworkset-merge-fixture.'+letter.lower()
        child=app/'Contents/Helpers'/(name+'.app')
        exe=child/'Contents/MacOS/MergeFixture'
        exe.parent.mkdir(parents=True)
        call('/bin/cp',binary,exe)
        (child/'Contents/Info.plist').write_bytes(plistlib.dumps(dict(CFBundlePackageType='APPL',CFBundleIdentifier=identifier,
            CFBundleExecutable=exe.name,CFBundleName=name,CFBundleVersion='1',LSMultipleInstancesProhibited=True,
            NearpaneNativeMergeNonce=nonce,NSPrincipalClass='NSApplication')))
        call('/usr/bin/codesign','--force','--options','runtime','--timestamp=none','--sign',identity,child)
        hashes[identifier]=dev.fields(child)
    call('/usr/bin/codesign','--force','--options','runtime','--timestamp=none','--preserve-metadata=entitlements',
         '--sign',identity,'--identifier',HOST,app)
    call('/usr/bin/codesign','--verify','--deep','--strict','--all-architectures',app)
    if dev.fields(app).get('TeamIdentifier')!=TEAM or any(v.get('TeamIdentifier')!=TEAM for v in hashes.values()):
        raise ValueError('unexpected signer')
    save(root/'seal.json',dict(nonce=nonce,source=revision,host=dev.fields(app),fixtures=hashes,scope='R4 native fixture drop'))
    print(root)


def confirmed_membership(receipt):
    reads=receipt.get('timeline',[])
    end=reads[-2:]
    agreed=(len(end)==2 and all(r.get('phase')=='readback' and r.get('settled') is True for r in end)
            and end[0].get('current')==end[1].get('current') and len(end[0].get('current',[]))==2
            and end[0].get('nativeAXStrip')==end[1].get('nativeAXStrip')==[]
            and end[1].get('timeNS',0)>end[0].get('timeNS',0)>0
            and reads[0].get('sourceWindow') in end[1]['current'] and len(reads[0].get('current',[]))==1
            and set(reads[0]['current']).issubset(end[1]['current']) and reads[0].get('managerTwin',0)>0)
    return agreed


def run(root, native_qualification):
    nonce=safe_root(root)
    app=root/'Nearpane.app'
    seal=json.loads((root/'seal.json').read_text())
    plist=plistlib.loads((app/'Contents/Info.plist').read_bytes())
    if (seal['nonce']!=nonce or seal['host']!=dev.fields(app) or seal['host'].get('TeamIdentifier')!=TEAM or
            plist.get('NearpaneNativeMergeNonce')!=nonce or plist.get('NearpaneNativeMergeFixtureProtocol')!=1):
        raise ValueError('lab pin mismatch')
    if (root/'run.json').exists() or (root/'result.json').exists():
        raise ValueError('single-use lab already consumed')
    call('/usr/bin/codesign','--verify','--deep','--strict','--all-architectures',app)
    # No global setting is changed. A disabled system or another existing .host stops before any window launch.
    if (platform.machine()!='arm64' or call('/usr/bin/sw_vers','-buildVersion').strip()!='26A428' or
            call('/usr/bin/csrutil','status').strip()!='System Integrity Protection status: enabled.' or
            call('/usr/bin/defaults','read','com.apple.WindowManager','GloballyEnabled').strip()!='1'):
        raise ValueError('target system or native Stage Manager unavailable')
    installed=subprocess.run(['/usr/bin/pgrep','-x','NearpaneHost'],capture_output=True,text=True)
    for pid in installed.stdout.split():
        path=call('/bin/ps','-p',pid,'-o','comm=').strip()
        if path!='/Applications/Nearpane.app/Contents/MacOS/NearpaneHost':
            raise ValueError('conflicting internal Host instance')
    result=dict(status='UNKNOWN',fixtureCleanup='UNKNOWN',productionQualified=False)
    try:
        call('/usr/bin/open','-g','-W','-a',app,'--args','--native-acceptance-apple-merge-once' if native_qualification else '--native-acceptance-apple-merge',nonce,timeout=155)
        receipt=json.loads((root/'host.json').read_text())
        children=receipt.get('children',[])
        expected={'com.holdsnow.stageworkset-merge-fixture.a','com.holdsnow.stageworkset-merge-fixture.b'}
        valid=(receipt.get('nonce')==nonce and {p['identifier'] for p in children}==expected and
               all(p['cdhash']==seal['fixtures'][p['identifier']]['CDHash'] and p['birth']>0 for p in children))
        def gone():
            return valid and all(subprocess.run(['/bin/ps','-p',str(p['pid']),'-o','pid='],capture_output=True).returncode == 1 for p in children)
        deadline=time.monotonic()+3
        while valid and not gone() and time.monotonic()<deadline:
            time.sleep(.1)
        cleared=gone()
        agreed = confirmed_membership(receipt)
        result.update(scope='oneNativeFixtureMergeAndCleanupOnly',nativeFixtureAutomation=native_qualification,physicalR4Gesture='NOT_RUN',fixtureCleanup='PASS' if cleared else 'UNKNOWN',
                      membershipDoubleRead=agreed,physicalInputReceiver='NOT_RUN',source=seal['source'],host=seal['host'],
                      status='PASS' if cleared and agreed and receipt.get('membershipDoubleRead') is True else
                      'NOT_RUN' if cleared and receipt.get('attempted') is False else 'UNKNOWN')
    finally:
        save(root/'result.json',result)
    print(json.dumps(result,sort_keys=True))


if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__)
    cmd=p.add_subparsers(dest='command',required=True)
    cmd.add_parser('prepare').add_argument('debug_host')
    launch=cmd.add_parser('run')
    launch.add_argument('lab',type=Path)
    launch.add_argument('--native-qualification',action='store_true',help='one native route operation restricted to this sealed test cohort; does not test a physical sidebar drag')
    a=p.parse_args()
    try:
        prepare(a.debug_host) if a.command=='prepare' else run(a.lab,a.native_qualification)
    except (OSError,ValueError,KeyError,subprocess.SubprocessError) as exc:
        if a.command == 'run':
            try:
                safe_root(a.lab)
                if (a.lab/'seal.json').is_file() and not (a.lab/'result.json').exists():
                    save(a.lab/'result.json',dict(status='BLOCKED',reason=type(exc).__name__,scope='preflight',
                         nativeFixtureAutomation=a.native_qualification,physicalR4Gesture='NOT_RUN',productionQualified=False))
            except (OSError,ValueError): pass
        p.exit(2,f'{type(exc).__name__}: {exc}\n')
