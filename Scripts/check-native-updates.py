#!/usr/bin/env python3
"""Run only the built app's synthetic update-pill harness, then verify safe shutdown.

The native app owns its timers/windows; this runner owns only its one child process.
It never launches Codex, reads accounts, requests screenshots, or downloads artifacts.
"""
from pathlib import Path
import subprocess
import sys


def main() -> int:
    root = Path(__file__).resolve().parent.parent
    executable = root / 'dist/Codex Notch Meter.app/Contents/MacOS/CodexNotchMeter'
    try:
        process = subprocess.Popen(
            [str(executable), '--update-test'], cwd=root,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
        )
    except OSError as error:
        print(f'Native update test could not start the built application: {error}', file=sys.stderr)
        return 1
    timed_out = False
    try:
        stdout, stderr = process.communicate(timeout=45)
    except subprocess.TimeoutExpired:
        timed_out = True
        # Kill only the exact process this runner created, never a name/global group.
        process.kill()
        try:
            stdout, stderr = process.communicate(timeout=5)
        except subprocess.TimeoutExpired:
            print('Native update test exceeded 45 seconds; owned-process cleanup exceeded 5 seconds.', file=sys.stderr)
            return 1
    print(stdout, end='')
    print(stderr, end='', file=sys.stderr)
    if timed_out:
        print('Native update test exceeded the 45-second deadline.', file=sys.stderr)
        return 1
    update_ok = any(line.startswith('UPDATE_OK:') for line in stdout.splitlines())
    shutdown_ok = any(line.startswith('SMOKE_OK:') for line in stdout.splitlines())
    failure = any(line.startswith(('UPDATE_FAILED:', 'SMOKE_FAILED:')) for line in stdout.splitlines())
    if process.returncode != 0 or not update_ok or not shutdown_ok or failure:
        print('Native update-pill or orderly-shutdown contract failed.', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
