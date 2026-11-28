"""Offline compact toolbar proof regression tests. No windows, preferences or capture API are opened."""
import base64
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
from unittest.mock import patch
import unittest
import zlib

HERE=Path(__file__).parent.resolve()
spec=importlib.util.spec_from_file_location('compact_tool_evidence',HERE/'compact-panel.py')
m=importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
D='00112233-4455-6677-8899-AABBCCDDEEFF'
U='10112233-4455-6677-8899-AABBCCDDEEFF'


def samples():
    stage={'uid':os.getuid(),'state':True}
    surface={'available':True,'stageManager':True,'panels':[35],'hostPID':20,'hostBirth':394851,'hostHash':'2'*40,'display':D,'space':7,
             'controls':{**dict.fromkeys(m.TOOLS,1),'desktop-reserved-region':0},'windowCards':0,'bareSpaceRows':0,'duplicatedCards':0,'legacyCards':0}
    observer={'observerAX':True,'observerScreenRead':True,'displays':[{'uuid':D}],'scopes':[{'scope':D,'current':7,'records':[{'id':7,'type':0,'uuid':U}]}],
              'scopedMembers':{'7':{'ordinary':[],'otherMembers':0,'unresolved':0}}}
    metrics={'pid':20,'stageManagerOwnsDispatch':1,'surfaceHidden':0,'activeStreams':0,'visibleDisplays':0,'gallerySessions':0,'capturesInFlight':0}
    return stage,surface,observer,metrics


