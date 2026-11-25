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
