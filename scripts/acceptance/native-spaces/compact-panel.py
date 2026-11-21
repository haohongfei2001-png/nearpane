#!/usr/bin/env python3
"""Photograph only the installed Host's idle compact tool window on an already-current, empty ordinary Space."""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import sqlite3
import stat
import struct
import subprocess
import uuid
import zlib

from acceptance import identity
from installed_profile import APP, CACHES, PROFILE, installed_pid, owns_profile
from space_scope import LEDGERS, guid, private_file

TOOLS=('voice-capture-toggle','tray-content','tray-camera-entry','tray-file-drop')


def check(test, reason):
    if not test:
        raise ValueError(reason)


def record(cmd, *, env=None, payload=None, timeout=10):
    run=subprocess.run(list(map(str,cmd)),input=json.dumps(payload).encode() if payload else None,
                       capture_output=True,env=env,timeout=timeout,check=True)
    return json.loads(run.stdout)


def clean_profile(pid):
    home=Path(os.environ.get('NEARPANE_TEST_HOME',''))
    generation=Path(os.environ.get('NEARPANE_TEST_GENERATION',''))
    check(home.is_absolute() and home.name=='home' and home.parent.parent==CACHES and home.parent.name.startswith('nearpane-native-acceptance.')
          and home.resolve()==home and all(s.stat().st_uid==os.getuid() and stat.S_IMODE(s.stat().st_mode)==0o700 for s in (home,home.parent)),
          'privateAcceptanceHomeRequired')
    root=home/PROFILE
    check(owns_profile(pid,root),'installedHostNotHoldingPrivateProfile')
    index=root/'profile-index.json'
    check(index.resolve()==index and index.is_file() and index.stat().st_uid==os.getuid(),'privateGenerationIndexUnavailable')
    active=json.loads(index.read_bytes())['active']
    check(str(uuid.UUID(active))==active and generation==root/'generations'/active and generation.resolve()==generation,
          'isolatedGenerationChanged')
    counts={}
    for rel,table in [('Nearpane/Voice/Saytile.sqlite','recordings'),('Riftlet/queue.sqlite','assets')]:
        db=generation/rel
        check(db.is_file() and db.resolve()==db and db.stat().st_uid==os.getuid() and
              all(not Path(str(db)+s).is_symlink() for s in ('-wal','-shm','-journal')), 'isolatedDatabaseIdentityChanged')
        connection=sqlite3.connect(db.as_uri()+'?mode=ro',uri=True,timeout=.5)
        try:
            counts[table]=connection.execute('SELECT EXISTS(SELECT 1 FROM '+table+')').fetchone()[0]
        finally:
            connection.close()
    check(counts=={'recordings':0,'assets':0},'isolatedToolContentIsNotEmpty')
    return active


def leased(pointer, boot, proof):
    ref=json.loads(private_file(pointer))
    ledger=Path(ref['receipt'])
    check(ledger.name=='created.json' and ledger.parent.name=='provision' and ledger.parent.parent.parent==LEDGERS and
          str(uuid.UUID(ledger.parent.parent.name))==ledger.parent.parent.name and
          not any(os.path.lexists(ledger.parent/name) for name in ('removed.json','remove-intent.json')),'noActiveDesktopLease')
    raw=private_file(ledger)
    check(hashlib.sha256(raw).hexdigest()==ref['sha256'],'leaseDigestMismatch')
    doc=json.loads(raw);intent=json.loads(private_file(ledger.with_name('create-intent.json')))
    before,after=intent['initial'],doc['after'];target=str(proof['space'])
    check(doc['intent']==intent and intent['boot']==boot and guid(intent['display'])==guid(proof['display']) and doc['target']==target and
          target not in before['sideOrder'] and after['sideOrder'].count(target)==1 and
          [i for i in after['sideOrder'] if i!=target]==before['sideOrder'] and target not in after['fullscreenIDs'] and
          guid(after['spaceUUIDs'][target])==guid(proof['spaceUUID']) and all(after['spaceUUIDs'][i]==before['spaceUUIDs'][i] for i in before['sideOrder']),
          'currentSpaceDoesNotMatchCreatedLease')
    return ref['sha256']


