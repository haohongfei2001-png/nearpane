#!/usr/bin/env python3
"""Independent ASR on generated VO without supplying the expected transcript.

This is a content/word check. It is not a subjective listening approval.
"""
import os
os.environ['ORT_DISABLE_TELEMETRY']='1'
os.environ['HF_HUB_DISABLE_TELEMETRY']='1'
os.environ['DO_NOT_TRACK']='1'
os.environ['HF_HUB_OFFLINE']='1'
import argparse,json,subprocess
from pathlib import Path
import numpy as np
from faster_whisper import WhisperModel
ROOT=Path(__file__).resolve().parents[1]

def main():
    p=argparse.ArgumentParser();p.add_argument('--model',type=Path,required=True);p.add_argument('--mixed',action='store_true');p.add_argument('--keys',nargs='*');p.add_argument('--output',type=Path);a=p.parse_args()
    model=WhisperModel(str(a.model),device='cpu',compute_type='int8',cpu_threads=4,local_files_only=True)
    cfg=json.loads((ROOT/'config/narration-zh.json').read_text());out=[]
    placements={}
    if a.mixed:
        placements={x['key']:x['timeline_seconds'] for x in json.loads((ROOT/'assets/audio/narration/mix-receipt.json').read_text())['placements']}
    for c in cfg['clips']:
        if a.keys and c['key'] not in a.keys:continue
        path=ROOT/'assets/audio/narration/raw'/(c['key']+'.wav')
        bounds=[]
        if a.mixed:
            path=ROOT/'assets/audio/nearpane-zh-narrated39.wav';start,end=placements[c['key']]
            bounds=['-ss',str(max(0,start-.1)),'-t',str(end-start+.2)]
        data=subprocess.check_output(['ffmpeg','-v','error','-i',str(path),*bounds,'-f','f32le','-ac','1','-ar','16000','-'])
        samples=np.frombuffer(data,np.float32).copy()
        segments,info=model.transcribe(samples,language='zh',beam_size=5,word_timestamps=True,vad_filter=False,condition_on_previous_text=False)
        ss=[{'start':s.start,'end':s.end,'text':s.text,'avg_logprob':s.avg_logprob,
             'words':[{'word':w.word,'start':w.start,'end':w.end,'probability':w.probability} for w in s.words]} for s in segments]
        d={'key':c['key'],'expected_text':c['text'],'transcription':''.join(s['text'] for s in ss),
           'model':'Systran/faster-whisper-small','revision':'536b0662742c02347bc0e980a01041f333bce120',
           'expected_transcript_supplied_to_ASR':False,'music_mixed_under_dialogue':a.mixed,'language':info.language,'segments':ss}
        out.append(d);print(json.dumps({k:d[k] for k in ['key','expected_text','transcription']},ensure_ascii=False),flush=True)
    dest=a.output or ROOT/'docs'/('MIX-INTELLIGIBILITY-REVIEW.json' if a.mixed else 'NARRATION-ASR-REVIEW.json')
    dest.write_text(json.dumps(out,ensure_ascii=False,indent=2)+'\n')

if __name__=='__main__':main()
