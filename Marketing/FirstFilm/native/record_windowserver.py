#!/usr/bin/env python3
"""Actual OS recording, launched by the same runner shell as proven capture.

The app requests bounded named takes. This process never supplies product state,
pointer positions or playback data. All motion comes from WindowServer.
"""
import argparse, json, subprocess, time
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument('directory', type=Path)
args = parser.parse_args()
folder = args.directory / 'windowserver'
folder.mkdir(parents=True, exist_ok=True)
seen = set()
deadline = time.monotonic() + 300
names = {'a-zh-lyrics', 'b-zh-lyrics', 'a-en-lyrics', 'b-en-lyrics', 'zh-controls', 'en-controls'}

def write(name, data):
    temporary = folder / (name + '.tmp')
    temporary.write_text(json.dumps(data, ensure_ascii=False, indent=2) + '\n')
    temporary.replace(folder / name)

while time.monotonic() < deadline and not (folder / 'stop').exists():
    try:
        request = json.loads((folder / 'request.json').read_text())
    except (OSError, ValueError):
        time.sleep(.05)
        continue
    token = request.get('token')
    name = request.get('name')
    seconds = request.get('seconds')
    if token in seen or name not in names or not isinstance(seconds, int) or not 5 <= seconds <= 20:
        time.sleep(.05)
        continue
    seen.add(token)
    display_index = request.get('displayIndex', 1)
    if not isinstance(display_index, int) or not 1 <= display_index <= 8:
        raise SystemExit('Invalid capture display index')
    command = ['/usr/sbin/screencapture', '-v', '-V', str(seconds), '-x', '-C', '-D', str(display_index), str(folder / (name + '-fullscreen.mov'))]
    started = time.monotonic()
    with (folder / (name + '-recorder.log')).open('w') as log:
        try:
            process = subprocess.Popen(command, stdout=log, stderr=log)
            write('started.json', {'token': token, 'name': name, 'hostMonotonic': started, 'pid': process.pid, 'cursorIncluded': True})
            result = process.wait(timeout=seconds + 15)
            write('done.json', {'token': token, 'name': name, 'exitCode': result, 'hostMonotonic': time.monotonic(), 'command': command})
        except Exception as error:
            if 'process' in locals() and process.poll() is None:
                process.terminate()
            write('done.json', {'token': token, 'name': name, 'exitCode': -1, 'error': str(error)})
