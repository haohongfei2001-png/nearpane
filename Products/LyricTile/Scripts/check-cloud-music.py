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
    with wave.open(str(audio), 'wb') as f:
        f.setparams((1, 2, rate, 0, 'NONE', 'not compressed'))
        for second in range(fixture['durationSeconds']):
            frequencies = fixture['frequenciesHz']
            freq = frequencies[(second // fixture['noteDurationSeconds']) % len(frequencies)]
            f.writeframes(b''.join(struct.pack('<h', int(fixture['peakAmplitude'] * math.sin(2 * math.pi * freq * i / rate)
                * min(1, i / (rate * fixture['fadeInSeconds'])) * max(0, 1-i/rate))) for i in range(rate)))
    lines = fixture['lyricLines']
    interval = fixture['lyricIntervalSeconds']
    lyrics.write_text('\n'.join(f'[{s//60:02d}:{s%60:02d}.00]{lines[(s//interval)%len(lines)]}'
        for s in range(0,fixture['durationSeconds'],interval))+'\n')
    save('media-provenance.json', {'origin':fixture['origin'], 'title':title,
        'fixtureSHA256':hashlib.sha256(fixture_bytes).hexdigest(),
        'notBundledWithProduct':True,'durationSeconds':fixture['durationSeconds'],'audioSHA256':hashlib.sha256(audio.read_bytes()).hexdigest(),
        'lyricSHA256':hashlib.sha256(lyrics.read_bytes()).hexdigest(),'streamingSubscription':False})
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
    permission_helper = start_cloud_ui(out/'setup-ui', 'music', seconds=40)
    stage = 'Music AppleScript import and play'
    setup = apple('''tell application "Music"
        set sound volume to 0
        set addedTracks to add POSIX file ''' + apple_string(audio) + '''
        if class of addedTracks is list then
            set testTrack to item 1 of addedTracks
        else
            set testTrack to addedTracks
        end if
        set name of testTrack to ''' + apple_string(title) + '''
        set artist of testTrack to ''' + apple_string(fixture['artist']) + '''
        set album of testTrack to ''' + apple_string(fixture['album']) + '''
        play testTrack
        delay 2
        return (name of current track) & " | " & (player state as string) & " | " & (player position as string)
    end tell''')
    setup_ui_result = stop_cloud_ui(permission_helper); permission_helper = None
    save('setup-permission-ui.json', setup_ui_result)
    (out / 'music-setup.log').write_text(setup.stdout + setup.stderr)
    if setup.returncode or title not in setup.stdout or 'playing' not in setup.stdout:
        environment = music_environment('music-setup-failure')
        capture_desktop('music-setup-failure-desktop','failed AppleScript import and play')
        harness_error = any(value in setup.stderr for value in ['(-1728)','(-1700)','syntax error'])
        save('cloud-music.json', {'status':'FAIL' if harness_error else 'BLOCKED',
             'failureClass':'test_harness_setup' if harness_error else 'player_setup',
             'stage':'Music local playback setup','exitCode':setup.returncode,
             'details':setup.stdout+setup.stderr,'musicEnvironment':environment,'realPlayerTestStarted':False})
        raise SystemExit(1 if harness_error else 0)
    music_environment('music-playing')
    stage = 'ordinary LyricTile verification'
    first_use = setup_ui_result.get('accessibilityAlreadyTrusted') is True
    settings = dict(appearance='light',largeText=False,showTranslation=False,onlineLyrics=False,
        hideWhenIdle=True,showInFullScreen=False,coordinateTiles=True,preferredPlayer='appleMusic',completedWelcome=not first_use)
    subprocess.run(['/usr/bin/defaults','write','com.holdsnow.lyrictile','LyricTile.settings.v1','-data',
                    json.dumps(settings).encode().hex()],check=True)
    # Compile and establish input-helper availability before the app's timed
    # verification begins; neither helper is included in runtime sampling.
    pointer_helper = start_cloud_pointer(out, seconds=120)
    permission_helper = start_cloud_ui(out/'app-ui', 'music', seconds=115,
        welcome_ready=out/'first-use-ready.json' if first_use else None)
    arguments = [str(a.app.resolve()/'Contents/MacOS/LyricTile'),'--verify-native-player',
        '--verification-output',str(out),'--verification-lyrics',str(lyrics),'--verification-title',title,
        '--verification-hold-seconds','75']
    if first_use: arguments += ['--verification-first-use']
    stdout = (out/'app.stdout.log').open('w'); stderr = (out/'app.stderr.log').open('w')
    process = subprocess.Popen(arguments,stdout=stdout,stderr=stderr,start_new_session=True)
    deadline = time.monotonic()+110
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
    report.update(host=platform.platform(),appExitCode=process.returncode,realPlayerSetup=setup.stdout.strip())
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
