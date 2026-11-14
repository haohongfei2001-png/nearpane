#!/usr/bin/env python3
"""Build the two Nearpane helpers' private CPython engine from a pinned PSF release."""
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
from zipfile import ZIP_DEFLATED, ZipFile, ZipInfo

ROOT = Path(__file__).resolve().parents[1]
INPUT = ROOT / 'scripts/helper-runtime'
LOCK = ROOT / 'Dependencies/automation-runtime.json'
PIN = json.loads(LOCK.read_bytes())
CACHE = ROOT / '.build/helper-runtime'
TARGET = '26.0'  # full Nearpane Alpha deployment target
SYSTEM = {'PATH': '/usr/bin:/bin:/usr/sbin:/sbin', 'LC_ALL': 'C', 'MACOSX_DEPLOYMENT_TARGET': TARGET,
          'CC': '/usr/bin/clang', 'CFLAGS': '-O2 -g0', 'PKG_CONFIG': '/usr/bin/false',
          'SOURCE_DATE_EPOCH': str(PIN['sourceDateEpoch']), 'PYTHONHASHSEED': '0'}


def sha(p):
    return hashlib.sha256(p.read_bytes()).hexdigest()


def source_archive():
    archive = CACHE / Path(PIN['source']).name
    if not archive.exists():
        if os.environ.get('NEARPANE_OFFLINE') == '1':
            raise ValueError('Offline build requires the verified CPython archive in .build/helper-runtime')
        with tempfile.NamedTemporaryFile(dir=CACHE) as tmp:
            subprocess.run(['/usr/bin/curl', '--fail', '--location', '--proto', '=https', '--proto-redir', '=https',
                            '--max-time', '180', '-o', tmp.name, PIN['source']], check=True)
            if sha(Path(tmp.name)) != PIN['sha256']:
                raise ValueError('CPython archive does not match the pinned PSF digest')
            shutil.copyfile(tmp.name, archive)
    if sha(archive) != PIN['sha256']:
        raise ValueError(f'Cached CPython archive failed SHA-256; preserved at {archive}')
    return archive


