#!/usr/bin/env python3
"""Observe official QQ/NetEase clients on a disposable GitHub macOS runner.

Uses original audio supplied by the caller and the packaged production adapter.
No account, TCC database, preference, entitlement, or licence dialog is changed.
A downloaded/started client is never counted as successful playback support.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import plistlib
import re
import shutil
import signal
import struct
import subprocess
import tempfile
import time
import urllib.parse
import urllib.request
import wave

QQ_ENDPOINT = 'https://y.qq.com/download/download.js'
NETEASE_ENDPOINT = 'https://music.163.com/api/mac/package/download/latest?arch=arm64&productName=music'
USER_AGENT = 'LyricTile-Cloud-Verification/1.0 (+https://github.com/haohongfei2001-png/nearpane)'
CLIENTS = [
    dict(player='qqMusic', bundleID='com.tencent.QQMusicMac', endpoint=QQ_ENDPOINT, allowedDomain='qq.com'),
    dict(player='netease', bundleID='com.netease.163music', endpoint=NETEASE_ENDPOINT, allowedDomain='126.net'),
]


def save(path: Path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n')


def command(args, timeout=20, log: Path | None = None):
    """Bound every subprocess and preserve its actual result."""
    started = time.monotonic()
    process = subprocess.Popen(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, start_new_session=True)
    try:
        stdout, stderr = process.communicate(timeout=timeout)
        value = dict(exitCode=process.returncode, stdout=stdout[-65536:], stderr=stderr[-65536:], timedOut=False)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            stdout, stderr = process.communicate(timeout=3)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            stdout, stderr = process.communicate(timeout=3)
        value = dict(exitCode=None, stdout=stdout[-65536:], stderr=stderr[-65536:], timedOut=True)
    value['elapsedSeconds'] = round(time.monotonic() - started, 3)
    if log:
        save(log, value)
    return value


def capture_desktop(directory: Path, name='native-desktop'):
    target = directory / (name + '.png')
    result = command(['/usr/sbin/screencapture', '-x', str(target)], timeout=10)
    width = height = None
    if target.exists():
        with target.open('rb') as image:
            header = image.read(24)
        if len(header) == 24 and header[:8] == b'\x89PNG\r\n\x1a\n':
            width, height = struct.unpack('>II', header[16:24])
    result.update(file=target.name, pixelWidth=width, pixelHeight=height,
                  saved=result['exitCode'] == 0 and bool(width and height),
                  captureKind='WindowServer desktop screenshot',
                  wallpaperChanged=False, permissionsChanged=False,
                  visualInspection='PENDING')
    save(directory / (name + '.json'), result)
    return result


def read_metadata(client):
    request = urllib.request.Request(client['endpoint'], headers={'User-Agent': USER_AGENT})
    with urllib.request.urlopen(request, timeout=20) as response:
        raw = response.read(256 * 1024 + 1)
    if len(raw) > 256 * 1024:
        raise ValueError('Official metadata response exceeded its bound.')
    text = raw.decode('utf-8')
    if client['player'] == 'qqMusic':
        match = re.fullmatch(r'\s*MusicJsonCallback\((\{.*\})\);?\s*', text, re.S)
        if not match:
            raise ValueError('Unexpected official QQ download metadata format.')
        record = next(item for item in json.loads(match.group(1))['data'] if item.get('Ftype') == 2 and item.get('Ftitle') == 'Mac')
        return dict(downloadURL=record['Flink1'], advertisedVersion=record.get('Fversion'), metadataSHA256=hashlib.sha256(raw).hexdigest())
    payload = json.loads(text)
    if payload.get('code') != 200:
        raise ValueError('Official NetEase metadata returned a non-success result.')
    record = payload['data']
    return dict(downloadURL=record['downloadUrl'], advertisedVersion=record.get('appVer'),
                advertisedBuild=record.get('buildVer'), metadataSHA256=hashlib.sha256(raw).hexdigest())


def download(url, destination, domain):
    def permitted(value):
        parsed = urllib.parse.urlsplit(value)
        host = (parsed.hostname or '').lower()
        return parsed.scheme == 'https' and (host == domain or host.endswith('.' + domain))
    if not permitted(url):
        raise ValueError('Download metadata points outside the expected official HTTPS domain.')
    class OfficialRedirects(urllib.request.HTTPRedirectHandler):
        def redirect_request(self, request, fp, code, message, headers, new_url):
            if not permitted(new_url):
                raise ValueError('Download redirected outside the expected official HTTPS domain.')
            return super().redirect_request(request, fp, code, message, headers, new_url)
    opener = urllib.request.build_opener(OfficialRedirects())
    digest = hashlib.sha256()
    count = 0
    started = time.monotonic()
    with opener.open(urllib.request.Request(url, headers={'User-Agent': USER_AGENT}), timeout=20) as response:
        final_url = response.url
        if not permitted(final_url):
            raise ValueError('Unexpected final download domain.')
        with destination.open('wb') as output:
            while True:
                if time.monotonic() - started > 90:
                    raise TimeoutError('Official package download exceeded 90 seconds.')
                chunk = response.read(256 * 1024)
                if not chunk:
                    break
                count += len(chunk)
                if count > 600 * 1024 * 1024:
                    raise ValueError('Official package exceeded the 600 MiB download bound.')
                output.write(chunk)
                digest.update(chunk)
    if count < 1024 * 1024:
        raise ValueError('Download is too small to be the expected macOS application package.')
    return dict(bytes=count, sha256=digest.hexdigest(), finalURL=final_url)


def own_processes(installation: Path):
    result = command(['/bin/ps', '-ww', '-axo', 'pid=,comm='], timeout=5)
    owned = []
    for row in result['stdout'].splitlines():
        fields = row.strip().split(None, 1)
        if len(fields) == 2 and fields[0].isdigit() and fields[1].startswith(str(installation) + '/'):
            owned.append(int(fields[0]))
    return owned


def stop_own_processes(installation: Path):
    pids = own_processes(installation)
    for pid in pids:
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
    deadline = time.monotonic() + 4
    while own_processes(installation) and time.monotonic() < deadline:
        time.sleep(.2)
    remaining = own_processes(installation)
    for pid in remaining:
        try:
            os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
    return dict(termPIDs=pids, killPIDs=remaining, remainingPIDs=own_processes(installation))


def observed_audio(directory: Path, player: str, bundle_id: str, expected_titles: set[str], duration_ms: int):
    events = directory / 'events.ndjson'
    matched = []
    total = 0
    authorized = False
    if events.exists():
        for line in events.read_text().splitlines():
            event = json.loads(line)
            total += 1
            authorized = authorized or bool(event.get('requiresAuthorization'))
            selection = event.get('selection') or {}
            recording = selection.get('recording') or {}
            title = recording.get('title') or ''
            duration = recording.get('durationMS')
            if (event.get('dataOrigin') == 'real_player' and event.get('player') == player
                    and selection.get('playerBundleID') == bundle_id and title.casefold() in expected_titles
                    and isinstance(duration, (int, float)) and abs(duration-duration_ms) <= 2000):
                matched.append(event)
    positions = [row['anchor']['positionMS'] for row in matched if row.get('state') == 'playing'
                 and isinstance((row.get('anchor') or {}).get('positionMS'), (int, float))]
    advancing = len(positions) >= 2 and max(positions) - min(positions) >= 500
    return dict(eventCount=total, matchedOriginalAudioSnapshots=len(matched),
                matchedPlayingPositions=len(positions), positionAdvanced=advancing,
                observedTitles=sorted({(row.get('selection') or {}).get('recording', {}).get('title') for row in matched}),
                requiresAuthorization=authorized, source='production adapter events.ndjson')


def verify_client(client, app: Path, audio: Path, output: Path, runner_temp: Path, expected_titles, duration_ms):
    directory = output / client['player']
    directory.mkdir()
    work = Path(tempfile.mkdtemp(prefix='LyricTile-client-' + client['player'] + '-', dir=runner_temp))
    mount = work / 'mount'
    install = work / 'Applications'
    install.mkdir()
    mounted = False
    report = dict(player=client['player'], status='NOT_RUN', scope='official client and production-adapter observation',
                  metadataEndpoint=client['endpoint'], expectedBundleID=client['bundleID'],
                  accountUsed=False, TCCModified=False, protocolsAccepted=False,
                  completePlayerQualification=False, nativeLyricUIQualification='NOT_RUN',
                  transportQualification='NOT_RUN', stage='metadata')
    try:
        report.update(read_metadata(client))
        report['stage'] = 'download'
        dmg = work / 'official.dmg'
        report['download'] = download(report['downloadURL'], dmg, client['allowedDomain'])
        report['stage'] = 'DMG verification'
        verify = command(['/usr/bin/hdiutil', 'verify', str(dmg)], timeout=30, log=directory/'dmg-verify.json')
        report['dmgVerified'] = verify['exitCode'] == 0
        if not report['dmgVerified']:
            report['status'] = 'BLOCKED'
            return report
        mount.mkdir()
        report['stage'] = 'mount'
        result = command(['/usr/bin/hdiutil', 'attach', '-readonly', '-nobrowse', '-noautoopen',
                          '-mountpoint', str(mount), str(dmg)], timeout=30, log=directory/'mount.json')
        mounted = result['exitCode'] == 0 or mount.is_mount()
        if result['exitCode'] != 0:
            report['status'] = 'BLOCKED'
            return report
        choices = []
        for candidate in mount.glob('*.app'):
            if not candidate.resolve().is_relative_to(mount.resolve()):
                continue
            plist = candidate/'Contents/Info.plist'
            if plist.is_file():
                with plist.open('rb') as file:
                    info = plistlib.load(file)
                if info.get('CFBundleIdentifier') == client['bundleID']:
                    choices.append((candidate, info))
        if len(choices) != 1:
            raise ValueError('The official DMG did not contain exactly one application with the expected bundle identifier.')
        source, info = choices[0]
        target = install / source.name
        report['stage'] = 'copy'
        copied = command(['/usr/bin/ditto', str(source), str(target)], timeout=35, log=directory/'copy.json')
        if copied['exitCode'] != 0:
            report['status'] = 'BLOCKED'
            return report
        report.update(actualBundleID=info['CFBundleIdentifier'], appVersion=info.get('CFBundleShortVersionString'),
                      appBuild=info.get('CFBundleVersion'), architecture=platform.machine())
        report['stage'] = 'signature'
        signature = command(['/usr/bin/codesign', '--verify', '--deep', '--strict', '--verbose=2', str(target)],
                            timeout=20, log=directory/'codesign-verify.json')
        detail = command(['/usr/bin/codesign', '-dv', '--verbose=4', str(target)], timeout=10, log=directory/'codesign-details.json')
        report['signatureVerified'] = signature['exitCode'] == 0
        gatekeeper = command(['/usr/sbin/spctl', '--assess', '--type', 'execute', '--verbose=2', str(target)],
                             timeout=20, log=directory/'gatekeeper.json')
        report['gatekeeperAccepted'] = gatekeeper['exitCode'] == 0
        report['signatureTeam'] = re.findall(r'^TeamIdentifier=(.+)$', detail['stderr'], re.M)
        if not report['signatureVerified'] or not report['gatekeeperAccepted']:
            report['status'] = 'BLOCKED'
            return report
        report['stage'] = 'ordinary open-file launch'
        launch = command(['/usr/bin/open', '-a', str(target), str(audio)], timeout=15, log=directory/'launch.json')
        report['launchRequestAccepted'] = launch['exitCode'] == 0
        time.sleep(6)
        report['runningProcessIDs'] = own_processes(install)
        report['desktop'] = capture_desktop(directory)
        if launch['exitCode'] != 0 or not report['runningProcessIDs']:
            report['status'] = 'UNVERIFIED'
            return report
        report['stage'] = 'production adapter observation'
        observation_dir = directory/'adapter'
        diagnostic = command([str(app/'Contents/MacOS/LyricTile'), '--diagnostics', '--player', client['player'],
                              '--seconds', '12', '--output', str(observation_dir)],
                             timeout=25, log=directory/'diagnostic-command.json')
        report['diagnosticExitCode'] = diagnostic['exitCode']
        report['diagnosticTimedOut'] = diagnostic['timedOut']
        report['observation'] = observed_audio(observation_dir, client['player'], client['bundleID'], expected_titles, duration_ms)
        # A read-only collector never certifies controls, lyric matching, UI or
        # account music. Even a positive real-source result is only PARTIAL.
        report['status'] = 'PARTIAL' if (diagnostic['exitCode'] == 0
            and report['observation']['matchedOriginalAudioSnapshots'] > 0
            and report['observation']['positionAdvanced']) else 'UNVERIFIED'
        report['reason'] = ('The real player exposed the supplied original recording and advancing position.'
            if report['status'] == 'PARTIAL' else 'No confirmed advancing playback of the supplied original audio. Review the actual first-launch screenshot and adapter evidence.')
        capture_desktop(directory, 'native-desktop-after-observation')
        report['stage'] = 'completed'
    except Exception as error:
        report.update(status='BLOCKED', error=f'{type(error).__name__}: {error}')
    finally:
        report['cleanup'] = stop_own_processes(install)
        if mounted:
            detach = command(['/usr/bin/hdiutil', 'detach', str(mount)], timeout=15, log=directory/'unmount.json')
            report['cleanup']['unmounted'] = detach['exitCode'] == 0
        # Do not traverse a still-mounted third-party image during cleanup.
        if not mounted or report['cleanup'].get('unmounted'):
            shutil.rmtree(work, ignore_errors=True)
        else:
            report['cleanup']['retainedMountPath'] = str(mount)
        save(directory/'result.json', report)
    return report


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('app', type=Path)
    parser.add_argument('--audio', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--expected-title', action='append', default=[])
    args = parser.parse_args()
    if os.environ.get('GITHUB_ACTIONS') != 'true' or platform.system() != 'Darwin' or not os.environ.get('RUNNER_TEMP'):
        parser.error('Only run on a disposable GitHub Actions macOS host with RUNNER_TEMP.')
    app, audio, output = args.app.resolve(), args.audio.resolve(), args.output.resolve()
    if not (app/'Contents/MacOS/LyricTile').is_file() or not audio.is_file():
        parser.error('An existing LyricTile app and original WAV file are required.')
    if output.exists() and any(output.iterdir()):
        parser.error('Use a new or empty output directory.')
    output.mkdir(parents=True, exist_ok=True)
    with wave.open(str(audio), 'rb') as original:
        duration_ms = round(1000*original.getnframes()/original.getframerate())
    provenance_file = audio.parent/'media-provenance.json'
    provenance = json.loads(provenance_file.read_text()) if provenance_file.exists() else {}
    expected_titles = {value.casefold() for value in [audio.stem, audio.name, *args.expected_title, provenance.get('title', '')] if value}
    results = [verify_client(client, app, audio, output, Path(os.environ['RUNNER_TEMP']).resolve(), expected_titles, duration_ms)
               for client in CLIENTS]
    spotify = dict(player='spotify', status='NOT_RUN', reason='No confirmed official account-free desktop playback path. Local Files setup is documented inside the signed-in app.',
                   sources=['https://www.spotify.com/us/download/mac/', 'https://support.spotify.com/us/article/getting-started/',
                            'https://support.spotify.com/us/article/local-files/'], completePlayerQualification=False)
    report = dict(host=platform.platform(), sourceAudioSHA256=hashlib.sha256(audio.read_bytes()).hexdigest(),
                  sourceAudioDurationMS=duration_ms, clients=results+[spotify],
                  realPlayerObservationOnly=True, credentialsUsed=False,
                  allPlayersSupported=False, releaseGate=False)
    save(output/'cloud-clients.json', report)
    print(json.dumps({'clients':[{key:item.get(key) for key in ['player','status','stage','reason']} for item in results+[spotify]]}, ensure_ascii=False))


if __name__ == '__main__':
    main()
