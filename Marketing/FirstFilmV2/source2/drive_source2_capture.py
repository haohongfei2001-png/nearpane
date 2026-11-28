#!/usr/bin/env python3
"""One bounded real QQ Music take, official client + production lyric module + SCK audio."""
import argparse,hashlib,importlib.util,json,os,platform,plistlib,shutil,subprocess,tempfile,time
from pathlib import Path
from cloud_ui import start_cloud_ui,stop_cloud_ui

p=argparse.ArgumentParser()
p.add_argument('--app',type=Path,required=True)
p.add_argument('--audio',type=Path,required=True)
p.add_argument('--wallpaper',type=Path,required=True)
p.add_argument('--recorder',type=Path,required=True)
p.add_argument('--placement-helper',type=Path,required=True)
p.add_argument('--output',type=Path,required=True)
a=p.parse_args()
assert os.environ.get('GITHUB_ACTIONS')=='true' and platform.system()=='Darwin','Disposable macOS CI only'
out=a.output.resolve();out.mkdir(parents=True,exist_ok=True)
here=Path(__file__).resolve().parent
spec=importlib.util.spec_from_file_location('reviewed_official_client_flow',here/'reference-check-cloud-clients.py')
ref=importlib.util.module_from_spec(spec);spec.loader.exec_module(ref)
client=next(c for c in ref.CLIENTS if c['player']=='qqMusic')
command=ref.command
events=[];permission=None;host=None;recorder=None;mounted=False;install=None
work=Path(tempfile.mkdtemp(prefix='Nearpane-source2-',dir=os.environ['RUNNER_TEMP']))
report={'status':'PREPARING','player':'qqMusic','accountUsed':False,'protocolsAccepted':False,
        'TCCDatabaseModified':False,'realClientRequired':True,'fixtureMetadata':False,
        'requestedSourceSeekSeconds':163.6,'desiredSourceUseSeconds':[165.6,170.6],
        'workflowRun':os.environ['GITHUB_RUN_ID'],'sourceAudioSHA256':hashlib.sha256(a.audio.read_bytes()).hexdigest()}
def save(name,value):(out/name).write_text(json.dumps(value,ensure_ascii=False,indent=2)+'\n')
def event(name,**extra):
    row={'event':name,'monotonic':time.monotonic(),'unixTime':time.time(),**extra}
    events.append(row);save('driver-events.json',{'events':events});return row
def screenshot(name):
    r=command(['/usr/sbin/screencapture','-x','-C','-D',os.environ['NEARPANE_FILM_SCREEN_INDEX'],str(out/name)],timeout=12)
    save(name+'.json',r)
def load(name):
    try:return json.loads((out/name).read_text())
    except (OSError,ValueError):return None
def wait(name,seconds,predicate=lambda r:True):
    until=time.monotonic()+seconds
    while time.monotonic()<until:
        r=load(name)
        if r is not None and predicate(r):return r
        time.sleep(.08)
    raise RuntimeError('Timed out waiting for actual '+name)
def media_readback(name):
    media=a.app/'Contents/Resources/MediaRemote'
    r=command(['/usr/bin/perl',str(media/'mediaremote-adapter.pl'),str(media/'MediaRemoteAdapter.framework'),
               'get','--micros','--allow-missing-title','--no-artwork','--bundle-id='+client['bundleID']],
              timeout=8,log=out/name)
    return r
