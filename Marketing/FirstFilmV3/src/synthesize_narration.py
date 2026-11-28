#!/usr/bin/env python3
"""Generate reproducible Chinese VO from the licensed, predefined Qwen voice.

Run in the separate voice environment documented in docs/NARRATION.md.
Model weights are downloaded by revision and kept outside the production repo.
No person is cloned, and no unsupported style instruction is silently claimed.
"""
import argparse, hashlib, json, time, os
from pathlib import Path

# Official ONNX process-lifetime opt-out must precede its first import.
# https://github.com/microsoft/onnxruntime/blob/main/docs/Privacy.md
# Inference uses already downloaded local weights and needs no network service.
os.environ['ORT_DISABLE_TELEMETRY']='1'
os.environ['HF_HUB_DISABLE_TELEMETRY']='1'
os.environ['DO_NOT_TRACK']='1'
os.environ['HF_HUB_OFFLINE']='1'
os.environ['GRADIO_ANALYTICS_ENABLED']='False'

ROOT=Path(__file__).resolve().parents[1]

def main():
    p=argparse.ArgumentParser()
    p.add_argument('--weights',type=Path,required=True)
    p.add_argument('--config',type=Path,default=ROOT/'config/narration-zh.json')
    p.add_argument('--keys',nargs='*')
    p.add_argument('--threads',type=int,default=6)
    a=p.parse_args()
    import torch, numpy as np, soundfile as sf
    import onnxruntime as ort
    ort.disable_telemetry_events()
    from qwen_tts import Qwen3TTSModel
    torch.set_num_threads(a.threads);torch.set_num_interop_threads(1)
    cfg=json.loads(a.config.read_text())
    target=ROOT/'assets/audio/narration/raw';target.mkdir(parents=True,exist_ok=True)
    started=time.monotonic()
    model=Qwen3TTSModel.from_pretrained(str(a.weights.resolve()),device_map='cpu',dtype=torch.float32,attn_implementation='sdpa')
    print(json.dumps({'model_loaded_seconds':round(time.monotonic()-started,2),'supported_speakers':model.get_supported_speakers()}),flush=True)
    for i,clip in enumerate(cfg['clips']):
        if a.keys and clip['key'] not in a.keys:continue
        path=target/(clip['key']+'.wav')
        seed=cfg['seed']+i;torch.manual_seed(seed);np.random.seed(seed)
        opts={'text':clip['text'],'speaker':cfg['speaker'],'language':'Chinese',
              'non_streaming_mode':True,'do_sample':True,'temperature':0.75,
              'top_p':0.95,'top_k':50,'repetition_penalty':1.05,'max_new_tokens':192}
        if cfg.get('instruct_supported') and cfg.get('instruction'):
            opts['instruct']=cfg['instruction']
        t=time.monotonic()
        wavs,sr=model.generate_custom_voice(**opts)
        wav=np.asarray(wavs[0],dtype=np.float32)
        if not np.all(np.isfinite(wav)) or np.max(np.abs(wav))<=1e-6:
            raise ValueError('Synthesis produced invalid/silent audio')
        sf.write(str(path),wav,sr,subtype='PCM_24')
        receipt={'key':clip['key'],'text':clip['text'],'language':'Chinese','speaker':cfg['speaker'],
                 'model':cfg['model'],'revision':cfg['revision'],'model_license':cfg['model_license'],
                 'seed':seed,'generation_parameters':opts,'sample_rate':sr,'samples':len(wav),
                 'duration':len(wav)/sr,'generation_seconds':round(time.monotonic()-t,2),
                 'peak':float(np.max(np.abs(wav))),'dtype':'float32','device':'cpu',
                 'sha256':hashlib.sha256(path.read_bytes()).hexdigest(),
                 'status':'SYNTHESIZED_NOT_SUBJECTIVELY_AUDITIONED'}
        path.with_suffix('.json').write_text(json.dumps(receipt,ensure_ascii=False,indent=2)+'\n')
        print(json.dumps(receipt,ensure_ascii=False),flush=True)

if __name__=='__main__':main()
