#!/usr/bin/env python3
"""Finish native scenes separately, then mux without recompressing the picture.

A short final-scene crossfade avoids retaining a whole4K film in a filter graph.
Scene boundaries use exact30fps counts and identical H.264 parameters.
"""
import hashlib,json,subprocess
from pathlib import Path
from brand_frames import caption,end_frame
from render_stage import cache_path,encode_scene,concat_input

FPS=30

def finish(clips,audit,cfg,base,out,width,height,lang,crf):
 from render_edit import bounded_inputs,source_path
 directory=out.parent/'.scene-cache'/'finished';directory.mkdir(parents=True,exist_ok=True)
 helper_hash=hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
 brand_hash=hashlib.sha256(Path(__file__).with_name('brand_frames.py').read_bytes()).hexdigest()
 prepared=[];time=0.;tail=float(cfg.get('end_duration',0))
 for i,(source,record) in enumerate(zip(clips,audit)):
  frames=record['conformed_frames'];seconds=frames/FPS
  ending=tail if i==len(clips)-1 else 0.
  caps=[c for c in cfg.get('captions',[]) if float(c['start'])<time+seconds and float(c['end'])>time]
  spec={'source':source.name,'frames':frames,'captions':caps,'caption_time_origin':time,'ending':ending,'language':lang,'crf':crf,'renderer':helper_hash,'brand':brand_hash}
  path=cache_path(directory,spec).with_suffix('.mp4');receipt=path.with_suffix('.json')
  expected=frames+round(ending*FPS)
  if path.exists() and receipt.exists() and json.loads(receipt.read_text()).get('frames')==expected:
   prepared.append(path);time+=seconds;continue
  print(f'Finishing {lang} scene {i+1}/{len(clips)} at {width}×{height}',flush=True)
  inputs=['-i',str(source)]
  filters=[f'[0:v]setpts=PTS-STARTPTS,fps={FPS},trim=end_frame={frames},settb=1/{FPS},setsar=1,format=yuv420p[base]']
  current='base';idx=1
  for j,c in enumerate(caps):
   a=float(c['start'])-time;z=float(c['end'])-time
   if a<-.001 or z>seconds+.001:raise ValueError('For bounded scene finishing, keep editorial caption fades within a scene')
   im=caption(width,height,lang,c['key'],paper=c.get('paper',False));b=im.getbbox()
   if not b:raise ValueError('Empty editorial caption')
   # Keep chroma alignment identical to the original full-canvas overlay.
   b=(b[0]//2*2,b[1]//2*2,(b[2]+1)//2*2,(b[3]+1)//2*2)
   image=directory/f'{path.stem}-label-{j}.png';im.crop(b).save(image)
   inputs+=['-loop','1','-framerate',str(FPS),'-t',str(seconds),'-i',str(image)]
   filters.append(f'[{idx}:v]format=rgba,fade=t=in:st={a:.9f}:d=0.35:alpha=1,fade=t=out:st={z-.35:.9f}:d=0.35:alpha=1,scale=out_color_matrix=bt709:out_range=tv,format=yuva420p[label{j}]')
   filters.append(f'[{current}][label{j}]overlay={b[0]}:{b[1]}:enable=\'between(t,{a:.9f},{z:.9f})\':shortest=1[c{j}]')
   current=f'c{j}';idx+=1
  if ending:
   image=directory/f'end-{lang}-{width}x{height}.png';end_frame(width,height,lang).save(image)
   endframes=round((ending+.6)*FPS)
   endclip=cache_path(directory,{'end_image':hashlib.sha256(image.read_bytes()).hexdigest(),'frames':endframes})
   encode_scene(endclip,['-loop','1','-framerate',str(FPS),'-i',str(image)],['[0:v]scale=out_color_matrix=bt709:out_range=tv,format=yuv420p,setsar=1[end]'],'end',endframes)
   inputs+=['-i',str(endclip)]
   filters.append(f'[{idx}:v]setpts=PTS-STARTPTS,fps={FPS},settb=1/{FPS},setsar=1,format=yuv420p[endcard]')
   filters.append(f'[{current}][endcard]xfade=transition=fade:duration=0.6:offset={seconds-.6:.9f},trim=end_frame={expected}[ended]');current='ended'
  working=path.with_name(path.stem+'.rendering.mp4')
  subprocess.run(['ffmpeg','-hide_banner','-loglevel','warning','-y',*bounded_inputs(inputs),'-filter_complex_threads','1','-filter_complex',';'.join(filters),
    '-map',f'[{current}]','-an','-frames:v',str(expected),'-r',str(FPS),'-c:v','libx264','-threads','2','-preset','medium','-crf',str(crf),
    '-profile:v','high','-level:v','5.1' if width>1920 else '4.2','-pix_fmt','yuv420p','-color_range','tv','-colorspace','bt709','-color_primaries','bt709','-color_trc','bt709',
    '-bsf:v','h264_metadata=colour_primaries=1:transfer_characteristics=1:matrix_coefficients=1:video_full_range_flag=0','-video_track_timescale','15360','-movflags','+faststart+write_colr',str(working)],check=True)
  meta=json.loads(subprocess.check_output(['ffprobe','-v','error','-select_streams','v:0','-show_entries','stream=nb_frames,duration','-of','json',str(working)]))['streams'][0]
  if int(meta['nb_frames'])!=expected:raise ValueError('Finished scene has the wrong frame count')
  working.replace(path);receipt.write_text(json.dumps({'frames':expected,'bytes':path.stat().st_size,'source_native_stage':source.name})+'\n')
  prepared.append(path);time+=seconds
 total=time+tail;audio=source_path(cfg['audio']['file'],base)
 inputs=concat_input(prepared,directory,f'finished-{lang}-{width}')+['-i',str(audio)]
 subprocess.run(['ffmpeg','-hide_banner','-loglevel','warning','-y',*bounded_inputs(inputs),'-map','0:v:0','-map','1:a:0','-c:v','copy',
   '-af',f'atrim=duration={total:.9f},asetpts=PTS-STARTPTS,aresample=48000','-c:a','aac','-b:a','320k','-ar','48000','-t',f'{total:.9f}',
   '-video_track_timescale','15360','-color_range','tv','-colorspace','bt709','-color_primaries','bt709','-color_trc','bt709','-movflags','+faststart+write_colr',
   '-metadata','title=Nearpane — Keep the music close',str(out)],check=True)
 return total
