#!/usr/bin/env python3
"""Request ordinary motion on the isolated runner; record actual command results.

This is an accessibility presentation preference, not a permission or TCC change.
The app separately records NSWorkspace and its actual SwiftUI environment value.
If the system keeps Reduce Motion on, the film hosting environment explicitly
selects the supported non-reduced-motion presentation without changing product
logic. The original consumer app is not reconfigured outside this disposable CI.
"""
import argparse, json, subprocess
from pathlib import Path
parser = argparse.ArgumentParser()
parser.add_argument('directory', type=Path)
args = parser.parse_args()
def run(arguments):
    result = subprocess.run(arguments, capture_output=True, text=True, timeout=10)
    return {'command': arguments, 'exitCode': result.returncode, 'stdout': result.stdout.strip(), 'stderr': result.stderr.strip()}
report = {'scope': 'disposable CI accessibility presentation preference only', 'before': run(['/usr/bin/defaults', 'read', 'com.apple.universalaccess', 'reduceMotion']), 'write': run(['/usr/bin/defaults', 'write', 'com.apple.universalaccess', 'reduceMotion', '-bool', 'false']), 'after': run(['/usr/bin/defaults', 'read', 'com.apple.universalaccess', 'reduceMotion'])}
args.directory.mkdir(parents=True, exist_ok=True)
(args.directory / 'normal-motion-preference.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
print(json.dumps({'writeExitCode': report['write']['exitCode'], 'readback': report['after']['stdout'], 'actualAppEnvironmentValidation': 'recorded by SwiftUI motionGateTrace'}))
