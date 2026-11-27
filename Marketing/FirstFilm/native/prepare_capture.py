#!/usr/bin/env python3
"""Copy the frozen product and add film-only native capture instrumentation.

No playback, lyric layout, material, interaction or shipping source file in the
repository is altered. The isolated build is a film instrumentation build.
"""
import argparse, hashlib, json, shutil
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('--source',type=Path,required=True);p.add_argument('--destination',type=Path,required=True);a=p.parse_args()
assets=Path(__file__).resolve().parent
a.destination.mkdir(parents=True,exist_ok=True)
shutil.copytree(a.source,a.destination,dirs_exist_ok=True,ignore=shutil.ignore_patterns('.build','dist'))
ui=a.destination/'Sources/LyricUI'
shutil.copy2(assets/'FilmCaptureSupport.swift',ui/'FilmCaptureSupport.swift')
shutil.copy2(assets/'FilmCaptureTests.swift',a.destination/'Tests/LyricUITests/FilmCaptureTests.swift')
changes=[]
def patch(path,before,after):
 s=path.read_text(); assert s.count(before)==1,(path,before,s.count(before)); s=s.replace(before,after);path.write_text(s);changes.append(str(path.relative_to(a.destination)))
patch(ui/'LyricNativeSmoke.swift',
 '        guard let view = window.contentView else { throw CaptureFailure.missingView }\n',
 '        guard let view = window.contentView else { throw CaptureFailure.missingView }\n        if FilmCaptureSupport.destination != nil { try FilmCaptureSupport.save(view: view, to: destination); return }\n')
patch(ui/'LyricNativePlayerVerification.swift',
 '        capture(capturePrefix + "-lyrics")\n',
 '        capture(capturePrefix + "-lyrics")\n        await FilmCaptureSupport.record(window: panel.panel, name: "music-lyrics", seconds: 6)\n')
patch(ui/'LyricNativePlayerVerification.swift',
 '        pointerAttempted = pointerReport()?["available"] as? Bool == true\n',
 '        let filmControls = Task { @MainActor in await FilmCaptureSupport.record(window: panel.panel, name: "music-controls", seconds: 10) }\n        pointerAttempted = pointerReport()?["available"] as? Bool == true\n')
patch(ui/'LyricNativePlayerVerification.swift',
 '        await record("resume-automatically-restores-lyrics", resumed && resumeConfirmed)\n',
 '        await record("resume-automatically-restores-lyrics", resumed && resumeConfirmed)\n        await filmControls.value\n')
patch(a.destination/'Scripts/build-app.sh', 'commit="$(git rev-parse HEAD)"', 'commit="${FILM_SOURCE_SHA:?Film source commit is required}"')
patch(ui/'LyricNativePlayerVerification.swift',
 '            capture(capturePrefix + "-next-lyrics")\n',
 '            capture(capturePrefix + "-next-lyrics")\n            if FilmCaptureSupport.destination != nil, pointerAttempted {\n                let posted = await pointerAction(4, "enter")\n                let shown = await wait { model.controlsVisible && model.panelInteractionActive }\n                write("film-next-hover.json", ["nativePointerPosted": posted, "hoverObserved": shown, "scope": "film capture of actual second-track controls"])\n                try? await Task.sleep(for: .milliseconds(200))\n                capture(capturePrefix + "-next-hover")\n                await FilmCaptureSupport.record(window: panel.panel, name: "music-english-controls", seconds: 3)\n                _ = await pointerAction(5, "leave")\n                _ = await wait { !model.controlsVisible && !model.panelInteractionActive }\n            }\n')
patch(a.destination/'Scripts/check-cloud-music.py',
    '    second_lyrics.write_text(',
    '    english_lines = ["A light upon the paper", "The wind along the street", "Every quiet moment", "Has a place to stay", "The corner fills with light", "A melody stays close", "Let this moment linger", "Let the next line arrive"]\n    second_lyrics.write_text(')
patch(a.destination/'Scripts/check-cloud-music.py',
    'lines[(s//interval+fixture["secondRecording"]["lyricLineOffset"])%len(lines)]',
    'english_lines[(s//interval+fixture["secondRecording"]["lyricLineOffset"])%len(english_lines)]')
patch(a.destination/'Scripts/check-cloud-music.py', "audio = out / 'original-chimes.wav'", "audio = out / '留在此刻.wav'")
fixture=a.destination/'Tests/Fixtures/CloudAcceptance.json';data=json.loads(fixture.read_text())
data['title']='留在此刻'
data['artist']='HOLDSNOW'
data['secondRecording']['fileStem']='Here, for a while'

data['lyricIntervalSeconds']=4
data['lyricLines']=['把微光留在纸上','窗外的风经过长街','让这一刻慢下来','脚步跟着雨停下来','灯在街角慢慢亮起','喜欢的旋律还在身边','把这一刻轻轻留下','让下一句自然到来']
fixture.write_text(json.dumps(data,ensure_ascii=False,indent=2)+'\n')
(a.destination/'film-instrumentation.json').write_text(json.dumps({'productSource':'d57878e51137f9dbf238a61ac97ea4b0da8b81f6','changedInIsolatedCopy':sorted(set(changes)), 'addedCaptureHelper':'Sources/LyricUI/FilmCaptureSupport.swift','addedAuthoredFixtureTest':'Tests/LyricUITests/FilmCaptureTests.swift','testMediaChanges':'Only original authored lyric strings and interval in Tests/Fixtures/CloudAcceptance.json. Original generated chime waveform and all real-player checks remain.','shippingSourceModified':False,'renderScaleStills':6,'renderScaleSequence':4},indent=2)+'\n')
print(a.destination)
