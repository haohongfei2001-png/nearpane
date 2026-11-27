#!/usr/bin/env python3
"""Disposable macOS runner: real Music playback, ordinary app, original media.

This does not change TCC, log into an account, fetch copyrighted recordings, or
substitute snapshots. BLOCKED remains distinct from a real application failure.
"""
import argparse
import hashlib
import json
import math
import os
import platform
import signal
import struct
import subprocess
import time
import wave
from pathlib import Path

p = argparse.ArgumentParser()
p.add_argument('app', type=Path)
p.add_argument('--output', type=Path, required=True)
a = p.parse_args()
if os.environ.get('GITHUB_ACTIONS') != 'true' or platform.system() != 'Darwin':
    p.error('Only run on a disposable GitHub Actions macOS host.')
out = a.output.resolve()
out.mkdir(parents=True, exist_ok=True)
title = 'LyricTile Cloud Original 20261127'
audio = out / 'original-chimes.wav'
lyrics = out / 'original-lyrics.lrc'
process = None

def save(name, obj):
    (out / name).write_text(json.dumps(obj, ensure_ascii=False, indent=2) + '\n')

def apple(script, timeout=25):
    return subprocess.run(['/usr/bin/osascript', '-e', script], capture_output=True, text=True, timeout=timeout)

try:
    # A short original repeating chime score, written here, with no third-party
    # sound recording. Actual decoded audio advances in the Music application.
    rate = 22050
    with wave.open(str(audio), 'wb') as f:
        f.setparams((1, 2, rate, 0, 'NONE', 'not compressed'))
        for second in range(180):
            freq = [261.63, 329.63, 392.0, 440.0][(second // 4) % 4]
            f.writeframes(b''.join(struct.pack('<h', int(2200 * math.sin(2 * math.pi * freq * i / rate)
                * min(1, i / (rate * .03)) * max(0, 1-i/rate))) for i in range(rate)))
    lines = ['光慢慢落在窗边', 'A quiet note beside the window', '把这一刻轻轻留下',
             'The melody returns, and the words find their place beside the work we carry on',
             '不必离开正在做的事', 'Let the next line arrive in its own time']
    lyrics.write_text('\n'.join(f'[{s//60:02d}:{s%60:02d}.00]{lines[(s//8)%len(lines)]}' for s in range(0,180,8))+'\n')
    save('media-provenance.json', {'origin':'original generated chime score and original bilingual test text',
        'notBundledWithProduct':True,'durationSeconds':180,'audioSHA256':hashlib.sha256(audio.read_bytes()).hexdigest(),
        'lyricSHA256':hashlib.sha256(lyrics.read_bytes()).hexdigest(),'streamingSubscription':False})
    setup = apple('''tell application "Music"
        launch
        set sound volume to 0
        set addedTracks to add POSIX file "''' + str(audio) + '''"
        set testTrack to item 1 of addedTracks
        set name of testTrack to "''' + title + '''"
        set artist of testTrack to "HOLDSNOW Verification"
        set album of testTrack to "Original Cloud Acceptance Audio"
        play testTrack
        delay 2
        return (name of current track) & " | " & (player state as string) & " | " & (player position as string)
    end tell''')
    (out / 'music-setup.log').write_text(setup.stdout + setup.stderr)
    if setup.returncode or title not in setup.stdout or 'playing' not in setup.stdout:
        save('cloud-music.json', {'status':'BLOCKED','stage':'Music local playback setup','exitCode':setup.returncode,
             'details':setup.stdout+setup.stderr,'realPlayerTestStarted':False})
        raise SystemExit(0)
    settings = dict(appearance='light',largeText=False,showTranslation=False,onlineLyrics=False,
        hideWhenIdle=True,showInFullScreen=False,coordinateTiles=True,preferredPlayer='appleMusic',completedWelcome=True)
    subprocess.run(['/usr/bin/defaults','write','com.holdsnow.lyrictile','LyricTile.settings.v1','-data',
                    json.dumps(settings).encode().hex()],check=True)
    stdout = (out/'app.stdout.log').open('w'); stderr = (out/'app.stderr.log').open('w')
    process = subprocess.Popen([str(a.app.resolve()/'Contents/MacOS/LyricTile'),'--verify-native-player',
        '--verification-output',str(out),'--verification-lyrics',str(lyrics),'--verification-title',title,
        '--verification-hold-seconds','75'],stdout=stdout,stderr=stderr,start_new_session=True)
    deadline = time.monotonic()+110
    while process.poll() is None and not (out/'native-player-ready.json').exists() and time.monotonic()<deadline:
        time.sleep(.5)
    if (out/'native-player-ready.json').exists() and process.poll() is None:
        subprocess.run(['python3',str(Path(__file__).with_name('measure-runtime.py')),'--pid',str(process.pid),
            '--seconds','60','--mode','line','--output',str(out/'performance')],check=True,timeout=85)
    app_timed_out = False
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
    save('cloud-music.json', {'status':'FAIL' if process is not None else 'BLOCKED',
        'reason':'Native app or runtime measurement timed out' if process is not None else 'Music setup/permission command timed out',
        'command':str(e.cmd),'realPlayerTestStarted':process is not None})
    if process is not None:
        raise SystemExit(1)
finally:
    if process and process.poll() is None:
        os.killpg(process.pid,signal.SIGTERM)
        try: process.wait(timeout=5)
        except subprocess.TimeoutExpired: os.killpg(process.pid,signal.SIGKILL)
    try: apple('tell application "Music" to quit',timeout=8)
    except subprocess.TimeoutExpired: pass
    subprocess.run(['/usr/bin/defaults','delete','com.holdsnow.lyrictile','LyricTile.settings.v1'],
        stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