try:
    report['stage']='official metadata';save('source2-result.json',report)
    report.update(ref.read_metadata(client))
    report['stage']='official download'
    dmg=work/'official.dmg';report['download']=ref.download(report['downloadURL'],dmg,client['allowedDomain'])
    verify=command(['/usr/bin/hdiutil','verify',str(dmg)],timeout=30,log=out/'dmg-verify.json')
    if verify['exitCode']!=0:raise RuntimeError('Official DMG verification failed')
    mount=work/'mount';mount.mkdir()
    result=command(['/usr/bin/hdiutil','attach','-readonly','-nobrowse','-noautoopen','-mountpoint',str(mount),str(dmg)],timeout=30,log=out/'mount.json')
    mounted=result['exitCode']==0 or mount.is_mount()
    if result['exitCode']!=0:raise RuntimeError('Official DMG could not be mounted')
    choices=[]
    for candidate in mount.glob('*.app'):
        if not candidate.resolve().is_relative_to(mount.resolve()):continue
        with (candidate/'Contents/Info.plist').open('rb') as f:info=plistlib.load(f)
        if info.get('CFBundleIdentifier')==client['bundleID']:choices.append((candidate,info))
    if len(choices)!=1:raise RuntimeError('Official DMG application identity was not unique')
    source,info=choices[0];install=work/'Applications';install.mkdir();target=install/source.name
    copied=command(['/usr/bin/ditto',str(source),str(target)],timeout=40,log=out/'copy.json')
    if copied['exitCode']!=0:raise RuntimeError('Could not install isolated official client')
    report.update(appVersion=info.get('CFBundleShortVersionString'),appBuild=info.get('CFBundleVersion'),actualBundleID=info['CFBundleIdentifier'])
    signature=command(['/usr/bin/codesign','--verify','--deep','--strict','--verbose=2',str(target)],timeout=25,log=out/'codesign-verify.json')
    command(['/usr/bin/codesign','-dv','--verbose=4',str(target)],timeout=10,log=out/'codesign-details.json')
    gate=command(['/usr/sbin/spctl','--assess','--type','execute','--verbose=2',str(target)],timeout=25,log=out/'gatekeeper.json')
    report.update(signatureVerified=signature['exitCode']==0,gatekeeperAccepted=gate['exitCode']==0)
    if not report['signatureVerified'] or not report['gatekeeperAccepted']:raise RuntimeError('Official client signature/Gatekeeper did not pass')
    report['stage']='actual open-file playback';save('source2-result.json',report)
    permission=start_cloud_ui(out/'permission-ui','qqMusic',seconds=150)
    launched=command(['/usr/bin/open','-a',str(target),str(a.audio.resolve())],timeout=15,log=out/'launch.json')
    if launched['exitCode']!=0:raise RuntimeError('Actual QQ open-file request failed')
    time.sleep(6)
    screenshot('client-first-desktop-4k.png')
    env=os.environ.copy();env.update(FILM_V2_OUTPUT=str(out),FILM_V2_LRC=str(here/'good-to-go-selected-sourceclock.lrc'),FILM_V2_DISPLAY_ID=os.environ['NEARPANE_FILM_DISPLAY_ID'],FILM_V2_WALLPAPER=str(a.wallpaper.resolve()))
    host=subprocess.Popen([str(a.app/'Contents/MacOS/FilmV2Capture')],env=env,stdout=(out/'camera-host.log').open('w'),stderr=subprocess.STDOUT)
    ready=wait('ready.json',38,lambda r:r.get('player')=='qqMusic' and r.get('title')=='Good To Go' and r.get('state')=='playing')
    event('actual-client-and-lyrics-ready',readback=ready)
    media_readback('actual-media-before-seek.json')
    geometry=wait('camera-host.json',2)
    x=int(geometry['screenFrame'][0]+120)
    placed=command([str(a.placement_helper),client['bundleID'],str(x),'112','1352','838',str(out/'client-window-placement.json')],timeout=12,log=out/'placement-command.json')
    screenshot('client-and-lyrics-before-seek-4k.png')
    if placed['exitCode']!=0:raise RuntimeError('Actual QQ client window geometry could not be confirmed')
    # Begin a short real-screen preroll before seeking; the source's complete
    # 165.6–170.6 interval must not be lost during recorder initialization.
    recorder=subprocess.Popen([str(a.recorder),os.environ['NEARPANE_FILM_DISPLAY_ID'],'12',str(out/'source2-fullscreen.mov')],stdout=(out/'recorder.log').open('w'),stderr=subprocess.STDOUT)
    capture=wait('capture-first-frame.json',20)
    event('capture-first-video-frame',capture=capture,latestState=load('state.json'))
    # Only the existing production control route performs the seek. Nothing sets a model clock.
    request_id='source2-seek-'+os.environ['GITHUB_RUN_ID']
    save('transport-command.json',{'id':request_id,'seekMS':163600})
    request=wait('transport-request.json',4,lambda r:r.get('id')==request_id)
    state=wait('state.json',12,lambda r:r.get('player')=='qqMusic' and r.get('state')=='playing'
        and isinstance(r.get('positionMS'),(int,float)) and 163000<=r['positionMS']<=168500
        and not r.get('isPerformingCommand') and not r.get('actionMessage'))
    event('actual-seek-readback-confirmed',request=request,readback=state)
    media_readback('actual-media-capture-start.json')
    screenshot('source2-first-frame-4k.png')
    recorder.wait(timeout=28)
    if recorder.returncode:raise RuntimeError('ScreenCaptureKit recording did not complete')
    media_readback('actual-media-capture-end.json')
    screenshot('source2-last-frame-4k.png')
    final=load('state.json');completed=load('capture-completed.json')
    event('source2-capture-complete',readback=final,capture=completed)
    if not completed or completed.get('audioBuffers',0)<=0:raise RuntimeError('Actual system audio was not recorded')
    report.update(status='CAPTURED',stage='completed',durationRequested=12,actualPlayback=True,desktopNative=True,
        firstReadyReadback=ready,seekReadback=state,finalReadback=final,capture=completed,
        limitations=['Raw capture starts with short pre-seek preroll; use real source/audio alignment to choose the 165.6–170.6 interval.',
                     'Current embedded production module in isolated native camera host; not full Host release qualification.',
                     'Source-clock LRC imported through actual local lyric importer; no injected player snapshots.',
                     'Final 165.6–170.6 selection must be aligned from real audio and source timeline; no speed change.'])
except Exception as error:
    report.update(status='BLOCKED',error=type(error).__name__+': '+str(error),lastNativeState=load('state.json'))
    try:screenshot('source2-failure-desktop-4k.png')
    except Exception:pass
    try:media_readback('actual-media-on-failure.json')
    except Exception:pass
    raise
finally:
    save('source2-result.json',report)
    (out/'stop').touch()
    if host:
        try:host.wait(timeout=8)
        except subprocess.TimeoutExpired:host.terminate()
    if recorder and recorder.poll() is None:recorder.terminate()
    if permission:save('permission-result.json',stop_cloud_ui(permission))
    if install:save('client-cleanup.json',ref.stop_own_processes(install))
    if mounted:command(['/usr/bin/hdiutil','detach',str(mount)],timeout=15,log=out/'unmount.json')
