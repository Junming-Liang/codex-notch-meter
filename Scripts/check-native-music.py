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

RUN_TIMEOUT_SECONDS = 110  # Native watchdog: 100 s; each own-view OCR has a 3 s cap.


def receipts_valid(stdout: str) -> bool:
    """Reject missing, duplicate, malformed, too-short or contradictory receipts."""
    def one(pattern: str):
        values = re.findall(pattern, stdout, re.MULTILINE)
        return values[0] if len(values) == 1 else None

    number = r'([0-9]+(?:\.[0-9]+)?)'
    disabled = one(r'^MUSIC_DISABLED_OK: observed=' + number + r' reads=0 lookups=0 imports=0$')
    consent = one(r'^MUSIC_CONSENT_OK: enablePrompt=true ordinaryPrompt=false pollGap=' + number + r' preOptInLookups=0$')
    timeline = one(r'^MUSIC_TIMELINE_OK: forwardSeek=true backwardSeek=true pausedCleared=' + number + r'$')
    stale = one(r'^MUSIC_STALE_OK: age=' + number + r' freshness=5 lineEmpty=true titleEmpty=true$')
    stale_empty = one(r'^MUSIC_STALE_EMPTY_OK: age=' + number + r' document=unavailable titleEmpty=true lineEmpty=true$')
    paint = one(r'^MUSIC_PAINT_OK: view=CompactDetailView originalLine=true width=(\d+) height=(\d+) scale=' + number + r'$')
    aggregate = one(r'^MUSIC_OK: checks=(\d+) elapsed=' + number + r' synthetic=true localViewPixels=true scanout=false$')
    auto_stale = one(r'^MUSIC_AUTO_STALE_OK: age=' + number + r' document=unavailable previouslyPainted=true owner=idle$')
    auto_priority = one(r'^MUSIC_AUTO_PRIORITY_OK: hold=' + number + r' expected=6 paintBeforeArm=true playingUpdates=(\d+) lyricUpdates=(\d+) dwellUnchanged=true motionUnchanged=true samePanel=true$')
    auto_paint = one(r'^MUSIC_AUTO_PAINT_OK: sequence=music-notice-music lyricBefore=true quota80to79=true lyricAfter=true appearances=aqua,darkAqua width=(\d+) height=(\d+) scale=' + number + r' localViewPixels=true scanout=false$')
    auto_pause = one(r'^MUSIC_AUTO_PAUSE_NOTICE_OK: hold=' + number + r' expected=4 dwellUnchanged=true lyricEmpty=true owner=idle$')
    auto_reduced = one(r'^MUSIC_AUTO_REDUCED_OK: hold=' + number + r' expected=2 sequence=music-notice-music-idle motionFrames=0 passive=true$')
    close_paint = one(r'^MUSIC_AUTO_CLOSE_PAINT_OK: intermediateFrames=(\d+) opacityDecreased=true opaqueBefore4pt=true idleOpacity=0 naturalPaint=true$')
    cooldown = one(r'^MUSIC_LOOKUP_COOLDOWN_OK: observed=' + number + r' retryAfter=60 polls=3 lookupCalls=1 synthetic=true$')
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
        'MUSIC_IMPORT_COMPLETION_OK: sameLine=true oldDocumentRejected=true requestReturned=true exactDocument=true expectedCue=true',
        'MUSIC_PRIORITY_OK: actualRefreshNotice=true lyricChanged=true noticeRetained=true passive=true',
        'MUSIC_LAYOUT_OK: nativeExpanded=2 measuredQuit=2 clickRouting=2 nonactivating=true',
        'MUSIC_LONG_LAYOUT_OK: view=DetailView quotaRows=8 longLyric=true footerUnchanged=true quitContained=true compactQuit=true',
        'MUSIC_RESUME_OK: wakePrompt=false stopTerminal=true',
        'MUSIC_AUTO_EMPTY_OK: noHover=true owner=music document=unavailable statusToken=LRC ownViewOCR=true passive=true',
        'MUSIC_AUTO_HOVER_OK: playingExit=music pausedExit=idle pausedDetailsRetained=true pausedLyricAbsentOCR=true realPointerDwell=true',
        'MUSIC_LABEL_OK: compactOCR=4 expandedOCR=2 legacyWordAbsent=true',
        'MUSIC_AUTO_STEADY_OK: polls=2 lyricUpdates=2 motionUnchanged=true sameFrame=true',
        'MUSIC_AUTO_SUPPRESS_OK: gates=settings,menu suppressed=idle reenabled=music playbackPreserved=true',
        'MUSIC_AUTO_REVERSAL_OK: realPolling=true suppressionReversed=true pauseDuringMotion=true finite=true finalOwner=idle',
        'MUSIC_AUTO_RECREATE_OK: inheritedPlaying=true oldPanelStopped=true noNewSample=true',
        'MUSIC_AUTO_RETIRE_OK: disable=idle sleep=idle permission=idle stoppedPlayback=idle controllerStop=idle wakePrompt=false',
        'MUSIC_LOOKUP_STATUS_OK: states=serviceUnavailable,noMatch,unavailable,identityMismatch polls=3 lookupCalls=1 fixedStatus=true noFalseNoMatch=true',
        'MUSIC_LOOKUP_RECOVERY_OK: source=timedOut freshSameTrack=true state=serviceUnavailable lookupCalls=1 cooldownPreserved=true',
    )
    lines = stdout.splitlines()
    singleton_prefixes = {line.split(':', 1)[0] for line in fixed} | {
        'MUSIC_DISABLED_OK', 'MUSIC_CONSENT_OK', 'MUSIC_TIMELINE_OK', 'MUSIC_STALE_OK',
        'MUSIC_STALE_EMPTY_OK', 'MUSIC_PAINT_OK', 'MUSIC_OK', 'MUSIC_CLEANUP_OK',
        'MUSIC_AUTO_STALE_OK', 'MUSIC_AUTO_PRIORITY_OK', 'MUSIC_AUTO_PAINT_OK',
        'MUSIC_AUTO_PAUSE_NOTICE_OK', 'MUSIC_AUTO_REDUCED_OK', 'MUSIC_LOOKUP_COOLDOWN_OK', 'MUSIC_AUTO_CLOSE_PAINT_OK',
    }
    if any(sum(line.startswith(prefix + ':') for line in lines) != 1 for prefix in singleton_prefixes):
        return False
    if sum(line.startswith('MUSIC_RETIRE_OK:') for line in lines) != 3 or sum(line.startswith('MUSIC_STATE_OK:') for line in lines) != 2:
        return False
    if not all(lines.count(receipt) == 1 for receipt in fixed):
        return False
    if len(states) != 2 or set(states) != {'unknown', 'stopped'} or cleanup is None or int(cleanup) < 18:
        return False
    if not all((disabled, consent, timeline, stale, stale_empty, paint, aggregate, auto_stale, auto_priority, auto_paint, auto_pause, auto_reduced, cooldown, close_paint)):
        return False
    if not (3.10 <= float(disabled) <= 100 and 0.95 <= float(consent) <= 5
            and 0.30 <= float(timeline) <= 5 and 5 <= float(stale) <= 7
            and 5 <= float(stale_empty) <= 7):
        return False
    if int(close_paint) < 1:
        return False
    hold, playing_updates, lyric_updates = auto_priority
    if not (6 <= float(hold) <= 7.5 and int(playing_updates) >= 2 and int(lyric_updates) >= 2
            and 4 <= float(auto_pause) <= 5.5 and 2 <= float(auto_reduced) <= 3.5
            and 5 <= float(auto_stale) <= 7 and 3 <= float(cooldown) < 60):
        return False
    auto_width, auto_height, auto_scale = map(float, auto_paint)
    if not (1 <= auto_scale <= 3 and 300 <= auto_width / auto_scale <= 500
            and 70 <= auto_height / auto_scale <= 180):
        return False
    width, height, scale = map(float, paint)
    if not (width >= 300 and height >= 250 and 1 <= scale <= 3):
        return False
    checks, elapsed = aggregate
    if int(checks) < 100 or not 40 <= float(elapsed) <= 100:
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


