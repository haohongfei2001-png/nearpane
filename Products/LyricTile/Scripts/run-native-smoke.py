#!/usr/bin/env python3
import argparse
import json
import platform
import subprocess
from pathlib import Path

p = argparse.ArgumentParser()
p.add_argument('app', type=Path)
p.add_argument('--output', type=Path, required=True)
a = p.parse_args()
a.output.mkdir(parents=True, exist_ok=True)
command = [str(a.app.resolve()/'Contents/MacOS/LyricTile'), '--smoke-test',
           '--smoke-screenshot', str((a.output/'native-empty-panel.png').resolve())]
try:
    r = subprocess.run(command, capture_output=True, text=True, timeout=30)
    code, stdout, stderr = r.returncode, r.stdout, r.stderr
except subprocess.TimeoutExpired as e:
    code, stdout, stderr = 124, (e.stdout or b'').decode(), (e.stderr or b'').decode()
(a.output/'native-smoke.stdout.log').write_text(stdout)
(a.output/'native-smoke.stderr.log').write_text(stderr)
rows = []
for line in stdout.splitlines():
    try: rows.append(json.loads(line))
    except json.JSONDecodeError: pass
observation = next((x for x in rows if x.get('check') == 'native-ui-load'), None)
passed = code == 0 and observation and observation.get('passed') is True
report = dict(status='PASS' if passed else 'FAIL', exitCode=code, host=platform.platform(),
              observation=observation, realPlayerQualification='NOT_RUN')
(a.output/'native-smoke.json').write_text(json.dumps(report, ensure_ascii=False, indent=2)+'\n')
print(json.dumps(report, ensure_ascii=False))
raise SystemExit(0 if passed else 1)
