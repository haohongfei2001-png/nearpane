#!/usr/bin/env python3
"""Align the genuine recorded system audio to the licensed original; no listening claim."""
import argparse,hashlib,json,subprocess
from pathlib import Path
import numpy as np
from scipy.signal import fftconvolve
p=argparse.ArgumentParser();p.add_argument('capture',type=Path);p.add_argument('reference',type=Path);p.add_argument('output',type=Path);a=p.parse_args()
sr=8000;take_start=5.25;take_duration=5.;reference_start=145.;reference_duration=40.
def decode(path,start,duration):
 b=subprocess.check_output(['ffmpeg','-v','error','-i',str(path),'-ss',str(start),'-t',str(duration),'-vn','-ac','1','-ar',str(sr),'-f','f32le','-'])
 return np.frombuffer(b,dtype='<f4').astype(np.float64)
sample=decode(a.capture,take_start,take_duration);ref=decode(a.reference,reference_start,reference_duration)
assert len(sample)>sr*3 and len(ref)>len(sample)
z=sample-sample.mean();n=len(z)
numerator=fftconvolve(ref,z[::-1],mode='valid')
ones=np.ones(n);sums=fftconvolve(ref,ones,mode='valid');squares=fftconvolve(ref*ref,ones,mode='valid')
denom=np.sqrt(np.maximum(squares-sums*sums/n,1e-16)*np.sum(z*z))
corr=numerator/denom;idx=int(np.argmax(corr));matched_start=reference_start+idx/sr
offset=matched_start-take_start
probe=json.loads(subprocess.check_output(['ffprobe','-v','error','-show_streams','-show_format','-of','json',str(a.capture)],text=True))
report={'capture':str(a.capture),'captureBytes':a.capture.stat().st_size,'captureSHA256':hashlib.sha256(a.capture.read_bytes()).hexdigest(),
 'reference':str(a.reference),'referenceSHA256':hashlib.sha256(a.reference.read_bytes()).hexdigest(),
 'method':'Actual captured system audio, mono 8000 Hz normalized cross correlation of file seconds5.25–10.25 against original source seconds145–185, wholly after the seek. Numerical matching; not a listening review.',
 'captureMatchWindow':[take_start,take_start+take_duration],
 'audioCorrelation':float(corr[idx]),'matchedSourceSecondsAtWindowStart':matched_start,'sourceSecondsEqualsCaptureSecondsPlus':offset,
 'desiredSourceRange':[165.6,170.6],'correspondingCaptureRange':[165.6-offset,170.6-offset],
 'scope':'Offset is valid for the uninterrupted post-seek segment, not initial pre-seek preroll. Root must choose the final cut and audio integration.',
 'mediaProbe':probe}
a.output.write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
print(json.dumps({k:v for k,v in report.items() if k not in ['mediaProbe','reference']},ensure_ascii=False,indent=2))