def self_test() -> int:
    """Exercise parser rejection with invented receipts; never run or certify UI."""
    sample = '''MUSIC_DISABLED_OK: observed=3.151 reads=0 lookups=0 imports=0
MUSIC_CONSENT_OK: enablePrompt=true ordinaryPrompt=false pollGap=1.020 preOptInLookups=0
MUSIC_TIMELINE_OK: forwardSeek=true backwardSeek=true pausedCleared=0.360
MUSIC_STALE_OK: age=5.040 freshness=5 lineEmpty=true titleEmpty=true
MUSIC_STALE_EMPTY_OK: age=5.060 document=unavailable titleEmpty=true lineEmpty=true
MUSIC_PAINT_OK: view=CompactDetailView originalLine=true width=700 height=640 scale=2.000
MUSIC_STARTUP_OK: enabledBeforeStart=true readsBeforeStart=0 startupPrompt=false
MUSIC_ONLINE_OFF_OK: pendingCancelled=true lateRejected=true localPreserved=true musicEnabled=true
MUSIC_SYNTHETIC_OK: defaultReader=silent defaultLookup=reject defaultImporter=reject
MUSIC_SOURCE_OK: reason=timedOut lineEmpty=true titleEmpty=true
MUSIC_DENIED_OK: explicitRetryPrompt=true followupPrompt=false idle=3.15 noAutomaticRetry=true
MUSIC_PICKER_OK: staleAtoB=blocked staleAtoBtoA=blocked importerCalls=0
MUSIC_REVISION_OK: sequence=A-B-A lookups=3 cancelledOld=2 newestLineRetained=true
MUSIC_IMPORT_OK: reversedImports=2 cancelledOld=true localWinsOverLateOnline=true
MUSIC_IMPORT_COMPLETION_OK: sameLine=true oldDocumentRejected=true requestReturned=true exactDocument=true expectedCue=true
MUSIC_PRIORITY_OK: actualRefreshNotice=true lyricChanged=true noticeRetained=true passive=true
MUSIC_LAYOUT_OK: nativeExpanded=2 measuredQuit=2 clickRouting=2 nonactivating=true
MUSIC_LONG_LAYOUT_OK: view=DetailView quotaRows=8 longLyric=true footerUnchanged=true quitContained=true compactQuit=true
MUSIC_RESUME_OK: wakePrompt=false stopTerminal=true
MUSIC_RETIRE_OK: kind=disable readerCancelled=true lookupCancelled=true importCancelled=true visibleCleared=true lateRejected=true quiet=3.151
MUSIC_RETIRE_OK: kind=sleep readerCancelled=true lookupCancelled=true importCancelled=true visibleCleared=true lateRejected=true quiet=3.152
MUSIC_RETIRE_OK: kind=stop readerCancelled=true lookupCancelled=true importCancelled=true visibleCleared=true lateRejected=true quiet=3.153
MUSIC_STATE_OK: kind=unknown freshSample=true previousLine=true cleared=true
MUSIC_STATE_OK: kind=stopped freshSample=true previousLine=true cleared=true
MUSIC_AUTO_EMPTY_OK: noHover=true owner=music document=unavailable statusToken=LRC ownViewOCR=true passive=true
MUSIC_AUTO_STALE_OK: age=5.030 document=unavailable previouslyPainted=true owner=idle
MUSIC_AUTO_PRIORITY_OK: hold=6.020 expected=6 paintBeforeArm=true playingUpdates=5 lyricUpdates=5 dwellUnchanged=true motionUnchanged=true samePanel=true
MUSIC_AUTO_PAINT_OK: sequence=music-notice-music lyricBefore=true quota80to79=true lyricAfter=true appearances=aqua,darkAqua width=700 height=240 scale=2.000 localViewPixels=true scanout=false
MUSIC_AUTO_PAUSE_NOTICE_OK: hold=4.030 expected=4 dwellUnchanged=true lyricEmpty=true owner=idle
MUSIC_AUTO_HOVER_OK: playingExit=music pausedExit=idle pausedDetailsRetained=true pausedLyricAbsentOCR=true realPointerDwell=true
MUSIC_LABEL_OK: compactOCR=4 expandedOCR=2 legacyWordAbsent=true
MUSIC_AUTO_CLOSE_PAINT_OK: intermediateFrames=8 opacityDecreased=true opaqueBefore4pt=true idleOpacity=0 naturalPaint=true
MUSIC_AUTO_STEADY_OK: polls=2 lyricUpdates=2 motionUnchanged=true sameFrame=true
MUSIC_AUTO_SUPPRESS_OK: gates=settings,menu suppressed=idle reenabled=music playbackPreserved=true
MUSIC_AUTO_REVERSAL_OK: realPolling=true suppressionReversed=true pauseDuringMotion=true finite=true finalOwner=idle
MUSIC_AUTO_RECREATE_OK: inheritedPlaying=true oldPanelStopped=true noNewSample=true
MUSIC_AUTO_RETIRE_OK: disable=idle sleep=idle permission=idle stoppedPlayback=idle controllerStop=idle wakePrompt=false
MUSIC_AUTO_REDUCED_OK: hold=2.010 expected=2 sequence=music-notice-music-idle motionFrames=0 passive=true
MUSIC_LOOKUP_STATUS_OK: states=serviceUnavailable,noMatch,unavailable,identityMismatch polls=3 lookupCalls=1 fixedStatus=true noFalseNoMatch=true
MUSIC_LOOKUP_RECOVERY_OK: source=timedOut freshSameTrack=true state=serviceUnavailable lookupCalls=1 cooldownPreserved=true
MUSIC_LOOKUP_COOLDOWN_OK: observed=7.150 retryAfter=60 polls=3 lookupCalls=1 synthetic=true
MUSIC_CLEANUP_OK: controllers=18 pendingRequests=0 panelStopped=true
MUSIC_OK: checks=250 elapsed=78.000 synthetic=true localViewPixels=true scanout=false
SMOKE_OK: synthetic orderly shutdown
'''
    cases = 1
    if not receipts_valid(sample):
        raise AssertionError('well-formed invented receipt fixture was rejected')
    for line in sample.splitlines():
        for altered in (sample.replace(line + '\n', '', 1), sample + line + '\n',
                        sample + line.split(':', 1)[0] + ': malformed\n'):
            cases += 1
            if receipts_valid(altered):
                raise AssertionError('missing, duplicate or malformed receipt was accepted: ' + line)
    changes = (
        ('intermediateFrames=8', 'intermediateFrames=0'), ('idleOpacity=0', 'idleOpacity=1'),
        ('legacyWordAbsent=true', 'legacyWordAbsent=false'), ('opaqueBefore4pt=true', 'opaqueBefore4pt=false'),
        ('hold=6.020', 'hold=5.999'), ('hold=4.030', 'hold=3.999'), ('hold=2.010', 'hold=1.999'),
        ('age=5.030', 'age=4.999'), ('playingUpdates=5', 'playingUpdates=0'), ('lyricUpdates=5', 'lyricUpdates=0'),
        ('paintBeforeArm=true', 'paintBeforeArm=false'), ('dwellUnchanged=true', 'dwellUnchanged=false'),
        ('motionUnchanged=true', 'motionUnchanged=false'), ('samePanel=true', 'samePanel=false'),
        ('lyricAfter=true', 'lyricAfter=false'), ('quota80to79=true', 'quota80to79=false'),
        ('appearances=aqua,darkAqua', 'appearances=darkAqua'), ('pausedLyricAbsentOCR=true', 'pausedLyricAbsentOCR=false'),
        ('width=700 height=240', 'width=10 height=240'), ('scale=2.000', 'scale=0'),
        ('observed=7.150', 'observed=0.1'), ('observed=7.150', 'observed=60.1'),
        ('cooldownPreserved=true', 'cooldownPreserved=false'), ('lookupCalls=1', 'lookupCalls=2'),
        ('controllers=18', 'controllers=12'), ('elapsed=78.000', 'elapsed=100.001'),
        ('checks=250', 'checks=10'), ('scanout=false', 'scanout=true'),
    )
    for before, after in changes:
        cases += 1
        if receipts_valid(sample.replace(before, after)):
            raise AssertionError('invalid numeric/content evidence was accepted: ' + before)
    for suffix in ('MUSIC_FAILED: injected failure\n', 'SMOKE_FAILED: injected failure\n'):
        cases += 1
        if receipts_valid(sample + suffix):
            raise AssertionError('failed run was accepted')
    cases += 1
    reordered = sample.replace('SMOKE_OK: synthetic orderly shutdown\n', '')
    if receipts_valid('SMOKE_OK: synthetic orderly shutdown\n' + reordered):
        raise AssertionError('shutdown before aggregate was accepted')
    print(f'MUSIC_RECEIPT_SELF_TEST_OK: assertions={cases} nativeAppRun=false')
    return 0


def main() -> int:
    if sys.argv[1:] == ["--self-test"]:
        return self_test()
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
