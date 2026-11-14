#!/usr/bin/env python3
"""Verify and embed the exact upstream Sparkle binary. No updater credentials or publication."""
import argparse
import base64
import fcntl
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import stat
import subprocess
import tempfile
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parent.parent
PIN = json.loads((ROOT / 'Dependencies/update-runtime.json').read_text())
FEED_URL = 'https://github.com/haohongfei2001-png/nearpane/releases/latest/download/appcast.xml'
RUN = os.environ.get('NEARPANE_RUN_ID', '')
if RUN and not re.fullmatch(r'[A-Za-z0-9_-]{1,64}', RUN):
    raise ValueError('Invalid isolated run ID')
CACHE = ROOT / (f'build/standalone.{RUN}/cache/update-runtime' if RUN else '.build/update-runtime')
FRAMEWORK = 'Contents/Frameworks/Sparkle.framework'
BASE = FRAMEWORK + '/Versions/B/'
COMPONENTS = (
    (BASE + 'XPCServices/Installer.xpc', 'org.sparkle-project.InstallerLauncher'),
    (BASE + 'XPCServices/Downloader.xpc', 'org.sparkle-project.DownloaderService'),
    (BASE + 'Autoupdate', 'org.sparkle-project.Sparkle.Autoupdate'),
    (BASE + 'Updater.app', 'org.sparkle-project.Sparkle.Updater'),
    (FRAMEWORK, 'org.sparkle-project.Sparkle'),
)
EXECUTABLES = (
    BASE + 'XPCServices/Installer.xpc/Contents/MacOS/Installer',
    BASE + 'XPCServices/Downloader.xpc/Contents/MacOS/Downloader',
    BASE + 'Autoupdate', BASE + 'Updater.app/Contents/MacOS/Updater', BASE + 'Sparkle',
)


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def framework_digest(source):
    rows = []
    for path in sorted(source.rglob('*')):
        mode = path.lstat().st_mode
        if stat.S_ISLNK(mode):
            kind, value = 'symlink', os.readlink(path)
            if source.resolve() not in path.resolve(strict=True).parents:
                raise ValueError('Sparkle link leaves its framework')
        elif stat.S_ISDIR(mode):
            kind, value = 'directory', ''
        elif stat.S_ISREG(mode):
            kind, value = 'file', sha(path)
        else:
            raise ValueError('Unexpected Sparkle file type')
        rows.append([path.relative_to(source).as_posix(), kind, value])
    return hashlib.sha256(json.dumps(rows, separators=(',', ':')).encode()).hexdigest()


