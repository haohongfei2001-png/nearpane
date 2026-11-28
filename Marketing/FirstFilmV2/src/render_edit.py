#!/usr/bin/env python3
"""Edit real desktop footage with an explicit, auditable source timeline.

There are no UI substitutes, invented pointers, synthetic lyric animations,
optical-flow frames, or automatic timeline padding. Every source in/out must
exist. A separate audio event map reproduces actual play, pause and seek.
"""
from __future__ import annotations
import argparse, json, subprocess, hashlib
from pathlib import Path

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
    for i,s in enumerate(scenes):
        src=source_path(s['file'],base)
        meta=probe(src);duration=float(meta['format']['duration'])
        start=float(s.get('in',0));length=float(s['duration'])
        if start<0 or length<=0 or start+length>duration+.04:
            raise ValueError(f'Source interval exceeds recorded footage: {src} {start}+{length}>{duration}')
        inputs+=['-ss',f'{start:.9f}','-t',f'{length:.9f}','-i',str(src)]
        framing=''
        if s.get('crop'):
            x,y,w,h=s['crop']; native=next(v for v in meta['streams'] if v['codec_type']=='video')
            if min(x,y)<0 or min(w,h)<=0 or x+w>native['width'] or y+h>native['height']:
                raise ValueError('Editorial crop outside real source')
            framing=f'crop={w}:{h}:{x}:{y},'
            box=s.get('inset_width',.88)
            target_w=round(width*box/2)*2; target_h=round(target_w*h/w/2)*2
            if target_h>height*.88: raise ValueError('Inset must preserve native aspect ratio and safe margins')
            framing+=f'scale={target_w}:{target_h}:flags=lanczos,pad={width}:{height}:(ow-iw)/2:(oh-ih)/2:color=0xf6f6f2,'
        else:
            framing=f'scale={width}:{height}:flags=lanczos,'
        filters.append(f'[{i}:v]trim=duration={length:.9f},setpts=PTS-STARTPTS,fps={FPS},{framing}setsar=1,format=yuv420p[v{i}]')
        clips.append(f'[v{i}]')
        scene_audit.append({'file':str(src),'in':start,'duration':length,'timeline_in':offset,'crop':s.get('crop'),'provenance':s.get('provenance','unreviewed')})
        offset+=length
    filters.append(''.join(clips)+f'concat=n={len(clips)}:v=1:a=0,fps={FPS},settb=1/{FPS}[desktop]')
    current='desktop';idx=len(scenes)
    for n,c in enumerate(cfg.get('captions',[])):
        from brand_frames import caption
        image=out.parent/f'.caption-{lang}-{width}-{c["key"]}.png'
        caption(width,height,lang,c['key']).save(image)
        inputs+=['-loop','1','-framerate',str(FPS),'-i',str(image)]
        start,end=float(c['start']),float(c['end'])
        if end>offset or end<=start: raise ValueError('Caption interval invalid')
        filters.append(f'[{idx}:v]format=rgba,fade=t=in:st={start}:d=0.35:alpha=1,fade=t=out:st={end-.35}:d=0.35:alpha=1[label{n}]')
        filters.append(f'[{current}][label{n}]overlay=0:0:enable=\'between(t,{start},{end})\':shortest=1[captioned{n}]')
        current=f'captioned{n}';idx+=1
    end_duration=float(cfg.get('end_duration',0))
    total=offset+end_duration
    if end_duration:
        from brand_frames import end_frame
        image=out.parent/f'.end-{lang}-{width}x{height}.png'
        end_frame(width,height,lang).save(image)
        inputs+=['-loop','1','-framerate',str(FPS),'-t',str(end_duration+.6),'-i',str(image)]
        filters.append(f'[{idx}:v]format=yuv420p,setsar=1,settb=1/{FPS}[endcard]')
        # A restrained fade carries the final desktop into the paper end card.
        filters.append(f'[{current}][endcard]xfade=transition=fade:duration=0.6:offset={offset-.6:.9f},trim=duration={total:.9f}[picture]')
        current='picture';idx+=1
    audio=source_path(cfg['audio']['file'],base)
    audio_duration=float(probe(audio)['format']['duration'])
    if audio_duration+1/FPS<total: raise ValueError('Soundtrack shorter than edit; no unannounced silence padding')
    inputs+=['-i',str(audio)]
    filters.append(f'[{idx}:a]atrim=duration={total:.9f},asetpts=PTS-STARTPTS,aresample=48000[sound]')
    cmd=['ffmpeg','-hide_banner','-loglevel','warning','-y',*inputs,'-filter_complex_threads','1','-filter_complex',';'.join(filters),
         '-map',f'[{current}]','-map','[sound]','-t',f'{total:.9f}','-r',str(FPS),'-c:v','libx264','-preset','medium','-crf',str(crf),
         '-pix_fmt','yuv420p','-color_range','tv','-colorspace','bt709','-color_primaries','bt709','-color_trc','bt709',
         '-bsf:v','h264_metadata=colour_primaries=1:transfer_characteristics=1:matrix_coefficients=1:video_full_range_flag=0',
         '-c:a','aac','-b:a','320k','-ar','48000','-movflags','+faststart+write_colr','-metadata','title=Nearpane — Keep the music close',str(working)]
    run(cmd)
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
