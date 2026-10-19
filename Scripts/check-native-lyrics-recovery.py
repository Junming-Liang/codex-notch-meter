#!/usr/bin/env python3
"""Run the independent 90 s synthetic Music controller-recovery gate.

Every source is an injected, real awaited reader/importer/lookup. This does not
access Music, a user's files, the network, or screen pixels. The existing 150 s
native Music/paint gate remains separate and required by its own runner.
"""
from pathlib import Path
import re
import subprocess
import sys

RUN_TIMEOUT_SECONDS = 100
SHUTDOWN_RECEIPT = "SMOKE_OK: native island geometry, expansion and orderly shutdown completed; demo-only"
SOURCES = ("local", "online")
REASONS = ("timedOut", "busy", "changedDuringRead", "unknownTrack")
BOUNDARIES = (
    "pause", "stopped", "unknown", "cross-track-no-match", "clear-local",
    "revoke-online", "disable", "sleep", "authorization", "target-mismatch",
    "permission-denied", "terminal-stop",
)
PREFIXES = (
    "MUSIC_LYRICS_RECOVERY_CASE_OK:", "MUSIC_LYRICS_RECOVERY_BOUNDARY_OK:",
    "MUSIC_LYRICS_RECOVERY_LATE_OK:", "MUSIC_LYRICS_RECOVERY_FRESHNESS_OK:",
    "MUSIC_LYRICS_RECOVERY_CLEANUP_OK:",
    "MUSIC_LYRICS_RECOVERY_GATE_OK:", "MUSIC_LYRICS_RECOVERY_DONE:", "SMOKE_OK:",
)


def expected_receipts(freshness_age: str = "5.025") -> list[str]:
    receipts = []
    for source in SOURCES:
        for reason in REASONS:
            lookups, imports = (0, 1) if source == "local" else (1, 0)
            receipts.append(
                f"MUSIC_LYRICS_RECOVERY_CASE_OK: source={source} reason={reason} "
                "hidden=true sameDocument=true selected=true currentCue=true "
                f"ordinaryPoll=true lookups={lookups} imports={imports}"
            )
    for kind in BOUNDARIES:
        result = "fresh-resume" if kind == "pause" else "no-resurrection"
        receipts.append(
            f"MUSIC_LYRICS_RECOVERY_BOUNDARY_OK: kind={kind} "
            f"oldContentHidden=true result={result}"
        )
    for kind in ("import", "lookup"):
        receipts.append(
            f"MUSIC_LYRICS_RECOVERY_LATE_OK: kind={kind} cancelled=true "
            "returned=true oldRejected=true currentDocument=true calls=2"
        )
    receipts += [
        "MUSIC_LYRICS_RECOVERY_FRESHNESS_OK: chain=timedOut,busy sameDocument=true "
        f"heldReader=true age={freshness_age} freshness=5 hidden=true freshResume=true lookups=0 imports=1",
        "MUSIC_LYRICS_RECOVERY_CLEANUP_OK: controllers=23 pendingRequests=0 countsStable=true",
        "MUSIC_LYRICS_RECOVERY_GATE_OK: independent=true deadline=90 oldMusicDeadline=150 "
        "softCases=8 boundaryCases=12 lateCases=2 chainCases=1 controllerOnly=true",
    ]
    return receipts


def receipts_valid(stdout: str) -> bool:
    """Fail closed on missing, duplicate, malformed, contradictory or failed runs."""
    lines = stdout.splitlines()
    if any(re.search(r"(?:^|\W)(?:[A-Z_]+_FAILED|fatal error|Fatal error)(?:\W|$)", line)
           for line in lines):
        return False
    # Normal debug diagnostics may surround receipts, but a receipt-like line
    # must never hide an extra malformed/unknown success under another spelling.
    selected = [line for line in lines if line.startswith("MUSIC_LYRICS_RECOVERY_")
                or line.startswith("SMOKE_OK:")]
    expected = expected_receipts()
    if len(selected) != len(expected) + 2:
        return False
    freshness = re.fullmatch(
        r"MUSIC_LYRICS_RECOVERY_FRESHNESS_OK: chain=timedOut,busy sameDocument=true "
        r"heldReader=true age=([0-9]+(?:\.[0-9]+)?) freshness=5 hidden=true freshResume=true lookups=0 imports=1",
        selected[22],
    )
    if not freshness or not 5 <= float(freshness[1]) <= 7:
        return False
    if selected[:-2] != expected_receipts(freshness[1]):
        return False
    done = re.fullmatch(
        r"MUSIC_LYRICS_RECOVERY_DONE: checks=([0-9]+) elapsed=([0-9]+(?:\.[0-9]+)?) "
        r"synthetic=true realPolling=true controllerOnly=true scanout=false", selected[-2]
    )
    if not done or int(done[1]) < 100 or not 8 <= float(done[2]) <= 90:
        return False
    if selected[-1] != SHUTDOWN_RECEIPT:
        return False
    # Other native branches cannot supply this gate's aggregate evidence.
    if any(line.startswith(("MUSIC_OK:", "MUSIC_POINTER_GATE_OK:")) for line in lines):
        return False
    # Reject whitespace-prefixed forged receipts instead of silently ignoring.
    for line in lines:
        if line != line.lstrip() and line.lstrip().startswith(PREFIXES):
            return False
    return True


