#!/usr/bin/env python3
"""Production native windows, with no playback fixtures or network activity."""
import argparse
import json
import platform
import subprocess
from pathlib import Path

p = argparse.ArgumentParser()
p.add_argument('app', type=Path)
p.add_argument('--output', type=Path, required=True)
a = p.parse_args()
a.output.mkdir(parents=True, exist_ok=True)


def run_surface(language, appearance, destination):
    destination.mkdir(parents=True, exist_ok=True)
    command = [str(a.app.resolve()/'Contents/MacOS/LyricTile'), '--smoke-test',
               '--smoke-appearance', appearance,
               '--smoke-screenshot', str((destination/'native-ui.png').resolve()),
               '-AppleLanguages', f'({language})']
    process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    try:
        stdout, stderr = process.communicate(timeout=30)
        code = process.returncode
    except subprocess.TimeoutExpired:
        # Preserve an actual stuck stack before killing a failed check.
        try:
            sample = subprocess.run(['/usr/bin/sample', str(process.pid), '2', '-file',
                                     str(destination/'native-timeout.sample.txt')],
                                    capture_output=True, text=True, timeout=5)
            (destination/'sample-command.log').write_text(sample.stdout+sample.stderr)
        except Exception as error:
            (destination/'sample-command.log').write_text(str(error))
        process.kill()
        stdout, stderr = process.communicate(timeout=5)
        code = 124
    (destination/'native-smoke.stdout.log').write_text(stdout)
    (destination/'native-smoke.stderr.log').write_text(stderr)
    rows = []
    for line in stdout.splitlines():
        try:
            rows.append(json.loads(line))
        except json.JSONDecodeError:
            pass
    observation = next((x for x in rows if x.get('check') == 'native-ui-load'), None)
    expected_language = 'chinese' if language.startswith('zh') else 'english'
    expected_appearance = 'NSAppearanceNameDarkAqua' if appearance == 'dark' else 'NSAppearanceNameAqua'
    passed = (code == 0 and observation is not None and observation.get('passed') is True
              and observation.get('language') == expected_language
              and observation.get('appearance') == expected_appearance)
    report = dict(status='PASS' if passed else 'FAIL', exitCode=code,
                  host=platform.platform(), language=language, appearance=appearance,
                  observation=observation, realPlayerQualification='NOT_RUN')
    (destination/'native-smoke.json').write_text(json.dumps(report, ensure_ascii=False, indent=2)+'\n')
    return report


variants = []
for language, appearance in [('zh-Hans', 'light'), ('zh-Hans', 'dark'), ('en', 'light'), ('en', 'dark')]:
    destination = a.output if not variants else a.output/'variants'/f'{language}-{appearance}'
    variants.append(run_surface(language, appearance, destination))
passed = all(x['status'] == 'PASS' for x in variants)
# Preserve the original top-level observation and screenshots for existing tools,
# while requiring all four actual native renders to pass before CI is green.
report = dict(status='PASS' if passed else 'FAIL', host=platform.platform(),
              observation=variants[0]['observation'], variants=variants,
              realPlayerQualification='NOT_RUN',
              displayScaleQualification='OBSERVED_HOST_SCALE_ONLY')
(a.output/'native-smoke.json').write_text(json.dumps(report, ensure_ascii=False, indent=2)+'\n')
print(json.dumps(report, ensure_ascii=False))
raise SystemExit(0 if passed else 1)
