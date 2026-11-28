#!/usr/bin/env python3
"""Prepare an editorial music interval without changing pitch or time.

When the input is a native capture, retain its audio/video timestamp offset
before trimming. Numerical loudness and correlation checks are not listening.
"""
import argparse, hashlib, json, subprocess
from pathlib import Path

def call(args):
    return subprocess.run(args, check=True, capture_output=True, text=True)

def prepare(source, out, start, duration, fade_in=.015, fade_out=.25):
    probe=json.loads(call(['ffprobe','-v','error','-show_streams','-show_format','-of','json',str(source)]).stdout)
    audio=next(s for s in probe['streams'] if s['codec_type']=='audio')
    video=next((s for s in probe['streams'] if s['codec_type']=='video'),None)
    origin=float(video.get('start_time',0)) if video else 0.
    if start<0 or duration<=0: raise ValueError('Invalid audio interval')
    extent=float(audio.get('start_time',0))+float(audio.get('duration',probe['format']['duration']))-origin
    if start+duration>extent+1/48000:
        raise ValueError(f'Audio interval exceeds captured coverage: {start+duration} > {extent}')
    base=(f'asetpts=PTS-{origin}/TB,aresample=48000:async=1:first_pts=0,'
          f'atrim=start={start:.9f}:duration={duration:.9f},asetpts=PTS-STARTPTS,'
          f'afade=t=in:st=0:d={fade_in},afade=t=out:st={duration-fade_out:.9f}:d={fade_out}')
    first=call(['ffmpeg','-hide_banner','-copyts','-i',str(source),'-vn','-af',base+',loudnorm=I=-16:TP=-1:LRA=11:print_format=json','-f','null','-'])
    info=first.stderr; measured=json.loads(info[info.rfind('{'):info.rfind('}')+1])
    norm=(f"loudnorm=I=-16:TP=-1:LRA=11:measured_I={measured['input_i']}:"
          f"measured_TP={measured['input_tp']}:measured_LRA={measured['input_lra']}:"
          f"measured_thresh={measured['input_thresh']}:offset={measured['target_offset']}:linear=true")
    out.parent.mkdir(parents=True,exist_ok=True)
    call(['ffmpeg','-hide_banner','-loglevel','warning','-y','-copyts','-i',str(source),'-vn','-af',base+','+norm,'-ar','48000','-ac','2','-c:a','pcm_s24le',str(out)])
    receipt={'source':str(source.resolve()),'source_sha256':hashlib.sha256(source.read_bytes()).hexdigest(),
             'start':start,'duration':duration,'video_origin_pts':origin,'decoded_audio_extent':extent,
             'fade_in':fade_in,'fade_out':fade_out,'loudnorm_first_pass':measured,
             'output':str(out.resolve()),'sha256':hashlib.sha256(out.read_bytes()).hexdigest(),
             'method':'Timestamp-preserving resample; source interval; short ramps; two-pass loudness normalization. No time stretch or pitch change.'}
    out.with_suffix('.json').write_text(json.dumps(receipt,ensure_ascii=False,indent=2)+'\n')
    print(out)

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('source',type=Path);p.add_argument('--out',type=Path,required=True)
    p.add_argument('--start',type=float,required=True);p.add_argument('--duration',type=float,required=True)
    p.add_argument('--fade-in',type=float,default=.015);p.add_argument('--fade-out',type=float,default=.25)
    a=p.parse_args();prepare(a.source,a.out,a.start,a.duration,a.fade_in,a.fade_out)
