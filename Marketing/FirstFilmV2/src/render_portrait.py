#!/usr/bin/env python3
"""9:16 editorial layout made exclusively from synchronized native crops.

This is an explicitly recomposed mobile film, not a claimed portrait macOS
desktop. UI pixels, cursor motion, lyrics, artwork and timing stay captured.
"""
import argparse, json, hashlib, subprocess
from pathlib import Path
from PIL import Image, ImageDraw, ImageFilter
from brand_frames import PAPER,INK,MUTED,put,end_frame
from render_edit import probe, source_path

W,H,FPS=1080,1920,30

def mask(path,w,h,r):
    im=Image.new('L',(w*3,h*3),0)
    ImageDraw.Draw(im).rounded_rectangle((0,0,w*3-1,h*3-1),r*3,fill=255)
    im.resize((w,h),Image.Resampling.LANCZOS).save(path)

def plate(path,parts,lang):
    im=Image.new('RGBA',(W,H),PAPER)
    put(im,'Nearpane',(66,91),49,weight=510,anchor='lm')
    put(im,'nearpane.com',(66,1815),22,MUTED,anchor='lm')
    put(im,'产品预览' if lang=='zh' else 'Product preview',(1014,1815),17,MUTED,anchor='rm')
    for p in parts:
        x,y,w,h=p['dest'];radius=p['radius'];pad=50
        a=Image.new('L',(w+pad*2,h+pad*2),0)
        ImageDraw.Draw(a).rounded_rectangle((pad,pad+10,pad+w-1,pad+h+9),radius,fill=30)
        a=a.filter(ImageFilter.GaussianBlur(18))
        sh=Image.new('RGBA',a.size,(27,43,40,0));sh.putalpha(a)
        im.alpha_composite(sh,(x-pad,y-pad))
    im.save(path)

LINES={
 'zh':{'opening':['让音乐，','留在手边。'],'continuity':['换个窗口，','歌还在。'],'sources':['在你习惯的','播放器里。'],'modules':['把需要的，','放在一起。']},
 'en':{'opening':['Keep the','music close.'],'continuity':['Your window','changes.','The music stays.'],'sources':['With the player','you already','love.'],'modules':['Your essentials,','together.']}}

def title(path,lang,key):
    im=Image.new('RGBA',(W,H),(0,0,0,0))
    for n,line in enumerate(LINES[lang][key]):
        put(im,line,(66,259+n*59),40 if lang=='en' else 44,INK,anchor='lm')
    im.save(path)

