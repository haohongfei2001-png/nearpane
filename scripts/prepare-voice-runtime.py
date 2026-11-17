#!/usr/bin/env python3
"""Embed only the pinned local recognizer, Metal library and notices from Saytile's public release."""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
PIN = json.loads((ROOT / 'Dependencies/voice-runtime.json').read_text())
WORKER = 'Helpers/SaytileModelWorker'
KEY = 'NearpaneVoiceRuntimeSHA256'


def sha(path):
    result = hashlib.sha256()
    with path.open('rb') as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b''):
            result.update(chunk)
    return result.hexdigest()


def verify(contents, worker_hash):
    for relative, original in PIN['files'].items():
        item = contents / relative
        if item.resolve() != item or not item.is_file() or sha(item) != (worker_hash if relative == WORKER else original):
            raise ValueError('Unexpected local speech runtime: ' + relative)
    subprocess.run(['/usr/bin/codesign', '--verify', '--strict', contents / WORKER], check=True)


def embed(app, cache):
    pin = json.loads((ROOT / 'Dependencies/domains.lock.json').read_text())['domains']['saytile']
    if pin['commit'] != PIN['sourceCommit'] or pin['releaseTag'] != PIN['release']:
        raise ValueError('Pin the voice runtime to the same Saytile release as the speech core')
    cache.mkdir(parents=True, exist_ok=True)
    with (cache / 'prepare.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        source = cache / PIN['sha256']
        if not source.exists():
            archive = cache / PIN['filename']
            if not archive.exists():
                if os.getenv('NEARPANE_OFFLINE') == '1':
                    raise ValueError('Pinned public Saytile release is missing from the offline cache')
                with tempfile.NamedTemporaryFile(dir=cache) as download:
                    subprocess.run(['/usr/bin/curl', '--http1.1', '-fsSL', '--proto', '=https', '--proto-redir', '=https',
                                    '--connect-timeout', '15', '--max-time', '240', '-H', 'Accept: application/octet-stream',
                                    '-o', download.name, PIN['url']], check=True)
                    if sha(Path(download.name)) != PIN['sha256']:
                        raise ValueError('Downloaded Saytile release digest mismatch')
                    shutil.copyfile(download.name, archive)
            if sha(archive) != PIN['sha256']:
                raise ValueError('Pinned Saytile release digest mismatch')
            with tempfile.TemporaryDirectory(dir=cache) as work:
                mount = Path(work) / 'mount'
                mount.mkdir()
                subprocess.run(['/usr/bin/hdiutil', 'attach', '-readonly', '-nobrowse', '-noautoopen',
                                '-mountpoint', mount, archive], check=True, stdout=subprocess.DEVNULL)
                try:
                    [bundle] = list(mount.glob('*.app'))
                    contents = bundle / 'Contents'
                    verify(contents, PIN['files'][WORKER])
                    stage = Path(work) / 'runtime'
                    for relative in PIN['files']:
                        target = stage / relative
                        target.parent.mkdir(parents=True, exist_ok=True)
                        shutil.copy2(contents / relative, target)
                    stage.rename(source)
                finally:
                    subprocess.run(['/usr/bin/hdiutil', 'detach', mount], check=True, stdout=subprocess.DEVNULL)
        verify(source, PIN['files'][WORKER])
        contents = app.resolve() / 'Contents'
        for relative in PIN['files']:
            target = contents / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source / relative, target)
        plist = contents / 'Info.plist'
        info = plistlib.loads(plist.read_bytes())
        info[KEY] = PIN['files'][WORKER]
        plist.write_bytes(plistlib.dumps(info))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=Path)
    args = parser.parse_args()
    run = os.getenv('NEARPANE_RUN_ID', '')
    if run and not re.fullmatch(r'[A-Za-z0-9_-]{1,64}', run):
        parser.error('Invalid isolated run ID')
    cache = ROOT / (f'build/standalone.{run}/cache/voice-runtime' if run else '.build/voice-runtime')
    embed(args.app, cache)
