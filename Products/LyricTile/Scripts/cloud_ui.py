"""Narrow native permission/onboarding helper for disposable macOS Actions."""
import hashlib
import json
import os
import platform
import signal
import subprocess
from pathlib import Path


def start_cloud_ui(directory: Path, mode: str, seconds=35, welcome_ready=None):
    directory.mkdir(parents=True, exist_ok=True)
    report = directory / 'native-permission-ui.json'
    if (os.environ.get('GITHUB_ACTIONS') != 'true' or platform.system() != 'Darwin'
            or not os.environ.get('RUNNER_TEMP')):
        raise RuntimeError('Native permission helper is restricted to disposable macOS Actions.')
    source = Path(__file__).with_name('CloudPermissionHelper.swift')
    binary = Path(os.environ['RUNNER_TEMP']) / ('LyricTileCloudUI-' + hashlib.sha256(source.read_bytes()).hexdigest()[:16])
    if not binary.is_file():
        try:
            build = subprocess.run(['/usr/bin/swiftc', str(source), '-o', str(binary)],
                                   capture_output=True, text=True, timeout=45)
            (directory / 'native-permission-build.log').write_text(build.stdout + build.stderr)
            if build.returncode:
                raise RuntimeError('The native Accessibility helper did not compile; inspect the build log.')
        except (subprocess.TimeoutExpired, RuntimeError) as error:
            report.write_text(json.dumps({'status': 'BLOCKED', 'reason': str(error),
                'accessibilityRequested': False, 'TCCDatabaseModified': False}) + '\n')
            return None, report
    stream = (directory / 'native-permission-process.log').open('w')
    arguments = [str(binary), '--mode', mode, '--seconds', str(seconds), '--output', str(report)]
    if welcome_ready is not None:
        arguments += ['--welcome-ready', str(welcome_ready)]
    process = subprocess.Popen(arguments,
                               stdout=stream, stderr=stream, start_new_session=True)
    stream.close()
    return process, report


def stop_cloud_ui(handle):
    if not handle:
        return {}
    process, report = handle
    if process is not None and process.poll() is None:
        try:
            os.killpg(process.pid, signal.SIGTERM)
            process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait(timeout=3)
        except ProcessLookupError:
            pass
    value = json.loads(report.read_text()) if report.exists() else {
        'status': 'BLOCKED', 'reason': 'No native UI report was produced.'}
    if process is not None:
        value['helperExitCode'] = process.returncode
    if value.get('status') == 'OBSERVING':
        value['status'] = 'COMPLETED' if value.get('actions') else 'NO_ALLOWED_CONTROL_OBSERVED'
    report.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n')
    return value
