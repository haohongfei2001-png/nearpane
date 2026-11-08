#!/usr/bin/env python3
"""Bounded offline CF/ABI fixture verification in the existing workspace sandbox.

Every invocation creates new private evidence, including compiler failures.
Neither the controller nor default helper loads SkyLight or reads WindowServer.
There is no live flag, selector option, permission escalation, or automatic retry.
"""
import datetime
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parent
os.umask(0o077)
RUN = ROOT / '.local' / datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%S.%fZ')
RUN.mkdir(parents=True, exist_ok=False)
print(f'private_run={RUN}', flush=True)
receipts = []


def command(label, args, *, timeout=60, env_extra=None, expected_exit=0):
    env = os.environ.copy()
    env.update(env_extra or {})
    start = datetime.datetime.now(datetime.timezone.utc).isoformat()
    out_path, err_path = RUN / f'{label}.stdout', RUN / f'{label}.stderr'
    status, timed_out = None, False
    # A separate process group contains timeouts to this helper/tool and its children.
    with out_path.open('xb') as out, err_path.open('xb') as err:
        child = subprocess.Popen(args, cwd=ROOT, env=env, stdout=out, stderr=err, start_new_session=True)
        try:
            status = child.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            import signal
            os.killpg(child.pid, signal.SIGKILL)
            status = child.wait()
            timed_out = True
    receipt = dict(label=label, argv=[str(a) for a in args], cwd=str(ROOT),
                   envOverrides=env_extra or {}, startedUTC=start,
                   finishedUTC=datetime.datetime.now(datetime.timezone.utc).isoformat(),
                   exitCode=status, expectedExit=expected_exit, timedOut=timed_out, stdout=out_path.name, stderr=err_path.name,
                   stdoutSHA256=hashlib.sha256(out_path.read_bytes()).hexdigest(),
                   stderrSHA256=hashlib.sha256(err_path.read_bytes()).hexdigest())
    receipts.append(receipt)
    (RUN / 'commands.json').write_text(json.dumps(receipts, indent=2) + '\n')
    print(f'{label}: exit={status}, timeout={timed_out}', flush=True)
    return status == expected_exit and not timed_out


def finalize():
    hashes = {str(p.relative_to(RUN)): hashlib.sha256(p.read_bytes()).hexdigest()
              for p in sorted(RUN.rglob('*')) if p.is_file() and 'module-cache' not in p.parts
              and p.name != 'SHA256SUMS.txt'}
    (RUN / 'SHA256SUMS.txt').write_text(''.join(f'{digest}  {name}\n' for name, digest in hashes.items()))
    print(f'receipts={RUN / "commands.json"}', flush=True)


