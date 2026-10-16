#!/usr/bin/env python3
"""Run only the built app's synthetic update-pill harness, then verify safe shutdown.

The native app owns its timers/windows; this runner owns only its one child process.
It never launches Codex, reads accounts, requests screenshots, or downloads artifacts.
"""
from pathlib import Path
import re
import subprocess
import sys

RUN_TIMEOUT_SECONDS = 70  # Native harness is bounded at 65 s, including real 2/4/6 s dwells.


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
        stdout, stderr = process.communicate(timeout=RUN_TIMEOUT_SECONDS)
    except subprocess.TimeoutExpired:
        timed_out = True
        # Kill only the exact process this runner created, never a name/global group.
        process.kill()
        try:
            stdout, stderr = process.communicate(timeout=5)
        except subprocess.TimeoutExpired:
            print(f'Native update test exceeded {RUN_TIMEOUT_SECONDS} seconds; owned-process cleanup exceeded 5 seconds.', file=sys.stderr)
            return 1
    print(stdout, end='')
    print(stderr, end='', file=sys.stderr)
    if timed_out:
        print(f'Native update test exceeded the {RUN_TIMEOUT_SECONDS}-second deadline.', file=sys.stderr)
        return 1
    update_ok = any(line.startswith('UPDATE_OK:') for line in stdout.splitlines())
    shutdown_ok = any(line.startswith('SMOKE_OK:') for line in stdout.splitlines())
    failure = any(line.startswith(('UPDATE_FAILED:', 'SMOKE_FAILED:')) for line in stdout.splitlines())
    # Require actual timing receipts for every supported setting. A single aggregate
    # success line cannot silently skip the longer runs or route rejected reads to a popup.
    dwells = re.findall(
        r'^UPDATE_DWELL_OK: seconds=([246]) armedHeld=([0-9]+(?:\.[0-9]+)?) paintHeld=([0-9]+(?:\.[0-9]+)?)$',
        stdout, re.MULTILINE,
    )
    dwell_ok = len(dwells) == 3 and {int(seconds) for seconds, _, _ in dwells} == {2, 4, 6}
    dwell_ok = dwell_ok and all(
        int(seconds) - 0.05 <= float(armed) <= int(seconds) + 0.75
        and float(painted) >= int(seconds) - 0.05
        for seconds, armed, painted in dwells
    )
    rejected = re.findall(r'^UPDATE_REJECT_OK: kind=(initial|unchanged|readFailed)$', stdout, re.MULTILINE)
    rejection_ok = len(rejected) == 3 and set(rejected) == {'initial', 'unchanged', 'readFailed'}
    secondary_ok = any(line.startswith('UPDATE_SECONDARY_OK:') for line in stdout.splitlines())
    generic = re.findall(
        r'^UPDATE_GENERIC_OK: kind=(identityFreeChange|metadataFreeChange) currentRemaining=79\.875 consumptionClaim=false$',
        stdout, re.MULTILINE,
    )
    generic_ok = len(generic) == 2 and set(generic) == {'identityFreeChange', 'metadataFreeChange'}
    settings_ok = any(line.startswith('UPDATE_SETTINGS_OK:') for line in stdout.splitlines())
    if process.returncode != 0 or not all((update_ok, shutdown_ok, dwell_ok, rejection_ok, secondary_ok, generic_ok, settings_ok)) or failure:
        print('Native update-pill or orderly-shutdown contract failed.', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
