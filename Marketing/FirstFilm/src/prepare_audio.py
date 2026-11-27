#!/usr/bin/env python3
"""Recreate the selected licensed score edit with FFmpeg (34 seconds by default).

Attribution remains required. This processes the original recording; it does not
synthesize a song or claim the displayed demo words are the score's lyrics.
"""
import argparse, hashlib, json, math, re, subprocess
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]

def ff(args):
    return subprocess.run(['ffmpeg','-hide_banner','-nostdin','-y']+args,capture_output=True,text=True,check=True)

def stats(text):
    return json.loads(re.search(r'\{\s*"input_i"[\s\S]+?\}',text).group(0))

def main():
    p=argparse.ArgumentParser()
    p.add_argument('--source',type=Path,default=ROOT/'assets/audio/Origami-original.mp3')
    p.add_argument('--output',type=Path,required=True)
    p.add_argument('--duration',type=float,default=34,help='Continuous opening excerpt in seconds (default: 34).')
    a=p.parse_args()
    if not math.isfinite(a.duration) or a.duration<=2.418:
        p.error('--duration must be finite and longer than the 18 ms fade-in plus 2.4 s fade-out.')
    a.output.parent.mkdir(parents=True,exist_ok=True)
    if a.source.resolve()==a.output.resolve(): raise ValueError('Keep the original source intact.')
    fade_out_start=a.duration-2.4
    base=(f'atrim=start=0:duration={a.duration:g},asetpts=PTS-STARTPTS,'
          f'afade=t=in:st=0:d=0.018,afade=t=out:st={fade_out_start:g}:d=2.4')
    first=stats(ff(['-i',str(a.source),'-vn','-af',base+',loudnorm=I=-16:TP=-1.2:LRA=11:print_format=json','-f','null','-']).stderr)
    normal=(f"loudnorm=I=-16:TP=-1.2:LRA=11:measured_I={first['input_i']}:"
            f"measured_TP={first['input_tp']}:measured_LRA={first['input_lra']}:"
            f"measured_thresh={first['input_thresh']}:offset={first['target_offset']}:linear=true:print_format=json")
    ff(['-i',str(a.source),'-vn','-af',base+','+normal,'-ar','48000','-ac','2','-c:a','pcm_s24le',str(a.output)])
    measured=stats(ff(['-i',str(a.output),'-af','loudnorm=I=-16:TP=-1.2:LRA=11:print_format=json','-f','null','-']).stderr)
    result={'file':str(a.output),'sha256':hashlib.sha256(a.output.read_bytes()).hexdigest(),
            'source':str(a.source),'source_sha256':hashlib.sha256(a.source.read_bytes()).hexdigest(),
            'duration_seconds':a.duration,'source_excerpt_seconds':[0,a.duration],
            'fade_in_seconds':[0,0.018],'fade_out_seconds':[round(fade_out_start,6),a.duration],
            'normalization_target':{'integrated_lufs':-16,'true_peak_dbtp':-1.2,'loudness_range_lu':11},
            'first_pass':first,'measured':measured,
            'listening_review':'Technical measurements only; not a subjective listening review.'}
    a.output.with_suffix('.analysis.json').write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps(result))

if __name__=='__main__': main()