def build(archive, dest):
    with tempfile.TemporaryDirectory(dir=CACHE) as staging:
        work = Path(staging)
        subprocess.run(['/usr/bin/tar', '-xJf', str(archive), '-C', str(work)], check=True)
        src = work / ('Python-' + PIN['version'])
        selected = set((INPUT / 'modules.txt').read_text().split())
        lines = dict((name, name + opts) for name, opts in re.findall(r'^@MODULE_\w+_TRUE@(\w+)( .+)$',
                     (src / 'Modules/Setup.stdlib.in').read_text(), re.M))
        (src / 'Modules/Setup.local').write_text('*static*\n' + '\n'.join(lines[m] for m in sorted(selected)) + '\n')
        shutil.copyfile(INPUT / 'NearpaneAutomation.c', src / 'NearpaneAutomation.c')
        env = {**SYSTEM, 'SDKROOT': subprocess.check_output(['/usr/bin/xcrun', '--sdk', 'macosx', '--show-sdk-path'], text=True).strip()}
        subprocess.run(['./configure', '--disable-shared', '--disable-test-modules', '--without-ensurepip',
                        '--prefix=/nearpane-private-runtime'], cwd=src, env=env, check=True)
        subprocess.run(['/usr/bin/make', '-j' + str(min(os.cpu_count() or 2, 6)), '-f', 'Makefile', '-f',
                        str(INPUT / 'Automation.mk'), 'NearpaneAutomation'], cwd=src, env=env, check=True)
        out = work / 'output'
        out.mkdir()
        executable = out / 'NearpaneAutomation'
        shutil.copyfile(src / executable.name, executable)
        executable.chmod(0o755)
        subprocess.run(['/usr/bin/strip', '-x', str(executable)], check=True)
        subprocess.run(['/usr/bin/codesign', '--force', '--sign', '-', '--identifier', 'com.holdsnow.nearpane.automation', str(executable)], check=True)
        excluded = {'test', 'tests', 'ensurepip', 'site-packages', 'idlelib', 'tkinter', 'turtledemo', 'venv', '__pycache__'}
        with ZipFile(out / 'stdlib.zip', 'w') as z:
            for path in sorted((src / 'Lib').rglob('*.py')):
                rel = path.relative_to(src / 'Lib')
                if excluded.isdisjoint(rel.parts):
                    z.writestr(ZipInfo(rel.as_posix()), path.read_bytes(), compress_type=ZIP_DEFLATED)
        shutil.copyfile(src / 'LICENSE', out / 'PYTHON-LICENSE.txt')
        notices = (src / 'Doc/license.rst').read_text()
        seen = set()
        for folder in ('_hacl', '_sqlite'):
            for file in sorted((src / 'Modules' / folder).rglob('*')):
                if file.suffix not in ('.c', '.h'):
                    continue
                match = re.match(r'/\*.*?\*/', file.read_text(), re.S)
                if match and match[0] not in seen:
                    seen.add(match[0])
                    notices += '\n\n' + str(file.relative_to(src)) + '\n' + match[0]
        (out / 'PYTHON-THIRD-PARTY-NOTICES.rst').write_text(notices)
        shutil.copyfile(LOCK, out / 'source.json')
        (out / 'build.json').write_text(json.dumps(dict(target=TARGET, architecture=os.uname().machine,
            sdk=subprocess.check_output(['/usr/bin/xcrun', '--sdk', 'macosx', '--show-sdk-build-version'], text=True).strip(),
            compiler=subprocess.check_output(['/usr/bin/clang', '--version'], text=True).strip(),
            staticModules=sorted(selected), systemLibraries=['libSystem', 'CoreFoundation', 'libsqlite3', 'libz'],
            modifiedSources=['NearpaneAutomation.c', 'Modules/Setup.local']), sort_keys=True, indent=2))
        (out / 'checksums.json').write_text(json.dumps({p.name: sha(p) for p in out.iterdir()}, sort_keys=True))
        out.rename(dest)


def package(app):
    CACHE.mkdir(parents=True, exist_ok=True)
    files = [LOCK, Path(__file__), *sorted(INPUT.iterdir())]
    sdk = subprocess.check_output(['/usr/bin/xcrun', '--sdk', 'macosx', '--show-sdk-build-version'])
    compiler = subprocess.check_output(['/usr/bin/clang', '--version'])
    key = hashlib.sha256(sdk + compiler + os.uname().machine.encode() + b''.join(bytes.fromhex(sha(p)) for p in files)).hexdigest()
    cached = CACHE / key
    with (CACHE / 'build.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        archive = source_archive()
        if not cached.exists():
            build(archive, cached)
        sums = json.loads((cached / 'checksums.json').read_bytes())
        contents = app / 'Contents'
        resources = contents / 'Resources/Automation'
        resources.mkdir()
        for name in ('NearpaneAutomation', 'stdlib.zip', 'source.json', 'build.json', 'PYTHON-LICENSE.txt', 'PYTHON-THIRD-PARTY-NOTICES.rst'):
            src = cached / name
            if sha(src) != sums[name]:
                raise ValueError(f'Cached automation build failed integrity check: {name}')
            shutil.copy2(src, contents / 'Helpers' / name if name == 'NearpaneAutomation' else resources / name)
    plist = contents / 'Info.plist'
    metadata = plistlib.loads(plist.read_bytes())
    code = ('Helpers/NearpaneAutomation', 'Resources/Automation/stdlib.zip', 'Resources/Profile/profile-migration.py',
            'Resources/Profile/profile_domains.py', 'Resources/WorkRect/window-management.py')
    metadata['NearpaneAutomationSHA256'] = {name: sha(contents / name) for name in code}
    plist.write_bytes(plistlib.dumps(metadata))
    subprocess.run([contents / code[0], '--self-check'], check=True, env={'PATH': '/nonexistent'})


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=Path)
    package(parser.parse_args().app.resolve(strict=True))
