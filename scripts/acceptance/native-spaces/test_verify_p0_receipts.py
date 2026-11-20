import hashlib
import importlib.util
import io
import json
from pathlib import Path
import shutil
import tarfile
import tempfile
import unittest
from unittest.mock import patch


HERE = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location('verify_p0', HERE / 'verify-p0-receipts.py')
verify = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(verify)
ARCHIVES = HERE.parents[2] / 'engineering/verification/native-spaces/5.22-p0'
REFERENCE = ARCHIVES / '11-adjacent-round-trip'


class ArchiveTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.reference = verify.read_archive(REFERENCE)

    def test_reproduces_archive_without_promoting_a_gate(self):
        report = verify.verify(REFERENCE)
        ten = report['stages']['ten']
        self.assertEqual((ten['gestureSequences'], ten['verifiedNavigations']), (10, 10))
        self.assertEqual(ten['latencyMS'], {'p50': 172.15, 'p95': 231.0, 'p99': 231.0})
        self.assertEqual((ten['recordedGate'], ten['visualByAttempt']), ('BLOCKED', {'UNKNOWN': 10}))
        self.assertEqual(report['stages']['fifty']['recordedGate'], 'NOT_RUN')

    def test_unissued_setup_has_no_verified_navigation(self):
        result = verify.verify(ARCHIVES / '17-system-dock-identity')
        self.assertEqual(result['uniqueHostJournals'], 0)
        self.assertEqual(result['stages']['roundTrip']['recordedGate'], 'BLOCKED')

    def test_corrupt_archive_or_individual_digest_is_rejected(self):
        with tempfile.TemporaryDirectory() as dest:
            temporary = Path(dest)
            archive = temporary / verify.ARCHIVE
            manifest = temporary / 'original-receipts-manifest.json'
            real = json.loads((REFERENCE / manifest.name).read_bytes())
            shutil.copyfile(REFERENCE / verify.ARCHIVE, archive)
            manifest.write_text(json.dumps(real))
            with archive.open('ab') as out:
                out.write(b'corrupted')
            with self.assertRaisesRegex(ValueError, 'archive SHA-256 mismatch'):
                verify.verify(temporary)
            real['archiveSHA256'] = hashlib.sha256(archive.read_bytes()).hexdigest()
            real['files'][0]['sha256'] = '0' * 64
            manifest.write_text(json.dumps(real))
            with self.assertRaisesRegex(ValueError, 'SHA-256 mismatch'):
                verify.verify(temporary)

    def test_valid_hashes_do_not_hide_a_late_return(self):
        original = REFERENCE / verify.ARCHIVE
        with tempfile.TemporaryDirectory() as dest, tarfile.open(original) as source:
            destination = Path(dest)
            path = destination / verify.ARCHIVE
            files = []
            with tarfile.open(path, 'w:gz') as target:
                for member in source:
                    raw = source.extractfile(member).read()
                    if member.name == 'roundTrip-01/windowserver.jsonl':
                        rows = [json.loads(line) for line in raw.splitlines()]
                        rows[-1]['topology']['current'] = rows[0]['topology']['current']
                        raw = b'\n'.join(json.dumps(r).encode() for r in rows)
                    member.size = len(raw)
                    target.addfile(member, io.BytesIO(raw))
                    files.append(dict(file=member.name, bytes=len(raw), sha256=hashlib.sha256(raw).hexdigest()))
            manifest = dict(archive=path.name, archiveSHA256=hashlib.sha256(path.read_bytes()).hexdigest(), files=files)
            (destination / 'original-receipts-manifest.json').write_text(json.dumps(manifest))
            with self.assertRaisesRegex(ValueError, 'roundTrip-01: late return to source'):
                verify.verify(destination)

    def test_semantic_contradictions_never_count_as_verification(self):
        digest, members, original = self.reference
        journal = next(k for k in original if k.startswith('roundTrip-01/') and verify.JOURNAL.fullmatch(k.split('/')[1]))
        changes = [
            ('roundTrip-01/ax-dispatch.json', lambda v: v.update(control='current-desktop-window:1:2'), 'background card'),
            ('roundTrip-01/identity.json', lambda v: v.update(hostBirth=v['hostBirth'] + 1), 'Host PID'),
            (journal, lambda v: v['result']['switchTrace'].update(phasesMachTicks=[100, 100, 200]), 'gesture phases'),
            ('results.json', lambda v: v['stages']['ten'].update(status='PASS'), 'required visual'),
        ]
        for filename, mutate, reason in changes:
            with self.subTest(filename=filename):
                data = original.copy()
                record = json.loads(data[filename])
                mutate(record)
                data[filename] = json.dumps(record).encode()
                with patch.object(verify, 'read_archive', return_value=(digest, members, data)):
                    with self.assertRaisesRegex(ValueError, reason):
                        verify.verify(REFERENCE)

    def test_foreground_change_does_not_relabel_the_current_space(self):
        _, _, data = self.reference
        req = json.loads(data['roundTrip-01/identity.json'])
        pressed = json.loads(data['roundTrip-01/ax-dispatch.json'])['uptime']
        rows = [json.loads(x) for x in data['roundTrip-01/windowserver.jsonl'].splitlines()]
        # A new foreground owner can appear while WindowServer still reports the enrolled target.
        rows[-1]['frontPID'] = -1
        result = verify.landing(rows, req, pressed)
        self.assertEqual(result['externalForegroundReads'], 1)
        self.assertGreater(result['firstExternalForegroundMS'], 2000)

    def test_absent_or_unknown_visual_receipt_cannot_pass(self):
        sample = dict(source=1, target=2, blankScreen='PASS')
        with self.assertRaisesRegex(ValueError, 'no original receipt'):
            verify.visual_status({}, 'ten-01', sample, 1, 4)
        sample['blankScreen'] = 'UNKNOWN'
        data = {'ten-01/visual/receipt.json': b'{"status":"PASS"}'}
        self.assertEqual(verify.visual_status(data, 'ten-01', sample, 1, 4), 'UNKNOWN')

    def test_hid_topology_sampling_and_short_dwell(self):
        _, _, data = self.reference
        req = json.loads(data['roundTrip-01/identity.json'])
        pressed = json.loads(data['roundTrip-01/ax-dispatch.json'])['uptime']
        raw = data['roundTrip-01/windowserver.jsonl'].splitlines()
        for case in ('HID', 'display', 'Space order', 'gap', 'short dwell', 'foreign Space'):
            with self.subTest(case=case):
                rows = [json.loads(x) for x in raw]
                if case == 'HID':
                    rows[-1]['hid'][0] += 1
                elif case == 'display':
                    rows[-1]['topology']['display'] = 'different'
                elif case == 'Space order':
                    rows[-1]['topology']['records'].reverse()
                elif case == 'gap':
                    rows = rows[:4] + rows[15:]
                elif case == 'short dwell':
                    rows = rows[:15]
                else:
                    rows[-1]['topology']['current'] = 123456
                with self.assertRaises(ValueError):
                    verify.landing(rows, req, pressed)


if __name__ == '__main__':
    unittest.main()
