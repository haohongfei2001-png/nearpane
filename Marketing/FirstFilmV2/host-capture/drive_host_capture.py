#!/usr/bin/env python3
"""Actual Host management reorder followed by actual Riftlet region capture."""
import argparse,ast,hashlib,json,os,platform,plistlib,shutil,subprocess,sys,time,uuid
from pathlib import Path
p=argparse.ArgumentParser()
for name in ['repo','app','audio','pdf','wallpaper','recorder','output','native']:
    p.add_argument('--'+name,type=Path,required=True)
a=p.parse_args();assert os.environ.get('GITHUB_ACTIONS')=='true' and platform.system()=='Darwin'
a.repo=a.repo.resolve();a.native=a.native.resolve()
sys.path.insert(0,str(a.native));sys.path.insert(0,str(Path(__file__).resolve().parent));from cloud_ui import start_cloud_ui,stop_cloud_ui
out=a.output.resolve();out.mkdir(parents=True,exist_ok=True);events=[]
# Exact already exercised import/identity/hash/seek helpers, not another
# abbreviated asynchronous Music playlist implementation.
core_source=(a.native/'drive_core_capture.py').read_text()
module=ast.parse(core_source)
defs=ast.Module(body=[x for x in module.body if isinstance(x,ast.FunctionDef)],type_ignores=[])
exec(compile(defs,str(a.native/'drive_core_capture.py'),'exec'),globals())
save('shared-music-driver.json',{'source':'Marketing/FirstFilmV2/native/drive_core_capture.py','sha256':hashlib.sha256(core_source.encode()).hexdigest(),'functionsOnly':True})

permission=None;host=None;recorder=None;session=None
def input_action(name,*arguments,report_label=None):
    report=out/('input-'+(report_label or name)+'.json')
    r=subprocess.run([str(Path(os.environ['RUNNER_TEMP'])/'film-host-input'),str(host.pid),name,str(report),*[str(x) for x in arguments]],capture_output=True,text=True,timeout=12)
    try:observed=json.loads(report.read_text())
    except (OSError,ValueError):observed={'stderr':r.stderr,'exitCode':r.returncode}
    event('actual-input-'+name,report=observed,reportFile=report.name)
    return r.returncode==0
def wait_offset(start,offset):
    while time.monotonic()<start+offset:time.sleep(.025)
