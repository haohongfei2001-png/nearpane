#!/usr/bin/env python3
"""Disposable macOS runner: real Music playback, ordinary app, original media.

This never edits TCC databases, logs into an account, fetches copyrighted music,
or substitutes snapshots. A CI-only helper can press narrowly observed native
Music controls using existing Accessibility access. All actions are recorded.
"""
import argparse
import hashlib
import json
import math
import os
import platform
import plistlib
import re
import signal
import struct
import subprocess
import time
import wave
from pathlib import Path
from cloud_ui import start_cloud_ui, stop_cloud_ui
from cloud_pointer import start_cloud_pointer, stop_cloud_pointer

p = argparse.ArgumentParser()
p.add_argument('app', type=Path)
p.add_argument('--output', type=Path, required=True)
a = p.parse_args()
if os.environ.get('GITHUB_ACTIONS') != 'true' or platform.system() != 'Darwin' or not os.environ.get('RUNNER_TEMP'):
    p.error('Only run on a disposable GitHub Actions macOS host with RUNNER_TEMP.')
out = a.output.resolve()
out.mkdir(parents=True, exist_ok=True)
fixture_path = Path(__file__).resolve().parent.parent/'Tests/Fixtures/CloudAcceptance.json'
fixture_bytes = fixture_path.read_bytes()
fixture = json.loads(fixture_bytes)
title = fixture['title']
audio = out / 'original-chimes.wav'
lyrics = out / 'original-lyrics.lrc'
second_audio = out / (fixture['secondRecording']['fileStem'] + '.wav')
second_lyrics = out / 'original-reprise-lyrics.lrc'
playlist_name = 'LyricTile Cloud Acceptance ' + os.environ.get('GITHUB_RUN_ID', 'disposable')
process = None
pointer_helper = None
permission_helper = None
music_app = Path('/System/Applications/Music.app')
music_baseline_pids = set()
music_launch_attempted = False
stage = 'generate original test media'

def save(name, obj):
    (out / name).write_text(json.dumps(obj, ensure_ascii=False, indent=2) + '\n')

def apple(script, timeout=25):
    return subprocess.run(['/usr/bin/osascript', '-e', script], capture_output=True, text=True, timeout=timeout)

def apple_string(value):
    return '"' + str(value).replace('\\', '\\\\').replace('"', '\\"') + '"'

def capture_desktop(name, timing):
    desktop = out/(name+'.png')
    code, error = None, ''
    try:
        capture = subprocess.run(['/usr/sbin/screencapture','-x',str(desktop)],
            capture_output=True,text=True,timeout=10)
        code, error = capture.returncode, capture.stderr
    except subprocess.TimeoutExpired:
        error = 'Desktop screenshot timed out after 10 seconds.'
    width = height = None
    if desktop.exists():
        with desktop.open('rb') as file:
            header = file.read(24)
        if len(header) == 24 and header[:8] == b'\x89PNG\r\n\x1a\n':
            width, height = struct.unpack('>II',header[16:24])
    report = {'exitCode':code,'pixelWidth':width,'pixelHeight':height,
        'saved':code == 0 and bool(width and height),'stderr':error,'file':desktop.name,
        'captureKind':'WindowServer desktop screenshot','wallpaperChanged':False,'permissionsChanged':False,
        'visualInspection':'PENDING','timing':timing}
    save(name+'.json',report)
    return report

def music_environment(name):
    details = {'applicationPath':str(music_app),'host':platform.platform(),'processes':[]}
    try:
        with (music_app/'Contents/Info.plist').open('rb') as file:
            info = plistlib.load(file)
        details.update(bundleID=info.get('CFBundleIdentifier'),version=info.get('CFBundleShortVersionString'),
            build=info.get('CFBundleVersion'),executable=info.get('CFBundleExecutable'))
    except Exception as error:
        details['bundleReadError'] = str(error)
    try:
        listing = subprocess.run(['/bin/ps','-ww','-axo','pid=,ppid=,stat=,etime=,comm='],
            capture_output=True,text=True,timeout=5)
        (out/(name+'.processes.log')).write_text(listing.stdout+listing.stderr)
        for line in listing.stdout.splitlines():
            parts = line.strip().split(None,4)
            if len(parts) == 5 and parts[4].startswith(str(music_app)+'/'):
                details['processes'].append({'pid':int(parts[0]),'parentPID':int(parts[1]),
                    'state':parts[2],'elapsed':parts[3],'executable':parts[4]})
        details['processQueryExitCode'] = listing.returncode
    except Exception as error:
        details['processQueryError'] = str(error)
    details['running'] = bool(details['processes'])
    save(name+'.json',details)
    return details

