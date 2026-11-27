#!/usr/bin/env python3
"""One real public recording -> ordinary app -> automatic LRCLIB -> native AX.

Only disposable macOS Actions. Third-party audio, cached lyrics and raw native
permission-window text remain temporary; the artifact contains hashes/timing.
No test data is injected into the app and no native verification entry is used.
"""
import argparse
import base64
import hashlib
import json
import os
import platform
import plistlib
import shutil
import signal
import subprocess
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path

from cloud_ui import start_cloud_ui, stop_cloud_ui


class CheckFailure(Exception):
    pass


def digest(data):
    return hashlib.sha256(data).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    env = os.environ
    if (env.get('GITHUB_ACTIONS') != 'true' or platform.system() != 'Darwin'
            or not env.get('RUNNER_TEMP') or not env.get('GITHUB_WORKSPACE')):
        parser.error('Only run on a disposable GitHub Actions macOS host.')
    product = Path(__file__).resolve().parent.parent
    app = args.app.resolve()
    out = args.output.resolve()
    evidence_root = Path(env['GITHUB_WORKSPACE']).resolve()/'Products/LyricTile/dist/evidence'
    if not out.is_relative_to(evidence_root) or out == evidence_root:
        parser.error('Output must be a dedicated product dist/evidence subdirectory.')
    out.mkdir(parents=True, exist_ok=True)
    work = Path(tempfile.mkdtemp(prefix='LyricTile-online-song-', dir=env['RUNNER_TEMP']))
    source = json.loads((product/'CloudAcceptance/CodeMonkey.source.json').read_text())
    support = Path.home()/'Library/Application Support/HOLDSNOW/LyricTile'
    backup = work/'previous-app-support'
    settings_key = 'LyricTile.settings.v1'
    bundle_id = 'com.holdsnow.lyrictile'
    playlist = 'LyricTile Public Song ' + env.get('GITHUB_RUN_ID', str(os.getpid()))
    process = helper = None
    music_started = support_isolated = settings_changed = False
    previous_preferences = None
    imported_location = None
    started = time.monotonic()
    deadline = started + 80
    wall_started = time.time()
    report = {'schemaVersion': 1, 'status': 'UNVERIFIED',
        'scope': 'ordinary native app, actual Apple Music, one public original recording and automatic LRCLIB',
        'nativeVerificationModeUsed': False, 'injectedLyrics': False, 'accountUsed': False,
        'audioBodyRetained': False, 'lyricBodyRetained': False, 'screenshotsTaken': False,
        'independentAcousticClockQualification': False, 'checks': [], 'observations': []}
    stage = 'preflight'
    exit_code = 0

    def save(name, value):
        (out/name).write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n')

    def require(condition, message):
        if not condition:
            raise CheckFailure(message)

    def run(command, timeout=8, bounded=True):
        remaining = deadline-time.monotonic()
        if bounded and remaining <= 0:
            raise TimeoutError('The bounded online-song observation budget expired.')
        return subprocess.run(command, capture_output=True, text=True,
                              timeout=max(.25, min(timeout, remaining)) if bounded else timeout)

    def apple_string(value):
        return '"' + str(value).replace('\\', '\\\\').replace('"', '\\"') + '"'

    def apple(script, timeout=8, bounded=True):
        result = run(['/usr/bin/osascript', '-e', script], timeout, bounded)
        if result.returncode:
            # These scripts return only public metadata and player position.
            raise CheckFailure('Music command failed: ' + result.stderr.strip()[:1500])
        return result.stdout.strip()

    def check(name, passed, **details):
        report['checks'].append(dict(check=name, passed=bool(passed), **details))
        save('online-song-progress.json', report)
        require(passed, name + ' did not pass.')

    def stop_app():
        if process is not None and process.poll() is None:
            os.killpg(process.pid, signal.SIGTERM)
            try:
                process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait(timeout=2)

    def permission_summary(value):
        # Never export raw windows/freshWindowText: the app can show lyrics.
        return {**{k: value.get(k) for k in ('status', 'accessibilityAlreadyTrusted',
            'accessibilityRequested', 'TCCDatabaseModified', 'helperExitCode')},
            'actions': [{k: row.get(k) for k in ('button', 'bundleID', 'AXResult', 'timestamp')}
                        for row in value.get('actions', [])]}

    def read_music():
        raw = apple('''tell application "Music"
            set songTitle to name of current track as string
            set songArtist to artist of current track as string
            set songAlbum to album of current track as string
            set songID to persistent ID of current track as string
            set songPosition to player position as string
            set songState to player state as string
            return songTitle & tab & songArtist & tab & songAlbum & tab & songID & tab & songPosition & tab & songState
        end tell''', timeout=4).split('\t')
        require(len(raw) == 6, 'Music current-track readback was incomplete.')
        return dict(title=raw[0], artist=raw[1], album=raw[2], persistentID=raw[3],
                    positionMS=round(float(raw[4])*1000), state=raw[5], observedUptime=time.monotonic())

    def cached_document():
        automatic = support/'Automatic'
        if not automatic.is_dir():
            return None
        files = list(automatic.glob('*.json'))
        require(len(files) <= 8, 'Unexpected extra cache records in the isolated ordinary app.')
        for file in files:
            data = file.read_bytes()
            require(len(data) <= 32*1024*1024, 'Automatic cache envelope exceeded its production limit.')
            try:
                envelope = json.loads(data)
            except json.JSONDecodeError:
                continue  # Index/document writes can still be completing.
            document = envelope.get('document', {})
            provenance = document.get('source', {})
            if provenance.get('providerID') != 'lrclib':
                continue
            require(provenance.get('providerRecordID') == source['providerRecordID'],
                    'The ordinary app automatically selected a different LRCLIB record.')
            raw = base64.b64decode(envelope.get('raw', {}).get('bytes', ''), validate=True)
            require(raw and digest(raw) == document.get('contentHash'),
                    'The actual cached raw payload and parsed document hashes do not agree.')
            recording = document.get('recording', {})
            require(recording.get('title') == source['title'] and source['artist'] in recording.get('artists', [])
                    and recording.get('album') == source['album']
                    and abs(recording.get('durationMS', 0)/1000-source['durationSeconds']) < 2,
                    'The cache document is not bound to the actual imported recording metadata.')
            require(any(row.get('value') == imported_id for row in recording.get('platformIDs', [])),
                    'The cached recording is not linked to the actual Music persistent ID.')
            fetched = provenance.get('fetchedAt')
            require(isinstance(fetched, (int, float)) and fetched+978307200 >= wall_started-2,
                    'The automatic document predates this fresh-cache observation.')
            index_path = support/'index-v1.json'
            if not index_path.exists():
                return None
            index = json.loads(index_path.read_text())
            entry = index.get('automatic', {}).get(recording.get('fingerprint'), {})
            if entry.get('file') != file.name:
                return None
            cues = sorted((cue for lane in document.get('lanes', []) if lane.get('kind') == 'lead'
                           for cue in lane.get('cues', []) if isinstance(cue.get('sourceStartMS'), int)
                           and cue.get('text', '').strip()), key=lambda cue: cue['sourceStartMS'])
            timing = document.get('sourceTiming', {})
            offset = (timing.get('sourceAdvanceMS') or 0) if timing.get('interpretation') == 'normalizedKnownFormat' else 0
            metadata = dict(providerID=provenance['providerID'], providerRecordID=provenance['providerRecordID'],
                sourceURL=provenance.get('sourceURL'), fetchedAtReferenceSeconds=fetched,
                envelopeSHA256=digest(data), documentContentSHA256=document['contentHash'],
                rawPayloadSHA256=digest(raw), rawPayloadByteCount=len(raw),
                referenceSourceHashMatched=digest(raw) == source['referenceSyncedLyricsSHA256'],
                referenceSourceHashScope='syncedLyrics reference only; informational for other source formats',
                recording=recording, timingLevel=document.get('timingLevel'),
                originalFormat=document.get('originalFormat'), cueCount=len(cues),
                wordSynchronizationQualified=False,
                sourceAdvanceMS=offset, automaticIndexBindingVerified=True, cacheWasInitiallyEmpty=True)
            # Save the actual format and hashes even if the timed-cue gate fails.
            # Token documents still have line cues; this probe verifies current
            # line text, without qualifying the player's clock for word timing.
            save('automatic-cache-source.json', metadata)
            require(document.get('timingLevel') in ('line', 'token') and len(cues) >= 2,
                    'The automatic source did not produce at least two timed lead cues.')
            return document, cues, offset, metadata
        return None

    def cue_at(cues, position, offset):
        lookup = position+offset
        active = [i for i, cue in enumerate(cues) if cue['sourceStartMS'] <= lookup
                  and (cue.get('sourceEndMS') is None or lookup < cue['sourceEndMS'])]
        if not active:
            return None
        i = active[-1]
        return i, digest(cues[i]['text'].strip().encode('utf-8'))

    try:
        for executable in ('LyricTile', 'Music'):
            existing = run(['/usr/bin/pgrep', '-x', executable])
            require(existing.returncode == 1, 'A previous ' + executable + ' process is still running; no test state was changed.')
        info = plistlib.loads((app/'Contents/Info.plist').read_bytes())
        check('same-production-candidate-bundle', info.get('CFBundleIdentifier') == bundle_id
              and info.get('LyricTileBuildCommit') == env.get('GITHUB_SHA'),
              build=info.get('CFBundleVersion'), sourceCommit=info.get('LyricTileBuildCommit'),
              executableSHA256=digest((app/'Contents/MacOS/LyricTile').read_bytes()))
        save('source-provenance.json', {**source, 'sourceConfigSHA256': digest((product/'CloudAcceptance/CodeMonkey.source.json').read_bytes()),
              'attributionRetained': True, 'thirdPartyTextOrAudioBundled': False})
        stage = 'compile read-only native AX observer'
        binary = work/'online-lyric-readback'
        build = run(['/usr/bin/swiftc', '-parse-as-library', '-framework', 'AppKit',
                     '-framework', 'ApplicationServices', str(product/'CloudAcceptance/OnlineLyricReadback.swift'),
                     '-o', str(binary)], timeout=22)
        save('ax-helper-compile.json', dict(exitCode=build.returncode, stderr=build.stderr[:6000]))
        check('read-only-native-observer-compiles', build.returncode == 0)
        stage = 'download official temporary recording'
        audio = work/'Code-Monkey.mp3'
        request = urllib.request.Request(source['audioURL'], headers={'User-Agent': 'LyricTile-Internal-CloudAcceptance/1.0'})
        with urllib.request.urlopen(request, timeout=min(12, max(1, deadline-time.monotonic()))) as response:
            body = response.read(12*1024*1024+1)
            content_type = response.headers.get('Content-Type', '')
            final_url = response.url
        check('official-audio-bytes', len(body) <= 12*1024*1024 and digest(body) == source['audioSHA256'],
              sha256=digest(body), bytes=len(body), contentType=content_type, finalURL=final_url)
        audio.write_bytes(body)
        del body
        stage = 'isolate ordinary app cache and preferences'
        if support.exists():
            require(support.is_dir() and not support.is_symlink(), 'Unexpected application-support directory type.')
            support.rename(backup)
        support_isolated = True
        prefs = run(['/usr/bin/defaults', 'export', bundle_id, '-'])
        if prefs.returncode == 0:
            previous_preferences = work/'previous-preferences.plist'
            previous_preferences.write_text(prefs.stdout)
        settings = dict(appearance='light', largeText=False, showTranslation=False, onlineLyrics=True,
            hideWhenIdle=True, showInFullScreen=False, coordinateTiles=True,
            preferredPlayer='appleMusic', completedWelcome=True)
        changed = run(['/usr/bin/defaults', 'write', bundle_id, settings_key, '-data', json.dumps(settings).encode().hex()])
        settings_changed = True
        require(changed.returncode == 0, 'The disposable ordinary-app preferences could not be configured.')
        stage = 'real Music import and source readback'
        helper = start_cloud_ui(work/'permission-ui', 'music', seconds=max(10, int(deadline-time.monotonic())))
        launched = run(['/usr/bin/open', '-a', '/System/Applications/Music.app'])
        music_started = True
        require(launched.returncode == 0, 'The system Music application did not launch.')
        raw = apple('''tell application "Music"
            set sound volume to 0
            set testPlaylist to make new user playlist with properties {name:''' + apple_string(playlist) + '''}
            add POSIX file ''' + apple_string(audio) + ''' to testPlaylist
            set shuffle enabled to false
            set song repeat to off
            set testTrack to item 1 of (tracks of testPlaylist)
            play testPlaylist
            delay 1
            set songTitle to name of testTrack as string
            set songArtist to artist of testTrack as string
            set songAlbum to album of testTrack as string
            set songID to persistent ID of testTrack as string
            set songDuration to duration of testTrack as string
            set songLocation to get location of testTrack
            set actualID to persistent ID of current track as string
            set actualState to player state as string
        end tell
        set songPath to POSIX path of songLocation
        return songTitle & tab & songArtist & tab & songAlbum & tab & songID & tab & songDuration & tab & songPath & tab & actualID & tab & actualState''', timeout=18).split('\t')
        require(len(raw) == 8, 'The actual imported Music source readback was incomplete.')
        title, artist, album, imported_id, duration, location, actual_id, state = raw
        imported_location = Path(location).resolve()
        imported_hash = digest(imported_location.read_bytes())
        check('actual-music-original-tags-file-and-current-track', title == source['title'] and artist == source['artist']
              and album == source['album'] and actual_id == imported_id and state == 'playing'
              and abs(float(duration)-source['durationSeconds']) < 2 and imported_hash == source['audioSHA256'],
              title=title, artist=artist, album=album, persistentID=imported_id, currentPersistentID=actual_id,
              durationSeconds=float(duration), importedFileSHA256=imported_hash, metadataEdited=False)
        stage = 'ordinary app automatic online resolution'
        stream = (work/'ordinary-app.log').open('w')
        process = subprocess.Popen([str(app/'Contents/MacOS/LyricTile')], stdout=stream, stderr=stream, start_new_session=True)
        stream.close()
        resolution_started = time.monotonic()
        cached = None
        while time.monotonic() < deadline-12 and process.poll() is None:
            cached = cached_document()
            if cached:
                break
            time.sleep(.3)
        require(process.poll() is None, 'The ordinary application exited during automatic online resolution.')
        if cached is None:
            report.update(status='UNVERIFIED', reason='No automatic LRCLIB document appeared within the bounded observation; no local lyrics were substituted.')
        else:
            document, cues, offset, cache_metadata = cached
            cache_metadata['observedResolutionSeconds'] = time.monotonic()-resolution_started
            save('automatic-cache-source.json', cache_metadata)
            check('production-automatic-online-source-and-cache', True, **cache_metadata)
            stage = 'native current lyric hash versus actual Music clock'
            observed_hashes = set()
            # Natural playback first; after its first verified line, a real
            # Music seek can select another cue within this short cloud budget.
            sought_second = False
            while time.monotonic() < deadline-3 and process.poll() is None and len(observed_hashes) < 2:
                before = read_music()
                ax = run([str(binary), '--pid', str(process.pid)], timeout=3)
                require(ax.returncode == 0, 'The native read-only observer process failed.')
                native = json.loads(ax.stdout)
                after = read_music()
                expected_before = cue_at(cues, before['positionMS'], offset)
                expected_after = cue_at(cues, after['positionMS'], offset)
                source_ok = all(row['persistentID'] == imported_id and row['title'] == source['title']
                    and row['artist'] == source['artist'] and row['state'] == 'playing' for row in (before, after))
                match = (source_ok and expected_before is not None and expected_before == expected_after
                    and after['positionMS'] >= before['positionMS'] and after['positionMS']-before['positionMS'] <= 3000
                    and native.get('status') == 'OBSERVED' and native.get('hitBelongsToTargetWindow') is True
                    and expected_before[1] in native.get('centerTextHashes', []))
                row = dict(beforeMusic=before, afterMusic=after, native=native, passed=bool(match),
                    expectedCueIndex=expected_before[0] if expected_before else None,
                    expectedCueSHA256=expected_before[1] if expected_before else None)
                report['observations'].append(row)
                save('online-song-progress.json', report)
                if match:
                    observed_hashes.add(expected_before[1])
                    if len(observed_hashes) == 1 and not sought_second:
                        target = next((cue for cue in cues[expected_before[0]+1:]
                            if digest(cue['text'].strip().encode()) not in observed_hashes
                            and cue['sourceStartMS'] > after['positionMS']+1500), None)
                        if target:
                            target_seconds = max(0, (target['sourceStartMS']-offset+600)/1000)
                            apple('tell application "Music" to set player position to ' + str(target_seconds))
                            report['realMusicSeekTargetSeconds'] = target_seconds
                            sought_second = True
                if native.get('status') == 'BLOCKED' and native.get('accessibilityAlreadyTrusted') is False:
                    break
                time.sleep(.35)
            report['distinctMatchedCurrentCueHashes'] = sorted(observed_hashes)
            report['checks'].append(dict(check='two-distinct-native-current-lines-follow-actual-Music-position',
                                          passed=len(observed_hashes) >= 2))
            report['status'] = 'PASS_REAL_ONLINE_SONG' if len(observed_hashes) >= 2 else 'UNVERIFIED'
            if len(observed_hashes) < 2:
                report['reason'] = 'Automatic online resolution was observed, but two current native lyric hashes were not confirmed against actual player readbacks.'
    except urllib.error.URLError as error:
        report.update(status='UNVERIFIED', stage=stage, failureClass='external_audio_request',
                      reason='The temporary official recording could not be retrieved: ' + type(error).__name__)
    except (TimeoutError, subprocess.TimeoutExpired) as error:
        compile_failure = stage == 'compile read-only native AX observer'
        report.update(status='FAIL' if compile_failure else 'UNVERIFIED', stage=stage,
                      reason='Bounded operation timed out: ' + type(error).__name__)
        if compile_failure:
            exit_code = 1
    except CheckFailure as error:
        report.update(status='FAIL', stage=stage, reason=str(error)); exit_code = 1
    except Exception as error:
        report.update(status='FAIL', stage=stage, reason=type(error).__name__ + ': ' + str(error)[:1000]); exit_code = 1
    finally:
        cleanup = {'privateAudioAndLyricsRemoved': False, 'previousApplicationSupportRestored': False,
                   'previousPreferencesRestored': False, 'errors': []}
        try:
            stop_app()
        except Exception as error:
            cleanup['errors'].append('ordinary-app-stop: ' + type(error).__name__)
        if helper:
            try:
                save('permission-actions.json', permission_summary(stop_cloud_ui(helper)))
            except Exception as error:
                cleanup['errors'].append('permission-helper-stop: ' + type(error).__name__)
        if music_started:
            try:
                apple('tell application "Music" to quit', timeout=4, bounded=False)
            except Exception:
                # It was absent at preflight and launched only by this probe.
                remaining = run(['/usr/bin/pgrep', '-x', 'Music'], timeout=2, bounded=False)
                for value in remaining.stdout.split():
                    try:
                        os.kill(int(value), signal.SIGTERM)
                    except ProcessLookupError:
                        pass
        try:
            if imported_location and imported_location.exists() and not imported_location.is_relative_to(work):
                require(imported_location.is_relative_to(Path.home()/'Music'), 'The imported copy is outside Music storage.')
                require(digest(imported_location.read_bytes()) == source['audioSHA256'], 'The imported file changed before cleanup.')
                imported_location.unlink()
            if support_isolated:
                if support.exists():
                    shutil.rmtree(support)
                if backup.exists():
                    backup.rename(support)
                cleanup['previousApplicationSupportRestored'] = True
            if settings_changed:
                restored = run(['/usr/bin/defaults', 'import', bundle_id, str(previous_preferences)]
                    if previous_preferences else ['/usr/bin/defaults', 'delete', bundle_id], timeout=3, bounded=False)
                cleanup['previousPreferencesRestored'] = restored.returncode == 0
            else:
                cleanup['previousPreferencesRestored'] = True
            shutil.rmtree(work)
            cleanup['privateAudioAndLyricsRemoved'] = True
        except Exception as error:
            cleanup['errors'].append('temporary-data-cleanup: ' + type(error).__name__ + ': ' + str(error)[:400])
        report['cleanup'] = cleanup
        report['elapsedSeconds'] = round(time.monotonic()-started, 3)
        if cleanup['errors'] or not cleanup['privateAudioAndLyricsRemoved'] or not cleanup['previousPreferencesRestored']:
            report['status'] = 'FAIL'; exit_code = 1
        save('online-song.json', report)
        print(json.dumps({k: report.get(k) for k in ('status', 'stage', 'reason', 'elapsedSeconds')}, ensure_ascii=False))
    return exit_code


if __name__ == '__main__':
    raise SystemExit(main())
