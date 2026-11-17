#!/usr/bin/env python3
"""Replay one public FLEURS sample through Nearpane's packaged, isolated Mandarin voice panel."""
import argparse
from pathlib import Path
import hashlib
import json
import os
import plistlib
import shutil
import subprocess
import uuid

ROOT = Path(__file__).resolve().parents[2]
SAMPLE = '95dae2e6509dac2af6b35149dbd46978e2a5bfd480d3604282a1a092606ff0ea'

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('app', type=Path)
parser.add_argument('wav', type=Path, help='FLEURS zh-CN, fleurs-c1fcf0cd023db10f, mono PCM16 WAV')
parser.add_argument('model', type=Path, help='verified Qwen 0.6B model revision directory')
args = parser.parse_args()
app = args.app.resolve(strict=True)
exe = app / 'Contents/MacOS/NearpaneHost'
if args.wav.stat().st_size != 496044 or hashlib.sha256(args.wav.read_bytes()).hexdigest() != SAMPLE:
    parser.error('Only the specified public 16 kHz sample is accepted')
manifest = json.loads((app / 'Contents/Resources/LocalASR/qwen-small.json').read_text())
session = str(uuid.uuid4())
directory = ROOT / 'build/native-acceptance' / session
env = dict(os.environ, NEARPANE_ACCEPTANCE_CHECKOUT=str(ROOT))
cmd = [str(exe), '--verify-bundled-resources']
info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
prepare = '--native-acceptance-prepare-draft' if info['CFBundleIdentifier'] == 'com.holdsnow.nearpane.alpha' else '--native-acceptance-prepare'
subprocess.run([*cmd, prepare, session], cwd=ROOT, env=env, check=True)
shutil.copyfile(args.wav, directory / 'public-mandarin.wav')
destination = directory / 'MandarinFixture/Nearpane/Voice/LocalModels/qwen-small' / manifest['revision']
destination.mkdir(mode=0o700, parents=True)
for entry in manifest['files']:
    src = args.model / entry['path']
    if src.is_symlink() or not src.is_file() or src.stat().st_size != entry['bytes']:
        parser.error('Missing pinned model file: ' + entry['path'])
    out = destination / entry['path']
    if subprocess.run(['/bin/cp', '-c', src, out], stderr=subprocess.DEVNULL).returncode:
        shutil.copyfile(src, out)
result = subprocess.run([*cmd, '--native-local-mandarin', session], cwd=ROOT, capture_output=True, text=True, env=env)
if result.returncode:
    raise SystemExit(result.stdout + result.stderr)
[record] = [line for line in result.stdout.splitlines() if line.startswith('{')]
receipt = json.loads(record)
receipt['sourceSHA'] = subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True, cwd=ROOT).strip()
receipt['executableSHA256'] = hashlib.sha256(exe.read_bytes()).hexdigest()
receipt['modelRevision'] = manifest['revision']
(directory / 'mandarin-receipt.json').write_text(json.dumps(receipt, ensure_ascii=False, indent=2) + '\n')
print(json.dumps(receipt, ensure_ascii=False))
print(directory)