def qualified(stage, surface, observer, metrics):
    check(stage.get('uid')==os.getuid() and stage.get('state') is True,'actualLoginStageManagerIsNotOn')
    check(surface.get('available') is True and surface.get('stageManager') is True and len(surface.get('panels',[]))==1 and
          all(surface.get('controls',{}).get(k)==1 for k in TOOLS) and surface['controls'].get('desktop-reserved-region')==0 and
          all(surface.get(k)==0 for k in ('windowCards','bareSpaceRows','duplicatedCards','legacyCards')),
          'uniqueCompactProductToolsUnavailable')
    p=surface['hostPID']
    check(metrics.get('pid')==p and metrics.get('stageManagerOwnsDispatch')==1 and metrics.get('surfaceHidden')==0 and
          all(metrics.get(k)==0 for k in ('activeStreams','visibleDisplays','gallerySessions','capturesInFlight')), 'installedHostHasNotYieldedItsWindowSwitcher')
    spaces=observer.get('scopes') or []
    check(observer.get('observerAX') is True and observer.get('observerScreenRead') is True and len(spaces)==1 and
          len(observer.get('displays',[]))==1 and observer['displays'][0]['uuid']==surface['display'] and
          spaces[0]['scope']==surface['display'] and spaces[0]['current']==surface['space'], 'exactSingleDisplayUnavailable')
    current=[r for r in spaces[0]['records'] if r['id']==surface['space'] and r['type']==0]
    c=observer.get('scopedMembers',{}).get(str(surface['space']),{})
    check(len(current)==1 and c.get('ordinary')==[] and c.get('otherMembers')==0 and c.get('unresolved')==0, 'currentOrdinaryDesktopIsNotProvenEmpty')
    return dict(pid=p,birth=surface['hostBirth'],hash=surface['hostHash'],panel=surface['panels'][0],
                display=surface['display'],space=surface['space'],spaceUUID=guid(current[0]['uuid']))


def png_chunks_valid(data):
    # A digest alone would also authenticate a truncated encoder result.
    pos,has_pixels=8,False
    while pos+12<=len(data):
        size=struct.unpack('>I',data[pos:pos+4])[0]
        tag=data[pos+4:pos+8]
        end=pos+12+size
        if end>len(data) or data[end-4:end]!=struct.pack('>I',zlib.crc32(data[pos+4:end-4])):
            return False
        has_pixels |= tag==b'IDAT' and size>0
        if tag==b'IEND':
            return has_pixels and size==0 and end==len(data)
        pos=end
    return False


def validated_image(result, proof):
    check(result.get('status')=='CAPTURED', result.get('reason','windowCaptureUnavailable'))
    check(all(result.get(k)==v for k,v in proof.items()) and result.get('filter')=='desktopIndependentWindow' and
          result.get('includedWindowCount')==1 and result.get('nativeTransparencyBacking')=='solidWhite' and
          result.get('controls')==dict.fromkeys(TOOLS,1), 'imageIsNotBoundToVerifiedCompactWindow')
    data=base64.b64decode(result['png'],validate=True)
    check(len(data)<=10_000_000 and len(data)>40 and data[:16]==b'\x89PNG\r\n\x1a\n\0\0\0\rIHDR' and
          struct.unpack('>II',data[16:24])==(result['width'],result['height']) and
          png_chunks_valid(data) and hashlib.sha256(data).hexdigest()==result['sha256'] and result['lumaRange'][1]-result['lumaRange'][0]>=48,
          'invalidNativeImageReadback')
    return data


def confirmed_frame(first, read, capture):
    check(read()==first,'admissionChangedAcrossIndependentReads')
    native=capture(first[0])
    data=validated_image(native,first[0])
    check(read()==first,'identityProfileStageOrDesktopChangedDuringImage')
    return native,data


