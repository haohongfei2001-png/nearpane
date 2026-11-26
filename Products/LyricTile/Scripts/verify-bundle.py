#!/usr/bin/env python3
"""Inspect actual bundle objects. This is not a real-player or release qualification."""
import argparse
import json
import platform
import plistlib
import subprocess
from pathlib import Path

p = argparse.ArgumentParser()
p.add_argument('app', type=Path)
p.add_argument('--architecture', required=True, choices=['arm64', 'x86_64'])
p.add_argument('--output', type=Path, required=True)
a = p.parse_args()
info = plistlib.loads((a.app/'Contents/Info.plist').read_bytes())
checks = []
def check(name, passed, detail=''):
    checks.append(dict(check=name, passed=bool(passed), detail=detail))
def command(*args):
    r = subprocess.run(args, capture_output=True, text=True)
    return r.returncode, (r.stdout+r.stderr).strip()
check('independent-bundle-id', info.get('CFBundleIdentifier') == 'com.holdsnow.lyrictile')
check('distribution-os-floor', info.get('LSMinimumSystemVersion') == '27.0')
check('automation-purpose', bool(info.get('NSAppleEventsUsageDescription')))
required = [
    'Contents/MacOS/LyricTile', 'Contents/Resources/LyricTile.icns',
    'Contents/Frameworks/Sparkle.framework/Sparkle',
    'Contents/Resources/MediaRemote/mediaremote-adapter.pl',
    'Contents/Resources/MediaRemote/MediaRemoteAdapter.framework/MediaRemoteAdapter',
    'Contents/Resources/MediaRemote/LICENSE', 'Contents/Resources/MediaRemote/SOURCE.json',
    'Contents/Resources/Notices/Yams-LICENSE', 'Contents/Resources/Notices/Sparkle-LICENSE',
    'Contents/Resources/Notices/mediaremote-adapter-LICENSE',
]
for relative in required:
    target = a.app/relative
    check('required:'+relative, target.is_file() and target.stat().st_size > 0)
for relative in [required[0], required[2], required[4]]:
    code, text = command('lipo', '-archs', str(a.app/relative))
    check('architecture:'+relative, code == 0 and a.architecture in text.split(), text)
code, text = command('codesign', '--verify', '--deep', '--strict', str(a.app))
check('signature-integrity', code == 0, text)
code, text = command('codesign', '-dv', '--verbose=4', str(a.app))
identity = 'ad-hoc' if 'Signature=adhoc' in text else 'developer-id-or-other'
code, entitlements = command('codesign', '-d', '--entitlements', ':-', str(a.app))
check('apple-events-entitlement', code == 0 and 'com.apple.security.automation.apple-events' in entitlements)
check('no-app-sandbox', 'com.apple.security.app-sandbox' not in entitlements)
code, text = command('otool', '-l', str(a.app/required[0]))
check('bundle-framework-rpath', code == 0 and '@executable_path/../Frameworks' in text)
report = dict(schemaVersion=1, status='PASS' if all(x['passed'] for x in checks) else 'FAIL',
              app=str(a.app), commit=info.get('LyricTileBuildCommit'), host=platform.platform(),
              signingIdentity=identity, realPlayerQualification='NOT_RUN', notarization='NOT_RUN', checks=checks)
a.output.parent.mkdir(parents=True, exist_ok=True)
a.output.write_text(json.dumps(report, ensure_ascii=False, indent=2)+'\n')
print(json.dumps({k:report[k] for k in ['status','commit','signingIdentity','realPlayerQualification']}))
raise SystemExit(0 if report['status']=='PASS' else 1)
