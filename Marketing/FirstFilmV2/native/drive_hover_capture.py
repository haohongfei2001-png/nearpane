#!/usr/bin/env python3
"""Verify the evidenced bridge candidate and film actual native cover on hover."""
import argparse,json,os,subprocess,time
from pathlib import Path
from cloud_ui import start_cloud_ui,stop_cloud_ui
p=argparse.ArgumentParser();p.add_argument('--app',type=Path,required=True);p.add_argument('--recorder',type=Path,required=True);p.add_argument('--baseline',type=Path,required=True);p.add_argument('--output',type=Path,required=True);a=p.parse_args()
assert os.environ.get('GITHUB_ACTIONS')=='true'
decision=json.loads((a.baseline/'artwork-candidate-decision.json').read_text())
if decision['status']!='APPLIED_UNRELEASED_CANDIDATE':raise SystemExit('No evidenced artwork candidate to capture')
events=json.loads((a.baseline/'driver-events.json').read_text())['events']
assert any(x['event']=='real-music-import-and-play' and 'Good To Go' in x.get('readback','') for x in events)
out=a.output.resolve();out.mkdir(parents=True,exist_ok=True)
def save(name,d):(out/name).write_text(json.dumps(d,ensure_ascii=False,indent=2)+'\n')
def apple(s):
    r=subprocess.run(['/usr/bin/osascript','-e',s],capture_output=True,text=True,timeout=12)
    if r.returncode:raise RuntimeError(r.stderr)
    return r.stdout.strip()
def wait(name,seconds):
    deadline=time.monotonic()+seconds
    while time.monotonic()<deadline:
        try:return json.loads((out/name).read_text())
        except (OSError,ValueError):time.sleep(.1)
    raise RuntimeError('Timed out: '+name)
permission=start_cloud_ui(out/'permission-ui','music',seconds=80);app=None;recorder=None
try:
    identity=apple('tell application "Music" to return {name of current track,artist of current track,persistent ID of current track}')
    assert 'Good To Go' in identity and 'Josh Woodward' in identity
    apple('tell application "Music" to play');time.sleep(.4)
    apple('tell application "Music" to set player position to 161.60')
    position=apple('tell application "Music" to get player position')
    env=os.environ.copy();env.update(FILM_V2_OUTPUT=str(out),FILM_V2_LRC=str(Path(__file__).with_name('good-to-go-selected-sourceclock.lrc')),FILM_V2_DISPLAY_ID=os.environ['NEARPANE_FILM_DISPLAY_ID'],FILM_V2_REQUIRE_ARTWORK='1')
    app=subprocess.Popen([str(a.app/'Contents/MacOS/FilmV2Capture')],env=env,stdout=(out/'camera-host.log').open('w'),stderr=subprocess.STDOUT)
    ready=wait('ready.json',25)
    assert ready.get('artworkDecoded') and ready.get('artworkBytes',0)>0
    apple('tell application "Music" to set player position to 161.60')
    try:apple('tell application "System Events" to set visible of process "Music" to false')
    except Exception:pass
    subprocess.run(['/usr/sbin/screencapture','-x','-D',os.environ['NEARPANE_FILM_SCREEN_INDEX'],str(out/'candidate-ordinary-frame-4k.png')],check=True)
    recorder=subprocess.Popen([str(a.recorder),os.environ['NEARPANE_FILM_DISPLAY_ID'],'9',str(out/'hover-fullscreen.mov')],stdout=(out/'recorder.log').open('w'),stderr=subprocess.STDOUT)
    wait('capture-first-frame.json',15);started=time.monotonic()
    timeline=[]
    for offset,action in [(1.5,'enter'),(7,'leave')]:
        while time.monotonic()<started+offset:time.sleep(.03)
        (out/'pointer-command.json').write_text(json.dumps({'action':action}))
        timeline.append({'event':action,'monotonic':time.monotonic(),'playerReadback':apple('tell application "Music" to return {player state,player position}')})
        if action=='enter':
            time.sleep(.9)
            subprocess.run(['/usr/sbin/screencapture','-x','-C','-D',os.environ['NEARPANE_FILM_SCREEN_INDEX'],str(out/'candidate-hover-frame-4k.png')],check=True)
    recorder.wait(timeout=15)
    if recorder.returncode:raise RuntimeError('Recorder failed')
    save('candidate-result.json',{'status':'CAPTURED','actualMusicIdentity':identity,'initialPosition':position,'nativeArtworkBytes':ready['artworkBytes'],'nativeArtworkSHA256':ready.get('artworkSHA256'),'actualDecodedArtwork':True,'events':timeline,'scope':'Unreleased real CPlayerBridge typed-descriptor candidate, only enabled after baseline descriptor/image/identity proof; no graphic replacement'})
except Exception as error:
    save('candidate-result.json',{'status':'BLOCKED','error':str(error)});raise
finally:
    (out/'stop').touch()
    if app:
        try:app.wait(timeout=8)
        except subprocess.TimeoutExpired:app.terminate()
    if recorder and recorder.poll() is None:recorder.terminate()
    save('permission-result.json',stop_cloud_ui(permission))
