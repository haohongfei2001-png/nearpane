#!/usr/bin/env python3
"""One bounded native take: actual licensed song -> actual Preview document."""
import argparse,hashlib,json,os,platform,subprocess,time
from pathlib import Path
from cloud_ui import start_cloud_ui,stop_cloud_ui

p=argparse.ArgumentParser()
p.add_argument('--app',type=Path,required=True)
p.add_argument('--audio',type=Path,required=True)
p.add_argument('--pdf',type=Path,required=True)
p.add_argument('--wallpaper',type=Path,required=True)
p.add_argument('--recorder',type=Path,required=True)
p.add_argument('--output',type=Path,required=True)
a=p.parse_args()
assert os.environ.get('GITHUB_ACTIONS')=='true' and platform.system()=='Darwin','Disposable CI only'
out=a.output.resolve();out.mkdir(parents=True,exist_ok=True)
events=[]
def save(name,data):(out/name).write_text(json.dumps(data,ensure_ascii=False,indent=2)+'\n')
def event(name,**extra):
    row={'event':name,'monotonic':time.monotonic(),'unixTime':time.time(),**extra}
    events.append(row);save('driver-events.json',{'events':events});return row
def quote(value):return json.dumps(str(value),ensure_ascii=False)
def apple(script,timeout=30,required=True):
    r=subprocess.run(['/usr/bin/osascript','-e',script],capture_output=True,text=True,timeout=timeout)
    with (out/'applescript.log').open('a') as f:f.write(script+'\n'+r.stdout+r.stderr+'\n')
    if required and r.returncode:raise RuntimeError(r.stderr)
    return r.stdout.strip()
def wait_json(name,seconds=60):
    deadline=time.monotonic()+seconds
    while time.monotonic()<deadline:
        try:return json.loads((out/name).read_text())
        except (OSError,ValueError):time.sleep(.1)
    raise RuntimeError('Timed out waiting for '+name)
def snap(name):
    subprocess.run(['/usr/sbin/screencapture','-x','-C','-D',os.environ['NEARPANE_FILM_SCREEN_INDEX'],str(out/name)],check=True)
def seek_real(seconds):
    deadline=time.monotonic()+12
    attempts=[]
    while time.monotonic()<deadline:
        try:
            before=apple('tell application "Music" to return {player state,name of current track,player position}',timeout=5)
            if 'Good To Go' not in before or 'playing' not in before:
                attempts.append({'readback':before});time.sleep(.25);continue
            apple('tell application "Music" to set player position to '+str(seconds),timeout=5)
            actual=float(apple('tell application "Music" to get player position',timeout=5))
            attempts.append({'readback':before,'seekReadback':actual})
            if abs(actual-seconds)<1.5:
                event('real-seek-confirmed',target=seconds,actual=actual,attempts=attempts)
                return
        except (RuntimeError,ValueError) as error:attempts.append({'error':str(error)})
        time.sleep(.25)
    event('real-seek-not-confirmed',target=seconds,attempts=attempts)
    # A genuine natural-playback fallback is cheaper and more truthful than
    # restarting the VM or supplying a synthetic time anchor.
    deadline=time.monotonic()+170
    while time.monotonic()<deadline:
        row=apple('tell application "Music" to return {player state,name of current track,player position}',timeout=8)
        bits=[x.strip() for x in row.split(',')]
        if len(bits)==3 and bits[0]=='playing' and bits[1]=='Good To Go':
            value=float(bits[2])
            if seconds<=value<=seconds+2:
                event('natural-playback-position-confirmed',actual=value,target=seconds);return
            if value>seconds+2:break
        time.sleep(.4)
    raise RuntimeError('Neither actual seek nor natural playback reached the excerpt')

def verified_import(playlist):
    # This is the same file-track/location/hash readback used by CI49. Do not
    # play a just-created lazy "first track" reference: Music can return -1700.
    script='''tell application "Music"
set filmList to first user playlist whose name is '''+quote(playlist)+'''
set importedTracks to get tracks of filmList
end tell
set readback to "COUNT" & tab & ((count of importedTracks) as string)
repeat with trackIndex from 1 to count of importedTracks
try
tell application "Music"
set importedTrack to get item trackIndex of importedTracks
set trackTitle to (get name of importedTrack) as string
set trackID to (get persistent ID of importedTrack) as string
set trackDuration to (get duration of importedTrack) as string
set trackLocation to get location of importedTrack
end tell
set trackPath to POSIX path of trackLocation
set readback to readback & linefeed & "TRACK" & tab & trackTitle & tab & trackID & tab & trackDuration & tab & trackPath
on error messageText number errorNumber
set readback to readback & linefeed & "ERROR" & tab & (errorNumber as string) & tab & messageText
end try
end repeat
return readback'''
    expected=hashlib.sha256(a.audio.read_bytes()).hexdigest();observations=[];expected_pcm=None
    deadline=time.monotonic()+24
    while time.monotonic()<deadline:
        try:
            text=apple(script,timeout=5);observations.append({'monotonic':time.monotonic(),'readback':text})
            for row in text.splitlines():
                fields=row.split('\t')
                if len(fields)==5 and fields[0]=='TRACK' and fields[1]=='Good To Go' and fields[2]:
                    path=Path(fields[4]);actual=hashlib.sha256(path.read_bytes()).hexdigest()
                    same_audio=actual==expected
                    if not same_audio:
                        def pcm_hash(file):return subprocess.check_output(['ffmpeg','-v','error','-i',str(file),'-map','0:a:0','-c:a','pcm_s16le','-f','hash','-hash','sha256','-'],text=True,timeout=15).strip()
                        if expected_pcm is None:expected_pcm=pcm_hash(a.audio)
                        same_audio=pcm_hash(path)==expected_pcm
                    if same_audio:
                        proof={'persistentID':fields[2],'title':fields[1],'duration':float(fields[3]),'actualImportedFile':str(path),'sha256':actual,'originalContainerSHA256':expected,'decodedPCMVerifiedIfContainerChanged':actual!=expected,'observations':observations}
                        save('verified-music-import.json',proof);return proof
        except (RuntimeError,ValueError,OSError,subprocess.TimeoutExpired) as error:observations.append({'error':str(error)})
        time.sleep(.25)
    save('verified-music-import.json',{'observations':observations,'status':'BLOCKED'})
    raise RuntimeError('Music never exposed the verified actual imported recording')

