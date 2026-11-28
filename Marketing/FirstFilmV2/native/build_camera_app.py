#!/usr/bin/env python3
import argparse,plistlib,shutil,subprocess
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('package',type=Path);p.add_argument('app',type=Path);a=p.parse_args()
subprocess.run(['swift','build','--package-path',str(a.package),'-c','release','--product','FilmV2Capture'],check=True)
binpath=Path(subprocess.check_output(['swift','build','--package-path',str(a.package),'-c','release','--show-bin-path'],text=True).strip())
exe=a.app/'Contents/MacOS';resources=a.app/'Contents/Resources';exe.mkdir(parents=True,exist_ok=True);resources.mkdir(parents=True,exist_ok=True)
shutil.copy2(binpath/'FilmV2Capture',exe/'FilmV2Capture')
plist={'CFBundleIdentifier':'com.holdsnow.nearpane.film.v2','CFBundleName':'Nearpane Film V2','CFBundleDisplayName':'Nearpane Film V2','CFBundleExecutable':'FilmV2Capture','CFBundlePackageType':'APPL','CFBundleShortVersionString':'0.2','CFBundleVersion':'2','LSMinimumSystemVersion':'26.0','LSUIElement':True,'NSAppleEventsUsageDescription':'This isolated film capture reads and controls the licensed song in Apple Music.','NSScreenCaptureUsageDescription':'This isolated film capture records its own disposable desktop.'}
(a.app/'Contents/Info.plist').write_bytes(plistlib.dumps(plist))
subprocess.run(['bash',str(a.package/'Scripts/build-media-helper.sh'),str(resources/'MediaRemote')],check=True)
entitlement=a.package/'film-entitlements.plist';entitlement.write_bytes(plistlib.dumps({'com.apple.security.automation.apple-events':True}))
subprocess.run(['codesign','--force','--deep','--sign','-','--entitlements',str(entitlement),str(a.app)],check=True)
