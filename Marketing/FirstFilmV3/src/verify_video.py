#!/usr/bin/env python3
"""Check actual video duration, streams, decode integrity, loudness and frames."""
import argparse,hashlib,json,subprocess
from pathlib import Path

def run(args): return subprocess.run(args,text=True,capture_output=True,check=True)
def verify(path):
    meta=json.loads(run(['ffprobe','-v','error','-show_streams','-show_format','-of','json',str(path)]).stdout)
    video=next(s for s in meta['streams'] if s['codec_type']=='video')
    audio=next(s for s in meta['streams'] if s['codec_type']=='audio')
    decode=run(['ffmpeg','-v','error','-threads','1','-i',str(path),'-f','null','-'])
    audio_check=run(['ffmpeg','-hide_banner','-i',str(path),'-vn','-af','loudnorm=I=-16:TP=-1:LRA=11:print_format=json','-f','null','-'])
    data=audio_check.stderr
    loud=json.loads(data[data.rfind('{'):data.rfind('}')+1])
    return {'file':path.name,'sha256':hashlib.sha256(path.read_bytes()).hexdigest(),
      'bytes':path.stat().st_size,'duration':float(meta['format']['duration']),
      'video':{k:video.get(k) for k in ['codec_name','width','height','pix_fmt','r_frame_rate','nb_frames','color_range','color_space','color_transfer','color_primaries']},
      'audio':{k:audio.get(k) for k in ['codec_name','sample_rate','channels','bit_rate']},
      'decoded_without_errors':not decode.stderr.strip(),
      'loudness_lufs':float(loud['input_i']),'true_peak_dbtp':float(loud['input_tp']),
      'audio_listening_review':'NOT AVAILABLE IN THIS RUNTIME; numerical checks are not listening',
      'not_a_quality_certification':'Composition and motion need visual review; package and product claims need their own evidence.'}
if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('files',nargs='+',type=Path);p.add_argument('--output',type=Path,required=True);a=p.parse_args()
    results=[verify(f) for f in a.files]
    a.output.parent.mkdir(parents=True,exist_ok=True);a.output.write_text(json.dumps(results,ensure_ascii=False,indent=2)+'\n')
    print(json.dumps(results,ensure_ascii=False,indent=2))
