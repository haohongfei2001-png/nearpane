#!/usr/bin/env python3
"""Stage an isolated second-player camera harness; production sources stay unchanged."""
import argparse, hashlib, json, shutil
from pathlib import Path

p=argparse.ArgumentParser()
p.add_argument('base',type=Path)
p.add_argument('destination',type=Path)
a=p.parse_args()
assert not a.destination.exists(), 'Use a fresh source2 harness directory'
shutil.copytree(a.base,a.destination)
here=Path(__file__).resolve().parent
for name in ['drive_source2_capture.py','place_source2_window.swift','reference-check-cloud-clients.py',
             'reference-cloud_pointer.py','good-to-go-selected-sourceclock.lrc']:
    shutil.copy2(here/name,a.destination/name)
shutil.copy2(a.destination/'reference-cloud_pointer.py',a.destination/'cloud_pointer.py')
source=a.destination/'FilmV2Capture.swift'
text=source.read_text()
changes={
    'module.model.selectPlayer(.appleMusic)': 'module.model.selectPlayer(.qqMusic)',
    '"audioSource":"Actual Apple Music playing the licensed song"': '"audioSource":"Actual official QQ Music playing the licensed local Good To Go file"',
    '            let command=destination.appendingPathComponent("pointer-command.json")': '''            let transportURL=destination.appendingPathComponent("transport-command.json")
            if let bytes=try? Data(contentsOf:transportURL),
               let request=(try? JSONSerialization.jsonObject(with:bytes)) as? [String:Any],
               let requestID=request["id"] as? String,
               let milliseconds=request["seekMS"] as? Int64 {
                try? FileManager.default.removeItem(at:transportURL)
                let before=model.playbackPositionMS
                model.perform(.seek(milliseconds:milliseconds))
                write("transport-request.json",["id":requestID,"action":"seek","targetMS":milliseconds,
                    "beforePositionMS":before as Any? ?? NSNull(),"uptime":ProcessInfo.processInfo.systemUptime,
                    "route":"Public production LyricAppModel.perform -> PlaybackController; result requires actual readback"])
            }
            let command=destination.appendingPathComponent("pointer-command.json")''',
    '"state":String(describing:model.snapshot.state),"positionMS":model.playbackPositionMS as Any? ?? NSNull(),': '''"state":String(describing:model.snapshot.state),"positionMS":model.playbackPositionMS as Any? ?? NSNull(),
                "sourceAnchorPositionMS":model.snapshot.anchor?.positionMS as Any? ?? NSNull(),
                "isPerformingCommand":model.isPerformingCommand,"actionMessage":model.actionMessage ?? "",
                "requiresAuthorization":model.snapshot.requiresAuthorization,
                "canSeek":model.snapshot.capabilities.canSeek,'''
}
for old,new in changes.items():
    assert text.count(old)==1, f'Expected one camera harness match: {old[:80]}'
    text=text.replace(old,new)
source.write_text(text)
manifest={
 'baseCaptureCommit':'29a18feb9402b89984f2115a10da3d59164771b7',
 'productionSourceCommit':'d5767d87bc45245b31d0980e91e43778c5f424ed',
 'selectedPlayer':'qqMusic','newSupportedPlayers':[],
 'productionRepositorySourcesChanged':[],
 'cameraOnlyChanges':['select existing qqMusic enum','call actual existing seek command before filming','record source-anchor/control readbacks'],
 'cameraSHA256':hashlib.sha256(source.read_bytes()).hexdigest(),
 'scope':'Isolated current embedded product view and real QQ client; not a shipping Host qualification.'}
(a.destination/'source2-staging.json').write_text(json.dumps(manifest,indent=2)+'\n')
print(json.dumps(manifest,indent=2))
