#!/usr/bin/env python3
"""Assemble an isolated camera host around the unchanged embedded product libraries.

This is not a shipping Nearpane package and does not alter the repository source.
Only the local lyric-file chooser is exposed to the bounded camera driver.
"""
import argparse, hashlib, json, shutil, subprocess
from pathlib import Path

p=argparse.ArgumentParser()
p.add_argument('source',type=Path)
p.add_argument('destination',type=Path)
a=p.parse_args()
source=a.source.resolve(); dest=a.destination.resolve()
assert not dest.exists(), 'Use a fresh isolated destination'
dest.mkdir(parents=True)
assets=Path(__file__).resolve().parent
modules=['LyricCore','LyricServices','CPlayerBridge','LyricPlayback','CTileLock','TileKit','LyricUI','NearpaneLyricsModule']
inventory={}
for name in modules:
    src=source/'Products/LyricTile/Sources'/name
    shutil.copytree(src,dest/'Sources'/name)
    for f in src.rglob('*'):
        if f.is_file(): inventory[str(f.relative_to(source))]=hashlib.sha256(f.read_bytes()).hexdigest()
shutil.copytree(source/'Products/LyricTile/Vendor',dest/'Vendor')
(dest/'Scripts').mkdir()
shutil.copy2(source/'Products/LyricTile/Scripts/build-media-helper.sh',dest/'Scripts')
(dest/'Sources/FilmV2Capture').mkdir()
shutil.copy2(assets/'FilmV2Capture.swift',dest/'Sources/FilmV2Capture/FilmV2Capture.swift')
(dest/'Sources/LyricUI/FilmLocalImport.swift').write_text('''import Foundation
public extension LyricAppModel {
    /// Film-only file chooser bridge; invokes the actual product importer.
    func filmImportLocalLyrics(_ url: URL) -> Bool {
        guard let selection = snapshot.selection else { return false }
        importLyrics(from: url, for: selection)
        return true
    }
}
''')
bridge=dest/'Sources/CPlayerBridge/CPlayerBridge.m'
text=bridge.read_text()
marker='NSData *LTPReadPlayer(int32_t pid, BOOL spotify, BOOL includeArtwork) {'
assert text.count(marker)==1
text=text.replace(marker,(assets/'FilmArtworkDiagnostic.m.inc').read_text()+'\n'+marker)
text=text.replace('if (includeArtwork && !spotify) {\n                    @try {','if (includeArtwork && !spotify) {\n                    id filmRaw = nil;\n                    @try {')
text=text.replace('id raw = [art valueForKey:@"rawData"];','id raw = [art valueForKey:@"rawData"];\n                            filmRaw = raw;')
guard='if (!identity.length || ![identity isEqualToString:artIdentity]) [result removeObjectForKey:@"artworkBase64"];'
assert text.count(guard)==1
text=text.replace(guard,guard+'\n                        LTPFilmArtworkProbe(filmRaw, identity.length && [identity isEqualToString:artIdentity], nil);')
text=text.replace('@catch (NSException *artError) {','@catch (NSException *artError) {\n                        LTPFilmArtworkProbe(filmRaw, NO, entry.errorDelegate.lastError);')
bridge.write_text(text)
(dest/'Package.swift').write_text('''// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "NearpaneFilmV2", platforms: [.macOS("26.0")],
 products: [.executable(name:"FilmV2Capture",targets:["FilmV2Capture"])],
 dependencies: [.package(url:"https://github.com/jpsim/Yams.git",revision:"a27b21e0c81c5bf42049b897a62aaf387e80f279")],
 targets:[
 .target(name:"LyricCore"),
 .target(name:"LyricServices",dependencies:["LyricCore",.product(name:"Yams",package:"Yams")]),
 .target(name:"CPlayerBridge",publicHeadersPath:"include",cSettings:[.unsafeFlags(["-fobjc-arc"])],linkerSettings:[.linkedFramework("Foundation"),.linkedFramework("AppKit"),.linkedFramework("ScriptingBridge")]),
 .target(name:"LyricPlayback",dependencies:["LyricCore","CPlayerBridge"]),
 .target(name:"CTileLock",publicHeadersPath:"include"),
 .target(name:"TileKit",dependencies:["CTileLock"]),
 .target(name:"LyricUI",dependencies:["LyricCore","LyricServices","LyricPlayback","TileKit"]),
 .target(name:"NearpaneLyricsModule",dependencies:["LyricCore","LyricPlayback","LyricUI","TileKit"]),
 .executableTarget(name:"FilmV2Capture",dependencies:["NearpaneLyricsModule","LyricUI","LyricPlayback","LyricCore"])
 ],swiftLanguageModes:[.v6])
''')
(dest/'source-manifest.json').write_text(json.dumps({
 'sourceCommit':subprocess.check_output(['git','rev-parse','HEAD'],cwd=source,text=True).strip(),
 'productionBaseCommit':'d5767d87bc45245b31d0980e91e43778c5f424ed',
 'unreleasedArtworkFix':'Actual Music SBObject/NSAppleEventDescriptor unwrap, verified in run46109639614; image SHA matches licensed original. Only film branch, not main.',
 'scope':'Current embedded NearpaneLyricsModule in an isolated photography host. Actual Music metadata/artwork/playback, actual product lyric importer/view/controls; not a packaged Host release qualification.',
 'productionRepositorySourceFilesModified':[],
 'isolatedInstrumentation':'CPlayerBridge logs actual rawData class/descriptor payload to diagnose missing production artwork. It does not change the baseline artwork result or inject an image.',
 'addedBridge':'LyricUI/FilmLocalImport.swift exposes the existing importLyrics(from:for:) path for an explicit licensed local LRC.',
 'uiRecreation':False,'sourceSHA256':inventory},indent=2)+'\n')
print(dest)
