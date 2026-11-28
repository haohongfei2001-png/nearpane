#!/usr/bin/env python3
"""Apply a minimal real bridge candidate only after actual typed-image proof.

The candidate unwraps the player's returned descriptor. It never loads the
album image from the media folder into the product, and preserves identity and
8 MiB checks. The original repository remains untouched.
"""
import argparse,difflib,hashlib,json,subprocess
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('package',type=Path);p.add_argument('evidence',type=Path);a=p.parse_args()
probe=a.evidence/'artwork-bridge-probe.json';payload=a.evidence/'actual-player-artwork-probe.bin'
result={'status':'NOT_APPLIED','productionRepositoryModified':False}
if probe.exists() and payload.exists():
    data=json.loads(probe.read_text());result['probe']=data
    typed=data.get('rawIsDescriptor') or data.get('rawIsSBObject') or data.get('resolvedIsDescriptor')
    image=subprocess.run(['ffprobe','-v','error','-select_streams','v:0','-show_entries','stream=codec_name,width,height','-of','json',str(payload)],capture_output=True,text=True)
    streams=json.loads(image.stdout or '{}').get('streams',[]) if image.returncode==0 else []
    good=any(s.get('width',0)>0 and s.get('height',0)>0 for s in streams)
    source=a.package/'Sources/CPlayerBridge/CPlayerBridge.m'
    already='if ([raw isKindOfClass:SBObject.class]) raw = [raw get];' in source.read_text() and 'if ([raw isKindOfClass:NSAppleEventDescriptor.class]) raw = [(NSAppleEventDescriptor *)raw data];' in source.read_text()
    if already:
        result.update(status='ALREADY_HAS_PROVEN_UNRELEASED_FIX',actualImageSHA256=hashlib.sha256(payload.read_bytes()).hexdigest(),actualImageProbe=streams)
    elif typed and data.get('identityValid') and data.get('unwrappedIsData') and 0<payload.stat().st_size<=8*1024*1024 and good:
        source=a.package/'Sources/CPlayerBridge/CPlayerBridge.m';before=source.read_text()
        needle='id raw = [art valueForKey:@"rawData"];'
        assert before.count(needle)==1
        replacement=needle+'\n                            if ([raw isKindOfClass:SBObject.class]) raw = [raw get];\n                            if ([raw isKindOfClass:NSAppleEventDescriptor.class]) raw = [(NSAppleEventDescriptor *)raw data];'
        after=before.replace(needle,replacement);source.write_text(after)
        patch=''.join(difflib.unified_diff(before.splitlines(True),after.splitlines(True),fromfile='baseline/CPlayerBridge.m',tofile='candidate/CPlayerBridge.m'))
        (a.evidence/'unreleased-artwork-candidate.patch').write_text(patch)
        result.update(status='APPLIED_UNRELEASED_CANDIDATE',actualImageSHA256=hashlib.sha256(payload.read_bytes()).hexdigest(),actualImageProbe=streams,
                      safeguards=['actual source descriptor only','same track identity guards unchanged','original 8 MiB guard unchanged','no fallback image','isolated camera source only'])
(a.evidence/'artwork-candidate-decision.json').write_text(json.dumps(result,indent=2)+'\n')
print(json.dumps(result))
