"""Replay only the released synthetic-window receipts. No system or graphics calls."""
import copy
import importlib.util
from pathlib import Path
import unittest

here = Path(__file__).parent
spec = importlib.util.spec_from_file_location('apple_reference', here/'apple-preview-reference.py')
reference = importlib.util.module_from_spec(spec)
spec.loader.exec_module(reference)


class ReferenceTests(unittest.TestCase):
    def test_signed_host_presentations_never_become_native_apple_samples(self):
        packet = reference.PACKET
        report = reference.audit(packet/'physical-09', packet/'physical-08/installed-stage-manager.json',
                                 packet/'apple-reference/mission-observation.jsonl')
        self.assertEqual(report['nativeStageManagerComparison']['status'], 'NOT_MEASURED')
        self.assertIsNone(report['nativeStageManagerComparison']['latencyMs'])
        self.assertEqual(report['nativeStageManagerComparison']['nativePresentationSamples'], 0)
        self.assertEqual(report['pairedRun']['matchedNearpaneTransitionsReported'], 12)
        self.assertEqual(report['stageOn']['verifiedOffscreenWindowManagerSurfacesInLease'], 2)

    def test_ambiguous_extra_or_relabelled_stream_requires_new_attribution(self):
        run = reference.file_json(reference.PACKET/'physical-09/result.json')
        for change in ('extra', 'apple', 'croppedOtherWindow'):
            specimen = copy.deepcopy(run)
            filters = next(e['filterGeometry'] for e in specimen['sampler']['events'] if 'filterGeometry' in e)
            if change == 'extra':
                filters.append(copy.deepcopy(filters[2]))
            elif change == 'apple':
                filters[2]['mode'] = 'windowManager'
            else:
                filters[2]['sampledGlobalRects'] = filters[0]['sampledGlobalRects']
            with self.subTest(change=change), self.assertRaises(ValueError):
                reference.enrolled_streams(specimen)

    def test_changed_raw_frame_hash_is_rejected(self):
        folder = reference.PACKET/'physical-09'
        meta = reference.file_json(folder/'result.json')['presentation']
        with self.assertRaisesRegex(ValueError, 'frameLedgerChecksum'):
            reference.pixel_counts(folder/'presentation-frames.jsonl.gz', {**meta, 'sha256': 'f'*64})


if __name__ == '__main__':
    unittest.main()
