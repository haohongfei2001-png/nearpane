import unittest
import importlib
import json
from unittest.mock import patch
from pathlib import Path
import split_fullscreen as fs

LEASE,FULL=7,8
SHELL=dict(animating=False,sameCurrent=True,signedDock=True,signedWindowManager=True,exposedRoots=0,dockBirth=1,managerBirth=2)

def ordinary():
    return dict(ready=True,space=LEASE,spaceUUID='ordinary',type=0,newFullscreenIDs=[],onlyTwoInLease=True,
                memberships=[[LEASE],[LEASE]],forward=[True,True],axStandard=[True,True],
                foreignVisibleMembers=0,unknownVisibleMembers=0,windowManagement=SHELL)

def tiled(member,current=FULL):
    return dict(ready=True,space=current,type=4 if current==FULL else 0,newFullscreenIDs=[FULL],
                memberships=[[FULL],[FULL] if member else [LEASE]],fullscreenForward=[True,member],
                leaseWindowCensus={'admitted':True},foreignVisibleMembers=0,unknownVisibleMembers=0,
                draw=[True,True],windowManagement=SHELL)

class Tests(unittest.TestCase):
    def test_only_one_independently_verified_offscreen_apple_surface_can_enter_the_initial_census(self):
        driver=importlib.import_module('split-view')
        candidate={'pid':647,'number':117}
        def snapshot(ordinary):
            return dict(host={'pid':1,'codeHash':'h'},installedHostCount=1,displays=[{}],stageManager=True,
                        scopes=[{'current':LEASE,'scope':'d','records':[{'id':LEASE,'uuid':'u','type':0}]}],
                        scopedMembers={str(LEASE):{'ordinary':ordinary,'otherMembers':0,'otherDetails':[],'unresolved':0}})
        proof={'admitted':True,'number':117,'ownerBirth':10,'bounds':[1352,446,103,97]}
        for ordinary_rows,replies,accepted in [([candidate],[proof,proof],True),([candidate],[{'admitted':False}],False),
                                 ([candidate],[proof,{**proof,'ownerBirth':11}],False),([candidate,candidate],[],False)]:
            def output(cmd,**_):
                return b'10' if len(cmd)>1 else json.dumps(snapshot(ordinary_rows)).encode()
            with self.subTest(ordinary=ordinary_rows,replies=replies),patch.object(driver.subprocess,'check_output',side_effect=output), \
                 patch.object(driver,'read',side_effect=replies),patch.object(driver.time,'sleep'):
                run=lambda:driver.fullscreen_admission(Path('/unused'),1,'h','d',LEASE,{str(LEASE):'u'})
                if accepted:self.assertEqual(run()['inactiveStageSurface'],proof)
                else:
                    with self.assertRaises(ValueError):run()

    def test_fullscreen_entry_requires_agreeing_display_sized_live_geometry(self):
        s=dict(displayFrame=[-1000,10,1000,680],cgFrames=[[-1000,40,1000,650],None],
               axFrames=[[-1000,40,1000,650],None])
        self.assertTrue(fs.full_geometry(s))
        for f in [[-1000,40,470,650],[-960,40,1000,650],[-1000,120,1000,570],None]:
            self.assertFalse(fs.full_geometry({**s,'cgFrames':[f,None],'axFrames':[f,None]}))
        self.assertFalse(fs.full_geometry({**s,'axFrames':[[-1000,40,1000,540],None]}))

    def test_only_the_preenrolled_installed_host_layer_zero_on_the_exact_lease_is_exempt(self):
        row=dict(number=31,pid=72,installedHost=1,layer=0,forward=[LEASE],reverse=[LEASE])
        self.assertEqual(fs.host_window_numbers([row],72,LEASE),[31])
        for change in [dict(pid=99),dict(installedHost=0),dict(layer=-1),dict(forward=[LEASE,FULL]),
                       dict(reverse=[FULL]),dict(number=32,forward=[])]:
            self.assertEqual(fs.host_window_numbers([{**row,**change}],72,LEASE),[])

    def test_normal_window_must_be_the_enrolled_fullscreen_member(self):
        base=tiled(False,current=LEASE)
        flags={'fullscreen':[True,False]}
        self.assertTrue(fs.source_member(base,flags,LEASE,0))
        self.assertFalse(fs.source_member(base,flags,LEASE,1))
        for broken in [dict(fullscreenForward=[False,False]),dict(newFullscreenIDs=[11,12]),dict(space=12),
                       dict(unknownVisibleMembers=1),dict(foreignVisibleMembers=1),dict(leaseWindowCensus={'admitted':False})]:
            self.assertFalse(fs.source_member({**base,**broken},flags,LEASE,0))
        self.assertFalse(fs.source_member(base,{'fullscreen':[False,False]},LEASE,0))

    def test_ordinary_self_report_cannot_substitute_for_fullscreen_space_gone(self):
        flags={'fullscreen':[False,False]}
        self.assertTrue(fs.ordinary(ordinary(),flags,LEASE))
        self.assertFalse(fs.ordinary({**ordinary(),'newFullscreenIDs':[FULL]},flags,LEASE))
        self.assertFalse(fs.ordinary({**ordinary(),'memberships':[[FULL],[LEASE]]},flags,LEASE))
        self.assertFalse(fs.stable_shell({'windowManagement':{**SHELL,'animating':True}}))

    def test_half_picker_unwinds_once_and_waits_for_ordinary_rereads(self):
        state=tiled(False,current=LEASE); flags=[True,False]; actions=[]; report={}
        def own():return dict(numbers=[31,32],fullscreen=flags.copy())
        def send(_folder,_fixture,verb,index):
            actions.append((verb,index)); flags[index]=False; state.clear();state.update(ordinary())
        with patch.object(fs,'request',send):
            fs.unwind(Path('/unused'),own,lambda:state,LEASE,report,lambda:None)
        self.assertEqual(actions,[('ordinary',0)])
        self.assertEqual(report['status'],'PASS')

    def test_system_applies_both_exits_or_leaves_b_fullscreen(self):
        state=tiled(True); flags=[True,True]; done=[]; report={}
        def own():return dict(numbers=[31,32],fullscreen=flags.copy())
        def send(_folder,_fixture,verb,index):
            done.append(index);flags[index]=False
            state.update(memberships=[[FULL] if f else [LEASE] for f in flags],fullscreenForward=flags.copy())
            if not any(flags):state.clear();state.update(ordinary())
        with patch.object(fs,'request',send):
            fs.unwind(Path('/unused'),own,lambda:state,LEASE,report,lambda:None)
        self.assertEqual(done,[0,1]);self.assertEqual(report['status'],'PASS')
