#!/usr/bin/env python3
"""Edit real desktop footage with an explicit, auditable source timeline.

There are no UI substitutes, invented pointers, synthetic lyric animations,
optical-flow frames, or automatic timeline padding. Every source in/out must
exist. A separate audio event map reproduces actual play, pause and seek.
"""
from __future__ import annotations
import argparse, json, subprocess, hashlib
from pathlib import Path
from render_stage import cache_path, encode_scene, concat_input

ROOT=Path(__file__).resolve().parents[1]
FPS=30

def probe(path):
    return json.loads(subprocess.run(['ffprobe','-v','error','-show_format','-show_streams','-of','json',str(path)],check=True,capture_output=True,text=True).stdout)

def run(cmd):
    print('Rendering:', Path(cmd[-1]).name, flush=True)
    subprocess.run(cmd,check=True)

def source_path(value,base):
    path=Path(value)
    return path if path.is_absolute() else (base/path).resolve()

def bounded_inputs(arguments):
    """Keep simultaneous 4K decoders from allocating a CPU-sized frame pool each."""
    result=[]
    for argument in arguments:
        if argument=='-i':result.extend(['-threads','1'])
        result.append(argument)
    return result

def render(config,out,width,height,lang,crf=18):
    if abs(width/height-16/9)>.001:
        raise ValueError('This renderer preserves the 16:9 desktop. Use a separately composed portrait edit; do not stretch native UI.')
    base=config.parent
    cfg=json.loads(config.read_text())
    out=out.resolve();out.parent.mkdir(parents=True,exist_ok=True)
    working=out.with_name(out.stem+'.rendering.mp4')
    scenes=cfg['scenes']
    if not scenes: raise ValueError('Real captured scenes required')
    inputs=[];filters=[];clips=[];offset=0.;scene_audit=[]
    stage_dir=out.parent/'.scene-cache'
    renderer_hash=hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
    for i,s in enumerate(scenes):
        src=source_path(s['file'],base)
        meta=probe(src);duration=float(meta['format']['duration'])
        start=float(s.get('in',0));length=float(s['duration'])
        frame_count=round((offset+length)*FPS)-round(offset*FPS)
        if start<0 or length<=0 or start+length>duration+.04:
            raise ValueError(f'Source interval exceeds recorded footage: {src} {start}+{length}>{duration}')
        scene_inputs=['-ss',f'{start:.9f}','-t',f'{length:.9f}','-i',str(src)]
        framing=''
        if s.get('crop'):
            x,y,w,h=s['crop']; native=next(v for v in meta['streams'] if v['codec_type']=='video')
            if min(x,y)<0 or min(w,h)<=0 or x+w>native['width'] or y+h>native['height']:
                raise ValueError('Editorial crop outside real source')
            framing=f'crop={w}:{h}:{x}:{y},'
            if s.get('crop_fill',False):
                if abs(w/h-width/height)>.002:raise ValueError('Full-frame crop must preserve aspect ratio')
                framing+=f'scale={width}:{height}:flags=lanczos,'
            else:
                box=s.get('inset_width',.88)
                target_w=round(width*box/2)*2; target_h=round(target_w*h/w/2)*2
                if target_h>height*.88: raise ValueError('Inset must preserve native aspect ratio and safe margins')
                framing+=f'scale={target_w}:{target_h}:flags=lanczos,pad={width}:{height}:(ow-iw)/2:(oh-ih)/2:color=0xf6f6f2,'
        else:
            framing=f'scale={width}:{height}:flags=lanczos,'
        # ScreenCaptureKit is VFR. Its last packet may carry a long hold even
        # after trim(duration); clamp the conformed frames as well, or that hold
        # can silently delay every following shot.
        scene_filter=f'[0:v]trim=duration={length:.9f},setpts=PTS-STARTPTS,fps={FPS},trim=end_frame={frame_count},setpts=N/({FPS}*TB),{framing}setsar=1,format=yuv420p[scene]'
        staged=cache_path(stage_dir,{'renderer':renderer_hash,'scene':s,'source':str(src),'source_mtime':src.stat().st_mtime_ns,'canvas':[width,height],'frames':frame_count})
        print(f'Preparing native scene {i+1}/{len(scenes)} at {width}×{height}',flush=True)
        encode_scene(staged,scene_inputs,[scene_filter],'scene',frame_count)
        clips.append(staged)
        scene_audit.append({'file':str(src),'in':start,'duration':length,'timeline_in':offset,'conformed_frames':frame_count,'crop':s.get('crop'),'provenance':s.get('provenance','unreviewed')})
        offset+=length
    from finish_landscape import finish
    audio=source_path(cfg['audio']['file'],base)
    total=offset+float(cfg.get('end_duration',0))
    if float(probe(audio)['format']['duration'])+1/FPS<total:
        raise ValueError('Soundtrack shorter than edit')
    finish(clips,scene_audit,cfg,base,working,width,height,lang,crf)
    actual=probe(working)
    if abs(float(actual['format']['duration'])-total)>1/FPS+.02:
        raise ValueError('Rendered length disagrees with declared edit')
    working.replace(out)
    receipt={'output':str(out),'duration':total,'canvas':[width,height],'language':lang,'scenes':scene_audit,
             'audio':cfg['audio'],'sha256':hashlib.sha256(out.read_bytes()).hexdigest(),
             'source_integrity':'All source intervals checked; original-speed video; no frame interpolation.',
             'release_stage':'product preview; integrated public download not verified'}
    out.with_suffix('.json').write_text(json.dumps(receipt,ensure_ascii=False,indent=2)+'\n')
    print(out,flush=True)

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('config',type=Path);p.add_argument('--out',type=Path,required=True)
    p.add_argument('--width',type=int,default=1920);p.add_argument('--height',type=int,default=1080)
    p.add_argument('--lang',choices=['zh','en'],default='zh');p.add_argument('--crf',type=int,default=18)
    a=p.parse_args();render(a.config,a.out,a.width,a.height,a.lang,a.crf)
