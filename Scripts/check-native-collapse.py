#!/usr/bin/env python3
"""Run only synthetic own-view collapse replay; never scanout, account, or login work."""
import itertools
import re
import subprocess

arguments = ['dist/Codex Notch Meter.app/Contents/MacOS/CodexNotchMeter', '--collapse-test']
process = subprocess.Popen(arguments, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
try:
    stdout, stderr = process.communicate(timeout=75)
except subprocess.TimeoutExpired:
    process.kill()
    stdout, stderr = process.communicate(timeout=5)
    print(stdout)
    print(stderr)
    raise SystemExit('Native close endpoint test exceeded the 75-second deadline')
print(stdout)
print(stderr)
if process.returncode != 0 or 'COLLAPSE_OK:' not in stdout or 'SMOKE_OK:' not in stdout:
    raise SystemExit('Native close endpoint or orderly-shutdown contract failed')

# A stale executable must not pass merely by printing the older success marker.
# Require the entire rendered matrix, including a real old-opacity negative control.
lines = (stdout + '\n' + stderr).splitlines()
themes = ('standard', 'rainbow', 'aurora', 'sunset', 'ice')
scales = (1, 2)


def check_matrix(label, keys, expected, flags):
    rows = [dict(re.findall(r'\b(\w+)=([^\s]+)', line)) for line in lines
            if line.startswith('SMOKE_STAGE: collapse ' + label + ' ')]
    seen = []
    try:
        for row in rows:
            key = tuple(float(row[name]) if name == 'progress' else
                        int(row[name]) if name == 'scale' else row[name] for name in keys)
            seen.append(key)
            if any(row.get(name) != value for name, value in flags.items()):
                raise ValueError('failed or missing assertion')
            if label == 'body-endpoint' and float(row['progress']) == 0:
                if float(row['meanAlpha']) != 0 or float(row['maxAlpha']) != 0:
                    raise ValueError('idle body is not exactly transparent')
    except (KeyError, ValueError) as error:
        raise SystemExit(f'Native {label} evidence is invalid: {error}') from error
    if len(seen) != len(expected) or set(seen) != expected:
        raise SystemExit(f'Native {label} matrix incomplete: got {len(seen)}, expected {len(expected)}')


replay_flags = {'valid': 'true', 'offlineReplay': 'true', 'scanout': 'false'}
check_matrix('coupled-body', ('theme', 'scale', 'progress'),
             set(itertools.product(themes, scales, (0.1, 0.05, 0.02))),
             dict(replay_flags, legacyRendered='true', legacyRejected='true', outsideCamera='true'))
endpoints = set(itertools.product(('default',), themes, scales, (0.001, 0.0005, 0.0)))
endpoints.update(itertools.product(('shortest', 'tallest'), ('standard',), scales, (0.001, 0.0005, 0.0)))
check_matrix('body-endpoint', ('fixture', 'theme', 'scale', 'progress'), endpoints,
             dict(replay_flags, transparentIdle='true'))
check_matrix('extreme-tail', ('fixture', 'scale'),
             set(itertools.product(('shortest', 'tallest'), scales)),
             dict(replay_flags, terminalBounds='true', terminalAxes='true'))
print('COLLAPSE_MATRIX_OK: 30 rendered coupling/legacy controls, 42 body endpoints, 4 extreme tails; offline replay only')
