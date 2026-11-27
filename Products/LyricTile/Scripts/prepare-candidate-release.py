#!/usr/bin/env python3
"""Prepare one unpublished engineering draft from a successful native CI artifact.

Default: validate with read-only GitHub API calls; --apply enables draft writes.
Offline: --dry-run --artifact-directory /path/to/downloaded/artifact (contains dist/).
Offline results never claim that GitHub run/release state was verified.
Authentication: standard GH_TOKEN/GITHUB_TOKEN only; never log or persist it.
"""
import argparse
import hashlib
import io
import json
import os
from pathlib import Path
import plistlib
import re
import struct
import sys
import tempfile
from urllib import error, parse, request
import zipfile


REPOSITORY = 'haohongfei2001-png/nearpane'
BRANCH = 'codex/lyrictile-standalone-20261126'
NATIVE_WORKFLOW = '.github/workflows/lyrictile.yml'
MARKER = '<!-- lyrictile-managed-engineering-draft-v1 -->'
MAX_ARCHIVE = 512 * 1024 * 1024
MAX_REPORT = 1024 * 1024


class Rejected(Exception):
    pass


def require(condition, message):
    if not condition:
        raise Rejected(message)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def encoded(value):
    return (json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + '\n').encode()


def manifest_at(path):
    value = json.loads(path.read_text())
    require(value.get('schemaVersion') == 1 and type(value.get('enabled')) is bool,
            'Manifest needs schemaVersion 1 and an explicit enabled boolean.')
    require(value.get('repository') == REPOSITORY and value.get('branch') == BRANCH,
            'This helper is restricted to the LyricTile development branch and repository.')
    if not value['enabled']:
        return value
    require(re.fullmatch(r'\d+\.\d+\.\d+', value.get('version') or ''), 'Invalid version.')
    require(type(value.get('build')) is int and value['build'] > 4, 'Pin a build greater than 4.')
    require(type(value.get('runID')) is int and value['runID'] > 0, 'Pin the successful native run ID.')
    require(re.fullmatch(r'[0-9a-f]{40}', value.get('sourceCommit') or ''), 'Pin the exact source SHA.')
    require(value.get('artifactName') == f"LyricTile-candidate-{value['build']}",
            'Artifact name must match the pinned native build exactly.')
    return value