try:
    if subprocess.run(['pgrep','-x','Music'],capture_output=True,text=True).stdout.strip():raise RuntimeError('Music unexpectedly running before isolated host take')
    permission=start_cloud_ui(out/'permission-ui','music',seconds=170)
    subprocess.run(['open','-a','Music'],check=True)
    # A cold Music launch can accept add() before its initial library finishes
    # opening, then silently leave the owned playlist empty. Complete only the
    # already observed native welcome/marketing controls before importing.
    native_window('com.apple.Music','music-onboarding-inspection.json')
    onboarding_deadline=time.monotonic()+18
    while time.monotonic()<onboarding_deadline:
        try:
            ui=json.loads((out/'permission-ui/native-permission-ui.json').read_text())
            if any(row.get('button')=='Not Now' for row in ui.get('actions',[])):break
        except (OSError,ValueError):pass
        time.sleep(.2)
    playlist='Nearpane Film Host '+os.environ['GITHUB_RUN_ID']
    apple('tell application "Music"\nset sound volume to 72\nset filmList to make new user playlist with properties {name:'+quote(playlist)+'}\nadd POSIX file '+quote(a.audio.resolve())+' to filmList\nend tell',timeout=50)
    for attempt in range(3):
        try:
            verified=verified_import(playlist)
            break
        except RuntimeError:
            failed=json.loads((out/'verified-music-import.json').read_text())
            save('import-attempt-'+str(attempt+1)+'.json',failed)
            reads=[row.get('readback') for row in failed.get('observations',[]) if row.get('readback')]
            if attempt==2 or not reads or any(value!='COUNT\t0' for value in reads):raise
            event('owned-empty-import-retry',attempt=attempt+2)
            apple('tell application "Music"\nset filmList to first user playlist whose name is '+quote(playlist)+'\nadd POSIX file '+quote(a.audio.resolve())+' to filmList\nend tell',timeout=30)
            time.sleep(1)
    apple('tell application "Music"\nset filmList to first user playlist whose name is '+quote(playlist)+'\nset shuffle enabled to false\nset song repeat to off\nplay filmList\nend tell')
    deadline=time.monotonic()+12
    while time.monotonic()<deadline:
        state=apple('tell application "Music" to return {player state,name of current track,persistent ID of current track,player position}',timeout=5,required=False)
        if 'playing' in state and verified['persistentID'] in state and float(state.split(',')[-1])>0:break
        time.sleep(.25)
    else:raise RuntimeError('Actual verified Music track did not become playing')
    event('real-music-import-and-play',readback=state)
    display=json.loads((out/'display/capture-display.json').read_text())
    screen=json.loads((out/'display'/display['selectedReport']).read_text())['selected']['nsFrame']
    x=int(screen['x']+120);y=112
    subprocess.run(['open','-a','Preview',str(a.pdf.resolve())],check=True);time.sleep(.8)
    native_window('com.apple.Preview','preview-position.json',x,y,1352,838)
    native_window('com.apple.Preview','preview-sidebar-key.json','--key','hide-sidebar')
    native_window('com.apple.Preview','preview-fit-key.json','--key','fit')
    snap('preview-owned-document-4k.png')
    apple('tell application "System Events" to set visible of process "Music" to false',required=False)
    # Ad-hoc alpha identity is the product's existing disposable, executable-
    # bound native entry; no normal user profile is opened or modified.
    staged=a.repo/'build/film-host-camera/Nearpane.app';staged.parent.mkdir(parents=True,exist_ok=True)
    subprocess.run(['/usr/bin/ditto',str(a.app.resolve()),str(staged)],check=True)
    info=staged/'Contents/Info.plist'
    values=plistlib.loads(info.read_bytes());values['CFBundleIdentifier']='com.holdsnow.nearpane.alpha';values['CFBundleDisplayName']='Nearpane'
    info.write_bytes(plistlib.dumps(values))
    subprocess.run(['/usr/bin/codesign','--force','--deep','--sign','-',str(staged)],check=True,capture_output=True)
    sid=str(uuid.uuid4());session=a.repo/'build/native-acceptance'/sid
    binary=staged/'Contents/MacOS/NearpaneHost'
    env=os.environ.copy();env.update(NEARPANE_ACCEPTANCE_CHECKOUT=str(a.repo),FILM_V2_HOST='1',FILM_V2_OUTPUT=str(out),FILM_V2_LRC=str(a.native/'good-to-go-selected-sourceclock.lrc'),FILM_V2_WALLPAPER=str(a.wallpaper.resolve()))
    prep=subprocess.run([str(binary),'--verify-bundled-resources','--native-acceptance-prepare-draft',sid],cwd=a.repo,env=env,capture_output=True,text=True,timeout=45)
    (out/'prepare-empty-owned-profile.log').write_text(prep.stdout+prep.stderr)
    if prep.returncode:raise RuntimeError('Existing empty-profile prepare entry failed')
    host=subprocess.Popen([str(binary),'--verify-bundled-resources','--native-settings-readback',sid],cwd=a.repo,env=env,stdout=(out/'actual-host.log').open('w'),stderr=subprocess.STDOUT)
    ready=wait_json('dual-ready.json',35);event('real-host-ready',state=ready)
    snap('dual-initial-4k.png');input_action('inspect')
    seek_real(168.60)
    apple('tell application "Music"\npause\nset player position to 168.60\nend tell')
    recorder=subprocess.Popen([str(a.recorder),os.environ['NEARPANE_FILM_DISPLAY_ID'],'24',str(out/'host-fullscreen.mov')],stdout=(out/'recorder.log').open('w'),stderr=subprocess.STDOUT)
    wait_json('capture-first-frame.json',15);start=time.monotonic()
    apple('tell application "Music" to play');event('host-take-resumed',readback=apple('tell application "Music" to return {player state,player position}'))
    wait_offset(start,1.7);input_action('reorder')
    time.sleep(.4);reordered=json.loads((out/'dual-state.json').read_text());event('actual-order-readback',state=reordered)
    snap('dual-reordered-4k.png')
    wait_offset(start,4.7);input_action('close-management')
    wait_offset(start,5.8);input_action('camera')
    time.sleep(.25);input_action('region')
    time.sleep(.55)
    # The selected rectangle is strictly inside the original water photograph
    # on the real PDF page, with generous margins from text/toolbars/cards.
    input_action('select-region',x+350,y+320,660,300)
    # Wait for the real intake to publish its actual asset, then let the native
    # thumbnail decode and render. No synthetic image is injected.
    shot_deadline=time.monotonic()+5
    while time.monotonic()<shot_deadline:
        shot_state=json.loads((out/'dual-state.json').read_text())
        if shot_state.get('trayVisibleIDs'):break
        time.sleep(.1)
    event('actual-screenshot-first-readback',state=shot_state)
    input_action('leave');time.sleep(.8);snap('dual-actual-capture-result-4k.png')
    shot_state=json.loads((out/'dual-state.json').read_text());event('actual-screenshot-readback',state=shot_state)
    recorder.wait(timeout=35)
    input_action('inspect',report_label='after-shot')
    final=json.loads((out/'dual-state.json').read_text())
    actual_reordered=final.get('hostOrder',[])[:2]==['com.holdsnow.nearpane.riftlet','com.holdsnow.nearpane.lyrictile']
    actual_shot=bool(final.get('trayVisibleIDs'))
    capture=wait_json('capture-completed.json',5)
    probe=subprocess.run(['ffprobe','-v','error','-show_streams','-show_format','-of','json',str(out/'host-fullscreen.mov')],capture_output=True,text=True,timeout=15)
    (out/'media-probe.json').write_text(probe.stdout)
    if probe.returncode:event('container-validation-failed',stderr=probe.stderr)
    shot_in_movie=bool(shot_state.get('trayVisibleIDs')) and capture['firstPTS']<=shot_state['uptime']<=capture['lastPTS']
    save('host-result.json',{'status':'CAPTURED' if recorder.returncode==0 and probe.returncode==0 else 'RECORDER_FAILED','actualReordered':actual_reordered,'actualScreenshotAppeared':actual_shot,'actualScreenshotReadbackInsideRecordedPTS':shot_in_movie,'actualState':final,'requestedSeconds':24,'systemAudioRequested':True,'fixturePlayback':False,'seededImages':False,'sourceView':'Complete production Host SettingsView/HostLyrics/TraySurface in isolated photographic composition','photographicAdjustment':'Equal280pt width and matched outer native material; Riftlet height follows actual production LayoutComposer and TrayModule.rowCount,76pt empty/144pt with screenshot before uniform280/208 scaling; no cell/icon distortion or content opacity reduction','emptyTrayAXReport':'input-inspect.json','fullTrayAXReport':'input-after-shot.json','limitations':['Unreleased two-line actual artwork bridge fix on creative branch','No release qualification or public-download assertion','Desktop card dragging is not implemented; actual management-window drag/drop is filmed']})
    if not actual_reordered or not actual_shot:event('take-preserved-with-incomplete-action',reordered=actual_reordered,screenshot=actual_shot)
except Exception as error:
    save('host-result.json',{'status':'BLOCKED','error':str(error),'events':events})
    try:snap('failure-desktop-4k.png')
    except Exception:pass
    raise
finally:
    (out/'stop').touch()
    if host:
        try:host.wait(timeout=10)
        except subprocess.TimeoutExpired:host.terminate()
    if recorder and recorder.poll() is None:recorder.terminate()
    if session and session.exists():
        for file in (session/'support/Riftlet').rglob('*'):
            if file.is_file() and file.suffix.lower() in ('.png','.jpg','.jpeg','.json','.sqlite'):
                target=out/'actual-riftlet-intake'/file.relative_to(session/'support/Riftlet');target.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(file,target)
    if permission:save('permission-result.json',stop_cloud_ui(permission))
    apple('tell application "Music" to pause',required=False)
