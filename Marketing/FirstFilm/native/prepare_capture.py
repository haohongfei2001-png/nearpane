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
fixture=a.destination/'Tests/Fixtures/CloudAcceptance.json';data=json.loads(fixture.read_text())
data['lyricIntervalSeconds']=4
data['lyricLines']=['把微光留在纸上','窗外的风经过长街','让这一刻慢下来','脚步跟着雨停下来','灯在街角慢慢亮起','喜欢的旋律还在身边','把这一刻轻轻留下','让下一句自然到来']
fixture.write_text(json.dumps(data,ensure_ascii=False,indent=2)+'\n')
(a.destination/'film-instrumentation.json').write_text(json.dumps({'productSource':'d57878e51137f9dbf238a61ac97ea4b0da8b81f6','changedInIsolatedCopy':sorted(set(changes)), 'addedCaptureHelper':'Sources/LyricUI/FilmCaptureSupport.swift','addedAuthoredFixtureTest':'Tests/LyricUITests/FilmCaptureTests.swift','testMediaChanges':'Only original authored lyric strings and interval in Tests/Fixtures/CloudAcceptance.json. Original generated chime waveform and all real-player checks remain.','shippingSourceModified':False,'renderScaleStills':6,'renderScaleSequence':4},indent=2)+'\n')
print(a.destination)
