import copy
import importlib.util
import subprocess
import sys
import tempfile
import time
from unittest.mock import Mock
from pathlib import Path
import unittest

path=Path(__file__).with_name('split-view.py')
spec=importlib.util.spec_from_file_location('split_view',path)
module=importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class SplitObservationTests(unittest.TestCase):
    def setUp(self):
        self.view=dict(space=70,type=4,spaceUUID='controlled-F',newFullscreenIDs=[70],
            memberships=[[70],[70]],forward=[True,True],drawn=[True,True],axStandard=[True,True],
            foreignVisibleMembers=0,unknownVisibleMembers=0,hostPanelPresent=True,displayFrame=[-1000,80,1000,600],cgFrames=[[-658,80,658,600],[-1000,80,330,600]],
            axFrames=[[-658,80,658,600],[-1000,80,330,600]],
            hostGroupCount=1,hostMemberCounts=[1,1],hostGroupFrame=[50,200,120,90],
            hostPaneFrames=[[91.04,200,78.96,72],[50,200,39.6,72]])

    def test_actual_unequal_geometry_and_window_order(self):
        self.assertTrue(module.system_pair(self.view,4))
        self.assertTrue(module.host_layout(self.view))

    def test_two_ordinary_side_by_side_single_fullscreen_and_half_completed_picker_are_ineligible(self):
        for change in [dict(type=0),dict(space=4),dict(foreignVisibleMembers=1),dict(unknownVisibleMembers=1),dict(memberships=[[70],[4]]),dict(axStandard=[True,False]),
                       dict(newFullscreenIDs=[66,70]),dict(forward=[True,False]),dict(drawn=[False,True]),
                       dict(axFrames=[None,self.view['cgFrames'][1]]),dict(axFrames=list(reversed(self.view['cgFrames'])))]:
            with self.subTest(change=change):
                self.assertFalse(module.system_pair({**self.view,**change},4))

    def test_a_physical_pair_does_not_confirm_absent_reversed_equalized_or_stale_installed_cards(self):
        for change in [dict(hostGroupCount=0),dict(hostPanelPresent=False),dict(hostMemberCounts=[1,0]),
                       dict(hostPaneFrames=list(reversed(self.view['hostPaneFrames']))),
                       dict(hostPaneFrames=[[111,200,59,72],[50,200,60,72]]),
                       dict(hostPaneFrames=[None,self.view['hostPaneFrames'][1]])]:
            with self.subTest(change=change):
                self.assertTrue(module.system_pair({**self.view,**change},4))
                self.assertFalse(module.host_layout({**self.view,**change}))

    def test_missing_too_wide_or_overlapping_divider_has_no_independent_system_pass(self):
        for right in [[-690,80,690,600],[-610,80,610,600],[-658,180,658,500]]:
            sample=copy.deepcopy(self.view)
            sample['cgFrames'][0]=sample['axFrames'][0]=right
            self.assertFalse(module.system_pair(sample,4))


class EnrollmentTests(unittest.TestCase):
    def test_read_only_startup_convergence_and_immediate_specific_identity_errors(self):
        good={'ready':True,'onlyTwoInLease':True,'space':7,'type':0,'newFullscreenIDs':[],
              'memberships':[[7],[7]],'axStandard':[True,True],'hostGroupCount':0,'hardware':[4],'foreignVisibleMembers':0,'unknownVisibleMembers':0}
        read=Mock(side_effect=[{**good,'axStandard':[True,False]},good])
        self.assertEqual(module.wait_ordinary_control(read,7,deadline=time.monotonic()+1),good)
        self.assertEqual(read.call_count,2)
        denial=Mock(return_value={'reason':'fixtureCDHashChanged','hardware':[4]})
        with self.assertRaisesRegex(ValueError,'fixtureCDHashChanged'):
            module.wait_ordinary_control(denial,7,deadline=time.monotonic()+99)
        self.assertEqual(denial.call_count,1)
        changed=Mock(side_effect=[{**good,'axStandard':[True,False]},{**good,'hardware':[5]}])
        with self.assertRaisesRegex(ValueError,'physicalInputChanged'):
            module.wait_ordinary_control(changed,7,deadline=time.monotonic()+1)
        self.assertEqual(module.ordinary_control({**good,'hostGroupCount':1},7),'ordinaryWindowsAlreadyShownAsNativeSplit')
        self.assertEqual(module.ordinary_control({**good,'foreignVisibleMembers':1},7),'foreignVisibleWindowOnLeasedDesktop')
        self.assertEqual(module.ordinary_control({**good,'unknownVisibleMembers':1},7),'visibleWindowNativeMembershipUnresolved')

    @unittest.skipUnless(sys.platform=='darwin','requires the macOS signing and process APIs')
    def test_private_tmp_alias_live_kernel_executable_and_signing_identity_without_a_gui(self):
        with tempfile.TemporaryDirectory(dir='/private/tmp',prefix='nearpane-d01.split-id-test.') as tmp:
            kit=Path(tmp);fixture=kit/'Split Notes.app/Contents/MacOS/SplitNotes';fixture.parent.mkdir(parents=True)
            main=kit/'main.swift'; main.write_text('import Foundation\nFileHandle.standardOutput.write(Data([49,10]))\n_ = FileHandle.standardInput.readDataToEndOfFile()')
            subprocess.run(['xcrun','swiftc',main,'-o',fixture],check=True,timeout=35)
            subprocess.run(['codesign','--force','-s','-','-i','net.example.spaces-split-documents',fixture],check=True,capture_output=True,timeout=5)
            observer=kit/'read-helper'
            main.write_text('''import Foundation
guard let pid=Int32(CommandLine.arguments[1]) else{exit(2)}
let expected=CommandLine.arguments[2],alias=CommandLine.arguments[3]
let witness=CommandLine.arguments[0]
precondition(splitFixturePath(expected,observerExecutable:witness)==expected)
precondition(splitFixturePath(alias,observerExecutable:witness)==expected)
precondition(splitProcessPath(pid)==expected)
precondition(splitSignedPID(pid,identifier:"net.example.spaces-split-documents"))
precondition(!splitSignedPID(pid,identifier:"com.example.someone-else"))
precondition(splitFixturePath("/usr/bin/true",observerExecutable:witness)==nil)
precondition(splitFixturePath(expected,observerExecutable:"/usr/bin/true")==nil)
''')
            subprocess.run(['xcrun','swiftc',path.with_name('split-fixture-identity.swift'),main,'-o',observer],check=True,timeout=35)
            with subprocess.Popen([fixture],stdin=subprocess.PIPE,stdout=subprocess.PIPE) as proc:
                try:
                    self.assertEqual(proc.stdout.readline(),b'1\n')
                    subprocess.run([observer,str(proc.pid),fixture,str(fixture).removeprefix('/private')],check=True,timeout=6)
                finally:
                    proc.stdin.close();proc.wait(timeout=4)


if __name__=='__main__':
    unittest.main()
