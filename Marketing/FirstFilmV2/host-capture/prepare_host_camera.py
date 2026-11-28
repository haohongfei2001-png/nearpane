#!/usr/bin/env python3
"""Instrument only a disposable git worktree of the actual complete Host."""
import argparse,hashlib,json,os,shutil,subprocess
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('source',type=Path);p.add_argument('destination',type=Path);a=p.parse_args()
assert os.environ.get('GITHUB_ACTIONS')=='true','Disposable runner only'
src=a.source.resolve();dest=a.destination.resolve();here=Path(__file__).resolve().parent
assert not dest.exists()
subprocess.run(['git','worktree','add','--detach',str(dest),'HEAD'],cwd=src,check=True)
# A restored build cache stays an ordinary owned directory, never a symlink.
if (src/'.build').exists():shutil.move(str(src/'.build'),str(dest/'.build'))
modified=[]
def write(path,text):
    target=dest/path;target.parent.mkdir(parents=True,exist_ok=True)
    old=target.read_bytes() if target.exists() else None
    target.write_text(text)
    modified.append({'path':path,'beforeSHA256':hashlib.sha256(old).hexdigest() if old else None,'afterSHA256':hashlib.sha256(target.read_bytes()).hexdigest()})
write('Sources/NearpaneUI/FilmDualCards.swift',(here/'FilmDualCards.swift').read_text())
write('Products/LyricTile/Sources/LyricUI/FilmLocalImport.swift','''import Foundation
public extension LyricAppModel {
    func filmImportLocalLyrics(_ url:URL) -> Bool {
        guard let selection=snapshot.selection else { return false }
        importLyrics(from:url,for:selection)
        return true
    }
}
''')
path='Sources/NearpaneHost/NearpaneApp.swift';text=(dest/path).read_text()
text=text.replace('import NearpaneUI\n','import NearpaneUI\nimport LyricUI\nimport LyricPlayback\n',1)
marker='    func renderSettingsReadback(_ session: NativeAcceptanceSession) async throws {\n        #if DEBUG\n'
assert text.count(marker)==1
text=text.replace(marker,marker+'        if ProcessInfo.processInfo.environment["FILM_V2_HOST"] == "1" {\n            try await filmV2HostScene(session)\n            return\n        }\n')
marker='    private func renderHiddenSettings(_ window: NSWindow, to url: URL) async throws {'
assert text.count(marker)==1
text=text.replace(marker,'    #if DEBUG\n'+(here/'FilmHostScene.swift.inc').read_text()+'    #endif\n\n'+marker)
write(path,text)
out=src/'build/film-v2-host';out.mkdir(parents=True,exist_ok=True)
(out/'isolated-source-manifest.json').write_text(json.dumps({'sourceCommit':subprocess.check_output(['git','rev-parse','HEAD'],cwd=src,text=True).strip(),'worktree':str(dest),'productionSourceModifiedInCheckout':False,'captureOnlyAdaptations':modified,'playback':'actual normal HostLyrics activation, not verification snapshots','reordering':'actual management-window draggable/dropDestination -> HostSession.moveModule','screenshot':'actual tray camera button and actual region capture; no seeded images','RiftletVisualAdjustment':'Equal width and matched native popover material only. Height is the real LayoutComposer output for TrayModule.rowCount:76pt empty,144pt with actual screenshot before uniform280/208 photography scaling. No fixed lyric-card height or cell/icon distortion.'},indent=2)+'\n')
