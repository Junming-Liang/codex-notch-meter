#!/usr/bin/env python3
"""Run only the built app's synthetic update-pill harness, then verify safe shutdown.

The native app owns its timers/windows; this runner owns only its one child process.
It never launches Codex, reads accounts, requests screenshots, or downloads artifacts.
"""
from pathlib import Path
import re
import subprocess
import sys

RUN_TIMEOUT_SECONDS = 80  # Native harness: 75 s; adds 6-second recovery/replacement and delayed-paint coverage.


def receipt_checks(stdout: str) -> dict[str, bool]:
    """Every required receipt is exact, unique and complete, including model delivery."""
    lines = stdout.splitlines()

    def receipts(prefix: str, pattern: str) -> list[tuple[str, ...]]:
        selected = [line for line in lines if line.startswith(prefix)]
        matched = [re.fullmatch(pattern, line) for line in selected]
        if not all(matched):
            return []
        return [match.groups() for match in matched if match is not None]

    def kinds(prefix: str, pattern: str, expected: set[str]) -> bool:
        found = receipts(prefix, pattern)
        return len(found) == len(expected) and {entry[0] for entry in found} == expected

    number = r'([0-9]+(?:\.[0-9]+)?)'
    dwells = receipts(
        'UPDATE_DWELL_OK:',
        rf'UPDATE_DWELL_OK: seconds=([246]) armedHeld={number} paintHeld={number}',
    )
    dwell_ok = len(dwells) == 3 and {int(seconds) for seconds, _, _ in dwells} == {2, 4, 6}
    dwell_ok = dwell_ok and all(
        int(seconds) - 0.05 <= float(armed) <= int(seconds) + 0.75
        and float(painted) >= int(seconds) - 0.05
        for seconds, armed, painted in dwells
    )
    recovery_paint = receipts(
        'UPDATE_RECOVERY_PAINT_OK:',
        rf'UPDATE_RECOVERY_PAINT_OK: reason=previousReadFailed currentRemaining=50 consumptionClaim=false blockedSeconds=11 armedHeld={number} paintHeld={number}',
    )
    unchanged_active = receipts(
        'UPDATE_UNCHANGED_ACTIVE_OK:',
        rf'UPDATE_UNCHANGED_ACTIVE_OK: publications=0 sameID=true samePaint=true sameDeadline=true armedHeld={number} paintHeld={number}',
    )
    recovery_paint_ok = len(recovery_paint) == 1 and all(
        5.95 <= float(armed) <= 6.75 and float(painted) >= 5.95
        for armed, painted in recovery_paint
    )
    pointer_dwell = receipts('UPDATE_POINTER_DWELL_OK:',
        rf'UPDATE_POINTER_DWELL_OK: seconds=6 held={number} adjacent=true settingsCaptured=true repeatedID=true delayedReadiness=true')
    replacement_dwell = receipts('UPDATE_REPLACEMENT_DWELL_OK:',
        rf'UPDATE_REPLACEMENT_DWELL_OK: seconds=6 held={number} settingsCaptured=true oldTimerIgnored=true')
    return {
        'replacement_dwell': len(replacement_dwell) == 1 and 6 <= float(replacement_dwell[0][0]) <= 6.75,
        'pointer_dwell': len(pointer_dwell) == 1 and 6 <= float(pointer_dwell[0][0]) <= 6.75,
        'aggregate': sum(line.startswith('UPDATE_OK:') for line in lines) == 1,
        'shutdown': sum(line.startswith('SMOKE_OK:') for line in lines) == 1,
        'no_assertion_failures': not any(line.startswith(('UPDATE_FAILED:', 'UPDATE_ASSERT_FAILED:', 'SMOKE_FAILED:')) for line in lines),
        'configured_dwells': dwell_ok,
        'ineligible_reads': kinds('UPDATE_REJECT_OK:', r'UPDATE_REJECT_OK: kind=(initial|unchanged|readFailed)',
            {'initial', 'unchanged', 'readFailed'}),
        'secondary_change': receipts('UPDATE_SECONDARY_OK:', r'UPDATE_SECONDARY_OK: unchanged primary did not mask numeric secondary change') == [()],
        'optional_metadata': kinds('UPDATE_GENERIC_OK:',
            r'UPDATE_GENERIC_OK: kind=(identityFreeChange|metadataFreeChange) currentRemaining=79\.875 consumptionClaim=false',
            {'identityFreeChange', 'metadataFreeChange'}),
        'blocked_delivery': kinds('UPDATE_DELIVERY_OK:',
            r'UPDATE_DELIVERY_OK: blocker=(hover|menu|settings) blockedSeconds=11 latest=true deliveries=1 unchangedPublications=0',
            {'hover', 'menu', 'settings'}),
        'newest_replacement': receipts('UPDATE_REPLACEMENT_OK:', r'UPDATE_REPLACEMENT_OK: newest=true currentRemaining=50 deliveries=1') == [()],
        'explicit_invalidation': kinds('UPDATE_INVALIDATION_OK:',
            r'UPDATE_INVALIDATION_OK: kind=(accountSwitch|failure|disabled) pending=false',
            {'accountSwitch', 'failure', 'disabled'}),
        'queue_guards': kinds('UPDATE_QUEUE_GUARD_OK:',
            r'UPDATE_QUEUE_GUARD_OK: kind=(receivedExpired|fetchedExpired|resetDue|receivedFuture|fetchedFuture) blocked=true pending=false',
            {'receivedExpired', 'fetchedExpired', 'resetDue', 'receivedFuture', 'fetchedFuture'}),
        'queue_age_boundary': receipts('UPDATE_QUEUE_BOUNDARY_OK:', r'UPDATE_QUEUE_BOUNDARY_OK: seconds=180 eligible=true invalidated=true') == [()],
        'model_recovery': kinds('UPDATE_RECOVERY_MODEL_OK:',
            r'UPDATE_RECOVERY_MODEL_OK: kind=(timedOut|disconnected|longGap) currentRemaining=50 consumptionClaim=false',
            {'timedOut', 'disconnected', 'longGap'}),
        'painted_recovery': recovery_paint_ok,
        'unchanged_active': recovery_paint_ok and unchanged_active == recovery_paint,
        'settings': receipts('UPDATE_SETTINGS_OK:', r'UPDATE_SETTINGS_OK: model restored and persisted preferences untouched') == [()],
    }


