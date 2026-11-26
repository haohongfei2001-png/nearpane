#!/usr/bin/env python3
"""Local process-tree sampling. Measures evidence; never labels real-player cases PASS."""
import argparse
import json
import math
import statistics
import subprocess
import time
from pathlib import Path

p = argparse.ArgumentParser()
p.add_argument('--pid', type=int, required=True)
p.add_argument('--seconds', type=int, default=120)
p.add_argument('--mode', choices=['idle','line','word'], required=True)
p.add_argument('--output', type=Path, required=True)
a = p.parse_args()
if not 10 <= a.seconds <= 28800: p.error('Duration must be 10 seconds to 8 hours.')
if a.output.exists() and any(a.output.iterdir()): p.error('Use a new or empty output directory.')
a.output.mkdir(parents=True, exist_ok=True, mode=0o700)
def ps(*args):
    return subprocess.check_output(['/bin/ps', *args], text=True, timeout=5).strip()
root_start = ps('-p',str(a.pid),'-o','lstart=')
root_command = ps('-p',str(a.pid),'-o','comm=')
if not root_start or Path(root_command).name != 'LyricTile': p.error('PID must identify the actual running LyricTile executable.')
def cpu_time(value):
    days = 0
    if '-' in value: day,value=value.split('-',1); days=int(day)
    parts=[float(x) for x in value.split(':')]
    result=0
    for part in parts: result=result*60+part
    return result+days*86400
def sample():
    rows={}
    for line in ps('-axo','pid=,ppid=,time=,rss=,comm=').splitlines():
        parts=line.split(None,4)
        if len(parts)!=5: continue
        try: rows[int(parts[0])]=dict(ppid=int(parts[1]),cpu=cpu_time(parts[2]),rssKiB=int(parts[3]),command=parts[4])
        except ValueError: continue
    children={a.pid}
    while True:
        more={pid for pid,r in rows.items() if r['ppid'] in children}
        new=children|more
        if new==children: break
        children=new
    return {pid:rows[pid] for pid in children if pid in rows}
start=time.monotonic(); previous=sample(); previous_time=start
rss=[]; cpu=[]; disappeared=set(); complete=False
try:
    with (a.output/'samples.ndjson').open('w') as trace:
        while time.monotonic()-start<a.seconds:
            time.sleep(1)
            if ps('-p',str(a.pid),'-o','lstart=') != root_start: raise RuntimeError('Root process ended or its PID was reused.')
            current=sample(); now=time.monotonic(); elapsed=now-previous_time
            disappeared.update(set(previous)-set(current))
            delta=sum(max(0,r['cpu']-previous.get(pid,{'cpu':0})['cpu']) for pid,r in current.items())
            percent=100*delta/elapsed
            resident=sum(r['rssKiB'] for r in current.values())/1024
            cpu.append(percent); rss.append(resident)
            trace.write(json.dumps(dict(elapsedSeconds=now-start,cpuPercentOneCore=percent,rssMiB=resident,processes=current))+'\n')
            trace.flush(); previous=current; previous_time=now
        complete=True
finally:
    def percentile(values,q):
        return sorted(values)[max(0,math.ceil(len(values)*q)-1)] if values else None
    result=dict(schemaVersion=1,status='MEASURED' if complete else 'INTERRUPTED',mode=a.mode,
        rootPID=a.pid,rootStart=root_start,rootCommand=root_command,durationSeconds=time.monotonic()-start,
        samples=len(cpu),cpuMeanPercentOneCore=statistics.mean(cpu) if cpu else None,
        cpuP95PercentOneCore=percentile(cpu,.95),rssMedianMiB=statistics.median(rss) if rss else None,
        rssPeakMiB=max(rss) if rss else None,processesExitedBetweenSamples=len(disappeared),
        cpuBudgetPercentOneCore={'idle':.3,'line':1,'word':3}[a.mode],rssMedianBudgetMiB=120,rssPeakBudgetMiB=180,
        limitation='ps CPU time has finite resolution; very short-lived helper CPU between samples can be missed. This is a process-tree estimate, not an acoustic or playback correctness qualification. Use Instruments for any borderline result.')
    (a.output/'summary.json').write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n')
    for f in a.output.iterdir():
        if f.is_file(): f.chmod(0o600)
    print(json.dumps(result,ensure_ascii=False))
