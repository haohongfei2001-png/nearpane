#!/usr/bin/env python3
"""Crop actual macOS WindowServer video into lossless native panel plates.

The alpha matte comes from a production SwiftUI still of the identical logical
208 x 192 view. No glyphs, controls, animation, or pointer paths are generated.
Keep the complete original recording and its capture manifest with these frames.
"""
import argparse, hashlib, json, subprocess
from pathlib import Path
from PIL import Image

def digest(path):
    h=hashlib.sha256()
    with path.open('rb') as f:
        for chunk in iter(lambda:f.read(1024*1024),b''): h.update(chunk)
    return h.hexdigest()

def main():
    p=argparse.ArgumentParser()
    p.add_argument('--source',type=Path,required=True)
    p.add_argument('--output',type=Path,required=True)
    p.add_argument('--mask',type=Path,required=True)
    p.add_argument('--crop',nargs=4,type=int,metavar=('X','Y','W','H'),required=True)
    p.add_argument('--start',type=float,default=0)
    p.add_argument('--duration',type=float,required=True)
    p.add_argument('--fps',type=int,default=30)
    p.add_argument('--capture-manifest',type=Path)
    p.add_argument('--cursor-included',action='store_true')
    a=p.parse_args();x,y,w,h=a.crop
    if abs(w/h-208/192)>.005: raise ValueError('Crop must preserve the native 208:192 geometry.')
    a.output.mkdir(parents=True,exist_ok=True)
    if any(a.output.glob('frame-*.png')): raise ValueError('Output already contains frames; choose a fresh directory.')
    meta=json.loads(subprocess.check_output(['ffprobe','-v','error','-show_streams','-show_format','-of','json',str(a.source)]))
    stream=next(s for s in meta['streams'] if s['codec_type']=='video')
    if x<0 or y<0 or x+w>stream['width'] or y+h>stream['height']: raise ValueError('Crop is outside the recorded display.')
    subprocess.run(['ffmpeg','-v','error','-ss',str(a.start),'-i',str(a.source),'-t',str(a.duration),
        '-vf',f'crop={w}:{h}:{x}:{y},fps={a.fps}','-start_number','0',str(a.output/'frame-%04d.png')],check=True)
    mask=Image.open(a.mask).convert('RGBA').getchannel('A').resize((w,h),Image.Resampling.LANCZOS)
    rows=[]
    for i,path in enumerate(sorted(a.output.glob('frame-*.png'))):
        im=Image.open(path).convert('RGBA');im.putalpha(mask);im.save(path,optimize=True)
        rows.append({'file':path.name,'elapsed':i/a.fps,'cursorIncluded':a.cursor_included})
    if len(rows)<max(1,round(a.duration*a.fps)-2): raise RuntimeError('Recording is shorter than the requested film passage.')
    report={'kind':'windowserver-native-continuous-video','sourceFile':a.source.name,'sourceSHA256':digest(a.source),
        'sourceVideo':{k:stream.get(k) for k in ['width','height','r_frame_rate','codec_name','color_space','color_transfer']},
        'sourceStartSeconds':a.start,'duration':len(rows)/a.fps,'fps':a.fps,
        'cropXYWH':a.crop,'logicalWidth':208,'logicalHeight':192,
        'alphaMatte':{'file':a.mask.name,'sha256':digest(a.mask),'origin':'Production SwiftUI view native screenshot'},
        'cursorIncluded':a.cursor_included,'frames':rows,
        'processing':'Spatial crop, frame sampling at original speed, original-native alpha matte; no animation or UI redraw.'}
    if a.capture_manifest:
        report['captureManifest']={'file':a.capture_manifest.name,'sha256':digest(a.capture_manifest)}
    (a.output/'capture.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
    print(json.dumps({'output':str(a.output),'frames':len(rows),'size':[w,h]},ensure_ascii=False))

if __name__=='__main__': main()
