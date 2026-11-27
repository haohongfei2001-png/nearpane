#!/usr/bin/env python3
"""Create a curated media companion without duplicating the Git source project."""
import argparse, hashlib, json, zipfile
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]
def sha(p):
    h=hashlib.sha256()
    with p.open('rb') as f:
        for b in iter(lambda:f.read(1024*1024),b''): h.update(b)
    return h.hexdigest()

def main():
    p=argparse.ArgumentParser();p.add_argument('--output',type=Path,required=True);a=p.parse_args()
    folders=['assets/backgrounds','assets/fonts','assets/audio','assets/riftlet',
        'assets/native/authored-native','assets/native/evidence-run5','assets/native/windowserver-source',
        'assets/native/windowserver-lyrics-zh','assets/native/windowserver-lyrics-en',
        'assets/native/windowserver-controls-zh','assets/native/windowserver-controls-en']
    files=[]
    for folder in folders:
        base=ROOT/folder
        if not base.is_dir(): raise FileNotFoundError(f'Required media folder absent: {folder}')
        files += [p for p in base.rglob('*') if p.is_file()]
    files += [p for p in (ROOT/'assets/workspace').glob('textedit-*-*') if p.is_file()]
    for n in ['CC-BY-4.0.txt','Inter-LICENSE.txt','NotoSansCJK-LICENSE.txt','MUSIC_CREDITS.txt','sources.json','README.txt']:
        files.append(ROOT/'licenses'/n)
    files.append(ROOT/'docs/PUBLISHING-CREDITS.txt')
    files=sorted(set(files));a.output.parent.mkdir(exist_ok=True,parents=True)
    index=[]
    with zipfile.ZipFile(a.output,'w',zipfile.ZIP_DEFLATED,compresslevel=5) as z:
        for i,path in enumerate(files):
            rel=str(path.relative_to(ROOT));z.write(path,rel)
            index.append({'path':rel,'bytes':path.stat().st_size,'sha256':sha(path)})
            if i%300==0: print(json.dumps({'packaged':i,'total':len(files)}),flush=True)
        z.writestr('MEDIA-INDEX.json',json.dumps(index,ensure_ascii=False,indent=2)+'\n')
        z.writestr('ASSETS-README.txt',
          'NEARPANE / KEEP THE MUSIC CLOSE — MEDIA COMPANION\n\n'
          'Extract this archive into Marketing/FirstFilm on branch\n'
          'creative/nearpane-first-film-20261128 of\n'
          'https://github.com/haohongfei2001-png/nearpane\n\n'
          'Editable capture/compositing code, brand system, timing and acceptance\n'
          'records are in that Git branch. This archive contains the selected raw\n'
          'and processed media needed by that code. It does not contain code or\n'
          'third-party reference films. Match files against MEDIA-INDEX.json.\n\n'
          'Stage: PRODUCT PREVIEW. No integrated Nearpane download is asserted.\n'
          'Native source passages are real WindowServer captures of the production\n'
          'SwiftUI view in a documented photography window. Wallpaper, desktop\n'
          'placement, camera and editorial fades are postproduction.\n\n'
          'Original demo lyrics are not lyrics to the instrumental soundtrack.\n'
          'Read licenses/ and docs/PUBLISHING-CREDITS.txt before publication.\n'
          'The full original music is a production source, not a standalone music\n'
          'release. Do not register the soundtrack with Content ID.\n')
    result={'file':a.output.name,'bytes':a.output.stat().st_size,'sha256':sha(a.output),'entries':len(files)+2}
    a.output.with_suffix('.manifest.json').write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps(result),flush=True)

if __name__=='__main__': main()
