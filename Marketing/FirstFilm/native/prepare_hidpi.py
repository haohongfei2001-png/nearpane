#!/usr/bin/env python3
"""Select and prove a native 2x screen on the disposable filming runner."""
import argparse, json, os, struct, subprocess, time
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument('output', type=Path)
args = parser.parse_args()
out = args.output / 'display'
out.mkdir(parents=True, exist_ok=True)
native = Path(__file__).resolve().parent
binary = Path(os.environ['RUNNER_TEMP']) / 'nearpane-native-display'
subprocess.run(['clang', '-fobjc-arc', '-O2', '-framework', 'AppKit', '-framework', 'Foundation', '-framework', 'CoreGraphics', str(native / 'np-virtual-hidpi.m'), '-o', str(binary)], check=True)
subprocess.run([str(binary), '--probe', '--output', str(out / 'before.json')], check=True)
selected_file = out / 'selected.json'
selected_result = subprocess.run([str(binary), '--select-existing', '--output', str(selected_file)])
report = json.loads(selected_file.read_text())
if selected_result.returncode or not report.get('ready'):
    selected_file = out / 'virtual.json'
    log = (out / 'virtual-process.log').open('w')
    process = subprocess.Popen([str(binary), '--create', '--width', '1600', '--height', '1200', '--seconds', '1800', '--output', str(selected_file)], stdout=log, stderr=log, start_new_session=True)
    (out / 'virtual-process.json').write_text(json.dumps({'pid': process.pid}) + '\n')
    deadline = time.monotonic() + 25
    while not selected_file.exists() and process.poll() is None and time.monotonic() < deadline:
        time.sleep(.2)
    report = json.loads(selected_file.read_text()) if selected_file.exists() else {'ready': False, 'error': 'No display initialization report'}
if not report.get('ready'):
    print(json.dumps({'ready': False, 'report': str(selected_file), 'reason': report.get('error', 'Actual 2x backing unavailable')}))
    raise SystemExit(2)
selected = report['selected']
mode = selected['currentMode']
expected = (mode['pixelWidth'], mode['pixelHeight'])
displays = report.get('displays') or json.loads((out / 'before.json').read_text()).get('displays', [])
count = max(1, len(displays))
matches = []
probes = []
for index in range(1, count + 1):
    image = out / ('screen-index-%d.png' % index)
    result = subprocess.run(['/usr/sbin/screencapture', '-x', '-D', str(index), str(image)], capture_output=True, text=True, timeout=20)
    size = None
    if result.returncode == 0 and image.exists():
        data = image.read_bytes()
        if data[:8] == b'\x89PNG\r\n\x1a\n':
            size = struct.unpack('>II', data[16:24])
    probes.append({'index': index, 'exitCode': result.returncode, 'pixels': size, 'stderr': result.stderr})
    if size == expected:
        matches.append(index)
evidence = {'ready': len(matches) == 1, 'selectedDisplayID': selected['displayID'], 'expectedPixels': expected, 'actualBackingScale': selected.get('backingScaleFactor'), 'screenIndexProbes': probes, 'matchingIndices': matches, 'selectedReport': selected_file.name}
(out / 'capture-display.json').write_text(json.dumps(evidence, indent=2) + '\n')
if len(matches) != 1:
    print(json.dumps(evidence))
    raise SystemExit('Capture display index could not be verified uniquely from actual PNG dimensions')
with open(os.environ['GITHUB_ENV'], 'a') as environment:
    environment.write('NEARPANE_FILM_DISPLAY_ID=%s\n' % selected['displayID'])
    environment.write('NEARPANE_FILM_SCREEN_INDEX=%s\n' % matches[0])
print(json.dumps({'ready': True, 'displayID': selected['displayID'], 'screenIndex': matches[0], 'actualPixels': expected}))