def render(config,out,lang):
    cfg=json.loads(config.read_text());base=config.parent
    out=out.resolve();out.parent.mkdir(parents=True,exist_ok=True)
    temp=out.parent/'.portrait-assets';temp.mkdir(exist_ok=True)
    inputs=[];filters=[];idx=0;segments=[];timeline=0.;audit=[]
    def add(args):
        nonlocal idx
        inputs.extend(args);value=idx;idx+=1;return value
    for k,s in enumerate(cfg['scenes']):
        src=source_path(s['file'],base);meta=probe(src)
        dur=float(s['duration']);start=float(s.get('in',0))
        if start<0 or dur<=0 or start+dur>float(meta['format']['duration'])+.04:raise ValueError('Invalid native source interval')
        pv=s.get('portrait',{})
        dual=bool(pv.get('dual',False))
        work=pv.get('work_crop',[240,224,2704,1676])
        work_w=948;work_h=round(work[3]*work_w/work[2]/2)*2
        work_y=int(pv.get('work_y',1114 if dual else 846))
        if work_y+work_h>1745:raise ValueError('Portrait workspace exceeds safe composition')
        parts=[{'crop':work,'dest':[66,work_y,work_w,work_h],'radius':18}]
        for j,c in enumerate(pv.get('card_crops',[[3224,104,560,518]])):
            cw=420;ch=round(c[3]*cw/c[2]/2)*2
            parts.append({'crop':c,'dest':[594,180+j*416,cw,ch],'radius':38})
        v=add(['-ss',f'{start:.9f}','-t',f'{dur:.9f}','-i',str(src)])
        native=next(q for q in meta['streams'] if q['codec_type']=='video')
        for p in parts:
            x,y,w,h=p['crop']
            if min(x,y)<0 or min(w,h)<=0 or x+w>native['width'] or y+h>native['height']:raise ValueError('Crop outside native capture')
        plate_file=temp/f'plate-{lang}-{k}.png';plate(plate_file,parts,lang)
        b=add(['-loop','1','-framerate',str(FPS),'-t',str(dur),'-i',str(plate_file)])
        filters.append(f'[{v}:v]trim=duration={dur:.9f},setpts=PTS-STARTPTS,fps={FPS},split={len(parts)}'+''.join(f'[s{k}p{j}]' for j in range(len(parts))))
        filters.append(f'[{b}:v]format=rgba,setpts=PTS-STARTPTS[base{k}]')
        current=f'base{k}'
        for j,p in enumerate(parts):
            x,y,w,h=p['crop'];dx,dy,dw,dh=p['dest']
            m=temp/f'mask-{dw}-{dh}-{p["radius"]}.png'
            if not m.exists():mask(m,dw,dh,p['radius'])
            mi=add(['-loop','1','-framerate',str(FPS),'-t',str(dur),'-i',str(m)])
            filters.append(f'[s{k}p{j}]crop={w}:{h}:{x}:{y},scale={dw}:{dh}:flags=lanczos,setsar=1,format=rgb24[pix{k}_{j}]')
            filters.append(f'[{mi}:v]format=gray[mask{k}_{j}]')
            filters.append(f'[pix{k}_{j}][mask{k}_{j}]alphamerge[alpha{k}_{j}]')
            next_name=f'piece{k}_{j}'
            filters.append(f'[{current}][alpha{k}_{j}]overlay={dx}:{dy}:shortest=1[{next_name}]');current=next_name
        filters.append(f'[{current}]trim=duration={dur:.9f},setpts=PTS-STARTPTS,format=yuv420p,setsar=1[scene{k}]')
        segments.append(f'[scene{k}]')
        audit.append({'source':str(src),'in':start,'duration':dur,'timeline_in':timeline,'native_crops':parts})
        timeline+=dur
    filters.append(''.join(segments)+f'concat=n={len(segments)}:v=1:a=0,fps={FPS},settb=1/{FPS}[mobile]')
    current='mobile'
    for k,c in enumerate(cfg.get('captions',[])):
        path=temp/f'title-{lang}-{c["key"]}.png';title(path,lang,c['key'])
        ci=add(['-loop','1','-framerate',str(FPS),'-i',str(path)])
        a,z=float(c['start']),float(c['end'])
        filters.append(f'[{ci}:v]format=rgba,fade=t=in:st={a}:d=0.35:alpha=1,fade=t=out:st={z-.35}:d=0.35:alpha=1[title{k}]')
        filters.append(f'[{current}][title{k}]overlay=0:0:enable=\'between(t,{a},{z})\':shortest=1[titled{k}]');current=f'titled{k}'
    tail=float(cfg.get('end_duration',0));total=timeline+tail
    if tail:
        ef=temp/f'end-{lang}.png';end_frame(W,H,lang).save(ef)
        ei=add(['-loop','1','-framerate',str(FPS),'-t',str(tail+.6),'-i',str(ef)])
        filters.append(f'[{ei}:v]format=yuv420p,setsar=1,settb=1/{FPS}[endcard]')
        filters.append(f'[{current}][endcard]xfade=transition=fade:duration=0.6:offset={timeline-.6:.9f},trim=duration={total:.9f}[final]');current='final'
    audio=source_path(cfg['audio']['file'],base)
    if float(probe(audio)['format']['duration'])+1/FPS<total:raise ValueError('Music shorter than edit')
    ai=add(['-i',str(audio)])
    filters.append(f'[{ai}:a]atrim=duration={total:.9f},asetpts=PTS-STARTPTS,aresample=48000[sound]')
    working=out.with_name(out.stem+'.rendering.mp4')
    cmd=['ffmpeg','-hide_banner','-loglevel','warning','-y',*inputs,'-filter_complex_threads','1','-filter_complex',';'.join(filters),
         '-map',f'[{current}]','-map','[sound]','-t',f'{total:.9f}','-r','30','-c:v','libx264','-preset','medium','-crf','18','-pix_fmt','yuv420p',
         '-color_range','tv','-colorspace','bt709','-color_primaries','bt709','-color_trc','bt709',
         '-bsf:v','h264_metadata=colour_primaries=1:transfer_characteristics=1:matrix_coefficients=1:video_full_range_flag=0',
         '-c:a','aac','-b:a','320k','-ar','48000','-movflags','+faststart+write_colr',str(working)]
    print('Rendering',out.name,flush=True);subprocess.run(cmd,check=True)
    if abs(float(probe(working)['format']['duration'])-total)>1/FPS+.02:raise ValueError('Duration mismatch')
    working.replace(out)
    out.with_suffix('.json').write_text(json.dumps({'output':str(out),'canvas':[W,H],'duration':total,'language':lang,
       'layout':'Independent editorial placement of actual native app/card crops; not a portrait macOS desktop.',
       'no_ui_reconstruction':True,'no_frame_interpolation':True,'scenes':audit,'audio':cfg['audio'],
       'sha256':hashlib.sha256(out.read_bytes()).hexdigest()},ensure_ascii=False,indent=2)+'\n')
    print(out)

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('config',type=Path);p.add_argument('--out',type=Path,required=True);p.add_argument('--lang',choices=['zh','en'],default='zh')
    a=p.parse_args();render(a.config,a.out,a.lang)