def run(kit, output, lease):
    output.mkdir(mode=0o700,parents=True,exist_ok=False)
    result={'status':'BLOCKED','selection':'existing ordinary desktop' if lease is None else 'creation receipt',
            'pixelReadRequested':False,'systemActions':0}
    try:
        check(kit.parent==Path('/private/tmp') and kit.name.startswith('nearpane-d01.') and kit.stat().st_uid==os.getuid() and
              stat.S_IMODE(kit.stat().st_mode)==0o700,'privateAcceptanceKitRequired')
        for name in ('preview-stage-control','preview-surface','observe','metrics','compact-tool-capture'):
            p=kit/name
            check(p.is_file() and p.resolve()==p and p.stat().st_uid==os.getuid(),'missingOrUnownedReadOnlyHelper')
            subprocess.run(['codesign','--verify','--strict',p],check=True,capture_output=True,timeout=8)
        subprocess.run(['codesign','--verify','--strict','--deep','-R=identifier "com.holdsnow.nearpane.alpha"',APP],check=True,capture_output=True,timeout=12)
        plist=plistlib.loads((APP/'Contents/Info.plist').read_bytes())
        check(plist.get('CFBundleShortVersionString')=='5.22' and plist.get('CFBundleVersion')=='90','installedCandidateVersionChanged')
        host=installed_pid();fingerprint=identity(APP)['CDHash']
        check(bool(host) and re.fullmatch('[0-9a-f]{40}',fingerprint),'signedInstalledHostUnavailable')
        result['installed']=dict(version='5.22',build='90',source=plist.get('NearpaneSourceRevision'),cdHash=fingerprint)
        env=os.environ.copy()
        for key in ('CFFIXED_USER_HOME','NEARPANE_CONTRACT_SPACE_IDS'):
            env.pop(key,None)
        boot=subprocess.check_output(['/usr/sbin/sysctl','-n','kern.bootsessionuuid'],text=True).strip()
        def read():
            check(installed_pid()==host,'installedHostRestarted')
            generation=clean_profile(host)
            stage=record([kit/'preview-stage-control','state'],env=env)
            check(stage.get('state') is True,'actualLoginStageManagerIsNotOn')
            surface=record([kit/'preview-surface',host,fingerprint],env=env)
            check(surface.get('available') is True and surface.get('hostPID')==host and surface.get('hostHash')==fingerprint,'signedSurfaceUnavailable')
            metrics=record([kit/'metrics',host],env=env)
            system=record([kit/'observe'],env={**env,'NEARPANE_CONTRACT_SPACE_IDS':str(surface['space'])})
            proof=qualified(stage,surface,system,metrics)
            return proof,generation,leased(lease,boot,proof) if lease else None
        first=read()
        result.update(binding=first[0],leaseSHA256=first[2])
        def capture(proof):
            result['pixelReadRequested']=True
            return record([kit/'compact-tool-capture'],env=env,payload=proof,timeout=18)
        native,data=confirmed_frame(first,read,capture)
        # All bytes stay in process memory until the independent post-capture admission succeeds.
        with (output/'compact-tools.png').open('xb') as stream:
            stream.write(data)
        result.update(status='CAPTURED',image='compact-tools.png',independentReads=3,frame={k:v for k,v in native.items() if k!='png'})
    except (ValueError,sqlite3.Error,KeyError,TypeError,OSError,subprocess.SubprocessError) as error:
        msg=str(error)
        result['reason']=msg if re.fullmatch('[a-zA-Z][a-zA-Z0-9]{0,90}',msg) else type(error).__name__
    (output/'receipt.json').write_text(json.dumps(result,indent=2,ensure_ascii=False)+'\n')
    return result


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('kit',type=Path);parser.add_argument('output',type=Path)
    scope=parser.add_mutually_exclusive_group(required=True)
    scope.add_argument('--lease',type=Path,help='active workspace desktop-N.json reference')
    scope.add_argument('--current-empty',action='store_true',help='capture in place only after proving current ordinary desktop has no other windows')
    args=parser.parse_args()
    res=run(args.kit.resolve(),args.output.resolve(),args.lease.absolute() if args.lease else None)
    print(res['status']);raise SystemExit(0 if res['status']=='CAPTURED' else 2)
