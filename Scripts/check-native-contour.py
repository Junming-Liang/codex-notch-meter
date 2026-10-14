#!/usr/bin/env python3
"""Run only our synthetic native contour harness, with a strict process deadline."""
import os
from pathlib import Path
import subprocess

environment = os.environ.copy()
environment['CODEX_CONTOUR_ARTIFACT_DIR'] = str(Path('dist/contour-rendering').resolve())
process = subprocess.Popen(
    ['dist/Codex Notch Meter.app/Contents/MacOS/CodexNotchMeter', '--contour-test'],
    stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=environment,
)
try:
    stdout, stderr = process.communicate(timeout=25)
except subprocess.TimeoutExpired:
    process.kill()
    stdout, stderr = process.communicate(timeout=5)
    print(stdout)
    print(stderr)
    raise SystemExit('Native contour test exceeded the 25-second deadline')
print(stdout)
print(stderr)
if process.returncode != 0 or 'CONTOUR_OK:' not in stdout or 'SMOKE_OK:' not in stdout:
    raise SystemExit('Native contour or orderly-shutdown contract failed')
