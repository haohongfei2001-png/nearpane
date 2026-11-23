#!/usr/bin/env python3
"""Sign the internal development Host. GUI observations always enter through Launch Services."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import stat
import subprocess
import sys
import tempfile
import uuid

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / 'scripts'))
import candidate_signing as signing

HOST = 'com.holdsnow.nearpane.host'
TEAM = 'ZB9D4T66QB'


def checked(*args):
    return subprocess.check_output(list(map(str, args)), stderr=subprocess.STDOUT, text=True, timeout=90)


def fields(path):
    return dict(re.findall(r'^(CDHash|TeamIdentifier|Identifier)=(.+)$', checked('/usr/bin/codesign', '-dvvv', path), re.M))


def metadata(app):
    data = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    return dict(fields(app), version=data['CFBundleShortVersionString'], build=data['CFBundleVersion'])


def seal(app, survival):
    info = app / 'Contents/Info.plist'
    plist = plistlib.loads(info.read_bytes())
    if plist['CFBundleIdentifier'] != HOST or (plist.get('NearpaneReadOnlyGuardianProtocol') == 1) != survival:
        raise ValueError('unexpected development package or protocol')
    if survival and (plist['NearpaneStageEngineSourceState'] != 'clean' or
                     plist['NearpaneStageEngineSourceRevision'] != checked('git', '-C', ROOT, 'rev-parse', 'HEAD').strip()):
        raise ValueError('build the internal package from the current clean source revision')
    fingerprint = signing.product_fingerprint(checked('/usr/bin/security', 'find-identity', '-v', '-p', 'codesigning'))
    components = {}

    def sign(path, identifier):
        checked('/usr/bin/codesign', '--force', '--sign', fingerprint, '--options', 'runtime', '--timestamp=none',
                '--preserve-metadata=entitlements', '--identifier', identifier, path)
        checked('/usr/bin/codesign', '--verify', '--strict', '--all-architectures', path)
        identity = fields(path)
        if identity.get('TeamIdentifier') != TEAM or identity.get('Identifier') != identifier:
            raise ValueError('unexpected signer for ' + path.name)
        components[str(path.relative_to(app))] = identity

    helpers = app / 'Contents/Helpers'
    expected = {'NearpaneDesktopReader', 'NearpaneOrdinaryWindowController', 'NearpaneSpaceAction', 'NearpaneCornerGuardian'}
    if {p.name for p in helpers.iterdir()} != expected:
        raise ValueError('unexpected helper inventory')
    for name in sorted(expected):
        path = helpers / name
        if path.resolve(strict=True) != path or not path.is_file() or signing.sha(path) != plist[name + 'SHA256']:
            raise ValueError('unexpected helper bytes or path')
        identifier = (HOST if survival else 'com.holdsnow.nearpane.alpha') + '.corner-guardian' if name == 'NearpaneCornerGuardian' else name
        sign(path, identifier)
        plist[name + 'SHA256'] = signing.sha(path)
    info.write_bytes(plistlib.dumps(plist))
    for relative, identifier in signing.gate.update_runtime.COMPONENTS:
        sign(app / relative, identifier)
    sign(app, HOST)
    checked('/usr/bin/codesign', '--verify', '--strict', '--deep', '--all-architectures', app)
    checked(sys.executable, '-B', ROOT / 'scripts/verify-packages.py', '--static-only', app)
    resources = (app / 'Contents/_CodeSignature/CodeResources').read_bytes()
    if not plistlib.loads(resources).get('files2'):
        raise ValueError('missing resource envelope')
    return dict(status='PASS', host=metadata(app), components=components, source=plist['NearpaneStageEngineSourceRevision'],
                protocol=plist.get('NearpaneReadOnlyGuardianProtocol'), visibleRecoveryProtocol=plist.get('NearpaneVisibleFixtureRecoveryProtocol'), engineABI=plist['NearpaneStageEngineABI'],
                codeResourcesSHA256=hashlib.sha256(resources).hexdigest(), deepStrictAllArchitectures=True,
                staticPackageVerification=True, app=str(app))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('development_app', type=Path)
    parser.add_argument('output', type=Path, help='fresh evidence directory')
    parser.add_argument('--seal-survival', action='store_true', help='seal the freshly built private read-only package without launching')
    args = parser.parse_args()
    source, out = args.development_app.resolve(strict=True), args.output.resolve()
    if args.seal_survival:
        d = source.parent
        if (source.name != 'Nearpane.app' or d.parent != Path('/private/tmp') or not d.name.startswith('nearpane-stage-engine-dev.')
                or stat.S_IMODE(d.stat().st_mode) != 0o700 or d.stat().st_uid != os.getuid() or source != args.development_app.absolute()):
            parser.error('expected a freshly built package in its owner-only internal build directory')
        app = source
    else:
        if ROOT / 'build' not in source.parents or metadata(source)['Identifier'] != HOST:
            parser.error('an existing Nearpane development build is required')
        app = Path(tempfile.mkdtemp(dir='/private/tmp', prefix='nearpane-stage-engine-dev.')) / 'Nearpane.app'
        checked('/usr/bin/ditto', '--rsrc', '--extattr', '--qtn', source, app)
    out.mkdir(mode=0o700, parents=True, exist_ok=False)
    evidence = {'status': 'UNKNOWN', 'scope': 'internalDevelopmentSigning', 'productionQualified': False}
    try:
        evidence.update(seal(app, args.seal_survival))
        if not args.seal_survival:
            challenge = str(uuid.uuid4())
            stdout, stderr = app.parent / 'probe.json', app.parent / 'probe.stderr'
            checked('/usr/bin/open', '-g', '-W', '-a', app, '--stdin', '/dev/null', '--stdout', stdout,
                    '--stderr', stderr, '--args', '--probe-stage-window-engine', challenge)
            observed = json.loads(stdout.read_bytes())
            if (observed.get('challenge') != challenge or observed.get('closed') is not True or
                    {row['backend'] for row in observed['engines'] if row.get('unqualifiedWriteRefused') is True} != {'corner', 'spaces'}):
                raise ValueError('uncorrelated Launch Services response')
            evidence['engineBoundary'] = observed
        (out / 'local-app-path.txt').write_text(str(app) + '\n')
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        evidence.update(status='BLOCKED', reason=str(error), detail=getattr(error, 'output', '')[-1200:])
        raise
    finally:
        (out / 'target.json').write_text(json.dumps(evidence, indent=2) + '\n')


if __name__ == '__main__':
    main()