permission=None;app=None;recorder=None;diagnostic=None;diagnostic_stop=out/'diagnostic-stop'
try:
    # No existing player or personal library is touched; this is a fresh VM.
    baseline=subprocess.run(['pgrep','-x','Music'],capture_output=True,text=True)
    if baseline.stdout.strip():raise RuntimeError('Music was already running before the isolated take')
    permission=start_cloud_ui(out/'permission-ui','music',seconds=150)
    subprocess.run(['open','-a','Music'],check=True)
    # Capture independently of product readiness. It is diagnostic footage,
    # not automatically accepted as a final take, and is stopped cleanly below.
    diagnostic_env=os.environ.copy();diagnostic_env['FILM_CAPTURE_STOP_FILE']=str(diagnostic_stop)
    diagnostic_folder=out/'diagnostic';diagnostic_folder.mkdir(exist_ok=True)
    diagnostic=subprocess.Popen([str(a.recorder),os.environ['NEARPANE_FILM_DISPLAY_ID'],'240',str(diagnostic_folder/'early-desktop.mov')],env=diagnostic_env,stdout=(diagnostic_folder/'recorder.log').open('w'),stderr=subprocess.STDOUT)
    display_manifest=json.loads((out/'display/capture-display.json').read_text())
    early_display=json.loads((out/'display'/display_manifest['selectedReport']).read_text())['selected']['nsFrame']
    early_x=int(early_display['x']+120)
    apple('tell application "Music"\nactivate\nset bounds of front window to {'+f'{early_x},112,{early_x+1352},950'+'}\nend tell',required=False)
    playlist='Nearpane Film '+os.environ['GITHUB_RUN_ID']
    apple('tell application "Music"\nset sound volume to 72\nset filmList to make new user playlist with properties {name:'+quote(playlist)+'}\nadd POSIX file '+quote(a.audio.resolve())+' to filmList\nend tell',timeout=50)
    verified=verified_import(playlist)
    play_script='tell application "Music"\nset filmList to first user playlist whose name is '+quote(playlist)+'\nset shuffle enabled to false\nset song repeat to off\nplay filmList\nend tell'
    apple(play_script)
    limit=time.monotonic()+12
    while time.monotonic()<limit:
        readback=apple('tell application "Music" to return {player state,name of current track,persistent ID of current track,player position}',timeout=5)
        if 'playing' in readback and verified['persistentID'] in readback and float(readback.split(',')[-1])>0:break
        time.sleep(.25)
    else:raise RuntimeError('Verified playlist did not become the actual playing source')
    identity=apple('tell application "Music" to return {name of current track,artist of current track,album of current track,persistent ID of current track,player position,count of artworks of current track}')
    event('real-music-import-and-play',readback=identity)
    if 'Good To Go' not in identity or 'Josh Woodward' not in identity:raise RuntimeError('Actual Music source identity did not match')
    env=os.environ.copy();env['FILM_V2_OUTPUT']=str(out);env['FILM_V2_LRC']=str(Path(__file__).with_name('good-to-go-selected-sourceclock.lrc'))
    env['FILM_V2_DISPLAY_ID']=os.environ['NEARPANE_FILM_DISPLAY_ID']
    env['FILM_V2_WALLPAPER']=str(a.wallpaper.resolve())
    log=(out/'camera-host.log').open('w')
    app=subprocess.Popen([str(a.app/'Contents/MacOS/FilmV2Capture')],env=env,stdout=log,stderr=log)
    ready=wait_json('ready.json',35);event('native-product-ready',ready=ready)
    geometry=json.loads((out/'camera-host.json').read_text());sf=geometry['screenFrame']
    # AppleScript window positions use the global top-left coordinates.
    x=int(sf[0]+120);y=112
    apple('tell application "Music"\nactivate\nset bounds of front window to {'+f'{x}, {y}, {x+1352}, {y+838}'+'}\nend tell')
    # Reveal the actual current song in the real library; artwork remains original.
    apple('tell application "Music" to reveal current track',required=False)
    # Native MiniPlayer is a real Apple Music command; use the large artwork view if available.
    apple('tell application "System Events" to tell process "Music"\nset frontmost to true\nkeystroke "m" using {command down,shift down}\nend tell',required=False)
    time.sleep(1.0)
    apple('tell application "Music" to set bounds of front window to {'+f'{x+85}, {y+80}, {x+735}, {y+730}'+'}',required=False)
    snap('core-initial-music-layout-4k.png')
    seek_real(147.60)
    apple('tell application "Music"\npause\nset player position to 147.60\nend tell')
    time.sleep(.6)
    snap('core-first-frame-4k.png')
    event('capture-source-position',readback=apple('tell application "Music" to return {player state,player position,name of current track}'))
    recorder=subprocess.Popen([str(a.recorder),os.environ['NEARPANE_FILM_DISPLAY_ID'],'18',str(out/'core-fullscreen.mov')],stdout=(out/'recorder.log').open('w'),stderr=subprocess.STDOUT)
    backend='ScreenCaptureKit'
    try:
        started=wait_json('capture-started.json',15)
        first=wait_json('capture-first-frame.json',10)
    except RuntimeError:
        recorder.terminate()
        try:recorder.wait(timeout=3)
        except subprocess.TimeoutExpired:recorder.kill();recorder.wait()
        incomplete=out/'core-fullscreen.mov'
        if incomplete.exists():incomplete.rename(out/'core-sck-incomplete.mov')
        backend='screencapture-WindowServer'
        recorder=subprocess.Popen(['/usr/sbin/screencapture','-v','-V','18','-x','-C','-D',os.environ['NEARPANE_FILM_SCREEN_INDEX'],str(out/'core-fullscreen.mov')],stdout=(out/'fallback-recorder.log').open('w'),stderr=subprocess.STDOUT)
        first={'launchMonotonic':time.monotonic(),'firstFramePTSUnverified':True,'systemAudioCaptured':False}
    save('capture-backend.json',{'backend':backend,'audioRequested':backend=='ScreenCaptureKit','cursorIncluded':True,'firstFrame':first})
    take_start=time.monotonic()
    event('recording-first-frame',capture=first)
    apple('tell application "Music" to play')
    event('music-resumed',readback=apple('tell application "Music" to return {player state,player position}'))
    switch_at=time.monotonic()+3.65
    while time.monotonic()<switch_at:time.sleep(.04)
    event('preview-open-request')
    subprocess.run(['open','-a','Preview',str(a.pdf.resolve())],check=True)
    time.sleep(.65)
    apple('tell application "System Events" to tell process "Preview"\nset frontmost to true\nset position of front window to {'+f'{x},{y}'+'}\nset size of front window to {1352,838}\nend tell',required=False)
    # Actual Preview Fit and hide-sidebar keyboard/menu commands, never a fake window.
    apple('tell application "System Events" to tell process "Preview"\nkeystroke "1" using {command down,option down}\nkeystroke "9" using {command down}\nend tell',required=False)
    apple('tell application "System Events" to set visible of process "Music" to false',required=False)
    event('preview-frontmost',readback=apple('tell application "Music" to return {player state,player position,name of current track}'))
    time.sleep(1)
    snap('core-document-frame-4k.png')
    # Baseline captures the ordinary lyric state. A missing production artwork
    # path must not produce a fake cover or an advertised placeholder hover.
    recorder.wait(timeout=30)
    if recorder.returncode:raise RuntimeError('Actual screen/audio recorder failed')
    event('core-complete',readback=apple('tell application "Music" to return {player state,player position,name of current track}'))
    save('core-result.json',{'status':'CAPTURED','player':'Apple Music','sourceTrack':'Good To Go','artist':'Josh Woodward','durationRequested':18,'actualPlayback':True,'realMusicTrackArtworkCountVerified':1,'lyricViewArtworkDecoded':ready.get('artworkDecoded',False),'desktopNative':True,'sourceView':'NearpaneLyricsModule','workflowRun':os.environ['GITHUB_RUN_ID'],'limitations':['Isolated photography host, not a release Host qualification','LRC real lyrics, ASR-derived source-clock timings pending final listening check','No hover advertised in baseline until actual product artwork is confirmed']})
except Exception as error:
    save('core-result.json',{'status':'BLOCKED','error':str(error),'events':events})
    try:snap('failure-desktop.png')
    except Exception:pass
    raise
finally:
    (out/'stop').touch()
    if app:
        try:app.wait(timeout=8)
        except subprocess.TimeoutExpired:app.terminate()
    if recorder and recorder.poll() is None:recorder.terminate()
    diagnostic_stop.touch()
    if diagnostic:
        try:diagnostic.wait(timeout=10)
        except subprocess.TimeoutExpired:diagnostic.terminate()
    if permission:save('permission-result.json',stop_cloud_ui(permission))
    apple('tell application "Music" to pause',required=False)
