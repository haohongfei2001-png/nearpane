#!/usr/bin/env python3
"""Read receipts only; verify hashes and export fixture data plus a private-file index.

Usage: python3 summarize-evidence.py FINAL_RUN_DIRECTORY NEW_OUTPUT_DIRECTORY
No helper is launched. Pre-correction live data is never exported or used to pass
the corrected live gate. All private runs, including failures, remain unchanged.
"""
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parent
BASE = 'beb6471fe360004425760a024636e5a63dbe87d1'
BASELINE = '159dc5b6f1c4d5d511ddf4e4fcac35be2a535f0e'
RUN = Path(sys.argv[1]).resolve()
OUT = Path(sys.argv[2]).resolve()
assert RUN.parent == ROOT / '.local'
assert OUT.is_relative_to(ROOT / 'evidence')
OUT.mkdir(parents=True, exist_ok=False)


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def read(name, run=RUN):
    return json.loads((run / name).read_text())


def save(name, value):
    (OUT / name).write_text(json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + '\n')


def probe_json(path):
    for line in path.read_text().splitlines():
        if line.startswith('{'):
            return json.loads(line)
    return None


results = read('offline-matrix.stdout')
assert results['mode'] == 'offline_synthetic_CF_fixtures'
assert results['safety']['fixtureBackend'] and not results['safety']['liveBackendCompiled']
assert {r['selector'] for r in results['matrix']} == {7}
assert results['validationPassed']
assert results['fixtureAllocatorAfterShutdown']['balanced']
assert results['fixtureAllocatorAfterShutdown']['allocations'] > 0
commands = read('commands.json')
assert all(c['exitCode'] == c['expectedExit'] and not c['timedOut'] for c in commands)
assert all(read('safety-static.json').values())
assert all(f['passed'] for f in results['parserFixtures'] + results['guardFixtures'])
assert all(f['fixtureCallCountDelta'] == 0 for f in results['guardFixtures'])
symbols = (RUN / 'undefined-symbols.stdout').read_text()
assert not re.search(r'_(dlopen|dlsym|dlclose|SLS\w+|CGWindowListCopyWindowInfo)\b', symbols)
asan = read('offline-asan.stdout')
assert asan['validationPassed'] and asan['fixtureAllocatorAfterShutdown']['balanced']
assert not (RUN / 'offline-asan.stderr').read_text().strip()

faults = {}
for name in ['missing-library', 'missing-symbol', 'managed-null', 'managed-malformed', 'membership-null', 'membership-wrong-type']:
    value = read(name + '.stdout')
    assert value['mode'] == 'offline_synthetic_CF_fixtures' and value['cOwnership']['balanced']
    if name.startswith('missing-'):
        assert value['expectedFault'] and value['cOwnership']['membershipCalls'] == 0
    else:
        assert value['state'] == 'helper_error' and value['shutdown'] == 0
        assert value['fixtureAllocatorAfterShutdown']['balanced']
    if name.startswith('managed-'):
        assert value['cOwnership']['membershipCalls'] == 0
    faults[name] = value

# Export only this known-synthetic run. All real-window identifiers stay private.
save('offline-fixture-results.json', results)
save('offline-fault-results.json', faults)
save('reference-crosscheck.json', read('reference-crosscheck.json'))

