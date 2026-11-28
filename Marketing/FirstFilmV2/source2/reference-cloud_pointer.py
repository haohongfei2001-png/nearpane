"""Bounded real pointer input for an already-authorized disposable macOS runner.

Start before the ordinary app: compilation is synchronous. The app atomically
writes pointer-request.json; native-pointer.json reports whether each requested
CGEvent was posted. Product state/source readback must establish actual success.
"""
import hashlib
import json
import math
import os
import platform
import signal
import subprocess
import time
from pathlib import Path


def _write_report(path: Path, value):
    temporary = path.with_name(path.name + '.tmp')
    temporary.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n')
    temporary.replace(path)


def start_cloud_pointer(directory: Path, seconds=120):
    """Return (Popen or None, report Path), after the availability handshake."""
    if (os.environ.get('GITHUB_ACTIONS') != 'true' or platform.system() != 'Darwin'
            or not os.environ.get('RUNNER_TEMP')
            or not Path(os.environ['RUNNER_TEMP']).is_dir()):
        raise RuntimeError('Native pointer input is restricted to disposable macOS Actions.')
    directory = Path(directory).resolve()
    directory.mkdir(parents=True, exist_ok=True)
    report = directory / 'native-pointer.json'
    for name in ('native-pointer.json', 'pointer-request.json', 'pointer-stop'):
        (directory / name).unlink(missing_ok=True)
    source = Path(__file__).with_name('CloudPointerHelper.swift')
    binary = Path(os.environ['RUNNER_TEMP']) / (
        'LyricTileCloudPointer-' + hashlib.sha256(source.read_bytes()).hexdigest()[:16])

    def blocked(reason):
        _write_report(report, {'available': False, 'status': 'BLOCKED', 'reason': reason,
            'accessibilityRequested': False, 'postEventAccessRequested': False,
            'TCCDatabaseModified': False, 'actions': []})
        return None, report

    if not binary.is_file():
        try:
            build = subprocess.run(['/usr/bin/swiftc', str(source), '-o', str(binary)],
                                   capture_output=True, text=True, timeout=45)
            (directory / 'native-pointer-build.log').write_text(build.stdout + build.stderr)
            if build.returncode:
                binary.unlink(missing_ok=True)
                return blocked('The native pointer helper did not compile; inspect native-pointer-build.log.')
        except (OSError, subprocess.TimeoutExpired) as error:
            binary.unlink(missing_ok=True)
            return blocked('Native pointer helper compilation was unavailable: ' + str(error))
    duration = float(seconds)
    duration = min(180, max(1, duration)) if math.isfinite(duration) else 120
    try:
        with (directory / 'native-pointer-process.log').open('w') as stream:
            process = subprocess.Popen([str(binary), '--directory', str(directory), '--seconds', str(duration)],
                                       stdout=stream, stderr=stream, start_new_session=True)
    except OSError as error:
        return blocked('The native pointer helper could not start: ' + str(error))
    handle = process, report
    deadline = time.monotonic() + 4
    while time.monotonic() < deadline and process.poll() is None and not report.exists():
        time.sleep(0.05)
    if not report.exists():
        stop_cloud_pointer(handle)
        return blocked('The native pointer helper did not produce its availability handshake.')
    return handle


def stop_cloud_pointer(handle):
    """Stop before performance sampling; return the persisted report, idempotently."""
    if not handle:
        return {}
    process, report = handle
    if process is not None and process.poll() is None:
        (report.parent / 'pointer-stop').touch()
        try:
            process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(process.pid, signal.SIGTERM)
                process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait(timeout=2)
            except ProcessLookupError:
                process.wait(timeout=2)
    try:
        value = json.loads(report.read_text())
    except (OSError, ValueError):
        value = {'available': False, 'status': 'BLOCKED', 'actions': [],
                 'reason': 'No valid native pointer report was produced.'}
    if process is not None:
        value['helperExitCode'] = process.returncode
    if value.get('status') == 'OBSERVING':
        value['status'] = 'COMPLETED' if process is not None and process.returncode == 0 else 'INTERRUPTED'
    _write_report(report, value)
    return value
