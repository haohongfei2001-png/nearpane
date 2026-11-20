"""Offline collection policy and lossless encoding checks. No applications, windows or screen capture."""
import binascii
import importlib.util
import json
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest
import uuid
import zlib

HERE=Path(__file__).resolve().parent
spec=importlib.util.spec_from_file_location('live_preview_media',HERE/'live-preview-media.py')
media=importlib.util.module_from_spec(spec)
spec.loader.exec_module(media)


def parts(png):
    assert png.startswith(media.SIGNATURE)
    i=8
    while i<len(png):
        n=struct.unpack('>I',png[i:i+4])[0]
        tag=png[i+4:i+8]; data=png[i+8:i+8+n]
        assert struct.pack('>I',binascii.crc32(tag+data)) == png[i+8+n:i+12+n]
        yield tag,data
        i+=12+n


def example(folder):
    proof={'ready':True,'ordinaryCount':2,'present':[True,True],'kinds':media.LIVE,'hostPID':10,'hostBirth':50,'hostHash':'a'*40,
           'fixturePID':12,'fixtureBirth':75,'fixtureHash':'b'*40,'panel':20,'numbers':[31,32],'display':str(uuid.uuid4()),'space':8,
           'pictures':[[2,3,4,4],[2,33,4,4]],'sources':[[14,15,4,4],[26,15,4,4]]}
    root=folder/'witness';root.mkdir()
    events=[];rows=[]
    for i,e in enumerate((0,0,1,1),1):
        panel=.1*i+1
        row=[{'start':panel,'end':panel+.02,'displayTime':panel-.002,'frameStatus':0,'color':f'{d}/{e}'} for d in (0,1,0,1)]
        data=b''.join(bytes([*media.PALETTE[e][d],255])*64 for d in (0,1,0,1))
        name=f'preview-{i:05d}.rgba'
        (root/name).write_bytes(data)
        events.append({'witness':{**{k:proof[k] for k in ('hostPID','fixturePID','numbers','panel')},
                                  'file':name,'batch':i,'epoch':e,'uptime':panel+.02,'sha256':media.sha(data),
                                  'bindingBefore':panel-.4,'bindingAfter':panel+.2,'cardKinds':media.LIVE}})
        rows.append(row)
    events.append({'completedBatches':len(rows)})
    return {'status':'PASS','fixtureLaunched':True,'captureAttempted':True,'cleanup':{'status':'PASS','windowNumbersGone':True},
            'binding':proof,'finalBinding':dict(proof),'installed':{'bundle':'com.holdsnow.nearpane.alpha','build':'90','pid':10,'cdHash':'a'*40},
            'fixture':{'pid':12,'birth':75,'numbers':[31,32],'presentation':'paired-preview'},'samples':rows,
            'sampler':{'exit':0,'timedOut':False,'events':events}}


