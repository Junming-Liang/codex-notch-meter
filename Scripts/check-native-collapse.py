#!/usr/bin/env python3
"""Run only our synthetic close-endpoint process; never account or login work."""
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
