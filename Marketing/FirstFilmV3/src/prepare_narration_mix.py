#!/usr/bin/env python3
"""Trim VO edge silence, master dialogue, and gently duck the real song.

No pitch change or time stretching. All placements are explicit sample offsets.
The two stems and processing receipts are retained for future remixing.
"""
import argparse, hashlib, json, re, subprocess
from pathlib import Path
import numpy as np

ROOT=Path(__file__).resolve().parents[1]
SR=48000

def read_audio(path,channels=2,rate=SR):
    data=subprocess.check_output(['ffmpeg','-v','error','-i',str(path),'-f','f32le','-ac',str(channels),'-ar',str(rate),'-'])
    return np.frombuffer(data,np.float32).reshape(-1,channels).copy()

def write_audio(path,data):
    subprocess.run(['ffmpeg','-v','error','-y','-f','f32le','-ar',str(SR),'-ac',str(data.shape[1]),'-i','pipe:0','-c:a','pcm_s24le',str(path)],input=np.asarray(data,np.float32).tobytes(),check=True)

def loudnorm(src,dest,target=-18,pre=''):
    norm=f'loudnorm=I={target}:TP=-2:LRA=7'
    first=subprocess.run(['ffmpeg','-hide_banner','-i',str(src),'-af',pre+norm+':print_format=json','-f','null','-'],capture_output=True,text=True,check=True)
    found=re.findall(r'\{\s*"input_i"[\s\S]*?\}',first.stderr)
    if not found:raise ValueError('Missing loudness measurements')
    m=json.loads(found[-1])
    second=norm+f':measured_I={m["input_i"]}:measured_TP={m["input_tp"]}:measured_LRA={m["input_lra"]}:measured_thresh={m["input_thresh"]}:offset={m["target_offset"]}:linear=true'
    subprocess.run(['ffmpeg','-v','error','-y','-i',str(src),'-af',pre+second,'-ar',str(SR),'-c:a','pcm_s24le',str(dest)],check=True)
    return m

def edge_trim(samples):
    # 10 ms RMS windows, -44 dBFS activity, 140 ms breathing margin.
    mono=samples.mean(axis=1);step=480
    n=(len(mono)+step-1)//step
    padded=np.pad(mono,(0,n*step-len(mono)))
    rms=np.sqrt((padded.reshape(n,step).astype(np.float64)**2).mean(axis=1))
    active=np.flatnonzero(rms>10**(-44/20))
    if not len(active):raise ValueError('No voice activity found')
    a=max(0,int(active[0]*step-.14*SR));z=min(len(mono),int((active[-1]+1)*step+.14*SR))
    return a,z

def srt_time(seconds):
    n=round(seconds*1000);h,n=divmod(n,3600000);m,n=divmod(n,60000);s,ms=divmod(n,1000)
    return f'{h:02}:{m:02}:{s:02},{ms:03}'

def main():
    p=argparse.ArgumentParser();p.add_argument('--duration',type=float,default=39);a=p.parse_args()
    cfg=json.loads((ROOT/'config/narration-zh.json').read_text())
    out=ROOT/'assets/audio/narration';clean=out/'processed';clean.mkdir(parents=True,exist_ok=True)
    frames=round(a.duration*SR);voice=np.zeros((frames,2),np.float32)
    gain=np.ones(frames,np.float32);placements=[];subs=[]
    for i,c in enumerate(cfg['clips']):
        raw=out/'raw'/(c['key']+'.wav');samples=read_audio(raw,1)
        first,last=edge_trim(samples);trimmed=samples[first:last].copy()
        fade=min(480,len(trimmed)//10)
        trimmed[:fade]*=np.linspace(0,1,fade,dtype=np.float32)[:,None]
        trimmed[-fade:]*=np.linspace(1,0,fade,dtype=np.float32)[:,None]
        trimfile=clean/(c['key']+'-trim.wav');write_audio(trimfile,trimmed)
        final=clean/(c['key']+'.wav')
        pre='highpass=f=70,acompressor=threshold=0.125:ratio=2:attack=15:release=100:makeup=1,pan=stereo|c0=c0|c1=c0,'
        measurements=loudnorm(trimfile,final,-18,pre)
        clip=read_audio(final);start=float(c['target_start']);end=start+len(clip)/SR
        if end>c['target_end']+.10:
            raise ValueError(f'{c["key"]} is longer than its reserved window: {end:.3f}>{c["target_end"]}; rewrite or re-place, never speed up speech')
        at=round(start*SR);voice[at:at+len(clip)]+=clip
        # Smooth dB-domain music envelope; avoid abrupt pumping between clauses.
        attack=.22;hold=.10;release=.48;depth=float(c.get('music_duck_db',-13.))
        b=max(0,round((start-attack)*SR));e=min(frames,round((end+hold+release)*SR))
        t=np.arange(b,e)/SR
        db=np.interp(t,[start-attack,start,end+hold,end+hold+release],[0,depth,depth,0])
        gain[b:e]=np.minimum(gain[b:e],10**(db/20))
        placements.append({'key':c['key'],'text':c['text'],'raw_sha256':hashlib.sha256(raw.read_bytes()).hexdigest(),
          'trim_raw_seconds':[first/SR,last/SR],'timeline_seconds':[start,end],'samples':len(clip),
          'normalization_input':measurements,'dialogue_target_lufs':-18,'music_duck_db':depth,
          'time_stretch':False,'pitch_shift':False,'file':str(final.relative_to(ROOT))})
        subs.append(f'{i+1}\n{srt_time(start)} --> {srt_time(end)}\n{c["text"]}\n')
    music=read_audio(ROOT/'assets/audio/good-to-go-master39.wav')
    if len(music)<frames:raise ValueError('Music master shorter than picture')
    ducked=music[:frames]*gain[:,None]
    write_audio(out/'dialogue-stem-zh.wav',voice);write_audio(out/'music-ducked-zh.wav',ducked)
    premix=out/'premaster-zh.wav';write_audio(premix,voice+ducked)
    result=ROOT/'assets/audio/nearpane-zh-narrated39.wav';master=loudnorm(premix,result,-16)
    record={'duration_seconds':a.duration,'sample_rate':SR,'samples':frames,'placements':placements,
      'music_source':'good-to-go-master39.wav','music_source_interval':[147.6,186.6],
      'ducking':{'attack_seconds':.22,'hold_seconds':.10,'release_seconds':.48,'default_depth_db':-13,'per_line_depths_in_placements':True},
      'mix_target_lufs':-16,'true_peak_ceiling_dbtp':-2,'premaster_measurements':master,
      'final_sha256':hashlib.sha256(result.read_bytes()).hexdigest(),
      'audition_status':'Objective content, timing and levels checked separately; no subjective listening claim.'}
    (out/'mix-receipt.json').write_text(json.dumps(record,ensure_ascii=False,indent=2)+'\n')
    (out/'narration-zh.srt').write_text('\n'.join(subs))
    print(json.dumps({'mix':str(result),'placements':[{k:x[k] for k in ['key','timeline_seconds']} for x in placements]},ensure_ascii=False,indent=2))

if __name__=='__main__':main()
