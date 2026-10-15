#!/usr/bin/env python3
"""Run our demo-only native frame timing and reversal gate, without account or login work."""
import subprocess
arguments = ['dist/Codex Notch Meter.app/Contents/MacOS/CodexNotchMeter', '--motion-test']
process = subprocess.Popen(arguments, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
try:
    stdout, stderr = process.communicate(timeout=45)
except subprocess.TimeoutExpired:
    process.kill()
    stdout, stderr = process.communicate(timeout=5)
    print(stdout)
    print(stderr)
    raise SystemExit('Native motion test exceeded the 45-second deadline')
print(stdout)
print(stderr)
if process.returncode != 0 or 'MOTION_OK:' not in stdout or 'SMOKE_OK:' not in stdout:
    raise SystemExit('Native motion or orderly-shutdown contract failed')
