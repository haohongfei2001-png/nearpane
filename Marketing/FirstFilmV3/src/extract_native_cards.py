#!/usr/bin/env python3
"""Matte actual filmed cards without changing their content or proportions.

Both layout changes are instantaneous in the native recording. The state probe
reads an observed gap pixel row, so masks switch on the exact decoded frame,
including after VFR-to-CFR conformance. It never invents an in-between state.
"""
import argparse,hashlib,json,subprocess
from functools import lru_cache
from pathlib import Path
import numpy as np
from PIL import Image,ImageDraw,ImageFilter

ROOT=Path(__file__).resolve().parents[1]
WIDTH,HEIGHT,PAD=560,942,48
OUT_W,OUT_H=WIDTH+PAD*2,HEIGHT+PAD*2
FPS=30

@lru_cache(maxsize=4)
def layers(mode,state):
    if mode=='order':
        # Actual AX bounds, checked against encoded native frames.
        rects=[(0,517),(549,205)] if state==0 else [(0,205),(237,517)]
    else:
        rects=[(0,205)] if state==0 else [(1,388)]
    mask=Image.new('L',(OUT_W*4,OUT_H*4),0);d=ImageDraw.Draw(mask)
    for y,h in rects:
        d.rounded_rectangle((PAD*4,(PAD+y)*4,(PAD+WIDTH)*4-1,(PAD+y+h)*4-1),radius=48.461538*4,fill=255)
    mask=mask.resize((OUT_W,OUT_H),Image.Resampling.LANCZOS)
    shadow=Image.new('L',(OUT_W,OUT_H),0)
    shadow.paste(mask,(0,7));shadow=shadow.filter(ImageFilter.GaussianBlur(13)).point(lambda v:round(v*.14))
    layer=Image.new('RGBA',(OUT_W,OUT_H),(27,43,40,0));layer.putalpha(shadow)
    return mask,layer,rects

def main():
    p=argparse.ArgumentParser();p.add_argument('--mode',choices=['order','capture'],required=True)
    p.add_argument('--start',type=float,required=True);p.add_argument('--duration',type=float,required=True)
    p.add_argument('--out',type=Path,required=True);a=p.parse_args()
    source=ROOT/'assets/native/dual/host-fullscreen.mov';frames=round(a.duration*FPS)
    a.out.parent.mkdir(parents=True,exist_ok=True)
    start_frame=round(a.start*FPS)
    # Conform from the source origin BEFORE trimming. Otherwise a VFR hold
    # immediately after the in-point can disappear when STARTPTS is reset.
    decoder=subprocess.Popen(['ffmpeg','-v','error','-threads','1','-i',str(source),
       '-vf',f'fps=30:start_time=0,trim=start_frame={start_frame}:end_frame={start_frame+frames},setpts=N/(30*TB),crop={WIDTH}:{HEIGHT}:3224:104',
       '-r','30','-f','rawvideo','-pix_fmt','rgb24','pipe:1'],stdout=subprocess.PIPE)
    encoder=subprocess.Popen(['ffmpeg','-v','error','-y','-f','rawvideo','-pixel_format','rgba','-video_size',f'{OUT_W}x{OUT_H}',
       '-framerate','30','-i','pipe:0','-an','-c:v','qtrle','-pix_fmt','argb','-threads','2',str(a.out)],stdin=subprocess.PIPE)
    state_history=[];last_state=None
    try:
        for index in range(frames):
            data=decoder.stdout.read(WIDTH*HEIGHT*3)
            if len(data)!=WIDTH*HEIGHT*3:raise ValueError(f'Native source ended at frame {index}, expected {frames}')
            pix=np.frombuffer(data,np.uint8).reshape(HEIGHT,WIDTH,3)
            # Global y327 is white lyric body before reorder, real wallpaper
            # after reorder, and real tray body after expansion. Native measured
            # green medians: 245 / 166–176 / 230; threshold210 is well separated.
            median=float(np.median(pix[223,56:506,1]))
            state=int(median<210) if a.mode=='order' else int(median>210)
            mask,shadow,rects=layers(a.mode,state)
            native=Image.new('RGBA',(OUT_W,OUT_H),(0,0,0,0))
            native.paste(Image.fromarray(pix),(PAD,PAD));native.putalpha(mask)
            result=shadow.copy();result.alpha_composite(native)
            encoder.stdin.write(result.tobytes())
            if state!=last_state:
                state_history.append({'output_frame':index,'output_seconds':index/FPS,'state':state,
                   'observed_green_median':median,'rects_relative_to_movie_3224_104':rects})
                last_state=state
    finally:
        decoder.stdout.close();encoder.stdin.close()
    if decoder.wait()!=0 or encoder.wait()!=0:raise RuntimeError('Native matte rendering failed')
    record={'mode':a.mode,'source':'assets/native/dual/host-fullscreen.mov','source_sha256':hashlib.sha256(source.read_bytes()).hexdigest(),
      'source_start':a.start,'conformed_source_start':start_frame/FPS,'source_duration':a.duration,'frames':frames,'fps':30,'pixel_scale':1,
      'place_output_at_movie_xy':[3224-PAD,104-PAD],'crop_origin':[3224,104],'actual_native_rounding_radius':48.461538,
      'state_changes':state_history,'product_pixels_redrawn':False,'motion_interpolation':False,
      'mask_authority':'Production AX geometry plus actual native frame changes; frame state is measured from pixels.',
      'editorial_only':'Transparent outer mask and soft paper-composition shadow; card content unchanged.',
      'output_sha256':hashlib.sha256(a.out.read_bytes()).hexdigest()}
    a.out.with_suffix('.json').write_text(json.dumps(record,ensure_ascii=False,indent=2)+'\n')
    print(json.dumps({'output':str(a.out),'states':state_history},ensure_ascii=False),flush=True)

if __name__=='__main__':main()
