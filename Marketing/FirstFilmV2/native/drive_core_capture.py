#!/usr/bin/env python3
"""One bounded native take: actual licensed song -> actual Preview document."""
import argparse,json,os,platform,subprocess,time
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

permission=None;app=None;recorder=None
try:
    # No existing player or personal library is touched; this is a fresh VM.
    baseline=subprocess.run(['pgrep','-x','Music'],capture_output=True,text=True)
    if baseline.stdout.strip():raise RuntimeError('Music was already running before the isolated take')
    permission=start_cloud_ui(out/'permission-ui','music',seconds=150)
    subprocess.run(['open','-a','Music'],check=True)
    playlist='Nearpane Film '+os.environ['GITHUB_RUN_ID']
    apple('tell application "Music"\nset sound volume to 72\nset filmList to make new user playlist with properties {name:'+quote(playlist)+'}\nadd POSIX file '+quote(a.audio.resolve())+' to filmList\nend tell',timeout=50)
    apple('tell application "Music"\nset filmList to first user playlist whose name is '+quote(playlist)+'\nplay first track of filmList\nset player position to 147.60\nend tell')
    time.sleep(.8)
    identity=apple('tell application "Music" to return {name of current track,artist of current track,album of current track,persistent ID of current track,player position,count of artworks of current track}')
    event('real-music-import-and-play',readback=identity)
    if 'Good To Go' not in identity or 'Josh Woodward' not in identity:raise RuntimeError('Actual Music source identity did not match')
    env=os.environ.copy();env['FILM_V2_OUTPUT']=str(out);env['FILM_V2_LRC']=str(Path(__file__).with_name('good-to-go-selected-sourceclock.lrc'))
    env['FILM_V2_DISPLAY_ID']=os.environ['NEARPANE_FILM_DISPLAY_ID']
    env['FILM_V2_WALLPAPER']=str(a.wallpaper.resolve())
    log=(out/'camera-host.log').open('w')
    app=subprocess.Popen([str(a.app/'Contents/MacOS/FilmV2Capture')],env=env,stdout=log,stderr=log)
    ready=wait_json('ready.json',80);event('native-product-ready',ready=ready)
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
    apple('tell application "Music"\npause\nset player position to 147.60\nend tell')
    time.sleep(.6)
    snap('core-first-frame-4k.png')
    event('capture-source-position',readback=apple('tell application "Music" to return {player state,player position,name of current track}'))
    recorder=subprocess.Popen([str(a.recorder),os.environ['NEARPANE_FILM_DISPLAY_ID'],'18',str(out/'core-fullscreen.mov')],stdout=(out/'recorder.log').open('w'),stderr=subprocess.STDOUT)
    started=wait_json('capture-started.json',25)
    first=wait_json('capture-first-frame.json',10)
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
    event('preview-frontmost',readback=apple('tell application "Music" to return {player state,player position,name of current track}'))
    time.sleep(1)
    snap('core-document-frame-4k.png')
    for offset,action in [(12,'enter'),(14.4,'leave')]:
        while time.monotonic()<take_start+offset:time.sleep(.04)
        (out/'pointer-command.json').write_text(json.dumps({'action':action}))
        event('native-pointer-'+action)
    recorder.wait(timeout=30)
    if recorder.returncode:raise RuntimeError('Actual screen/audio recorder failed')
    event('core-complete',readback=apple('tell application "Music" to return {player state,player position,name of current track}'))
    save('core-result.json',{'status':'CAPTURED','player':'Apple Music','sourceTrack':'Good To Go','artist':'Josh Woodward','durationRequested':18,'actualPlayback':True,'artworkFromActualPlayer':True,'desktopNative':True,'sourceView':'NearpaneLyricsModule','workflowRun':os.environ['GITHUB_RUN_ID'],'limitations':['Isolated photography host, not a release Host qualification','LRC real lyrics, ASR-derived source-clock timings pending final listening check']})
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
    if permission:save('permission-result.json',stop_cloud_ui(permission))
    apple('tell application "Music" to pause',required=False)
