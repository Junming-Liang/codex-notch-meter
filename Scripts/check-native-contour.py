#!/usr/bin/env python3
"""Run only our synthetic native contour harness, with a strict process deadline."""
import os
from pathlib import Path
import subprocess

for theme in ("standard", "rainbow", "aurora", "sunset", "ice"):
    environment = os.environ.copy()
    environment['CODEX_CONTOUR_ARTIFACT_DIR'] = str(Path('dist/contour-rendering', theme).resolve())
    arguments = ['dist/Codex Notch Meter.app/Contents/MacOS/CodexNotchMeter', '--contour-test']
    arguments.append('--skin=' + theme)
    process = subprocess.Popen(arguments, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=environment)
    try:
        stdout, stderr = process.communicate(timeout=25)
    except subprocess.TimeoutExpired:
        process.kill()
        stdout, stderr = process.communicate(timeout=5)
        print(stdout)
        print(stderr)
        raise SystemExit(f'Native {theme} contour test exceeded the 25-second deadline')
    print(stdout)
    print(stderr)
    if process.returncode != 0 or 'CONTOUR_OK:' not in stdout or 'SMOKE_OK:' not in stdout:
        raise SystemExit(f'Native {theme} contour or orderly-shutdown contract failed')
