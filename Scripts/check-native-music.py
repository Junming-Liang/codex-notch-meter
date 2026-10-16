#!/usr/bin/env python3
"""Run the built app's bounded, synthetic-only native music integration harness.

The runner owns just its child process. The app injects every Music/lyrics source;
no Music launch, automation prompt, account/file read, network or screen capture
is allowed. Pixel evidence comes only from its own synthetic NSView cache.
"""
from pathlib import Path
import re
import subprocess
import sys

RUN_TIMEOUT_SECONDS = 50  # Native watchdog: 43 s; OCR has its own 3 s cap.


def receipts_valid(stdout: str) -> bool:
    """Reject missing, duplicate, malformed, too-short or contradictory receipts."""
    def one(pattern: str):
        values = re.findall(pattern, stdout, re.MULTILINE)
        return values[0] if len(values) == 1 else None

    number = r'([0-9]+(?:\.[0-9]+)?)'
    disabled = one(r'^MUSIC_DISABLED_OK: observed=' + number + r' reads=0 lookups=0 imports=0$')
    consent = one(r'^MUSIC_CONSENT_OK: enablePrompt=true ordinaryPrompt=false pollGap=' + number + r' preOptInLookups=0$')
    timeline = one(r'^MUSIC_TIMELINE_OK: forwardSeek=true backwardSeek=true pausedHeld=' + number + r'$')
    stale = one(r'^MUSIC_STALE_OK: age=' + number + r' freshness=5 lineEmpty=true titleEmpty=true$')
    stale_empty = one(r'^MUSIC_STALE_EMPTY_OK: age=' + number + r' document=unavailable titleEmpty=true lineEmpty=true$')
    paint = one(r'^MUSIC_PAINT_OK: view=CompactDetailView originalLine=true width=(\d+) height=(\d+) scale=' + number + r'$')
    aggregate = one(r'^MUSIC_OK: checks=(\d+) elapsed=' + number + r' synthetic=true localViewPixels=true scanout=false$')
    retirements = re.findall(
        r'^MUSIC_RETIRE_OK: kind=(disable|sleep|stop) readerCancelled=true lookupCancelled=true '
        r'importCancelled=true visibleCleared=true lateRejected=true quiet=' + number + r'$', stdout, re.MULTILINE,
    )
    states = re.findall(r'^MUSIC_STATE_OK: kind=(unknown|stopped) freshSample=true previousLine=true cleared=true$', stdout, re.MULTILINE)
    cleanup = one(r'^MUSIC_CLEANUP_OK: controllers=(\d+) pendingRequests=0 panelStopped=true$')
    fixed = (
        'MUSIC_STARTUP_OK: enabledBeforeStart=true readsBeforeStart=0 startupPrompt=false',
        'MUSIC_ONLINE_OFF_OK: pendingCancelled=true lateRejected=true localPreserved=true musicEnabled=true',
        'MUSIC_SYNTHETIC_OK: defaultReader=silent defaultLookup=reject defaultImporter=reject',
        'MUSIC_SOURCE_OK: reason=timedOut lineEmpty=true titleEmpty=true',
        'MUSIC_DENIED_OK: explicitRetryPrompt=true followupPrompt=false idle=3.15 noAutomaticRetry=true',
        'MUSIC_PICKER_OK: staleAtoB=blocked staleAtoBtoA=blocked importerCalls=0',
        'MUSIC_REVISION_OK: sequence=A-B-A lookups=3 cancelledOld=2 newestLineRetained=true',
        'MUSIC_IMPORT_OK: reversedImports=2 cancelledOld=true localWinsOverLateOnline=true',
        'MUSIC_PRIORITY_OK: actualRefreshNotice=true lyricChanged=true noticeRetained=true passive=true',
        'MUSIC_LAYOUT_OK: nativeExpanded=2 measuredQuit=2 clickRouting=2 nonactivating=true',
        'MUSIC_LONG_LAYOUT_OK: view=DetailView quotaRows=8 longLyric=true footerUnchanged=true quitContained=true compactQuit=true',
        'MUSIC_RESUME_OK: wakePrompt=false stopTerminal=true',
    )
    lines = stdout.splitlines()
    if not all(lines.count(receipt) == 1 for receipt in fixed):
        return False
    if len(states) != 2 or set(states) != {'unknown', 'stopped'} or cleanup is None or int(cleanup) < 12:
        return False
    if not all((disabled, consent, timeline, stale, stale_empty, paint, aggregate)):
        return False
    if not (3.10 <= float(disabled) <= 43 and 0.95 <= float(consent) <= 5
            and 0.30 <= float(timeline) <= 5 and 5 <= float(stale) <= 7
            and 5 <= float(stale_empty) <= 7):
        return False
    width, height, scale = map(float, paint)
    if not (width >= 300 and height >= 250 and 1 <= scale <= 3):
        return False
    checks, elapsed = aggregate
    if int(checks) < 40 or not 15 <= float(elapsed) <= 43:
        return False
    if len(retirements) != 3 or {kind for kind, _ in retirements} != {'disable', 'sleep', 'stop'}:
        return False
    if not all(3.10 <= float(quiet) <= 6 for _, quiet in retirements):
        return False
    shutdown = [index for index, line in enumerate(lines) if line.startswith('SMOKE_OK:')]
    aggregate_index = next((index for index, line in enumerate(lines) if line.startswith('MUSIC_OK:')), len(lines))
    if len(shutdown) != 1 or shutdown[0] <= aggregate_index:
        return False
    if any(line.startswith(('MUSIC_FAILED:', 'SMOKE_FAILED:')) for line in lines):
        return False
    return True


def main() -> int:
    root = Path(__file__).resolve().parent.parent
    executable = root / 'dist/Codex Notch Meter.app/Contents/MacOS/CodexNotchMeter'
    try:
        process = subprocess.Popen(
            [str(executable), '--music-test'], cwd=root,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
        )
    except OSError as error:
        print(f'Native music test could not start the built application: {error}', file=sys.stderr)
        return 1
    timed_out = False
    try:
        stdout, stderr = process.communicate(timeout=RUN_TIMEOUT_SECONDS)
    except subprocess.TimeoutExpired:
        timed_out = True
        process.kill()  # Exact owned child only, never a process name or group.
        try:
            stdout, stderr = process.communicate(timeout=5)
        except subprocess.TimeoutExpired:
            print('Native music test timed out; owned-child cleanup exceeded 5 seconds.', file=sys.stderr)
            return 1
    print(stdout, end='')
    print(stderr, end='', file=sys.stderr)
    if timed_out:
        print(f'Native music test exceeded the {RUN_TIMEOUT_SECONDS}-second runner deadline.', file=sys.stderr)
        return 1
    if process.returncode != 0 or not receipts_valid(stdout):
        print('Native music integration or orderly-shutdown contract failed.', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
