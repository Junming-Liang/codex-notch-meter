#!/usr/bin/env python3
"""Demo-only native alignment gate; never enrolls login items or launches Codex."""
import subprocess
arguments = ['dist/Codex Notch Meter.app/Contents/MacOS/CodexNotchMeter', '--alignment-test']
process = subprocess.Popen(arguments, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
try:
    stdout, stderr = process.communicate(timeout=45)
except subprocess.TimeoutExpired:
    process.kill()
    stdout, stderr = process.communicate(timeout=5)
    print(stdout)
    print(stderr)
    raise SystemExit('Native alignment test exceeded the 45-second deadline')
print(stdout)
print(stderr)
if process.returncode != 0 or 'ALIGNMENT_OK:' not in stdout or 'SMOKE_OK:' not in stdout:
    raise SystemExit('Native alignment or orderly-shutdown contract failed')