class NoRedirect(request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


class GitHub:
    def __init__(self):
        token = os.environ.get('GH_TOKEN') or os.environ.get('GITHUB_TOKEN')
        require(bool(token), 'Set the standard GitHub Actions token for online verification.')
        self.headers = {'Accept': 'application/vnd.github+json', 'Authorization': 'Bearer ' + token,
                        'X-GitHub-Api-Version': '2026-03-10', 'User-Agent': 'LyricTile-draft-preparation'}
        self.opener = request.build_opener(NoRedirect())

    def api(self, path, method='GET', payload=None, missing_ok=False, upload=None):
        url = 'https://api.github.com/repos/' + REPOSITORY + path
        headers = dict(self.headers)
        data = encoded(payload) if payload is not None else None
        if payload is not None:
            headers['Content-Type'] = 'application/json'
        if upload is not None:
            url, data = upload
            parsed = parse.urlparse(url)
            require(parsed.scheme == 'https' and parsed.hostname == 'uploads.github.com'
                    and parsed.path.startswith('/repos/' + REPOSITORY + '/releases/'),
                    'Unexpected release upload endpoint.')
            headers['Content-Type'] = 'application/octet-stream'
        try:
            with self.opener.open(request.Request(url, data=data, headers=headers, method=method), timeout=90) as response:
                return json.load(response)
        except error.HTTPError as exc:
            if missing_ok and exc.code == 404:
                return None
            raise Rejected(f'GitHub {method} {path} returned HTTP {exc.code}. No alternate credentials or permissions were attempted.') from None
        except error.URLError:
            raise Rejected('GitHub API connection failed; retry the same authorized workflow.') from None

    def pages(self, path, key=None):
        result = []
        for page in range(1, 101):
            response = self.api(f'{path}?per_page=100&page={page}')
            values = response[key] if key else response
            result.extend(values)
            if len(values) < 100:
                return result
        raise Rejected('Unexpected pagination size; no mutation performed.')

    def download(self, path, destination):
        headers = dict(self.headers, Accept='application/octet-stream')
        url = 'https://api.github.com/repos/' + REPOSITORY + path
        try:
            try:
                response = self.opener.open(request.Request(url, headers=headers), timeout=90)
            except error.HTTPError as exc:
                if exc.code != 302:
                    raise Rejected(f'GitHub artifact/asset download returned HTTP {exc.code}.') from None
                location = exc.headers.get('Location', '')
                parsed = parse.urlparse(location)
                require(parsed.scheme == 'https' and parsed.hostname and not parsed.username and not parsed.password,
                        'Artifact download redirect must use HTTPS.')
                # Signed storage URLs are fetched without the GitHub Authorization header.
                response = self.opener.open(request.Request(location), timeout=90)
            total = 0
            with response, destination.open('wb') as output:
                while chunk := response.read(1024 * 1024):
                    total += len(chunk)
                    require(total <= MAX_ARCHIVE, 'Artifact/asset exceeds the bounded download size.')
                    output.write(chunk)
        except (error.HTTPError, error.URLError):
            raise Rejected('Artifact/asset HTTPS download failed; signed storage URLs are not logged.') from None


def verify_run(api, manifest):
    run = api.api(f"/actions/runs/{manifest['runID']}")
    require(run.get('id') == manifest['runID'] and run.get('run_number') == manifest['build'], 'Run ID/build mismatch.')
    require(run.get('status') == 'completed' and run.get('conclusion') == 'success', 'Native run has not succeeded.')
    require(run.get('head_sha') == manifest['sourceCommit'] and run.get('head_branch') == BRANCH,
            'Native run source/branch mismatch.')
    require(run.get('head_repository', {}).get('full_name') == REPOSITORY, 'Native run belongs to a different source repository.')
    workflow = api.api(f"/actions/workflows/{run['workflow_id']}")
    require(workflow.get('path') == NATIVE_WORKFLOW, 'Pinned run is not the native LyricTile workflow.')
    matches = [item for item in api.pages(f"/actions/runs/{manifest['runID']}/artifacts", 'artifacts')
               if item.get('name') == manifest['artifactName']]
    require(len(matches) == 1 and matches[0].get('expired') is False, 'Need exactly one unexpired artifact with the pinned name.')
    artifact = matches[0]
    provenance = artifact.get('workflow_run', {})
    require(provenance.get('id') == manifest['runID'] and provenance.get('head_sha') == manifest['sourceCommit']
            and provenance.get('head_branch') == BRANCH, 'Artifact run/source/branch mismatch.')
    return run, artifact


class Artifact:
    def __init__(self, source):
        self.directory = source.resolve() if source.is_dir() else None
        self.archive = None if self.directory else zipfile.ZipFile(source)
        self.names = ([str(p.relative_to(self.directory)) for p in self.directory.rglob('*') if p.is_file()]
                      if self.directory else self.archive.namelist())
        require(len(self.names) == len(set(self.names)), 'Duplicate artifact member paths.')

    def read(self, name, limit=MAX_ARCHIVE):
        require(name in self.names, 'Missing artifact member: ' + name)
        if self.directory:
            path = (self.directory / name).resolve()
            require(path.is_relative_to(self.directory) and path.stat().st_size <= limit, 'Invalid local artifact member.')
            return path.read_bytes()
        require(self.archive.getinfo(name).file_size <= limit, 'Oversized artifact member: ' + name)
        return self.archive.read(name)

    def report(self, name, optional=False):
        if optional and name not in self.names:
            return {'status': 'NOT_RECORDED'}
        return json.loads(self.read(name, MAX_REPORT))


def validated_assets(artifact, manifest):
    stem = f"LyricTile-{manifest['version']}-{manifest['build']}-candidate-arm64"
    assets = {name: artifact.read('dist/' + name) for name in (stem + '.zip', stem + '.dmg', 'SHA256SUMS')}
    sums = {}
    for line in assets['SHA256SUMS'].decode().splitlines():
        match = re.fullmatch(r'([0-9a-f]{64})  ([^/\\]+)', line)
        require(match is not None and match[2] not in sums, 'Malformed or duplicate checksum entry.')
        sums[match[2]] = match[1]
    require(set(sums) == {stem + '.zip', stem + '.dmg'}, 'Checksum file must cover exactly the pinned ZIP and DMG.')
    for name, expected in sums.items():
        require(bool(assets[name]) and digest(assets[name]) == expected, 'Candidate checksum mismatch: ' + name)
    report = artifact.report('dist/evidence/release-integrity.json')
    require(report.get('status') == 'PASS' and report.get('mode') == 'candidate' and report.get('published') is False,
            'Native candidate integrity did not pass.')
    require(report.get('commit') == manifest['sourceCommit'] and str(report.get('build')) == str(manifest['build'])
            and report.get('version') == manifest['version'], 'Integrity report source/version/build mismatch.')
    checks = report.get('checks', [])
    required = {'exact-source-commit', 'bundle-id', 'archive-metadata-matches-app', 'archive-executable-matches-app',
                'archive-crc', 'mount-distribution-dmg', 'dmg-metadata-matches-app', 'dmg-executable-matches-app',
                'dmg-applications-shortcut', 'detach-distribution-dmg'}
    require(checks and all(item.get('passed') is True for item in checks)
            and required <= {item.get('check') for item in checks}, 'Incomplete or failed native integrity checks.')
    require(set(report.get('files', {})) == set(sums), 'Integrity report package list mismatch.')
    for name, expected in sums.items():
        require(report['files'][name] == {'bytes': len(assets[name]), 'sha256': expected}, 'Integrity report bytes/hash mismatch.')
    bundle = artifact.report('dist/bundle-verification.json')
    require(bundle.get('status') == 'PASS' and bundle.get('commit') == manifest['sourceCommit']
            and bundle.get('signingIdentity') == 'ad-hoc' and bundle.get('notarization') == 'NOT_RUN',
            'Expected the original ad-hoc engineering candidate, not a differently signed package.')
    with zipfile.ZipFile(io.BytesIO(assets[stem + '.zip'])) as app:
        names = app.namelist()
        require(len(names) == len(set(names)) and sum(i.file_size for i in app.infolist()) <= MAX_ARCHIVE,
                'Invalid candidate archive structure/size.')
        require(app.testzip() is None, 'Candidate archive CRC failed.')
        info = plistlib.loads(app.read('LyricTile.app/Contents/Info.plist'))
        expected = {'CFBundleIdentifier': 'com.holdsnow.lyrictile', 'CFBundleShortVersionString': manifest['version'],
                    'CFBundleVersion': str(manifest['build']), 'LyricTileBuildCommit': manifest['sourceCommit'],
                    'LSMinimumSystemVersion': '27.0', 'LyricTileDistributionChannel': 'candidate'}
        require(all(info.get(k) == v for k, v in expected.items()), 'Actual ZIP bundle metadata differs from the manifest.')
        binary = app.read('LyricTile.app/Contents/MacOS/LyricTile')
        require(len(binary) >= 8 and struct.unpack('<II', binary[:8]) == (0xfeedfacf, 0x0100000c),
                'Candidate executable is not the expected native arm64 Mach-O.')
    assets['release-integrity.json'] = artifact.read('dist/evidence/release-integrity.json', MAX_REPORT)
    return assets


def evidence_zip(artifact, manifest, remote):
    exact = {'dist/bundle-verification.json', 'dist/evidence/native-smoke.json', 'dist/evidence/host.txt',
             'dist/evidence/signing-identities.txt', 'dist/evidence/media-helper-load.json',
             'dist/evidence/live-lyrics.json', 'dist/evidence/release-integrity.json',
             'dist/evidence/website-integrity.json', 'dist/evidence/idle/idle-check.json',
             'dist/evidence/idle/idle-samples/summary.json', 'dist/evidence/real-music/cloud-music.json',
             'dist/evidence/real-music/native-player.json', 'dist/evidence/real-music/cloud-desktop-capture.json',
             'dist/evidence/real-music/media-provenance.json', 'dist/evidence/cloud-clients/cloud-clients.json'}
    patterns = [r'dist/evidence/native-[^/]+\.png', r'dist/evidence/layout/fixture-[^/]+\.(png|json)',
                r'dist/evidence/variants/(en|zh-Hans)-(light|dark)/native-(welcome\.png|settings\.png|smoke\.json)',
                r'dist/evidence/real-music/([^/]+\.(png|json)|performance/summary\.json)',
                r'dist/evidence/real-online-song/[^/]+\.json',
                r'dist/evidence/cloud-clients/[^/]+/([^/]+\.png|result\.json|permission-ui/native-permission-ui\.json)',
                r'dist/evidence/cloud-clients/(qqMusic|netease)/native-player/([^/]+\.(png|json)|performance/summary\.json)']
    selected = sorted(name for name in artifact.names if name in exact or any(re.fullmatch(pattern, name) for pattern in patterns))
    require('dist/evidence/native-smoke.json' in selected and any('/layout/' in name and name.endswith('.png') for name in selected),
            'Original native screenshot evidence is missing.')
    if 'dist/evidence/live-lyrics.json' in selected:
        require(artifact.report('dist/evidence/live-lyrics.json').get('lyricTextIncluded') is False,
                'Live-provider report must explicitly exclude lyric text.')
    output, hashes, total = io.BytesIO(), {}, 0
    with zipfile.ZipFile(output, 'w', compression=zipfile.ZIP_DEFLATED, compresslevel=6) as archive:
        for name in selected:
            data = artifact.read(name, 16 * MAX_REPORT if name.endswith('.png') else MAX_REPORT)
            total += len(data)
            require(total <= 64 * MAX_REPORT, 'Selected verification evidence exceeds 64 MiB.')
            hashes[name] = {'sha256': digest(data), 'bytes': len(data)}
            member = zipfile.ZipInfo(name.removeprefix('dist/'), date_time=(1980, 1, 1, 0, 0, 0))
            member.compress_type = zipfile.ZIP_DEFLATED
            archive.writestr(member, data)
        provenance = {'manifest': manifest, 'remoteVerification': remote,
                      'scope': 'Original CI screenshots and small reports, copied unchanged. Individual reports retain their fixture/runtime boundaries.',
                      'excluded': ['WAV/LRC media', 'NDJSON', 'raw logs', 'executables', 'duplicate installers', 'third-party lyric text'],
                      'originalArtifactFiles': hashes}
        member = zipfile.ZipInfo('SOURCE.json', date_time=(1980, 1, 1, 0, 0, 0))
        member.compress_type = zipfile.ZIP_DEFLATED
        archive.writestr(member, encoded(provenance))
    return output.getvalue(), len(selected)


def compact_evidence(artifact):
    native = artifact.report('dist/evidence/native-smoke.json')
    music = artifact.report('dist/evidence/real-music/cloud-music.json', optional=True)
    clients = artifact.report('dist/evidence/cloud-clients/cloud-clients.json', optional=True)
    idle = artifact.report('dist/evidence/idle/idle-check.json', optional=True)
    live = artifact.report('dist/evidence/live-lyrics.json', optional=True)
    return {
        'nativeUI': {'status': native.get('status'), 'host': native.get('host'),
                     'realPlayerQualification': native.get('realPlayerQualification'),
                     'displayScaleQualification': native.get('displayScaleQualification')},
        'appleMusic': {k: music[k] for k in ('status', 'stage', 'reason', 'realPlayerTestStarted') if k in music},
        'otherPlayers': [{k: item[k] for k in ('player', 'status', 'stage', 'reason', 'completePlayerQualification') if k in item}
                         for item in clients.get('clients', [])],
        'idle': {'status': idle.get('status'), 'withinTargets': idle.get('withinTargets'), 'qualification': idle.get('qualification')},
        'liveLyrics': {k: live[k] for k in ('evidenceClass', 'actualPlayerPlayback', 'independentlyVerifiedAudioIdentity',
                                           'lyricTextIncluded') if k in live},
        'supportScope': 'Per-player statuses are observations of this run, not a claim that every adapter or commercial song is qualified.'}


def check_draft(release, tag, manifest):
    require(release.get('draft') is True and release.get('published_at') is None,
            'Refusing a published or previously published release; only an unpublished draft is editable.')
    require(release.get('tag_name') == tag and release.get('target_commitish') == manifest['sourceCommit']
            and MARKER in (release.get('body') or ''), 'Existing release is not this managed, source-pinned engineering draft.')


def existing_draft(api, tag, manifest):
    matches = [item for item in api.pages('/releases') if item.get('tag_name') == tag]
    require(len(matches) <= 1, 'Multiple releases use the candidate tag.')
    if matches:
        check_draft(matches[0], tag, manifest)
    ref = api.api('/git/ref/tags/' + parse.quote(tag, safe=''), missing_ok=True)
    if ref:
        obj = ref['object']
        for _ in range(5):
            if obj.get('type') == 'commit':
                break
            require(obj.get('type') == 'tag', 'Unexpected tag object type.')
            obj = api.api('/git/tags/' + obj['sha'])['object']
        require(obj.get('type') == 'commit' and obj.get('sha') == manifest['sourceCommit'], 'Existing tag points to different source.')
    return matches[0] if matches else None


def asset_matches(api, asset, data):
    if asset.get('state') != 'uploaded' or asset.get('size') != len(data):
        return False
    if asset.get('digest'):
        return asset['digest'] == 'sha256:' + digest(data)
    with tempfile.TemporaryDirectory(prefix='lyrictile-release-asset-') as folder:
        path = Path(folder) / 'asset'
        api.download(f"/releases/assets/{asset['id']}", path)
        return digest(path.read_bytes()) == digest(data)


def prepare_remote(api, release, tag, manifest, body, assets):
    # Check existing assets before any mutation. Reruns may complete missing
    # uploads; mismatching bytes under an existing build are never overwritten.
    existing = api.pages(f"/releases/{release['id']}/assets") if release else []
    require(len({a['name'] for a in existing}) == len(existing), 'Duplicate release asset names.')
    for asset in existing:
        require(asset['name'] in assets, 'Unmanaged asset exists on the candidate draft: ' + asset['name'])
        require(asset_matches(api, asset, assets[asset['name']]), 'Existing draft asset differs: ' + asset['name'])
    name = f"LyricTile {manifest['version']} (build {manifest['build']}) — UNSIGNED engineering candidate [DRAFT]"
    if release:
        check_draft(api.api(f"/releases/{release['id']}"), tag, manifest)
        # Never send draft:false. Updating text does not publish a release.
        release = api.api(f"/releases/{release['id']}", 'PATCH', {'name': name, 'body': body, 'make_latest': 'false'})
    else:
        release = api.api('/releases', 'POST', {'tag_name': tag, 'target_commitish': manifest['sourceCommit'],
                          'name': name, 'body': body, 'draft': True, 'prerelease': True, 'make_latest': 'false'})
    check_draft(release, tag, manifest)
    existing_names = {asset['name'] for asset in existing}
    upload_base = release['upload_url'].split('{', 1)[0]
    for name, data in assets.items():
        if name in existing_names:
            continue
        check_draft(api.api(f"/releases/{release['id']}"), tag, manifest)
        uploaded = api.api(f"/releases/{release['id']}/assets", 'POST',
                           upload=(upload_base + '?' + parse.urlencode({'name': name}), data))
        require(asset_matches(api, uploaded, data), 'Uploaded asset hash verification failed: ' + name)
    final = api.api(f"/releases/{release['id']}")
    check_draft(final, tag, manifest)
    final_assets = api.pages(f"/releases/{release['id']}/assets")
    require({a['name'] for a in final_assets} == set(assets), 'Draft asset list incomplete.')
    return {'id': final['id'], 'url': final['html_url'], 'draft': True, 'published': False}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--manifest', type=Path, default=Path(__file__).resolve().parent.parent / 'Release/candidate.json')
    parser.add_argument('--output', type=Path, required=True, help='New or empty preparation directory')
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument('--apply', action='store_true', help='Create/update only the verified engineering DRAFT')
    mode.add_argument('--dry-run', action='store_true', help='Validate without GitHub API mutation (default)')
    parser.add_argument('--artifact-directory', type=Path, help='Offline dry-run only; downloaded artifact root containing dist/')
    args = parser.parse_args()
    require(not (args.apply and args.artifact_directory), 'Offline artifact input cannot be used for API mutation.')
    args.output.mkdir(parents=True, exist_ok=True)
    require(not any(args.output.iterdir()), 'Use a new or empty preparation output directory.')
    manifest = manifest_at(args.manifest)
    if not manifest['enabled']:
        result = {'status': 'DISABLED', 'published': False, 'reason': 'Final successful native run has not been pinned.'}
        (args.output / 'preparation-result.json').write_bytes(encoded(result))
        print(json.dumps(result))
        return 0
    if args.apply:
        require(os.environ.get('GITHUB_ACTIONS') == 'true' and os.environ.get('GITHUB_REPOSITORY') == REPOSITORY
                and os.environ.get('GITHUB_REF') == 'refs/heads/' + BRANCH,
                'Draft writes are limited to the authorized repository Actions branch.')
    api, release = None, None
    tag = f"lyrictile-v{manifest['version']}-build{manifest['build']}-candidate"
    with tempfile.TemporaryDirectory(prefix='lyrictile-candidate-') as folder:
        if args.artifact_directory:
            require(args.artifact_directory.is_dir(), 'Offline artifact directory does not exist.')
            source = args.artifact_directory
            remote = {'status': 'NOT_ASSESSED_OFFLINE'}
        else:
            api = GitHub()
            run, item = verify_run(api, manifest)
            release = existing_draft(api, tag, manifest)
            source = Path(folder) / 'artifact.zip'
            api.download(f"/actions/artifacts/{item['id']}/zip", source)
            artifact_hash = digest(source.read_bytes())
            if item.get('digest'):
                require(item['digest'] == 'sha256:' + artifact_hash, 'Downloaded Actions artifact digest differs.')
            remote = {'status': 'VERIFIED', 'runID': run['id'], 'runAttempt': run['run_attempt'],
                      'runURL': run['html_url'], 'artifactID': item['id'], 'artifactSHA256': artifact_hash}
        artifact = Artifact(source)
        assets = validated_assets(artifact, manifest)
        evidence, evidence_count = evidence_zip(artifact, manifest, remote)
        assets[f"LyricTile-{manifest['version']}-{manifest['build']}-verification.zip"] = evidence
        summary = {'schemaVersion': 1, 'status': 'PASS', 'manifest': manifest, 'remoteVerification': remote,
                   'distribution': 'UNSIGNED engineering candidate: ad-hoc signature only; no Developer ID or notarization.',
                   'draftOnly': True, 'published': False, 'evidenceFilesPreserved': evidence_count,
                   'evidence': compact_evidence(artifact),
                   'assets': {name: {'sha256': digest(data), 'bytes': len(data)} for name, data in assets.items()}}
        assets['candidate-verification.json'] = encoded(summary)
        assets_dir = args.output / 'assets'
        assets_dir.mkdir()
        for name, data in assets.items():
            (assets_dir / name).write_bytes(data)
        music_status = summary['evidence']['appleMusic'].get('status', 'NOT_RECORDED')
        body = (f"{MARKER}\n# LyricTile {manifest['version']} · build {manifest['build']}\n\n"
                "**UNSIGNED ENGINEERING DRAFT · 未公开的工程候选**\n\n"
                "These are the original ad-hoc CI packages, without Developer ID signing or Apple notarization. "
                "This draft is release preparation, not the signed consumer release.\n\n"
                f"- Source: `{manifest['sourceCommit']}`\n- Native CI: https://github.com/{REPOSITORY}/actions/runs/{manifest['runID']}\n"
                f"- Artifact: `{manifest['artifactName']}`\n- Platform: Apple silicon, macOS 27+\n"
                f"- Apple Music result in this run: **{music_status}**; inspect the original report for scope.\n\n"
                "`SHA256SUMS` covers the unchanged candidate ZIP/DMG. `candidate-verification.json` records asset hashes and evidence boundaries. "
                "The verification ZIP preserves original native screenshots and small CI reports; authored fixtures, live network probes, "
                "and actual player observations remain distinct. No all-player, commercial-catalog, word-timing, or new eight-hour qualification is implied.\n\n"
                "待本机使用现有凭据对同一源码完成签名、公证和必要的升级验证后，再建立独立正式 Release。"
                "此草稿不会更新公开下载入口或自动更新 feed；旧 build 4 不代表本候选。\n")
        (args.output / 'release-notes.md').write_text(body)
        result = {'status': 'DRAFT_PREPARATION_INCOMPLETE' if args.apply else 'DRY_RUN_PASS', 'tag': tag,
                  'sourceCommit': manifest['sourceCommit'], 'build': manifest['build'],
                  'remoteVerification': remote['status'], 'assetCount': len(assets), 'published': False}
        if args.apply:
            (args.output / 'preparation-result.json').write_bytes(encoded(result))
            try:
                result['release'] = prepare_remote(api, release, tag, manifest, body, assets)
                result['status'] = 'DRAFT_PREPARED'
            except Rejected as exc:
                result.update(status='DRAFT_PREPARATION_BLOCKED', reason=str(exc))
                (args.output / 'preparation-result.json').write_bytes(encoded(result))
                raise
        (args.output / 'preparation-result.json').write_bytes(encoded(result))
        print(json.dumps(result, ensure_ascii=False))
        if os.environ.get('GITHUB_STEP_SUMMARY'):
            with open(os.environ['GITHUB_STEP_SUMMARY'], 'a') as stream:
                stream.write('## LyricTile draft preparation\n\n' + json.dumps(result, ensure_ascii=False) + '\n')
    return 0


if __name__ == '__main__':
    try:
        raise SystemExit(main())
    except (Rejected, OSError, ValueError, KeyError, zipfile.BadZipFile, plistlib.InvalidFileException) as exc:
        print('Candidate draft preparation stopped: ' + str(exc), file=sys.stderr)
        raise SystemExit(1)
