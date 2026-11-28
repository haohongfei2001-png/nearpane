#!/usr/bin/env python3
"""Keep the licensed song and original cover; use standard QQ-readable MP3/APIC."""
import argparse,hashlib,json,subprocess
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('--alac',type=Path,required=True);p.add_argument('--cover',type=Path,required=True);p.add_argument('--output',type=Path,required=True);p.add_argument('--evidence',type=Path,required=True);a=p.parse_args()
a.evidence.mkdir(parents=True,exist_ok=True)
cover=a.evidence/'playback-compatible-cover.jpg'
subprocess.run(['ffmpeg','-y','-v','error','-i',str(a.cover),'-vf','scale=600:-1:flags=lanczos','-frames:v','1','-q:v','2',str(cover)],check=True)
subprocess.run(['ffmpeg','-y','-v','error','-i',str(a.alac),'-i',str(cover),'-map','0:a:0','-map','1:v:0','-map_metadata','0','-c:a','libmp3lame','-b:a','320k','-c:v','copy','-id3v2_version','3','-write_id3v1','1','-metadata:s:v','title=Album cover','-metadata:s:v','comment=Cover (front)',str(a.output)],check=True)
def digest(p):return hashlib.sha256(p.read_bytes()).hexdigest()
probe=json.loads(subprocess.check_output(['ffprobe','-v','error','-show_streams','-show_format','-of','json',str(a.output)],text=True))
record={'alacSHA256':digest(a.alac),'originalCoverSHA256':digest(a.cover),'compatibleCoverSHA256':digest(cover),'outputSHA256':digest(a.output),'conversion':'Original ALAC playback derivative -> 320kbps MP3 with ID3v2.3/APIC; same real recording, original cover scaled uniformly to600px, no speed/pitch edit. Not a lossless master.','probe':probe}
(a.evidence/'mp3-compatibility.json').write_text(json.dumps(record,ensure_ascii=False,indent=2)+'\n')
print(json.dumps({k:v for k,v in record.items() if k!='probe'},indent=2))