def self_test() -> int:
    root = Path(__file__).resolve().parent.parent
    app_source = (root / "Sources/CodexNotchMeter/AppController.swift").read_text()
    assert f'"{SHUTDOWN_RECEIPT}"' in app_source, "shutdown receipt diverged from actual AppController output"
    sample = "\n".join(expected_receipts() + [
        "MUSIC_LYRICS_RECOVERY_DONE: checks=240 elapsed=24.250 synthetic=true "
        "realPolling=true controllerOnly=true scanout=false",
        SHUTDOWN_RECEIPT, "",
    ])
    assert receipts_valid(sample), "invented valid parser fixture was rejected"
    cases = 2
    for line in sample.splitlines():
        variants = (
            sample.replace(line + "\n", "", 1),
            sample + line + "\n",
            sample.replace(line, line + " malformed", 1),
            sample.replace(line, " " + line, 1),
        )
        for changed in variants:
            cases += 1
            assert not receipts_valid(changed), f"bad receipt accepted: {line}"
    changes = (
        ("lookups=0 imports=1", "lookups=1 imports=1"),
        ("lookups=1 imports=0", "lookups=2 imports=0"),
        ("hidden=true", "hidden=false"),
        ("sameDocument=true", "sameDocument=false"),
        ("selected=true", "selected=false"),
        ("currentCue=true", "currentCue=false"),
        ("ordinaryPoll=true", "ordinaryPoll=false"),
        ("result=fresh-resume", "result=no-resurrection"),
        ("result=no-resurrection", "result=fresh-resume"),
        ("cancelled=true", "cancelled=false"),
        ("returned=true", "returned=false"),
        ("oldRejected=true", "oldRejected=false"),
        ("currentDocument=true", "currentDocument=false"),
        ("calls=2", "calls=3"),
        ("controllers=23", "controllers=22"),
        ("pendingRequests=0", "pendingRequests=1"),
        ("countsStable=true", "countsStable=false"),
        ("deadline=90", "deadline=150"),
        ("oldMusicDeadline=150", "oldMusicDeadline=240"),
        ("softCases=8", "softCases=7"),
        ("boundaryCases=12", "boundaryCases=11"),
        ("lateCases=2", "lateCases=1"),
        ("chainCases=1", "chainCases=0"),
        ("chain=timedOut,busy", "chain=timedOut"),
        ("heldReader=true", "heldReader=false"),
        ("age=5.025", "age=4.999"),
        ("age=5.025", "age=7.001"),
        ("freshResume=true", "freshResume=false"),
        ("checks=240", "checks=99"),
        ("elapsed=24.250", "elapsed=7.999"),
        ("elapsed=24.250", "elapsed=90.001"),
        ("elapsed=24.250", "elapsed=nan"),
        ("realPolling=true", "realPolling=false"),
        ("scanout=false", "scanout=true"),
        (SHUTDOWN_RECEIPT, "SMOKE_OK: synthetic orderly shutdown"),
    )
    for before, after in changes:
        cases += 1
        assert before in sample
        assert not receipts_valid(sample.replace(before, after, 1)), before
    for suffix in (
        "MUSIC_LYRICS_RECOVERY_FAILED: injected failure\n",
        "MUSIC_FAILED: injected failure\n", "SMOKE_FAILED: injected failure\n",
        "MUSIC_LYRICS_RECOVERY_EXTRA_OK: unexpected\n",
        "MUSIC_OK: unrelated native aggregate\n", "Fatal error: fixture\n",
    ):
        cases += 1
        assert not receipts_valid(sample + suffix), suffix
    reordered = sample.splitlines()
    reordered[0], reordered[1] = reordered[1], reordered[0]
    cases += 1
    assert not receipts_valid("\n".join(reordered)), "reordered evidence accepted"
    cases += 1
    assert receipts_valid("ordinary diagnostic\n" + sample), "ordinary debug output rejected"
    print(f"MUSIC_LYRICS_RECOVERY_RECEIPT_SELF_TEST_OK: assertions={cases} nativeAppRun=false")
    return 0


def main() -> int:
    if sys.argv[1:] == ["--self-test"]:
        return self_test()
    if sys.argv[1:]:
        print("Usage: check-native-lyrics-recovery.py [--self-test]", file=sys.stderr)
        return 2
    root = Path(__file__).resolve().parent.parent
    executable = root / "dist/Codex Notch Meter.app/Contents/MacOS/CodexNotchMeter"
    try:
        process = subprocess.Popen(
            [str(executable), "--music-test", "--lyrics-recovery-test"], cwd=root,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
        )
    except OSError as error:
        print(f"Native lyrics recovery could not start the built application: {error}", file=sys.stderr)
        return 1
    timed_out = False
    try:
        stdout, stderr = process.communicate(timeout=RUN_TIMEOUT_SECONDS)
    except subprocess.TimeoutExpired:
        timed_out = True
        process.kill()  # The exact child this runner owns, never a process group.
        try:
            stdout, stderr = process.communicate(timeout=5)
        except subprocess.TimeoutExpired:
            print("Native lyrics recovery owned-child cleanup exceeded 5 seconds.", file=sys.stderr)
            return 1
    print(stdout, end="")
    print(stderr, end="", file=sys.stderr)
    if timed_out:
        print(f"Native lyrics recovery exceeded its {RUN_TIMEOUT_SECONDS} s runner deadline.", file=sys.stderr)
        return 1
    if process.returncode != 0 or not receipts_valid(stdout):
        print("Native lyrics recovery or orderly-shutdown contract failed.", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