class CompactTests(unittest.TestCase):
    def test_exact_stage_host_panel_and_windowserver_desktop(self):
        result=m.qualified(*samples())
        self.assertEqual((result['panel'],result['spaceUUID'],result['pid']),(35,U,20))
        for issue in ('off','login','ambiguous','other','ordinary','unknown','fullscreen','gallery','camera','display'):
            with self.subTest(issue=issue):
                s,p,o,h=samples()
                if issue=='off':s['state']=False
                if issue=='login':s['uid']=-10
                if issue=='ambiguous':p['panels']=[35,36]
                if issue=='other':o['scopedMembers']['7']['otherMembers']=1
                if issue=='ordinary':o['scopedMembers']['7']['ordinary']=[{'pid':888}]
                if issue=='unknown':del o['scopedMembers']['7']['unresolved']
                if issue=='fullscreen':o['scopes'][0]['records'][0]['type']=4
                if issue=='gallery':h['activeStreams']=1
                if issue=='camera':p['controls']['tray-camera-entry']=2
                if issue=='display':o['displays']*=2
                with self.assertRaises(ValueError):m.qualified(s,p,o,h)

    def test_opaque_single_window_identity_hash_and_actual_dimensions(self):
        proof=m.qualified(*samples())
        def chunk(tag,data):
            return struct.pack('>I',len(data))+tag+data+struct.pack('>I',zlib.crc32(tag+data))
        raw=b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('>IIBBBBB',40,70,8,6,0,0,0))+chunk(b'IDAT',zlib.compress((b'\0'+bytes(160))*70))+chunk(b'IEND',b'')
        result={**proof,'status':'CAPTURED','filter':'desktopIndependentWindow','includedWindowCount':1,'nativeTransparencyBacking':'solidWhite',
                'width':40,'height':70,'controls':dict.fromkeys(m.TOOLS,1),'lumaRange':[15,250],'sha256':hashlib.sha256(raw).hexdigest(),'png':base64.b64encode(raw).decode()}
        self.assertEqual(m.validated_image(result,proof),raw)
        damaged=raw[:-9]
        with self.assertRaisesRegex(ValueError,'invalidNativeImageReadback'):
            m.validated_image({**result,'png':base64.b64encode(damaged).decode(),'sha256':hashlib.sha256(damaged).hexdigest()},proof)
        for field,value in [('hash','f'*40),('birth',42),('filter','display'),('includedWindowCount',2),('width',61),
                            ('nativeTransparencyBacking','desktop'),('lumaRange',[127,130]),('sha256','a'*64)]:
            with self.subTest(field=field),self.assertRaises(ValueError):m.validated_image({**result,field:value},proof)

    def test_change_before_capture_prevents_pixel_request_and_late_change_withholds_frame(self):
        first=({'panel':35},'private-generation','active-lease')
        changed=({'panel':36},'private-generation','active-lease')
        asked=[]
        def sample(proof):
            asked.append(proof);return {'status':'CAPTURED'}
        with self.assertRaisesRegex(ValueError,'admissionChanged'):
            m.confirmed_frame(first,lambda:changed,sample)
        self.assertEqual(asked,[])
        observations=iter([first,changed])
        with patch.object(m,'validated_image',return_value=b'unpublished'),self.assertRaisesRegex(ValueError,'ChangedDuringImage'):
            m.confirmed_frame(first,lambda:next(observations),sample)
        self.assertEqual(asked,[first[0]])

    def test_missing_home_refuses_without_touching_or_creating_one(self):
        with tempfile.TemporaryDirectory() as tmp,patch.dict(os.environ,{'NEARPANE_TEST_HOME':str(Path(tmp)/'home'),'NEARPANE_TEST_GENERATION':tmp}):
            with self.assertRaisesRegex(ValueError,'privateAcceptanceHomeRequired'):m.clean_profile(23)
            self.assertEqual(list(Path(tmp).iterdir()),[])

    def test_creation_ledger_boot_uuid_and_absence_of_a_pending_removal(self):
        from uuid import uuid4
        proof=m.qualified(*samples())
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp).resolve()
            folder=root/str(uuid4())/'provision';folder.mkdir(parents=True)
            intent={'boot':'this-boot','display':D,'initial':{'sideOrder':['4'],'spaceUUIDs':{'4':D}}}
            made={'intent':intent,'target':'7','after':{'sideOrder':['4','7'],'spaceUUIDs':{'4':D,'7':U},'fullscreenIDs':[]}}
            def save(file,value):
                raw=json.dumps(value).encode();file.write_bytes(raw);file.chmod(0o600);return hashlib.sha256(raw).hexdigest()
            save(folder/'create-intent.json',intent)
            checksum=save(folder/'created.json',made);pointer=root/'desktop-1.json'
            save(pointer,{'receipt':str(folder/'created.json'),'sha256':checksum})
            with patch.object(m,'LEDGERS',root):
                self.assertEqual(m.leased(pointer,'this-boot',proof),checksum)
                with self.assertRaises(ValueError):m.leased(pointer,'earlier-boot',proof)
                (folder/'remove-intent.json').touch()
                with self.assertRaisesRegex(ValueError,'noActiveDesktopLease'):m.leased(pointer,'this-boot',proof)

    @unittest.skipUnless(sys.platform=='darwin','Swift required')
    def test_native_pixel_gate_takes_only_opaque_nonblank_window_bytes(self):
        with tempfile.TemporaryDirectory() as tmp:
            folder=Path(tmp);entry=folder/'test.swift';exe=folder/'test'
            entry.write_text('''import Foundation
@main struct Test {
    static func main() {
        var bytes=Data(repeating:255,count:64)
        precondition(actualPanelInk(bytes,width:4,height:4)==nil)
        bytes[0]=16;bytes[1]=16;bytes[2]=16
        let ok=actualPanelInk(bytes,width:4,height:4)
        precondition(ok?.0==16 && ok?.1==255)
        bytes[7]=220
        precondition(actualPanelInk(bytes,width:4,height:4)==nil)
        precondition(actualPanelInk(bytes,width:1,height:4)==nil)
    }
}''')
            subprocess.run(['xcrun','swiftc','-D','COMPACT_TOOL_TEST','-parse-as-library',HERE/'compact-tool-capture.swift',entry,'-o',exe],check=True,timeout=45)
            subprocess.run([exe],check=True,timeout=4)


if __name__=='__main__':
    unittest.main()