def prepare(offline=False):
    CACHE.mkdir(parents=True, exist_ok=True)
    archive = CACHE / f"Sparkle-{PIN['version']}.zip"
    target = CACHE / 'Sparkle.xcframework'
    with (CACHE / 'prepare.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if not archive.exists():
            if offline:
                raise ValueError('Pinned Sparkle archive missing in offline mode')
            with tempfile.NamedTemporaryFile(dir=CACHE, suffix='.download') as output:
                with urllib.request.urlopen(PIN['url'], timeout=60) as response:
                    if not response.url.startswith('https://'):
                        raise ValueError('Sparkle download left HTTPS')
                    shutil.copyfileobj(response, output)
                output.flush()
                if sha(Path(output.name)) != PIN['sha256']:
                    raise ValueError('Sparkle archive SHA-256 mismatch')
                shutil.copyfile(output.name, archive)
        if sha(archive) != PIN['sha256']:
            raise ValueError('Cached Sparkle archive SHA-256 mismatch')
        if not target.exists():
            with tempfile.TemporaryDirectory(dir=CACHE) as work:
                subprocess.run(['/usr/bin/ditto', '-x', '-k', str(archive), work], check=True)
                unpacked = Path(work) / 'Sparkle.xcframework'
                source = unpacked / 'macos-arm64_x86_64/Sparkle.framework'
                if framework_digest(source) != PIN['frameworkSHA256']:
                    raise ValueError('Sparkle framework content mismatch')
                unpacked.rename(target)
        source = target / 'macos-arm64_x86_64/Sparkle.framework'
        if framework_digest(source) != PIN['frameworkSHA256']:
            raise ValueError('Cached Sparkle framework content mismatch')
        with zipfile.ZipFile(archive) as package:
            license_text = package.read('LICENSE')
        if hashlib.sha256(license_text).hexdigest() != PIN['licenseSHA256']:
            raise ValueError('Sparkle license fingerprint mismatch')
        license_file = CACHE / 'LICENSE'
        if license_file.exists() and license_file.read_bytes() != license_text:
            raise ValueError('Cached Sparkle license fingerprint mismatch')
        if not license_file.exists():
            license_file.write_bytes(license_text)
        return source


def validate_layout(app):
    framework = app / FRAMEWORK
    if not framework.is_dir() or framework.is_symlink():
        raise ValueError('Missing embedded Sparkle framework')
    links = {name: 'Versions/Current/' + name for name in (
        'Autoupdate', 'Headers', 'Modules', 'PrivateHeaders', 'Resources', 'Sparkle', 'Updater.app', 'XPCServices')}
    links['Versions/Current'] = 'B'
    for name, target in links.items():
        path = framework / name
        if not path.is_symlink() or os.readlink(path) != target or not path.exists():
            raise ValueError('Unexpected Sparkle link: ' + name)
    for relative in EXECUTABLES:
        path = app / relative
        if path.is_symlink() or not path.is_file() or not path.stat().st_mode & 0o111:
            raise ValueError('Missing Sparkle executable: ' + relative)
    for component, identifier in COMPONENTS:
        path = app / component
        if path.is_file():
            continue
        plist = path / ('Versions/B/Resources/Info.plist' if component == FRAMEWORK else 'Contents/Info.plist')
        info = plistlib.loads(plist.read_bytes())
        if info.get('CFBundleIdentifier') != identifier or info.get('CFBundleShortVersionString') != PIN['version']:
            raise ValueError('Unexpected Sparkle identity: ' + component)
    provenance = json.loads((app / 'Contents/Resources/Updates/source.json').read_text())
    if provenance != PIN:
        raise ValueError('Unexpected Sparkle provenance')
    if sha(app / 'Contents/Resources/Updates/SPARKLE-LICENSE.txt') != PIN['licenseSHA256']:
        raise ValueError('Missing or modified Sparkle license')


def embed(app, source):
    target = app / FRAMEWORK
    target.parent.mkdir(exist_ok=True)
    shutil.copytree(source, target, symlinks=True)
    resources = app / 'Contents/Resources/Updates'
    resources.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(ROOT / 'Dependencies/update-runtime.json', resources / 'source.json')
    shutil.copyfile(CACHE / 'LICENSE', resources / 'SPARKLE-LICENSE.txt')
    info_path = app / 'Contents/Info.plist'
    info = plistlib.loads(info_path.read_bytes())
    if info.get('CFBundleIdentifier') not in ('com.holdsnow.nearpane.host', 'com.holdsnow.nearpane.alpha'):
        raise ValueError('Updater can only be embedded in Nearpane')
    info.update({'SUFeedURL': FEED_URL, 'SURequireSignedFeed': True,
                 'SUVerifyUpdateBeforeExtraction': True, 'SUSignedFeedFailureExpirationInterval': 0,
                 'SUAllowsAutomaticUpdates': False, 'SUAutomaticallyUpdate': False,
                 'SUEnableAutomaticChecks': False, 'SUScheduledCheckInterval': 86400,
                 'SUEnableSystemProfiling': False, 'SUEnableJavaScript': False})
    if 'SUPublicEDKey' in info:
        key = base64.b64decode(info['SUPublicEDKey'], validate=True)
        if len(key) != 32 or not any(key):
            raise ValueError('Invalid Nearpane public update key')
    info_path.write_bytes(plistlib.dumps(info))
    host = app / 'Contents/MacOS/NearpaneHost'
    load = subprocess.check_output(['/usr/bin/otool', '-l', host], text=True)
    paths = set(re.findall(r'cmd LC_RPATH\s+cmdsize \d+\s+path (.+?) \(offset', load))
    allowed = {'@executable_path/../Frameworks', '/usr/lib/swift'}
    if '@executable_path/../Frameworks' not in paths:
        raise ValueError('Host lacks embedded framework runpath')
    extra = paths - allowed
    if extra:
        args = [value for path in sorted(extra) for value in ('-delete_rpath', path)]
        subprocess.run(['/usr/bin/install_name_tool', *args, host], check=True)
    validate_layout(app)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--offline', action='store_true')
    parser.add_argument('--embed', type=Path)
    parser.add_argument('--sign-development', action='store_true', help='Seal embedded Sparkle children with local ad-hoc identities')
    args = parser.parse_args()
    try:
        source = prepare(args.offline)
        if args.embed:
            embed(args.embed, source)
            if args.sign_development:
                for relative, identifier in COMPONENTS:
                    subprocess.run(['/usr/bin/codesign', '--force', '--sign', '-', '--timestamp=none',
                                    '--identifier', identifier, str(args.embed / relative)], check=True)
        elif args.sign_development:
            raise ValueError('--sign-development requires --embed')
        print(json.dumps({'version': PIN['version'], 'sha256': PIN['sha256'], 'framework': str(source)}))
    except (OSError, ValueError, subprocess.CalledProcessError) as exc:
        parser.exit(1, str(exc) + '\n')