try:
    # Test content lives only in Tests/Fixtures, never in the release bundle.
    # Actual decoded audio advances in the Music application.
    rate = fixture['sampleRate']
    for destination, frequencies in [(audio, fixture['frequenciesHz']),
            (second_audio, list(reversed(fixture['frequenciesHz'])))]:
        with wave.open(str(destination), 'wb') as f:
            f.setparams((1, 2, rate, 0, 'NONE', 'not compressed'))
            for second in range(fixture['durationSeconds']):
                freq = frequencies[(second // fixture['noteDurationSeconds']) % len(frequencies)]
                f.writeframes(b''.join(struct.pack('<h', int(fixture['peakAmplitude'] * math.sin(2 * math.pi * freq * i / rate)
                    * min(1, i / (rate * fixture['fadeInSeconds'])) * max(0, 1-i/rate))) for i in range(rate)))
    lines = fixture['lyricLines']
    interval = fixture['lyricIntervalSeconds']
    lyrics.write_text('\n'.join(f'[{s//60:02d}:{s%60:02d}.00]{lines[(s//interval)%len(lines)]}'
        for s in range(0,fixture['durationSeconds'],interval))+'\n')
    second_lyrics.write_text('\n'.join(f'[{s//60:02d}:{s%60:02d}.00]{lines[(s//interval+fixture["secondRecording"]["lyricLineOffset"])%len(lines)]}'
        for s in range(0,fixture['durationSeconds'],interval))+'\n')
    save('media-provenance.json', {'origin':fixture['origin'], 'title':title,
        'fixtureSHA256':hashlib.sha256(fixture_bytes).hexdigest(),
        'notBundledWithProduct':True,'durationSeconds':fixture['durationSeconds'],'audioSHA256':hashlib.sha256(audio.read_bytes()).hexdigest(),
        'lyricSHA256':hashlib.sha256(lyrics.read_bytes()).hexdigest(),'streamingSubscription':False,
        'secondRecording':{'audioSHA256':hashlib.sha256(second_audio.read_bytes()).hexdigest(),
            'lyricSHA256':hashlib.sha256(second_lyrics.read_bytes()).hexdigest(),
            'durationSeconds':fixture['durationSeconds'],'frequencyOrder':'reverse'}})
    before = music_environment('music-before-launch')
    music_baseline_pids = {row['pid'] for row in before['processes']}
    stage = 'open system Music application'
    music_launch_attempted = True
    launch = subprocess.run(['/usr/bin/open','-a',str(music_app)],capture_output=True,text=True,timeout=20)
    (out/'music-launch.log').write_text(launch.stdout+launch.stderr)
    save('music-launch.json',{'exitCode':launch.returncode,'stdout':launch.stdout,'stderr':launch.stderr})
    time.sleep(3)
    initial = music_environment('music-after-launch')
    capture_desktop('music-initial-desktop','after ordinary launch, before AppleScript')
    if launch.returncode != 0 or not initial['running']:
        save('cloud-music.json',{'status':'BLOCKED','stage':stage,'launchExitCode':launch.returncode,
            'musicEnvironment':initial,'reason':'The system Music app did not start on this host.',
            'realPlayerTestStarted':False})
        raise SystemExit(0)
    # CI39 captured the actual Automation prompt and Music welcome page. Use
    # only an already-trusted AX connection and exact freshly read controls.
    permission_helper = start_cloud_ui(out/'setup-ui', 'music', seconds=60)
    stage = 'Music AppleScript import and play'
    # CI41 proved that changing a newly imported WAV's name can return -50.
    # Keep the player's actual metadata. A temporary playlist gives the real
    # production next/previous commands two distinct original recordings.
    import_report = {'schemaVersion':1,'temporaryPlaylist':playlist_name,
        'scope':'only this newly created playlist; no other library tracks are inspected',
        'attempts':[],'selectedSources':[],'currentTrackReadbacks':[]}

    def setup_log(label, result):
        with (out/'music-setup.log').open('a') as stream:
            stream.write(label+'\n'+result.stdout+result.stderr+'\n')

    def setup_failure(details, error_number=10001, exit_code=1):
        global permission_helper
        save('music-import-observations.json',import_report)
        if permission_helper:
            save('setup-permission-ui.json',stop_cloud_ui(permission_helper))
            permission_helper = None
        environment = music_environment('music-setup-failure')
        capture_desktop('music-setup-failure-desktop','failed AppleScript import and play')
        harness_error = error_number not in {-1743, -600, -1712}
        save('cloud-music.json', {'status':'FAIL' if harness_error else 'BLOCKED',
             'failureClass':'test_harness_setup' if harness_error else 'player_setup',
             'stage':'Music local playback setup','exitCode':exit_code,
             'appleScriptErrorNumber':error_number,
             'details':details,'musicEnvironment':environment,'realPlayerTestStarted':False})
        raise SystemExit(1 if harness_error else 0)

    def checked_setup_command(label, script, timeout=8):
        result = apple(script,timeout=timeout)
        setup_log(label,result)
        if result.returncode:
            number = re.search(r'\((-?\d+)\)\s*$',result.stderr)
            setup_failure(result.stdout+result.stderr,
                int(number[1]) if number else None,result.returncode)
        return result

    setup_script = '''tell application "Music"
        set sound volume to 0
        set testPlaylist to make new user playlist with properties {name:''' + apple_string(playlist_name) + '''}
        add POSIX file ''' + apple_string(audio) + ''' to testPlaylist
    end tell'''
    (out/'music-setup.applescript').write_text(setup_script)
    checked_setup_command('create playlist and import first original',setup_script,timeout=25)
    read_tracks_script = '''tell application "Music"
        set testPlaylist to first user playlist whose name is ''' + apple_string(playlist_name) + '''
        set importedTracks to get tracks of testPlaylist
    end tell
    set readback to "COUNT" & tab & ((count of importedTracks) as string)
    repeat with trackIndex from 1 to count of importedTracks
        try
            tell application "Music"
                set importedTrack to get item trackIndex of importedTracks
                try
                    set trackKind to (get class of importedTrack) as string
                on error kindMessage number kindNumber
                    set trackKind to "unreadable class (" & (kindNumber as string) & ")"
                end try
                set trackTitle to (get name of importedTrack) as string
                set trackID to (get persistent ID of importedTrack) as string
                set trackDuration to (get duration of importedTrack) as string
                set trackLocation to get location of importedTrack
            end tell
            -- POSIX conversion is an AppleScript operation outside Music.
            set trackPath to POSIX path of trackLocation
            set readback to readback & linefeed & "TRACK" & tab & (trackIndex as string) & tab & trackKind & tab & trackTitle & tab & trackID & tab & trackDuration & tab & trackPath
        on error importMessage number importNumber
            set readback to readback & linefeed & "ERROR" & tab & (trackIndex as string) & tab & (importNumber as string) & tab & importMessage
        end try
    end repeat
    return readback'''
    (out/'music-import-readback.applescript').write_text(read_tracks_script)
    original_hashes = {'first':hashlib.sha256(audio.read_bytes()).hexdigest(),
                       'second':hashlib.sha256(second_audio.read_bytes()).hexdigest()}

    def wait_for_imports(expected, phase):
        limit = time.monotonic()+12
        last_error_number = 10001
        while time.monotonic()<limit:
            attempt = {'phase':phase,'observedUptime':time.monotonic(),
                       'trackCount':None,'tracks':[],'trackErrors':[]}
            try:
                observed = apple(read_tracks_script,timeout=max(.25,min(4,limit-time.monotonic())))
                setup_log(phase,observed)
                attempt.update(exitCode=observed.returncode,stderr=observed.stderr)
                rows = observed.stdout.strip().splitlines()
                if observed.returncode:
                    number = re.search(r'\((-?\d+)\)\s*$',observed.stderr)
                    last_error_number = int(number[1]) if number else 10001
                else:
                    last_error_number = 10001
                    for row in rows:
                        fields = row.split('\t')
                        if fields[0]=='COUNT' and len(fields)==2:
                            attempt['trackCount'] = int(fields[1])
                        elif fields[0]=='ERROR':
                            attempt['trackErrors'].append(row)
                            if len(fields)>=3:
                                try:
                                    attempt.setdefault('trackErrorNumbers',[]).append(int(fields[2]))
                                except ValueError:
                                    attempt['trackErrors'].append('Malformed AppleScript error number.')
                        elif fields[0]=='TRACK' and len(fields)==7:
                            track = dict(index=int(fields[1]),kind=fields[2],actualTitle=fields[3],
                                persistentID=fields[4],durationSeconds=float(fields[5]),location=fields[6])
                            try:
                                track['importedFileSHA256'] = hashlib.sha256(Path(fields[6]).read_bytes()).hexdigest()
                            except OSError as error:
                                track['fileReadError'] = type(error).__name__+': '+str(error)
                            attempt['tracks'].append(track)
                        else:
                            attempt['trackErrors'].append('Malformed track readback: '+row)
            except subprocess.TimeoutExpired as error:
                last_error_number = -1712
                decode = lambda value: value.decode('utf-8','replace') if isinstance(value,bytes) else value or ''
                attempt.update(timedOut=True,timeoutSeconds=error.timeout,
                    partialStdout=decode(error.stdout),stderr=decode(error.stderr))
            track_error_numbers = attempt.get('trackErrorNumbers',[])
            critical_error = next((number for number in track_error_numbers if number in {-1743,-600}),None)
            if critical_error is not None:
                last_error_number = critical_error
            elif track_error_numbers and all(number==-1712 for number in track_error_numbers):
                last_error_number = -1712
            import_report['attempts'].append(attempt)
            save('music-import-observations.json',import_report)
            if last_error_number in {-1743,-600}:
                setup_failure('Actual Music playlist readback was denied or its process disappeared.',last_error_number)
            matches = {key:[row for row in attempt['tracks']
                if row.get('importedFileSHA256')==original_hashes[key]
                and row['persistentID'] and row['actualTitle']
                and abs(row['durationSeconds']-fixture['durationSeconds'])<1] for key in expected}
            if (attempt['trackCount']==len(expected) and not attempt['trackErrors']
                    and all(len(rows)==1 for rows in matches.values())):
                selected = {key:rows[0] for key,rows in matches.items()}
                if (len({row['persistentID'] for row in selected.values()})==len(expected)
                        and len({row['location'] for row in selected.values()})==len(expected)):
                    return selected
            time.sleep(.25)
        setup_failure('The actual playlist did not expose the required distinct original files within 12 seconds; see music-import-observations.json.',last_error_number)

    wait_for_imports(['first'],'wait for first original')
    checked_setup_command('import second original','''tell application "Music"
        set testPlaylist to first user playlist whose name is ''' + apple_string(playlist_name) + '''
        add POSIX file ''' + apple_string(second_audio) + ''' to testPlaylist
    end tell''')
    imported = wait_for_imports(['first','second'],'wait for both originals')
    first, second = imported['first'], imported['second']
    import_report['selectedSources'] = [first,second]
    save('music-import-observations.json',import_report)
    # Both files are verified before starting the actual playlist. Keep the
    # current-source readback and production next/previous checks independent.
    play_script = '''tell application "Music"
        set testPlaylist to first user playlist whose name is ''' + apple_string(playlist_name) + '''
        set shuffle enabled to false
        set song repeat to off
        play testPlaylist
    end tell'''
    (out/'music-select-first.applescript').write_text(play_script)
    checked_setup_command('select verified original in this playlist',play_script)
    read_current_script = '''tell application "Music"
        set actualState to player state as string
        set actualPosition to player position as string
        set actualID to persistent ID of current track as string
        set actualTitle to name of current track as string
        set actualLocation to get location of current track
    end tell
    set actualPath to POSIX path of actualLocation
    return actualState & tab & actualPosition & tab & actualID & tab & actualTitle & tab & actualPath'''
    (out/'music-current-readback.applescript').write_text(read_current_script)
    play_deadline = time.monotonic()+12
    current = None
    last_play_error = 10001
    while time.monotonic()<play_deadline:
        observed = apple(read_current_script,timeout=max(.25,min(4,play_deadline-time.monotonic())))
        setup_log('current playback readback',observed)
        values = observed.stdout.strip().split('\t')
        row = {'exitCode':observed.returncode,'stderr':observed.stderr,'observedUptime':time.monotonic()}
        last_play_error = 10001
        if observed.returncode==0 and len(values)==5:
            row.update(state=values[0],positionSeconds=float(values[1]),persistentID=values[2],
                       actualTitle=values[3],location=values[4])
            if (row['state']=='playing' and row['persistentID']==first['persistentID']
                    and row['actualTitle']==first['actualTitle'] and row['location']==first['location']):
                current = row
        elif observed.returncode:
            number = re.search(r'\((-?\d+)\)\s*$',observed.stderr)
            last_play_error = int(number[1]) if number else 10001
        import_report['currentTrackReadbacks'].append(row)
        save('music-import-observations.json',import_report)
        if last_play_error in {-1743,-600}:
            setup_failure('Actual Music current-track readback was denied or its process disappeared.',last_play_error)
        if current is not None:
            break
        time.sleep(.25)
    if current is None:
        setup_failure('Music did not confirm the verified first source as its actual playing track within 12 seconds.',last_play_error)
    # Optional context evidence only. An unavailable playlist property cannot
    # replace, relax or add a gate to the actual source/transport checks.
    playlist_context = {'status':'UNAVAILABLE','qualificationGate':False}
    try:
        observed = apple('''tell application "Music"
            set observedPlaylist to current playlist
            return (name of observedPlaylist as string) & tab & (persistent ID of observedPlaylist as string)
        end tell''',timeout=3)
        values = observed.stdout.strip().split('\t')
        playlist_context.update(exitCode=observed.returncode,stdout=observed.stdout,stderr=observed.stderr)
        if observed.returncode==0 and len(values)==2:
            playlist_context.update(status='OBSERVED',name=values[0],persistentID=values[1])
    except subprocess.TimeoutExpired:
        playlist_context.update(timedOut=True,timeoutSeconds=3)
    save('music-current-playlist.json',playlist_context)
    fields = [first['actualTitle'],first['persistentID'],str(first['durationSeconds']),first['location'],
              second['actualTitle'],second['persistentID'],str(second['durationSeconds']),second['location'],
              current['state'],str(current['positionSeconds']),current['persistentID']]
    setup_readback = '\t'.join(fields)
    setup_ui_result = stop_cloud_ui(permission_helper); permission_helper = None
    save('setup-permission-ui.json',setup_ui_result)
    # Independently link actual imported files to the authored bytes; merely
    # returning the desired song title is not proof that this audio is playing.
    title, first_id, first_duration, first_location, second_title, second_id, second_duration, second_location, _, initial_position, current_id = fields
    music_sources = []
    for observed_title, persistent_id, duration, location, original in [
            (title,first_id,first_duration,first_location,audio),
            (second_title,second_id,second_duration,second_location,second_audio)]:
        file_hash = hashlib.sha256(Path(location).read_bytes()).hexdigest()
        expected_hash = hashlib.sha256(original.read_bytes()).hexdigest()
        music_sources.append({'actualTitle':observed_title,'persistentID':persistent_id,
            'durationSeconds':float(duration),'location':location,'importedFileSHA256':file_hash,
            'originalFileSHA256':expected_hash,'identicalOriginalAudio':file_hash == expected_hash})
    source_verified = (title != second_title and first_id != second_id and current_id == first_id
        and all(row['identicalOriginalAudio'] and abs(row['durationSeconds']-fixture['durationSeconds']) < 1
                for row in music_sources))
    save('music-source-readback.json',{'status':'PASS' if source_verified else 'FAIL',
        'temporaryPlaylist':playlist_name,'actualPlayerPosition':float(initial_position),
        'currentPersistentID':current_id,'sources':music_sources,'metadataEdited':False,'accountUsed':False})
    if not source_verified:
        save('cloud-music.json',{'status':'FAIL','stage':'actual imported source verification',
            'reason':'The real playlist, imported file hashes, duration or current track did not match the two original recordings.',
            'realPlayerTestStarted':False})
        raise SystemExit(1)
    music_environment('music-playing')
    stage = 'ordinary LyricTile verification'
    first_use = setup_ui_result.get('accessibilityAlreadyTrusted') is True
    settings = dict(appearance='light',largeText=False,showTranslation=False,onlineLyrics=False,
        hideWhenIdle=True,showInFullScreen=False,coordinateTiles=True,preferredPlayer='appleMusic',completedWelcome=not first_use)
    subprocess.run(['/usr/bin/defaults','write','com.holdsnow.lyrictile','LyricTile.settings.v1','-data',
                    json.dumps(settings).encode().hex()],check=True)
    # Compile and establish input-helper availability before the app's timed
    # verification begins; neither helper is included in runtime sampling.
    pointer_helper = start_cloud_pointer(out, seconds=180)
    permission_helper = start_cloud_ui(out/'app-ui', 'music', seconds=180,
        welcome_ready=out/'first-use-ready.json' if first_use else None)
    arguments = [str(a.app.resolve()/'Contents/MacOS/LyricTile'),'--verify-native-player',
        '--verification-output',str(out),'--verification-lyrics',str(lyrics),'--verification-title',title,
        '--verification-next-title',second_title,'--verification-next-lyrics',str(second_lyrics),
        '--verification-hold-seconds','75']
    if first_use: arguments += ['--verification-first-use']
    stdout = (out/'app.stdout.log').open('w'); stderr = (out/'app.stderr.log').open('w')
    process = subprocess.Popen(arguments,stdout=stdout,stderr=stderr,start_new_session=True)
    deadline = time.monotonic()+180
    while process.poll() is None and not (out/'native-player-ready.json').exists() and time.monotonic()<deadline:
        time.sleep(.5)
    # Stop AX traversal before performance sampling; helper CPU is not part of
    # the ordinary production workload and must not obscure resource evidence.
    save('app-permission-ui.json', stop_cloud_ui(permission_helper)); permission_helper = None
    stop_cloud_pointer(pointer_helper); pointer_helper = None
    if (out/'native-player-ready.json').exists() and process.poll() is None:
        save('cloud-desktop-capture.json',capture_desktop('real-music-cloud-desktop','before runtime sampling'))
        stage = 'runtime measurement'
        subprocess.run(['python3',str(Path(__file__).with_name('measure-runtime.py')),'--pid',str(process.pid),
            '--seconds','60','--mode','line','--output',str(out/'performance')],check=True,timeout=85)
    app_timed_out = False
    stage = 'ordinary LyricTile completion'
    try: process.wait(timeout=100)
    except subprocess.TimeoutExpired:
        app_timed_out = True
        os.killpg(process.pid,signal.SIGTERM); process.wait(timeout=5)
    stdout.close(); stderr.close()
    report = json.loads((out/'native-player.json').read_text()) if (out/'native-player.json').exists() else {
        'status':'FAIL','reason':'The ordinary app timed out without a completed report.' if app_timed_out
            else 'The ordinary app exited without a completed verification report; inspect the exit code and app logs.'}
    if report.get('status') == 'PASS' and process.returncode != 0:
        report['status'] = 'FAIL'
        report['reason'] = 'Native checks completed, but the ordinary app did not exit successfully.'
    report.update(host=platform.platform(),appExitCode=process.returncode,realPlayerSetup=setup_readback)
    save('cloud-music.json', report)
    print(json.dumps({'status':report['status'],'scope':'native app with real Music and original local audio',
        'checks':len(report.get('checks',[]))}))
    if report['status']=='FAIL': raise SystemExit(1)
except subprocess.TimeoutExpired as e:
    def decoded(value):
        return value.decode('utf-8','replace') if isinstance(value,bytes) else value or ''
    timeout_log = 'music-setup.log' if process is None else 'native-timeout.log'
    (out/timeout_log).write_text(decoded(e.stdout)+decoded(e.stderr)+'\nTimed out during '+stage+'\n')
    save('timeout.json',{'stage':stage,'stdout':decoded(e.stdout),'stderr':decoded(e.stderr),
        'timeoutSeconds':e.timeout,'command':str(e.cmd)})
    environment = music_environment('music-at-timeout')
    capture_desktop('music-timeout-desktop','timeout during '+stage)
    save('cloud-music.json', {'status':'FAIL' if process is not None else 'BLOCKED',
        'stage':stage,'musicEnvironment':environment,
        'reason':'Native app or runtime measurement timed out' if process is not None else 'Music setup/permission command timed out',
        'command':str(e.cmd),'realPlayerTestStarted':process is not None})
    if process is not None:
        raise SystemExit(1)
finally:
    if pointer_helper:
        stop_cloud_pointer(pointer_helper)
    if permission_helper:
        save('unfinished-permission-ui.json', stop_cloud_ui(permission_helper))
    if process and process.poll() is None:
        os.killpg(process.pid,signal.SIGTERM)
        try: process.wait(timeout=5)
        except subprocess.TimeoutExpired: os.killpg(process.pid,signal.SIGKILL)
    try: apple('tell application "Music" to quit',timeout=8)
    except subprocess.TimeoutExpired: pass
    if music_launch_attempted:
        # Only the system Music processes launched in this disposable run are
        # eligible for fallback cleanup; no unrelated application is terminated.
        remaining = music_environment('music-before-cleanup')
        killed = []
        for row in remaining['processes']:
            if row['pid'] not in music_baseline_pids:
                try:
                    os.kill(row['pid'],signal.SIGTERM)
                    killed.append(row['pid'])
                except ProcessLookupError:
                    pass
        save('music-cleanup.json',{'terminatedOwnPIDs':killed,'preexistingPIDs':sorted(music_baseline_pids)})
    subprocess.run(['/usr/bin/defaults','delete','com.holdsnow.lyrictile','LyricTile.settings.v1'],
        stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