history = []
command_exports = []
for directory in sorted((ROOT / '.local').iterdir()):
    manifest = directory / 'SHA256SUMS.txt'
    if not directory.is_dir() or not manifest.exists():
        continue
    files = {}
    for line in manifest.read_text().splitlines():
        digest, relative = line.split('  ', 1)
        file = directory / relative
        assert file.resolve().is_relative_to(directory.resolve())
        assert sha(file) == digest, f'evidence changed: {directory.name}/{relative}'
        files[relative] = digest
    entry = dict(run=directory.name, manifestSHA256=sha(manifest), fileSHA256=files)
    if (directory / 'matrix.stdout').exists():
        legacy = probe_json(directory / 'matrix.stdout')
        if legacy.get('state') == 'helper_error':
            entry.update(category='initial_sandbox_live_attempt', acceptance='FAILED_PREREQUISITE',
                         error=legacy['error'], cOwnership=legacy['cOwnership'])
            assert legacy['cOwnership']['membershipCalls'] == 0
        else:
            # Explicitly disclose the privileged executions before the safety correction.
            entry.update(category='pre_correction_privileged_live_execution', acceptance='EXCLUDED_FROM_CORRECTED_GATE',
                         observedSelectors=sorted({x['selector'] for x in legacy['matrix']}),
                         matrixRows=len(legacy['matrix']), matrixMismatchCount=legacy['matrixMismatchCount'],
                         guardFailures=[f['name'] for f in legacy['guardFixtures'] if not f['passed']],
                         cOwnership=legacy['cOwnership'], swiftOwnership=legacy['swiftOwnership'],
                         disclosure='Executed outside the execution sandbox before the user safety correction; retained, never rerun.')
            for label in ['leaks', 'asan']:
                if (directory / (label + '.stdout')).exists():
                    receipt = probe_json(directory / (label + '.stdout'))
                    entry[label + 'HistoricalRun'] = {
                        'guardFailures': [f['name'] for f in receipt['guardFixtures'] if not f['passed']],
                        'cOwnership': receipt['cOwnership'],
                        'swiftOwnership': receipt['swiftOwnership'],
                    }
    elif (directory / 'offline-matrix.stdout').exists():
        fixture = probe_json(directory / 'offline-matrix.stdout')
        entry.update(category='post_correction_offline_fixtures', acceptance='FINAL' if directory == RUN else 'SUPERSEDED_BY_ALLOCATOR_OBSERVER',
                     validationPassed=fixture['validationPassed'], matrixRows=len(fixture['matrix']),
                     selectors=sorted({x['selector'] for x in fixture['matrix']}))
        if (directory / 'offline-leaks.stderr').exists():
            text = (directory / 'offline-leaks.stderr').read_text()
            entry['leakScan'] = dict(status='NOT TESTED', blocker='Could not get task port immediately after launch',
                                     taskPortDenied='Couldn\'t get task port' in text)
    history.append(entry)
    for command in read('commands.json', directory):
        sanitized = json.loads(json.dumps(command).replace(str(directory), '$RUN').replace(str(ROOT), '$EXPERIMENT'))
        sanitized['run'] = directory.name
        command_exports.append(sanitized)
save('raw-evidence-index.json', {'privateRoot': 'experiments/macos-spaces-abi/.local', 'runs': history,
                               'referenceTextSHA256': read('reference-crosscheck.json')['referenceFiles'],
                               'excludedFromManifests': 'Rebuildable compiler module-cache only; manifests do not hash themselves.'})
save('command-receipts.json', command_exports)

provenance = []
for ref, path, requested in [
    (BASE, 'docs/reviews/P1-TECHNICAL-GATE-REVIEW.md', 'docs/reviews/P1-TECHNICAL-GATE-REVIEW.md'),
    (BASE, 'engineering/P1-READONLY-BASELINE-20261109.md', 'docs/engineering/P1-READONLY-BASELINE-20261109.md'),
    (BASE, 'architecture/MACOS-SPACES-FEASIBILITY.md', 'docs/architecture/MACOS-SPACES-FEASIBILITY.md'),
    *[(BASELINE, p, p) for p in [
        'experiments/macos-spaces-readonly/README.md',
        'experiments/macos-spaces-readonly/spaces-mapping-probe.swift',
        'experiments/macos-spaces-readonly/evidence/p1-readonly-summary.json']],
]:
    content = subprocess.check_output(['git', 'show', f'{ref}:{path}'], cwd=ROOT)
    provenance.append(dict(requestedPath=requested, readFrom=f'{ref}:{path}', sha256=hashlib.sha256(content).hexdigest()))
save('baseline-provenance.json', {'inputs': provenance, 'baselineReexecuted': False,
                                'note': 'Base HEAD had moved two docs and removed the old experiment; read-only git show recovered its source/evidence.'})

