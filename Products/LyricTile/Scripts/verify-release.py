#!/usr/bin/env python3
"""Check the exact release artifacts. Candidate integrity never means published readiness."""
import argparse
import base64
import hashlib
import json
import platform
import plistlib
import re
import subprocess
import tempfile
import xml.etree.ElementTree as ET
import zipfile
from pathlib import Path
from urllib.parse import unquote, urlparse


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--app', type=Path, required=True)
    p.add_argument('--archive', type=Path, required=True)
    p.add_argument('--dmg', type=Path, required=True)
    p.add_argument('--checksums', type=Path, required=True)
    p.add_argument('--expected-commit', required=True)
    p.add_argument('--minimum-build', type=int, default=4, help='New build must be greater than this installed/released build')
    p.add_argument('--appcast', type=Path)
    p.add_argument('--mode', choices=('candidate', 'release'), default='candidate')
    p.add_argument('--output', type=Path, required=True)
    a = p.parse_args()
    checks = []

    def check(name, ok, detail=''):
        checks.append({'check': name, 'passed': bool(ok), 'detail': detail})

    def command(name, args):
        try:
            r = subprocess.run(args, capture_output=True, text=True, timeout=90)
            check(name, r.returncode == 0, (r.stdout + r.stderr).strip()[-2500:])
            return r
        except (OSError, subprocess.TimeoutExpired) as e:
            check(name, False, str(e))
            return None

    info = plistlib.loads((a.app / 'Contents/Info.plist').read_bytes())
    build = info.get('CFBundleVersion', '')
    check('bundle-id', info.get('CFBundleIdentifier') == 'com.holdsnow.lyrictile')
    check('exact-source-commit', bool(re.fullmatch(r'[0-9a-f]{40}', a.expected_commit)) and info.get('LyricTileBuildCommit') == a.expected_commit)
    check('increasing-build', str(build).isdigit() and int(build) > a.minimum_build, f'{build} > {a.minimum_build}')
    check('distribution-floor', info.get('LSMinimumSystemVersion') == '27.0')
    check('version-present', bool(re.fullmatch(r'\d+\.\d+\.\d+', info.get('CFBundleShortVersionString', ''))))
    sums = {}
    for line in a.checksums.read_text().splitlines():
        match = re.fullmatch(r'([0-9a-f]{64})  ([^/\\]+)', line)
        if match:
            sums[match[2]] = match[1]
        elif line.strip():
            check('checksum-file-format', False, line)
    files = {}
    for path in (a.archive, a.dmg):
        data = path.read_bytes()
        digest = hashlib.sha256(data).hexdigest()
        files[path.name] = {'bytes': len(data), 'sha256': digest}
        check('nonempty:' + path.name, bool(data))
        check('checksum:' + path.name, sums.get(path.name) == digest)
    with zipfile.ZipFile(a.archive) as archive:
        members = archive.namelist()
        plist_path = 'LyricTile.app/Contents/Info.plist'
        binary_path = 'LyricTile.app/Contents/MacOS/LyricTile'
        check('archive-root', plist_path in members and binary_path in members)
        if plist_path in members:
            check('archive-metadata-matches-app', plistlib.loads(archive.read(plist_path)) == info)
        if binary_path in members:
            check('archive-executable-matches-app', archive.read(binary_path) == (a.app / 'Contents/MacOS/LyricTile').read_bytes())
        check('archive-crc', archive.testzip() is None)

    signature_verified = False
    if a.appcast:
        ns = '{http://www.andymatuschak.org/xml-namespaces/sparkle}'
        root = ET.parse(a.appcast).getroot()
        items = [item for item in root.findall('./channel/item') if item.find('enclosure') is not None and item.find('enclosure').get(ns + 'version') == str(build)]
        check('appcast-build-present-once', len(items) == 1)
        if len(items) == 1:
            enclosure = items[0].find('enclosure')
            url = urlparse(enclosure.get('url', ''))
            check('appcast-https-download', url.scheme == 'https' and bool(url.hostname) and not url.username and not url.password)
            check('appcast-archive-name', unquote(Path(url.path).name) == a.archive.name)
            check('appcast-archive-size', enclosure.get('length') == str(a.archive.stat().st_size))
            check('appcast-display-version', enclosure.get(ns + 'shortVersionString') == info.get('CFBundleShortVersionString'))
            check('appcast-minimum-os', items[0].findtext(ns + 'minimumSystemVersion') == info.get('LSMinimumSystemVersion'))
            try:
                public_key = base64.b64decode(info.get('SUPublicEDKey', ''), validate=True)
                signature = base64.b64decode(enclosure.get(ns + 'edSignature', ''), validate=True)
                check('update-signature-shape', len(public_key) == 32 and len(signature) == 64)
                if len(public_key) == 32 and len(signature) == 64 and platform.system() == 'Darwin':
                    result = command('update-signature-valid', ['xcrun', 'swift', str(Path(__file__).with_name('verify-update-signature.swift')), str(a.archive), info['SUPublicEDKey'], enclosure.get(ns + 'edSignature')])
                    signature_verified = result is not None and result.returncode == 0
                elif len(public_key) == 32 and len(signature) == 64:
                    with tempfile.TemporaryDirectory(prefix='lyrictile-verify-') as temp:
                        temp = Path(temp)
                        (temp / 'key.der').write_bytes(bytes.fromhex('302a300506032b6570032100') + public_key)
                        (temp / 'signature').write_bytes(signature)
                        result = command('update-signature-valid', ['openssl', 'pkeyutl', '-verify', '-pubin', '-keyform', 'DER', '-inkey', str(temp / 'key.der'), '-rawin', '-in', str(a.archive), '-sigfile', str(temp / 'signature')])
                        signature_verified = result is not None and result.returncode == 0
            except (ValueError, TypeError) as error:
                check('update-signature-shape', False, str(error))
            feed = urlparse(info.get('SUFeedURL', ''))
            check('bundle-update-feed', feed.scheme == 'https' and bool(feed.hostname))
    elif a.mode == 'release':
        check('signed-update-appcast-required', False, 'Pass the actual final appcast, not an empty channel.')

    if platform.system() == 'Darwin':
        mount = command('mount-distribution-dmg', ['hdiutil', 'attach', '-readonly', '-nobrowse', '-plist', str(a.dmg)])
        mounts = []
        try:
            if mount is not None and mount.returncode == 0:
                mounts = [e['mount-point'] for e in plistlib.loads(mount.stdout.encode()).get('system-entities', []) if e.get('mount-point')]
                check('single-dmg-volume', len(mounts) == 1)
                if len(mounts) == 1:
                    mounted_app = Path(mounts[0]) / 'LyricTile.app'
                    mounted_info = plistlib.loads((mounted_app / 'Contents/Info.plist').read_bytes())
                    check('dmg-metadata-matches-app', mounted_info == info)
                    check('dmg-executable-matches-app', (mounted_app / 'Contents/MacOS/LyricTile').read_bytes() == (a.app / 'Contents/MacOS/LyricTile').read_bytes())
                    check('dmg-applications-shortcut', (Path(mounts[0]) / 'Applications').is_symlink())
        except (OSError, ValueError, plistlib.InvalidFileException) as error:
            check('dmg-contents', False, str(error))
        finally:
            for mount_point in mounts:
                command('detach-distribution-dmg', ['hdiutil', 'detach', mount_point])

    if a.mode == 'release':
        check('native-release-verification-host', platform.system() == 'Darwin')
        if platform.system() == 'Darwin':
            command('app-code-signature', ['codesign', '--verify', '--deep', '--strict', str(a.app)])
            r = command('app-signing-details', ['codesign', '-dv', '--verbose=4', str(a.app)])
            check('developer-id-application', r is not None and 'Authority=Developer ID Application:' in r.stderr)
            command('app-notarization-ticket', ['xcrun', 'stapler', 'validate', str(a.app)])
            command('app-gatekeeper', ['spctl', '--assess', '--type', 'execute', '--verbose=4', str(a.app)])
            command('dmg-code-signature', ['codesign', '--verify', '--strict', str(a.dmg)])
            command('dmg-notarization-ticket', ['xcrun', 'stapler', 'validate', str(a.dmg)])
            command('dmg-gatekeeper', ['spctl', '--assess', '--type', 'open', '--context', 'context:primary-signature', '--verbose=4', str(a.dmg)])
    passed = all(c['passed'] for c in checks)
    report = {'schemaVersion': 1, 'status': 'PASS' if passed else 'FAIL', 'mode': a.mode,
              'version': info.get('CFBundleShortVersionString'), 'build': build, 'commit': info.get('LyricTileBuildCommit'),
              'host': platform.platform(), 'files': files, 'updateSignatureVerified': signature_verified,
              'realPlayerQualification': 'NOT_ASSESSED', 'published': False, 'checks': checks}
    a.output.parent.mkdir(parents=True, exist_ok=True)
    a.output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps({key: report[key] for key in ('status', 'mode', 'version', 'build', 'commit', 'published')}))
    return 0 if passed else 1


if __name__ == '__main__':
    raise SystemExit(main())
