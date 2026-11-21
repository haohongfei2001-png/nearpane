"""Deterministic temporal, shared-panel-frame, and palette checks; never start an application."""
from pathlib import Path
import importlib.util
import json
import plistlib
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

from paired_preview_metrics import summarize


def timeline(change=lambda window, phase: f'{window}/{phase}', delay=1):
    rows=[]
    for tick in range(56):
        phase=tick//8
        picture=max(0,tick-delay)//8
        def sample(color, shift):
            return {'start':1+tick*.1+shift,'end':1+tick*.1+shift+.018,'color':color,'displayTime':None,'frameStatus':None}
        rows.append([sample(f'0/{phase}',0),sample(f'1/{phase}',.002),sample(change(0,picture),.004),sample(change(1,picture),.004)])
    return rows


class PreviewTests(unittest.TestCase):
    def test_suspended_active_stage_returns_before_fixture_or_capture(self):
        source=Path(__file__).resolve().with_name('paired-preview.py')
        spec=importlib.util.spec_from_file_location('paired_preview_runner',source)
        runner=importlib.util.module_from_spec(spec);spec.loader.exec_module(runner)
        with tempfile.TemporaryDirectory(prefix='nearpane-d01.test-',dir='/private/tmp') as d:
            kit=Path(d); app=kit/'Nearpane.app'; (app/'Contents').mkdir(parents=True)
            (app/'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':'com.holdsnow.nearpane.alpha','CFBundleVersion':'90'}))
            blocked={'ready':False,'stageManager':True,'reason':'sidebarUnavailableWithStageManagerOn'}
            with patch.object(runner,'APP',app),patch.object(runner,'installed_pid',return_value=123),patch.object(runner,'identity',return_value={'CDHash':'fixture'}),patch.object(runner,'read',return_value=blocked),patch.object(runner.subprocess,'run'),patch.object(runner.subprocess,'Popen') as launch:
                self.assertEqual(runner.run(kit,kit/'proof'),2);launch.assert_not_called()
            result=json.loads((kit/'proof/result.json').read_bytes());self.assertFalse(result['captureAttempted']);self.assertFalse(result['fixtureLaunched'])
            self.assertEqual((result['status'],result['reason']),('BLOCKED',blocked['reason']))
    def test_all_real_transitions_and_two_windows_on_one_frame(self):
        r=summarize(timeline());self.assertEqual(r['status'],'PASS');self.assertEqual(r['latencyMs']['n'],12)
        self.assertEqual(r['windows'][0]['outcomes'],{'MATCH':6});self.assertTrue(all(i['twoConsecutive'] for i in r['simultaneous']))
        self.assertGreaterEqual(r['latencyMs']['upper']['p95'],100);self.assertLessEqual(r['latencyMs']['lower']['p50'],100)
        self.assertEqual(r['nativeStageManagerComparison']['status'],'NOT_MEASURED')

    def test_blank_unknown_staleness_and_wrong_window_are_preserved(self):
        for replacement,expected,status in [('blank','BLANK','FAIL'),('unknown','UNKNOWN','INCONCLUSIVE'),('1/0','STALE','FAIL'),('0/3','WRONG_WINDOW','FAIL')]:
            r=summarize(timeline(lambda d,p:replacement if d==1 else f'{d}/{p}'))
            self.assertEqual((r['windows'][1]['outcomes'],r['status']),({expected:6},status));self.assertEqual(r['windows'][0]['latencyMs']['n'],6)

    def test_missing_source_and_nonshared_or_reversed_samples_never_pass(self):
        rows=timeline()
        for row in rows:row[0]['color']='unknown'
        r=summarize(rows);self.assertEqual(r['windows'][0]['outcomes'],{'UNKNOWN':6});self.assertNotEqual(r['status'],'PASS')
        rows=timeline();rows[1][3]['start']+=.01
        with self.assertRaisesRegex(ValueError,'one captured frame'):summarize(rows)
        rows=timeline();rows[2][0]['start']=0
        with self.assertRaisesRegex(ValueError,'capture clock'):summarize(rows)
        rows=timeline();rows[3][0]['displayTime']=1000000
        with self.assertRaisesRegex(ValueError,'display-time clock'):summarize(rows)

    def test_native_lookups_do_not_substitute_for_same_frame_or_empty_measurements(self):
        self.assertIsNone(summarize([])['latencyMs']['upper'])
        rows=timeline()
        for i, row in enumerate(rows):
            if i%2:row[3]['color']='unknown'
            else:row[2]['color']='unknown'
        r=summarize(rows);self.assertTrue(all(p['matchingFrames']==0 for p in r['simultaneous']));self.assertNotEqual(r['status'],'PASS')

    @unittest.skipUnless(sys.platform=='darwin','requires Swift')
    def test_actual_palette_and_color_classifier_without_a_screen(self):
        source=Path(__file__).resolve().with_name('paired-preview-palette.swift')
        with tempfile.TemporaryDirectory() as d:
            main=Path(d)/'main.swift'; exe=Path(d)/'palette'
            main.write_text('''import Foundation
for (epoch, pair) in PairedPreviewPalette.epochs.enumerated() {
    for (doc, rgb) in pair.enumerated() { for offset in [-8, 0, 8] {
        precondition(PairedPreviewPalette.classify(rgb[0]+offset,rgb[1]+offset,rgb[2]+offset,255)=="\\(doc)/\\(epoch)")
    } }
}
precondition(PairedPreviewPalette.classify(60,60,60,255)=="blank")
precondition(PairedPreviewPalette.classify(255,0,255,0)=="blank")
precondition(PairedPreviewPalette.classify(0,255,255,255)=="unknown")
''')
            subprocess.run(['xcrun','swiftc',main,source,'-o',exe],check=True,timeout=40)
            subprocess.run([exe],check=True,timeout=3)

if __name__=='__main__':unittest.main()