tests = [
    ('helper_isolation', 'PASS', 'Default executable imports no dlopen/dlsym/dlclose, SLS symbols, or window-list metadata function; no Host changes.'),
    ('pinned_declarations_and_static_abi', 'PASS', 'Three declarations match pinned yabai; Clang static width/type assertions and dormant-path syntax check passed.'),
    ('c_swift_ffi_and_sint32_bridge_fixtures', 'PASS', f"{len(results['matrix'])} fixture rows x four call/encoding paths; zero mismatches. Not real windows."),
    ('empty_single_multiple_duplicate_invalid_fixture_inputs', 'PASS', '15 input cases, three rounds; both SInt32 and NSNumber encodings.'),
    ('selector_source_restriction', 'PASS', 'Both call sites hard-code 0x7; no selector parameter, sweep, alternate-selector test, or CLI live mode.'),
    ('cf_types_null_empty_and_uint64_fixtures', 'PASS', '15 parser fixtures, including wrong types, missing fields, 2^32+17, 2^53+1, Int64.max and UInt64.max.'),
    ('input_guards', 'PASS', 'Nine malformed/out-of-range inputs rejected before the fixture backend; includes the UInt64.max signed-wrap regression.'),
    ('fault_injection', 'PASS', 'Six injected loader/symbol/managed/membership errors; managed failures stop before membership; all acquired C objects released.'),
    ('copy_consumption_and_fixture_cf_deallocation', 'PASS', 'Manual releases balance; retained Swift returns consumed once; custom CF allocator reports zero outstanding allocations after shutdown.'),
    ('repeated_fixture_calls', 'PASS', '100 warmup + 1000 measured iterations; four membership and two managed fixture calls each; no result drift.'),
    ('address_sanitizer_fixtures', 'PASS', '200 measured iterations; exit 0 and empty stderr. ASan leak detection disabled; not a whole-process leak scan.'),
    ('whole_process_leak_scan', 'NOT TESTED', 'leaks exited 255: task port denied by current sandbox. Preserved and not retried; allocation observer covers only controlled CF objects.'),
    ('live_selector7_bridge_and_input_differentials', 'NOT TESTED', 'Initial sandbox managed query returned NULL and no usable window sample; membership calls 0. No privileged retry allowed under corrected scope.'),
    ('live_return_schema_uint64_and_copy_contract', 'NOT TESTED', 'Fixtures and static signatures cannot prove the private implementation contract. Prior privileged evidence excluded from corrected gate.'),
    ('live_selector_semantics_dedup_and_ordering', 'NOT TESTED', 'No permitted live comparison. Synthetic multi-ID rules are test fixtures and imply no undocumented selector semantics.'),
    ('live_connection_thread_session_sleep_wake', 'NOT TESTED', 'No session disturbance, forced invalidation, thread sweep, sleep/wake or WindowServer restart.'),
    ('cross_build_private_api_stability', 'NOT TESTED', 'Only macOS 27.0 / 26A428 / arm64 environment recorded; no private ABI stability claim.'),
    ('evidence_preservation', 'PASS', 'All private run manifests verified, including initial failure and both pre-correction privileged runs; only fixture data exported.'),
]
repeat = results['repeated']
summary = dict(
    scope='P1-A static/offline completion under corrected sandbox and selector boundary; live gate remains open',
    branch='spike/p1-abi-20261109', baseHEAD=BASE, finalOfflineRun=RUN.name,
    environment=results['environment'], abi=results['abi'], tests=[dict(item=a, status=b, evidence=c) for a, b, c in tests],
    fixtureMatrix=dict(inputCases=len({r['case'] for r in results['matrix']}), rounds=3, rows=len(results['matrix']), pathsPerRow=4,
                       selectors=[7], mismatchCount=results['matrixMismatchCount']),
    cOwnership=results['cOwnership'], swiftOwnership=results['swiftOwnership'],
    fixtureAllocatorAfterShutdown=results['fixtureAllocatorAfterShutdown'],
    repeated=repeat, asan=dict(validationPassed=asan['validationPassed'], repeated=asan['repeated'],
                             allocator=asan['fixtureAllocatorAfterShutdown']),
    safety=results['safety'], staticSafety=read('safety-static.json'),
    limitations=[
        'Current execution performed zero live SkyLight calls after the safety correction.',
        'Historical privileged executions swept selectors 0..7 before the correction; they are disclosed and excluded, not relabeled as unexecuted.',
        'The first historical privileged run had an input-guard failure: NSNumber(UInt64.max) converted to signed -1; later source fixes are verified with offline fixtures.',
        'Core Foundation may canonicalize numeric storage; construction type and CFNumberGetType need not match.',
        'The allocation observer counts only objects using the custom fixture allocator; runtime caches and system framework internals are outside that measurement.',
        'Live results, process/thread connection semantics, sleep/wake, and private Copy ownership remain unverified within the corrected boundary.',
    ],
)
save('p1-abi-summary.json', summary)
print(json.dumps({'output': str(OUT), 'tests': {s: sum(x[1] == s for x in tests) for s in ['PASS', 'FAIL', 'NOT TESTED']},
                  'verifiedPrivateRuns': len(history), 'allocator': results['fixtureAllocatorAfterShutdown']}, indent=2))
