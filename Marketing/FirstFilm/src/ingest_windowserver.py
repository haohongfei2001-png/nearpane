#!/usr/bin/env python3
"""Crop actual macOS WindowServer video into lossless native panel plates.

The alpha matte comes from a production SwiftUI still of the identical logical
208 x 192 view. No glyphs, controls, animation, or pointer paths are generated.
Keep the complete original recording and its capture manifest with these frames.
"""
import argparse, bisect, hashlib, json, subprocess
from pathlib import Path
from PIL import Image, ImageStat

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
    source_duration=float(stream.get('duration',meta['format'].get('duration',0)))
    if a.start+a.duration>source_duration+.05:
        raise ValueError('Requested passage exceeds the recorded source duration.')
    subprocess.run(['ffmpeg','-v','error','-ss',str(a.start),'-i',str(a.source),'-t',str(a.duration),
        '-vf',f'crop={w}:{h}:{x}:{y},fps={a.fps},tpad=stop_mode=clone:stop_duration={a.duration}','-start_number','0',str(a.output/'frame-%04d.png')],check=True)
    mask=Image.open(a.mask).convert('RGBA').getchannel('A').resize((w,h),Image.Resampling.LANCZOS)
    capture=json.loads(a.capture_manifest.read_text()) if a.capture_manifest else {}
    states=capture.get('states',[]);state_times=[s.get('elapsed',0) for s in states]
    paths=sorted(a.output.glob('frame-*.png'))
    details=[]
    for path in paths:
        im=Image.open(path)
        details.append(ImageStat.Stat(im.crop((round(w*.1),round(h*.1),round(w*.9),round(h*.9))).convert('L')).stddev[0])
    last_visible=max((i for i,v in enumerate(details) if v>.6),default=-1)
    if last_visible<0: raise RuntimeError('Source passage contains no visible native interface.')
    rows=[];seen={}
    for i,path in enumerate(paths):
        im=Image.open(path).convert('RGBA')
        # When the real OS window withdraws, the recorded neutral backdrop remains.
        # Removing those empty pixels avoids inventing a blank lyric card afterward.
        # A native cue transition can briefly contain no text. Only the sustained
        # final empty run is withdrawal; never erase a transient blank panel.
        visible=i<=last_visible
        im.putalpha(mask if visible else Image.new('L',(w,h),0))
        pixels=hashlib.sha256(im.tobytes()).hexdigest()
        if pixels in seen:
            path.unlink();name=seen[pixels]
        else:
            im.save(path,compress_level=6);name=path.name;seen[pixels]=name
        row={'file':name,'elapsed':i/a.fps,'cursorIncluded':a.cursor_included,'windowVisible':visible}
        if states:
            state=states[max(0,bisect.bisect_right(state_times,a.start+i/a.fps)-1)]
            row['sourceState']={k:state[k] for k in ['windowVisible','controlsVisible','positionMS','playbackState','currentCueIndex'] if k in state}
        rows.append(row)
    if len(rows)<max(1,round(a.duration*a.fps)-2): raise RuntimeError('Recording is shorter than the requested film passage.')
    report={'kind':'windowserver-native-continuous-video','sourceFile':a.source.name,'sourceSHA256':digest(a.source),
        'sourceVideo':{k:stream.get(k) for k in ['width','height','r_frame_rate','codec_name','color_space','color_transfer']},
        'sourceStartSeconds':a.start,'duration':len(rows)/a.fps,'fps':a.fps,
        'sourceContainerDuration':source_duration,
        'tailSampling':'The final recorded frame is held through the requested end, which cannot exceed the original recorded stream duration. No new intermediate motion is generated.',
        'cropXYWH':a.crop,'logicalWidth':208,'logicalHeight':192,
        'alphaMatte':{'file':a.mask.name,'sha256':digest(a.mask),'origin':'Production SwiftUI view native screenshot'},
        'cursorIncluded':a.cursor_included,'uniquePixelFrames':len(seen),'frames':rows,
        'processing':'Spatial crop, sampling at original speed, native alpha matte. Only the sustained final uniform run after actual window withdrawal becomes transparent. Earlier blank native cue-transition frames retain their panel. No animation or UI redraw.',
        'stateTimingNote':'Runtime state samples are approximate companions to the video; recorded pixels, not those samples, determine visible content.'}
    if a.capture_manifest:
        report['captureManifest']={'file':a.capture_manifest.name,'sha256':digest(a.capture_manifest)}
    (a.output/'capture.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
    print(json.dumps({'output':str(a.output),'frames':len(rows),'uniquePixelFrames':len(seen),'size':[w,h]},ensure_ascii=False))

if __name__=='__main__': main()
