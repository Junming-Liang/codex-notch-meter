#!/usr/bin/env python3
"""Synthetic production-path display checks. Never changes a real display or login item."""
import subprocess

process = subprocess.Popen(
    ['dist/Codex Notch Meter.app/Contents/MacOS/CodexNotchMeter', '--display-test'],
    stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
)
try:
    stdout, stderr = process.communicate(timeout=30)
except subprocess.TimeoutExpired:
    process.kill()
    stdout, stderr = process.communicate(timeout=5)
    print(stdout)
    print(stderr)
    raise SystemExit('Native display compatibility test exceeded the 30-second deadline')
print(stdout)
print(stderr)
if process.returncode != 0 or 'DISPLAY_OK:' not in stdout or 'SMOKE_OK:' not in stdout:
    raise SystemExit('Native display compatibility or orderly-shutdown contract failed')
