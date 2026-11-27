#!/usr/bin/env python3
"""Wait for the real app's first lyric image then record the actual desktop."""
import argparse,json,subprocess,time
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('directory',type=Path);a=p.parse_args()
a.directory.mkdir(parents=True,exist_ok=True)
start=time.monotonic();trigger=a.directory/'real-music/real-music-lyrics.png'
while time.monotonic()-start<300 and not trigger.exists():time.sleep(.15)
r={'triggerObserved':trigger.exists(),'captureKind':'WindowServer desktop video','requestedSeconds':24}
if trigger.exists():
 try:
  cmd=['/usr/sbin/screencapture','-v','-V','24','-x','-C',str(a.directory/'real-desktop.mov')]
  result=subprocess.run(cmd,capture_output=True,text=True,timeout=35)
  r.update(exitCode=result.returncode,stdout=result.stdout,stderr=result.stderr,command=cmd)
 except Exception as e:r['error']=str(e)
(a.directory/'desktop-video.json').write_text(json.dumps(r,indent=2)+'\n')
