"""Offline receipt/packaging tests. No application is built, signed or launched."""
import copy
import importlib.util
from pathlib import Path
import tempfile
import unittest
import uuid

spec = importlib.util.spec_from_file_location('lab', Path(__file__).with_name('merge-lab.py'))
lab = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lab)


class RestrictedLabTests(unittest.TestCase):
    def setUp(self):
        self.receipt = {'timeline': [
            {'phase':'before','current':[22],'sourceWindow':11,'managerTwin':42},
            {'phase':'readback','settled':True,'current':[11,22],'nativeAXStrip':[],'timeNS':120},
            {'phase':'readback','settled':True,'current':[11,22],'nativeAXStrip':[],'timeNS':170}]}

    def test_exact_native_completion_requires_independent_matching_reads(self):
        self.assertTrue(lab.confirmed_membership(self.receipt))
        for key,value in [('phase','before'),('settled',False),('timeNS',120),('current',[22]),('nativeAXStrip',[[11]])]:
            changed=copy.deepcopy(self.receipt)
            changed['timeline'][-1][key]=value
            self.assertFalse(lab.confirmed_membership(changed),key)

    def test_closed_other_or_unrelated_destination_cannot_complete(self):
        for field,value in [('current',[99]),('sourceWindow',99),('managerTwin',0)]:
            changed=copy.deepcopy(self.receipt)
            changed['timeline'][0][field]=value
            self.assertFalse(lab.confirmed_membership(changed),field)
        self.assertFalse(lab.confirmed_membership({'timeline':[]}))

    def test_cycle_requires_all_three_r4_buttons_and_two_later_exact_reads(self):
        children=[dict(identifier='com.holdsnow.stageworkset-merge-fixture.'+letter,pid=10+i,birth=100+i)
                  for i,letter in enumerate('abc')]
        keys=[dict(pid=c['pid'],birth=c['birth'],window=1000+i) for i,c in enumerate(children)]
        bootstrap=[dict(k,timeNS=10+i*2+j) for i,k in enumerate(keys) for j in range(2)]
        steps=[]
        for i in range(3):
            target=keys[(i+1)%3]
            reads=[dict(target, timeNS=20+i*2+j,otherStages=[k['window'] for k in keys if k!=target])
                   for j in range(2)]
            steps.append(dict(entry='R4AccessibilityButton',fromWindow=keys[i]['window'],
                              to=target['window'],confirmedReads=reads))
            steps[-1]['from']=steps[-1].pop('fromWindow')
        receipt=dict(children=children,bootstrap=bootstrap,focusCycleSteps=steps,focusCycleComplete=True)
        self.assertTrue(lab.confirmed_focus_cycle(receipt))
        for field,value in [('birth',0),('pid',99),('window',77),('otherStages',[]),('timeNS',20)]:
            mutated=copy.deepcopy(receipt)
            mutated['focusCycleSteps'][-1]['confirmedReads'][1][field]=value
            self.assertFalse(lab.confirmed_focus_cycle(mutated))
        self.assertFalse(lab.confirmed_focus_cycle(dict(receipt,focusCycleSteps=steps[:2])))
        self.assertFalse(lab.confirmed_focus_cycle(dict(receipt,bootstrap=bootstrap[:4])))

    def test_prepare_refuses_daily_path_before_signing_or_launching(self):
        with self.assertRaises((ValueError,OSError)):
            lab.prepare('/Applications/Nearpane.app')

    def test_finder_metadata_cleanup_refuses_a_link_to_another_bundle(self):
        root = Path('/private/tmp') / ('nearpane-apple-merge.' + str(uuid.uuid4()))
        root.mkdir(mode=0o700)
        try:
            with tempfile.TemporaryDirectory(dir='/private/tmp') as other:
                app = root / 'Nearpane.app'
                app.symlink_to(other, target_is_directory=True)
                try:
                    with self.assertRaises(ValueError): lab.normalize_build_copy(app)
                finally: app.unlink()
        finally: root.rmdir()

    def test_receipt_directory_rejects_unsealed_and_foreign_location(self):
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaises(ValueError): lab.safe_root(Path(tmp))

if __name__=='__main__':
    unittest.main()