def self_test() -> int:
    """Only parser controls, never a native-execution receipt."""
    line = 'UPDATE_POINTER_DWELL_OK: seconds=6 held=6.02 adjacent=true settingsCaptured=true repeatedID=true delayedReadiness=true'
    assert receipt_checks(line)['pointer_dwell']
    controls = ['', line + '\n' + line, line.replace('6.02', '1.02'),
                line.replace('6.02', '7.02'), line.replace('6.02', 'nan')]
    controls += [line.replace(field + '=true', field + '=false')
                 for field in ('adjacent', 'settingsCaptured', 'repeatedID', 'delayedReadiness')]
    for bad in controls:
        assert not receipt_checks(bad)['pointer_dwell']
    replacement = 'UPDATE_REPLACEMENT_DWELL_OK: seconds=6 held=6.02 settingsCaptured=true oldTimerIgnored=true'
    assert receipt_checks(replacement)['replacement_dwell']
    for bad in ['', replacement + '\n' + replacement, replacement.replace('6.02', '4.02'),
                replacement.replace('oldTimerIgnored=true', 'oldTimerIgnored=false')]:
        assert not receipt_checks(bad)['replacement_dwell']
    print(f'UPDATE_RECEIPT_SELF_TEST_OK: assertions={6 + len(controls)} nativeAppRun=false')
    return 0


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
    # Require actual timing receipts for every supported setting. A single aggregate
    # line cannot skip delivery/recovery coverage or the existing longer native dwells.
    checks = receipt_checks(stdout)
    if process.returncode != 0 or not all(checks.values()):
        failed = ', '.join(name for name, valid in checks.items() if not valid) or 'process exit'
        print(f'Native update-pill or orderly-shutdown contract failed: returncode={process.returncode}; checks={failed}.', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    raise SystemExit(self_test() if sys.argv[1:] == ['--self-test'] else main())
