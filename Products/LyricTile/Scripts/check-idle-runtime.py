#!/usr/bin/env python3
"""Measure the real candidate with no target player on a disposable Actions host."""
import argparse
import json
import os
import signal
import subprocess
import time
from pathlib import Path

p=argparse.ArgumentParser()
p.add_argument('app',type=Path)
p.add_argument('--output',type=Path,required=True)
p.add_argument('--seconds',type=int,default=60)
a=p.parse_args()
if os.environ.get('GITHUB_ACTIONS')!='true':
    p.error('This disposable-profile check is for CI only. Use measure-runtime.py against your existing local app instead.')
if not 30<=a.seconds<=120: p.error('Use 30 to 120 seconds for the hosted idle baseline.')
a.output.mkdir(parents=True,exist_ok=True)
inventory = subprocess.run(['/usr/bin/xcrun','swift',str(Path(__file__).resolve().parent/'running-players.swift')],
                           capture_output=True,text=True,check=True,timeout=30)
players=json.loads(inventory.stdout)
if players:
    report={'status':'NOT_RUN','reason':'An actual target app is already running; this is not an empty idle environment.',
            'players':players}
    (a.output/'idle-check.json').write_text(json.dumps(report)+'\n')
    print(json.dumps(report))
    raise SystemExit(0)
settings=dict(appearance='automatic',largeText=False,showTranslation=False,onlineLyrics=False,
              hideWhenIdle=True,showInFullScreen=False,coordinateTiles=True,completedWelcome=True)
subprocess.run(['/usr/bin/defaults','write','com.holdsnow.lyrictile','LyricTile.settings.v1','-data',
                json.dumps(settings).encode().hex()],check=True)
root=Path(__file__).resolve().parent
process=subprocess.Popen([str(a.app.resolve()/'Contents/MacOS/LyricTile')],
    stdout=subprocess.DEVNULL,stderr=subprocess.PIPE,start_new_session=True)
try:
    time.sleep(18) # Real startup and the normal 15-second no-playback auto-hide.
    if process.poll() is not None: raise RuntimeError('The ordinary candidate exited before sampling.')
    subprocess.run(['python3',str(root/'measure-runtime.py'),'--pid',str(process.pid),'--seconds',str(a.seconds),
                    '--mode','idle','--output',str(a.output/'idle-samples')],check=True,timeout=a.seconds+30)
    measured=json.loads((a.output/'idle-samples/summary.json').read_text())
    report=dict(scope='actual_candidate_idle_no_player',status='MEASURED',recordingsUsed=0,
                app=str(a.app),summary=measured,
                withinTargets=measured['cpuMeanPercentOneCore']<=.3 and measured['rssMedianMiB']<=120 and measured['rssPeakMiB']<=180,
                qualification='Hosted idle baseline only; no real-player/line/word/8-hour performance claim.')
    (a.output/'idle-check.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(report))
    # Preserve measurements even when hosted noise exceeds a target. The report
    # says withinTargets=false; release qualification must investigate that fact.
finally:
    if process.poll() is None:
        os.killpg(process.pid,signal.SIGTERM)
        try: process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid,signal.SIGKILL); process.wait(timeout=3)
    error=process.stderr.read().decode(errors='replace')
    (a.output/'idle-app.stderr.log').write_text(error)
    subprocess.run(['/usr/bin/defaults','delete','com.holdsnow.lyrictile','LyricTile.settings.v1'],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