class MediaTests(unittest.TestCase):
    def test_lossless_from_original_bytes_and_single_play_actual_sequence(self):
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp);data=example(root);(root/'result.json').write_text(json.dumps(data))
            result=media.publish(root)
            self.assertEqual(result['status'],'CAPTURED')
            self.assertEqual(result['sampledClip']['batches'],[1,2,3,4])
            self.assertEqual(result['readableOverview']['status'],'BLOCKED')
            self.assertEqual(result['nativeStageManagerComparison']['status'],'NOT_MEASURED')
            chunk=dict(parts((root/'media/epoch-0-card-2.png').read_bytes()))
            raw=(root/'witness/preview-00001.rgba').read_bytes()[768:1024]
            self.assertEqual(zlib.decompress(chunk[b'IDAT']),b''.join(b'\0'+raw[n:n+32] for n in range(0,256,32)))
            animation=list(parts((root/'media/sampled-card-1.apng').read_bytes()))
            self.assertEqual(dict(animation)[b'acTL'],struct.pack('>II',4,1))
            self.assertEqual([k for k,v in animation].count(b'fcTL'),4)
            for i,k in enumerate(v for n,v in animation if n in (b'IDAT',b'fdAT')):
                src=(root/'witness'/f'preview-{i+1:05d}.rgba').read_bytes()[512:768]
                self.assertEqual(zlib.decompress(k[4:] if i else k),b''.join(b'\0'+src[j:j+32] for j in range(0,256,32)))

    def test_one_changed_pixel_with_matching_digest_or_unbound_control_withholds_media(self):
        for problem in ('shape','counterfeit','unbound','filename','bracket','mixedFrame','symlink','generation'):
            with self.subTest(problem=problem),tempfile.TemporaryDirectory() as temp:
                root=Path(temp);v=example(root);w=v['sampler']['events'][0]['witness'];file=root/'witness'/w['file']
                if problem=='shape':
                    modified=bytearray(file.read_bytes());modified[-16]+=1;file.write_bytes(modified);w['sha256']=media.sha(modified)
                elif problem=='counterfeit':file.write_bytes(bytes(1024))
                elif problem=='unbound':w['cardKinds']=['上次画面','窗口画面']
                elif problem=='filename':w['file']='../result.json'
                elif problem=='bracket':w['bindingBefore']=5
                elif problem=='mixedFrame':v['samples'][0][3]['displayTime']+=.001
                elif problem=='symlink':file.unlink();file.symlink_to(root/'result.json')
                else:v['finalBinding']['hostBirth']+=1
                (root/'result.json').write_text(json.dumps(v)); report=media.publish(root)
                self.assertEqual(report['status'],'NOT_CAPTURED')
                self.assertEqual([p.name for p in (root/'media').iterdir()],['receipt.json'])
                self.assertNotIn(str(root),json.dumps(report))

    def test_unwitnessed_change_is_never_presented_as_continuous_video(self):
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp);r=example(root);del r['sampler']['events'][1];(root/'result.json').write_text(json.dumps(r))
            report=media.publish(root)
            self.assertEqual(report['microCrops']['qualifiedFrames'],3)
            self.assertEqual(report['sampledClip']['status'],'NOT_CAPTURED')
            self.assertEqual(len(list((root/'media').glob('*.apng'))),0)
            self.assertTrue((root/'media/epoch-1-card-2.png').is_file())

    def test_invalid_wide_capture_does_not_revoke_certified_independent_microcrops(self):
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp);r=example(root);r['status']='INCONCLUSIVE';r['overview']={'status':'CAPTURED','file':'../../secret'}
            (root/'result.json').write_text(json.dumps(r));report=media.publish(root)
            self.assertEqual(report['physicalRunStatus'],'INCONCLUSIVE')
            self.assertEqual(report['readableOverview']['status'],'BLOCKED')
            self.assertTrue((root/'media/epoch-0-card-1.png').exists())
            self.assertFalse((root/'media/paired-overview.png').exists())

    def test_independent_wide_png_retains_exact_bytes_even_when_timing_microcrops_are_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp);r=example(root);proof=r['binding'];r['sampler']['events'][0]['witness']['cardKinds']=[]
            width,height=40,60
            raw=b''.join(b'\0'+bytes((30,60,120,255))*width for _ in range(height))
            png=media.SIGNATURE+media.chunk(b'IHDR',struct.pack('>IIBBBBB',width,height,8,6,0,0,0))+media.chunk(b'IDAT',zlib.compress(raw))+media.chunk(b'IEND',b'')
            (root/'witness/paired-overview.png').write_bytes(png)
            r['overview']={**{k:proof[k] for k in ('display','space','hostPID','hostBirth','hostHash','panel','fixturePID','fixtureBirth','fixtureHash','numbers')},
                'status':'CAPTURED','file':'paired-overview.png','sha256':media.sha(png),'scale':1,'width':width,'height':height,
                'crop':[0,0,width,height],'epoch':1,'sourceEpochs':[1,1],'cardEpochs':[1,1],'panelSample':[2.75,2.8],
                'bindingBefore':2.7,'bindingAfter':3.1,'singleIncludedHostWindow':True,'beforeAfterScopeEqual':True,
                'isolatedProfile':True,'sourceDocumentsEmpty':True,'otherControlsInCrop':0,'otherNonDesktopSurfacesInCrop':0,
                'fixedCaptions':['Field Notes · 1','Field Notes · 2']}
            (root/'result.json').write_text(json.dumps(r))
            report=media.publish(root)
            self.assertEqual(report['readableOverview']['status'],'CAPTURED')
            self.assertEqual(report['microCrops']['status'],'BLOCKED')
            self.assertEqual((root/'media/paired-overview.png').read_bytes(),png)

    def test_marker_source_tables_are_identical(self):
        text=(HERE/'paired-preview-palette.swift').read_text()
        declared=text.split('static let epochs = ',1)[1].split('static let seconds',1)[0]
        self.assertEqual(json.loads(declared),[[list(c) for c in p] for p in media.PALETTE])

    @unittest.skipUnless(sys.platform=='darwin' and shutil.which('xcrun'),'requires macOS SDK')
    def test_native_body_pixel_gate_and_original_srgb_png_do_not_access_a_screen(self):
        with tempfile.TemporaryDirectory() as temp:
            folder=Path(temp);entry=folder/'check.swift';exe=folder/'check'
            entry.write_text('''import AppKit
import ImageIO
@main struct Check {
    static func main() throws {
        let area=CGRect(x:10,y:20,width:20,height:20)
        let body=CGRect(x:12,y:22,width:10,height:8)
        var pixels=Data()
        for _ in 0..<400 { pixels.append(contentsOf:[50,55,218,255]) }
        func sample(_ bytes:Data)->ImageRead {
            ImageRead(pixels:bytes,width:20,height:20,area:area,scale:1,start:1,end:2)
        }
        let valid=sample(pixels)
        let first=try valid.marker(body,document:0);precondition(first==0)
        precondition((try? valid.marker(body,document:1)) == nil)
        precondition((try? valid.marker(area.offsetBy(dx:1,dy:1),document:0)) == nil)
        let png=try valid.png()
        guard let provider=CGImageSourceCreateWithData(png as CFData,nil),let img=CGImageSourceCreateImageAtIndex(provider,0,nil) else{exit(2)}
        precondition(img.width==20 && img.height==20)
        let pixel=4*(20*4+4)
        pixels[pixel+3]=128
        precondition((try? sample(pixels).marker(body,document:0)) == nil)
        pixels[pixel+3]=255;pixels[pixel+1]=255
        precondition((try? sample(pixels).marker(body,document:0)) == nil)
    }
}''')
            subprocess.run(['xcrun','swiftc','-parse-as-library','-D','PAIRED_OVERVIEW_TEST',HERE/'paired-preview-palette.swift',
                            HERE/'paired-preview-overview.swift',entry,'-o',exe],check=True,timeout=45)
            subprocess.run([exe],check=True,timeout=4)


if __name__=='__main__':
    unittest.main()
