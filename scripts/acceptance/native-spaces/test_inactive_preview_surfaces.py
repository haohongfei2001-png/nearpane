import unittest
from contract_workspace import inactive_empty

class InactiveSurfaceTests(unittest.TestCase):
    def test_only_invisible_exclusive_signed_system_compositor_rows_in_explicit_recovery(self):
        sid=5094
        row=dict(number=90,pid=421,layer=24,code={'apple':True,'identifier':'com.apple.WindowServer'},onscreen=False,
                 visibleQuery=False,installedHost=0,forward=[sid],reverse=[sid])
        def check(r,opt=True,**change):
            return inactive_empty(dict({'ordinary':[],'unresolved':0,'otherMembers':1,'otherDetails':[r]},**change),sid,system_surfaces=opt)
        self.assertTrue(check(row));self.assertFalse(check(row,False))
        self.assertTrue(check({**row,'layer':-1,'code':{'apple':True,'identifier':'com.apple.dock'}}))
        for delta in [dict(onscreen=True),dict(visibleQuery=True),dict(layer=0),dict(installedHost=1),dict(reverse=[sid,6]),
                      dict(forward=[]),dict(pid=0),dict(number=0),dict(code={'apple':False,'identifier':'com.apple.WindowServer'}),
                      dict(code={'apple':True,'identifier':'com.apple.WindowManager'})]:
            self.assertFalse(check({**row,**delta}))
        for delta in [dict(unresolved=1),dict(ordinary=[{'pid':72,'number':97}]),dict(otherMembers=2)]:
            self.assertFalse(check(row,**delta))