try:
    if sys.platform != 'darwin' or platform.machine() != 'arm64':
        raise SystemExit('This experiment is scoped to the measured ARM64 macOS build.')
    for label, args in [
        ('os', ['/usr/bin/sw_vers']), ('architecture', ['/usr/bin/uname', '-m']),
        ('clang-version', ['xcrun', 'clang', '--version']),
        ('swift-version', ['xcrun', 'swiftc', '--version']),
        ('sdk', ['xcrun', '--show-sdk-path']),
        ('git-head', ['git', 'rev-parse', 'HEAD']),
        ('git-branch', ['git', 'branch', '--show-current']),
        ('git-status', ['git', 'status', '--short']),
    ]:
        command(label, args)
    snapshot = RUN / 'source'
    snapshot.mkdir()
    for name in ['skylight-shim.h', 'skylight-shim.c', 'abi-probe.swift', 'run-verification.py']:
        (snapshot / name).write_bytes((ROOT / name).read_bytes())
    reference = ROOT / '.local' / 'reference'
    upstream = (reference / 'yabai-extern.h').read_text()
    window_c = (reference / 'yabai-window.c').read_text()
    declarations = [line for line in (ROOT / 'skylight-shim.h').read_text().splitlines() if line.startswith('extern ')]
    crosscheck = {
        'revision': 'dd845723416f5fe92af49fad5ebab00369e07edd',
        'declarations': [dict(text=line, presentVerbatim=line in upstream.splitlines(),
                              upstreamLine=upstream.splitlines().index(line) + 1 if line in upstream.splitlines() else None)
                         for line in declarations],
        'sint32ConstructionPresent': 'cfarray_of_cfnumbers(&wid, sizeof(uint32_t), 1, kCFNumberSInt32Type)' in window_c,
        'selector7Present': 'SLSCopySpacesForWindows(g_connection, 0x7, window_list_ref)' in window_c,
        'copyReleasePresent': 'CFRelease(space_list_ref);' in window_c,
        'referenceFiles': {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in reference.iterdir() if p.is_file()},
        'note': 'Archived connector text, not a claim of Apple ABI documentation.'
    }
    (RUN / 'reference-crosscheck.json').write_text(json.dumps(crosscheck, indent=2) + '\n')
    assert all(x['presentVerbatim'] for x in crosscheck['declarations']) and len(declarations) == 3
    assert crosscheck['sint32ConstructionPresent'] and crosscheck['selector7Present'] and crosscheck['copyReleasePresent']
    c_text = (ROOT / 'skylight-shim.c').read_text()
    swift_text = (ROOT / 'abi-probe.swift').read_text()
    safety = {
        'cCallFixedAt7': re.findall(r'membership_fn\(connection,\s*([^,]+),', c_text) == ['0x7'],
        'swiftCallFixedAt7': re.findall(r'swiftMember\(connection,\s*([^,]+),', swift_text) == ['0x7'],
        'noSelectorSweepOrNegativeCall': 'for selector' not in swift_text and 'unapproved_selector' not in swift_text,
        'noPublicWindowMetadataCalls': 'CGWindowListCopyWindowInfo' not in swift_text,
        'onlyFixtureInitializerInCLI': 'NPInitializeFixtures(fault,' in swift_text and 'NPInitialize(fault,' not in swift_text,
        'liveBackendDisabledByDefault': '#define NEARPANE_ENABLE_LIVE 0' in c_text,
    }
    (RUN / 'safety-static.json').write_text(json.dumps(safety, indent=2) + '\n')
    assert all(safety.values()), safety
    cc = ['xcrun', 'clang', '-std=c11', '-Wall', '-Wextra', '-Werror', '-g', '-O1', '-c',
          str(ROOT / 'skylight-shim.c')]
    swift = ['xcrun', 'swiftc', '-g', '-Onone', '-warnings-as-errors', '-module-cache-path', str(RUN / 'module-cache'),
             '-import-objc-header', str(ROOT / 'skylight-shim.h'), str(ROOT / 'abi-probe.swift')]
    if not command('compile-c', cc + ['-o', str(RUN / 'shim.o')]):
        raise SystemExit(1)
    if not command('compile-swift', swift + [str(RUN / 'shim.o'), '-o', str(RUN / 'abi-probe')]):
        raise SystemExit(1)
    command('linked-libraries', ['/usr/bin/otool', '-L', str(RUN / 'abi-probe')])
    command('undefined-symbols', ['/usr/bin/nm', '-u', str(RUN / 'abi-probe')])
    symbols = (RUN / 'undefined-symbols.stdout').read_text()
    assert not re.search(r'_(dlopen|dlsym|dlclose|SLS\w+|CGWindowListCopyWindowInfo)\b', symbols), 'offline binary has forbidden imports'
    # Compile the dormant path for type checking only. Never link or execute it.
    assert command('live-path-syntax-only', ['xcrun', 'clang', '-std=c11', '-Wall', '-Wextra', '-Werror',
                   '-DNEARPANE_ENABLE_LIVE=1', '-fsyntax-only', str(ROOT / 'skylight-shim.c')])
    for fault in ['missing-library', 'missing-symbol', 'managed-null', 'managed-malformed', 'membership-null', 'membership-wrong-type']:
        assert command(fault, [str(RUN / 'abi-probe'), '--fault', fault, '--iterations', '1', '--stress-only'],
                       expected_exit=0 if fault.startswith('missing-') else 2)
    success = command('offline-matrix', [str(RUN / 'abi-probe'), '--iterations', '1000'])
    # Failures are preserved; no live run exists in this runner.
    if not success:
        raise SystemExit(2)
    # The existing sandbox already denied leaks' task-port request. Do not retry
    # that diagnostic or change privileges. Count fixture CF allocations directly.
    (RUN / 'leaks-status.json').write_text(json.dumps({
        'status': 'NOT TESTED', 'scope': 'whole-process leak scan',
        'reason': 'Earlier offline-leaks receipt: task port denied by current sandbox; not retried.',
        'alternative': 'fixtureAllocatorAfterShutdown and AddressSanitizer (not a global leak detector)',
    }, indent=2) + '\n')
    assert command('compile-c-asan', cc + ['-fsanitize=address', '-fno-omit-frame-pointer', '-o', str(RUN / 'shim-asan.o')])
    assert command('compile-swift-asan', swift + ['-sanitize=address', str(RUN / 'shim-asan.o'), '-o', str(RUN / 'abi-probe-asan')])
    assert command('offline-asan', [str(RUN / 'abi-probe-asan'), '--stress-only', '--iterations', '200'],
                   env_extra={'ASAN_OPTIONS': 'halt_on_error=1:detect_leaks=0'})
finally:
    finalize()
