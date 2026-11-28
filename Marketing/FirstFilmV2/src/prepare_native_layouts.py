#!/usr/bin/env python3
"""Two editorial detail shots, using actual native pixels at actual speed.

The management rows and cards are cropped from the SAME frame/time. The final
Riftlet detail uses its real recorded thumbnail plus the actually acquired file.
Neither composition is represented as an uncropped desktop screenshot.
"""
import json, subprocess, hashlib
from pathlib import Path
from PIL import Image,ImageDraw,ImageFilter
from render_portrait import mask
from brand_frames import PAPER
from render_edit import bounded_inputs

ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'assets/processed';OUT.mkdir(parents=True,exist_ok=True)
TEMP=OUT/'layout-mattes';TEMP.mkdir(exist_ok=True)

def prepare(name,start,duration,parts,photo=None):
    source=ROOT/'assets/native/dual/host-fullscreen.mov'
    im=Image.new('RGBA',(3840,2160),PAPER)
    if photo:
        path,rect=photo;x,y,w,h=rect
        p=Image.open(path).convert('RGBA').resize((w,h),Image.Resampling.LANCZOS)
        mm=Image.new('L',(w,h),0);ImageDraw.Draw(mm).rounded_rectangle((0,0,w-1,h-1),20,fill=255);p.putalpha(mm)
        im.alpha_composite(p,(x,y))
    for p in parts:
        if not p.get('shadow',True):continue
        x,y,w,h=p['dest'];pad=80
        a=Image.new('L',(w+pad*2,h+pad*2),0)
        ImageDraw.Draw(a).rounded_rectangle((pad,pad+16,pad+w-1,pad+h+15),p['radius'],fill=36)
        a=a.filter(ImageFilter.GaussianBlur(24));sh=Image.new('RGBA',a.size,(27,43,40,0));sh.putalpha(a)
        im.alpha_composite(sh,(x-pad,y-pad))
    bg=TEMP/(name+'-plate.png');im.save(bg)
    inputs=['-ss',f'{start:.9f}','-t',f'{duration:.9f}','-i',str(source),'-loop','1','-framerate','30','-t',str(duration),'-i',str(bg)]
    frames=round(duration*30)
    filters=[f'[0:v]trim=duration={duration},setpts=PTS-STARTPTS,fps=30,trim=end_frame={frames},setpts=N/(30*TB),split={len(parts)}'+''.join(f'[p{j}]' for j in range(len(parts))), '[1:v]format=rgba[base]']
    current='base'
    for j,p in enumerate(parts):
        x,y,w,h=p['crop'];dx,dy,dw,dh=p['dest'];m=TEMP/f'mask-{dw}-{dh}-{p["radius"]}.png'
        if not m.exists():mask(m,dw,dh,p['radius'])
        mi=j+2;inputs+=['-loop','1','-framerate','30','-t',str(duration),'-i',str(m)]
        filters += [f'[p{j}]crop={w}:{h}:{x}:{y},scale={dw}:{dh}:flags=lanczos,format=rgb24[pix{j}]',f'[{mi}:v]format=gray[m{j}]',f'[pix{j}][m{j}]alphamerge[a{j}]']
        a=f'a{j}'
        if 'fade_out' in p:
            st,d=p['fade_out'];filters.append(f'[{a}]fade=t=out:st={st}:d={d}:alpha=1[faded{j}]');a=f'faded{j}'
        filters.append(f'[{current}][{a}]overlay={dx}:{dy}:format=rgb:shortest=1[c{j}]');current=f'c{j}'
    filters.append(f'[{current}]scale=out_color_matrix=bt709:out_range=tv,format=yuv444p,setsar=1[final]')
    out=OUT/(name+'.mkv')
    subprocess.run(['ffmpeg','-hide_banner','-loglevel','warning','-y',*bounded_inputs(inputs),'-filter_complex_threads','1','-filter_complex',';'.join(filters),'-map','[final]','-an','-frames:v',str(frames),'-c:v','libx264','-threads','4','-qp','0','-preset','veryfast','-pix_fmt','yuv444p','-color_range','tv','-colorspace','bt709','-color_primaries','bt709','-color_trc','bt709',str(out)],check=True)
    out.with_suffix('.json').write_text(json.dumps({'source':'assets/native/dual/host-fullscreen.mov','source_in':start,'source_duration':duration,'parts':parts,'actual_acquired_image':str(photo[0].relative_to(ROOT)) if photo else None,'same_source_time_for_all_native_parts':True,'product_pixels_generated':False,'source_speed':1,'output_sha256':hashlib.sha256(out.read_bytes()).hexdigest()},ensure_ascii=False,indent=2)+'\n')
    print(out,flush=True)

if __name__=='__main__':
    prepare('dual-order-detail-4k',2.4825827954,8.3674172046,[
      {'crop':[624,488,1950,368],'dest':[240,720,2640,498],'radius':22,'shadow':False,'fade_out':[6.0,.4]},
      {'crop':[3224,104,560,518],'dest':[3224,104,560,518],'radius':50},
      {'crop':[3224,653,560,518],'dest':[3224,653,560,518],'radius':50}])
    prepare('riftlet-result-detail-4k',21.5,1.5,[
      {'crop':[3224,104,560,518],'dest':[3224,104,560,518],'radius':50}],
      photo=(ROOT/'assets/native/dual/actual-captured-water.png',[240,420,2480,1128]))
