#!/usr/bin/env python3
"""Independent native failed-lyric-gesture recovery gate and fixed110 red/green.

No fetch, remote, CI or publication. --prepare-only works on Linux and overlays
only the identical MusicRendering.swift fixture on fixed110. Native execution
requires macOS. Own event identities are observed by an unchanged local monitor;
production accepted point/time receipts separately establish real IslandPanel
local-monitor ingress. This is not evidence of global-input delivery or scanout.
"""
from __future__ import annotations

import argparse
import copy
import importlib.util
import json
import math
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parent.parent
BASELINE_COMMIT = "d48181bd285620108b01303a7072d1b0743a3cb3"
HARNESS_PATH = "Sources/CodexNotchMeter/MusicRendering.swift"
FLAGS = ("--music-test", "--gesture-recovery-test")
RUN_TIMEOUT_SECONDS = 110
REASON = "rejected no-match crossing recovers stationary same-region hover without a full-envelope exit"
SHUTDOWN = "SMOKE_OK: native island geometry, expansion and orderly shutdown completed; demo-only"
FAILURE = "MUSIC_GESTURE_RECOVERY_FAILED: native synthetic gesture recovery contract failed"
SETUP = ("MUSIC_GESTURE_RECOVERY_SETUP_OK: kind=no-match actualLookup=true freshPlaying=true "
         "usable=false selected=false nativeCrossing=true sameEnvelope=true")
CLEANUP = ("MUSIC_GESTURE_RECOVERY_CLEANUP_OK: controllers=9 pendingRequests=0 "
           "countsStable=true panelsStopped=true monitorsRemoved=true")
GATE = ("MUSIC_GESTURE_RECOVERY_GATE_OK: independent=true deadline=100 oldMusicDeadline=150 "
        "oldPointerDeadline=45 cases=9 nativeEventQueue=true controllerInjection=false scanout=false")
EVENT_PREFIX = "MUSIC_GESTURE_RECOVERY_EVENTS_JSON: "
CASES = ("no-match", "loading", "before-first-cue", "gap", "lost-opening", "late-availability",
         "pause-opening", "successful-reverse", "quota-interruption")
SELECTED = {name: name in ("lost-opening", "pause-opening", "quota-interruption") for name in CASES}
DETAILS = {name: name not in ("successful-reverse", "quota-interruption") for name in CASES}
BAD = re.compile(r"valid=false|music failed:|\b[A-Z_]+_FAILED\b|fatal error|\berror:|deadline exceeded|cancelled or fixture|traceback", re.I)


def load_helper(name, filename):
    spec = importlib.util.spec_from_file_location(name, ROOT / "Scripts" / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


common = load_helper("gesture_recovery_common", "check-native-baseline.py")
# Reuse the already adversarially-tested bounded child/log and source-binding
# helpers; its diagnostic log envelopes retain their historical LYRICS_ prefix.
processes = load_helper("gesture_recovery_processes", "check-native-lyrics-redgreen.py")
require, ValidationError = common.require, common.ValidationError


def finite(value):
    return type(value) in (int, float) and math.isfinite(value)


def point(value):
    return type(value) is list and len(value) == 2 and all(finite(v) for v in value)


def swift_rounded(value):
    """Match CGFloat.rounded(): nearest, with exact half ties away from zero."""
    fraction, integral = math.modf(value)
    if abs(fraction) >= 0.5:
        integral += math.copysign(1, fraction)
    return int(integral)


def events_valid(data, name, stage, *, red=False):
    if type(data) is not dict or set(data) != {"kind", "stage", "events", "overflow", "crossingStart", "crossingEnd",
                                               "corridor", "sameEnvelope", "pollAfterCrossing", "details", "selected", "owner"}:
        return False
    details = False if red else DETAILS[name]
    owner = "idle" if red or name == "successful-reverse" else ("details" if details else "music")
    if (data["kind"] != name or data["stage"] != stage or data["overflow"] is not False
            or data["sameEnvelope"] is not True or data["pollAfterCrossing"] is not False
            or data["details"] is not details or data["selected"] is not SELECTED[name] or data["owner"] != owner):
        return False
    rows, start, end, corridor = (data[k] for k in ("events", "crossingStart", "crossingEnd", "corridor"))
    if (type(rows) is not list or not 20 <= len(rows) <= 256 or type(start) is not int or type(end) is not int
            or not 0 < start < end < len(rows) or end - start != 6 or type(corridor) is not list
            or len(corridor) != 4 or not all(finite(v) for v in corridor) or corridor[2] < 48 or corridor[3] < 4):
        return False
    keys = {"number", "type", "window", "requested", "constructed", "delivered", "local", "screen",
            "observedLocal", "observedScreen", "accepted", "acceptedTimestamp", "acceptedScreen", "acceptedOwner", "acceptedTarget"}
    previous_requested = previous_constructed = -math.inf
    window = None
    for index, row in enumerate(rows):
        if type(row) is not dict or set(row) != keys:
            return False
        if (type(row["number"]) is not int or row["number"] != 24_000 + index
                or type(row["type"]) is not int or row["type"] != 5
                or type(row["window"]) is not int or row["window"] <= 0 or row["accepted"] is not True):
            return False
        if window is None:
            window = row["window"]
        if row["window"] != window:
            return False
        if not all(finite(row[key]) for key in ("requested", "constructed", "delivered", "acceptedTimestamp", "acceptedTarget")):
            return False
        if (not previous_requested < row["requested"] or not previous_constructed < row["constructed"]
                or abs(row["requested"] - row["constructed"]) >= 1e-9
                or abs(row["requested"] - row["delivered"]) >= 1e-9
                or abs(row["constructed"] - row["delivered"]) >= 1e-9
                or row["acceptedTimestamp"] != row["delivered"]):
            return False
        previous_requested, previous_constructed = row["requested"], row["constructed"]
        if not all(point(row[key]) for key in ("local", "screen", "observedLocal", "observedScreen", "acceptedScreen")):
            return False
        if (row["local"] != row["observedLocal"] or row["screen"] != row["observedScreen"]
                or row["screen"] != row["acceptedScreen"]
                or row["local"][0] - row["screen"][0] != 900 or row["local"][1] - row["screen"][1] != 700):
            return False
        if row["acceptedOwner"] not in ("idle", "music", "quotaNotice", "details") or not 0 <= row["acceptedTarget"] <= 1:
            return False
        if (index < end or not details) and (row["acceptedOwner"] == "details" or row["acceptedTarget"] == 1):
            return False
    # Six actual continuous moving samples, followed by at least 650 ms in the
    # same corridor; the first-trap red cannot be satisfied by a random failure.
    for row, fraction in zip(rows[start:end], (-0.04, 0.02, 0.25, 0.52, 0.75, 0.98)):
        if (abs(row["screen"][0] - (corridor[0] + corridor[2] * fraction)) > 0.501
                or abs(row["screen"][1] - (corridor[1] + corridor[3] / 2)) > 0.501):
            return False
    if any(not 0 < b["constructed"] - a["constructed"] <= 0.25 for a, b in zip(rows[start:], rows[start + 1:])):
        return False
    if rows[-1]["constructed"] - rows[end]["constructed"] < 0.65:
        return False
    if name == "no-match":
        # Run62 used a 35-point corridor: Swift rounds y=750.5 to 751.
        # Python round() would silently substitute its ties-to-even rule (750).
        center = [swift_rounded(corridor[0] + corridor[2] / 2), swift_rounded(corridor[1] + corridor[3] / 2)]
        if any(row["screen"] != center for row in rows[end:]):
            return False
    if details and rows[-1]["acceptedOwner"] != "details":
        return False
    return True


def parse_evidence(line, name, stage, *, red=False):
    if not line.startswith(EVENT_PREFIX) or len(line.encode()) > 160_100:
        return None
    try:
        data = common.strict_json(line[len(EVENT_PREFIX):])
        return data if events_valid(data, name, stage, red=red) else None
    except (ValidationError, ValueError, TypeError, OverflowError, KeyError):
        return None


def relevant(stdout):
    lines = stdout.splitlines()
    for line in lines:
        if line != line.lstrip() and line.lstrip().startswith(("MUSIC_", "SMOKE_")):
            return None
        if line.startswith(("MUSIC_OK:", "MUSIC_POINTER_GATE_OK:", "MUSIC_LYRICS_RECOVERY_")):
            return None
    return [line for line in lines if line.startswith(("MUSIC_GESTURE_RECOVERY_", "SMOKE_OK:", "SMOKE_FAILED:"))]


def receipts_valid(stdout, stderr=""):
    if BAD.search(stdout + "\n" + stderr):
        return False
    lines = relevant(stdout)
    if lines is None or len(lines) != 24 or lines[0] != SETUP:
        return False
    first_trap = parse_evidence(lines[1], "no-match", "first-trap")
    if first_trap is None:
        return False
    index = 2
    for name in CASES:
        data = parse_evidence(lines[index], name, "complete")
        if data is None:
            return False
        if name == "no-match" and (data["events"][:len(first_trap["events"])] != first_trap["events"]
                or any(data[key] != first_trap[key] for key in ("crossingStart", "crossingEnd", "corridor"))):
            return False
        receipt = (f"MUSIC_GESTURE_RECOVERY_CASE_OK: kind={name} nativeQueue=true sameEnvelope=true pollingExit=false "
                   f"details={str(DETAILS[name]).lower()} selected={str(SELECTED[name]).lower()} events={len(data['events'])}")
        if lines[index + 1] != receipt:
            return False
        index += 2
    if lines[index:index + 2] != [CLEANUP, GATE] or lines[-1] != SHUTDOWN:
        return False
    done = re.fullmatch(r"MUSIC_GESTURE_RECOVERY_DONE: checks=([0-9]+) elapsed=([0-9]+(?:\.[0-9]+)?) synthetic=true nativeQueue=true scanout=false", lines[-2])
    return bool(done and int(done[1]) >= 200 and 10 <= float(done[2]) <= 100)


def red_valid(code, stdout, stderr):
    if code != 0:
        return False
    lines = relevant(stdout)
    if (lines is None or len(lines) != 4 or lines[0] != SETUP
            or parse_evidence(lines[1], "no-match", "first-trap", red=True) is None
            or lines[2:] != [FAILURE, "SMOKE_FAILED: native island checks failed"]):
        return False
    assertion = "SMOKE_STAGE: music " + REASON + " valid=false"
    failure = "SMOKE_STAGE: music failed: " + REASON
    errors = stderr.splitlines()
    if errors.count(assertion) != 1 or errors.count(failure) != 1 or errors.index(assertion) >= errors.index(failure):
        return False
    setup_labels = (
        "complete actual no-match lookup", "gesture recovery source has its exact requested eligibility",
        "gesture recovery starts at a settled native closed shell with a visible stationary target",
        "unusable queued crossing is rejected without selecting lyric mode",
        "first trap has complete queued native evidence with no live-pointer exit",
    )
    for label in setup_labels:
        check = "SMOKE_STAGE: music " + label + " valid=true"
        if errors.count(check) != 1 or errors.index(check) >= errors.index(assertion):
            return False
    sources = [line for line in stdout.splitlines() if line.startswith("MUSIC_FAILURE_SOURCE:")]
    if len(sources) != 1 or not sources[0].startswith("MUSIC_FAILURE_SOURCE: fixture=0 enabled=true playing=false "):
        return False
    for line in stdout.splitlines() + errors:
        if BAD.search(line) and line not in (assertion, failure, FAILURE, "SMOKE_FAILED: native island checks failed"):
            return False
    return True


def prepare(output):
    require(common.git(ROOT, "rev-parse", "--verify", BASELINE_COMMIT + "^{commit}").decode().strip() == BASELINE_COMMIT,
            "Fixed110 is unavailable; no fetch is performed")
    archive = common.git(ROOT, "archive", "--format=tar", BASELINE_COMMIT)
    harness = common.bounded_read(ROOT / HARNESS_PATH)
    require(REASON.encode() in harness and b"--gesture-recovery-test" in harness, "Missing exact first-trap fixture")
    stage = output / "baseline-source"
    stage.mkdir()
    common.extract_archive(archive, stage)
    before = common.source_manifest(stage)
    (stage / HARNESS_PATH).write_bytes(harness)
    after = common.source_manifest(stage)
    changed = sorted(path for path in before.keys() | after.keys() if before.get(path) != after.get(path))
    require(changed == [HARNESS_PATH], "Fixed110 overlay must change only MusicRendering.swift")
    result = {"schema": 1, "baselineCommit": BASELINE_COMMIT, "archiveSHA256": common.digest(archive),
              "harnessSHA256": common.digest(harness), "changedFiles": changed, "before": before, "after": after,
              "productionSourcesUnchanged": True, "flags": list(FLAGS), "expectedFailure": REASON, "nativeAppRun": False}
    processes.write_json(output / "preparation.json", result)
    return stage, result


def native_red_green(output, stage, preparation):
    require(sys.platform == "darwin", "Native red/green requires macOS")
    candidate, binding = processes.candidate_binding(ROOT)
    processes.checked_command(["swift", "build", "-c", "release", "--product", "CodexNotchMeter"], stage, output / "baseline-build", 600)
    bin_path = processes.checked_command(["swift", "build", "-c", "release", "--show-bin-path"], stage, output / "baseline-bin-path", 60).strip()
    baseline = Path(bin_path) / "CodexNotchMeter"
    require(baseline.resolve().is_relative_to((stage / ".build").resolve()) and not (stage / ".build").is_symlink()
            and os.access(baseline, os.X_OK), "Fixed110 binary escaped its isolated build")
    require(common.source_manifest(stage) == preparation["after"], "Fixed110 production changed during build")
    baseline_sha = common.digest(common.bounded_read(baseline))
    red = processes.run_process([baseline, *FLAGS], stage, output / "baseline-red", RUN_TIMEOUT_SECONDS)
    require(red_valid(*red), "Fixed110 did not fail at the precise first semantic trap; crash/timeout/build failure never counts as red")
    print("GESTURE_RECOVERY_RED_OK: exactFirstTrap=true nativeQueue=true normalExit=true", flush=True)
    green = processes.run_process([candidate, *FLAGS], ROOT, output / "candidate-green", RUN_TIMEOUT_SECONDS)
    require(green[0] == 0 and receipts_valid(green[1], green[2]), "Candidate failed the complete strict native receipt contract")
    require(common.source_manifest(stage) == preparation["after"], "Fixed110 production changed during runs")
    require(processes.candidate_binding(ROOT)[1] == binding, "Candidate source/binary changed during runs")
    require(common.digest(common.bounded_read(baseline)) == baseline_sha, "Fixed110 binary changed during runs")
    require(common.digest(common.bounded_read(ROOT / HARNESS_PATH)) == preparation["harnessSHA256"], "Harness changed during runs")
    processes.write_json(output / "result.json", {"schema": 1, "baselineCommit": BASELINE_COMMIT,
        "candidate": binding, "harnessSHA256": preparation["harnessSHA256"], "baselineExecutableSHA256": baseline_sha,
        "expectedRed": True, "strictGreen": True, "nativeAppRun": True, "nativeIngress": True, "scanout": False,
        "productionSourcesUnchanged": True, "flags": list(FLAGS), "expectedFailure": REASON,
        "logs": {p.name: common.digest(common.bounded_read(p)) for p in sorted(output.glob("*.log"))}})
    print("GESTURE_RECOVERY_REDGREEN_OK: sameHarnessSHA256=" + preparation["harnessSHA256"]
          + " expectedRed=true strictGreen=true nativeQueue=true productionSourcesUnchanged=true scanout=false")


def sample_evidence(name, stage="complete", red=False, corridor=None):
    details = False if red else DETAILS[name]
    corridor = [100, 400, 288, 32] if corridor is None else corridor
    center = [swift_rounded(corridor[0] + corridor[2] / 2), swift_rounded(corridor[1] + corridor[3] / 2)]
    points = [[center[0] + 260, center[1]]] * 2 + [
        [swift_rounded(corridor[0] + corridor[2] * f), center[1]]
        for f in (-0.04, 0.02, 0.25, 0.52, 0.75, 0.98)
    ] + [center] * 26
    rows = []
    for index, position in enumerate(points):
        timestamp = 1000 + index * 0.03
        local = [position[0] + 900, position[1] + 700]
        owner = "details" if details and index > 13 else ("music" if name in ("lost-opening", "pause-opening", "quota-interruption") else "idle")
        rows.append(dict(number=24000 + index, type=5, window=100, requested=timestamp, constructed=timestamp, delivered=timestamp,
                         local=local, screen=position, observedLocal=local, observedScreen=position,
                         accepted=True, acceptedTimestamp=timestamp, acceptedScreen=position, acceptedOwner=owner,
                         acceptedTarget=1 if owner == "details" else 0.3 if owner == "music" else 0))
    return dict(kind=name, stage=stage, events=rows, overflow=False, crossingStart=2, crossingEnd=8,
                corridor=corridor, sameEnvelope=True, pollAfterCrossing=False, details=details, selected=SELECTED[name],
                owner="idle" if red or name == "successful-reverse" else "details" if details else "music")


def encode(data):
    return EVENT_PREFIX + json.dumps(data, sort_keys=True, separators=(",", ":"))


def sample_green():
    lines = [SETUP, encode(sample_evidence("no-match", "first-trap"))]
    for name in CASES:
        evidence = sample_evidence(name)
        lines += [encode(evidence), f"MUSIC_GESTURE_RECOVERY_CASE_OK: kind={name} nativeQueue=true sameEnvelope=true pollingExit=false "
                  f"details={str(DETAILS[name]).lower()} selected={str(SELECTED[name]).lower()} events={len(evidence['events'])}"]
    return "\n".join(lines + [CLEANUP, GATE, "MUSIC_GESTURE_RECOVERY_DONE: checks=1200 elapsed=24.000 synthetic=true nativeQueue=true scanout=false", SHUTDOWN])


def sample_red():
    labels = ("complete actual no-match lookup", "gesture recovery source has its exact requested eligibility",
              "gesture recovery starts at a settled native closed shell with a visible stationary target",
              "unusable queued crossing is rejected without selecting lyric mode",
              "first trap has complete queued native evidence with no live-pointer exit")
    out = "\n".join([SETUP, encode(sample_evidence("no-match", "first-trap", red=True)),
                      "MUSIC_FAILURE_SOURCE: fixture=0 enabled=true playing=false synthetic", FAILURE, "SMOKE_FAILED: native island checks failed"])
    err = "\n".join(["SMOKE_STAGE: music " + label + " valid=true" for label in labels]
                    + ["SMOKE_STAGE: music " + REASON + " valid=false", "SMOKE_STAGE: music failed: " + REASON])
    return out, err


class SelfTests(unittest.TestCase):
    def test_green_receipts_fail_closed(self):
        sample = sample_green()
        self.assertTrue(receipts_valid(sample))
        for line in sample.splitlines():
            for changed in (sample.replace(line, "", 1), sample + "\n" + line,
                            sample.replace(line, " " + line, 1), sample.replace(line, line + " malformed", 1)):
                self.assertFalse(receipts_valid(changed))
        for before, after in (("events=34", "events=33"), ("checks=1200", "checks=199"),
                              ("elapsed=24.000", "elapsed=100.001"), ("elapsed=24.000", "elapsed=nan"),
                              ("deadline=100", "deadline=150"), ("nativeQueue=true", "nativeQueue=false")):
            self.assertFalse(receipts_valid(sample.replace(before, after, 1)))
        for suffix in ("MUSIC_FAILED: fail", "MUSIC_OK: other branch", "MUSIC_POINTER_GATE_OK: unrelated",
                       "MUSIC_GESTURE_RECOVERY_EXTRA_OK: unknown", "Fatal error: failure"):
            self.assertFalse(receipts_valid(sample + "\n" + suffix))
        self.assertFalse(receipts_valid(sample, "SMOKE_STAGE: music unrelated valid=false"))
        self.assertTrue(receipts_valid("ordinary diagnostic\n" + sample))

    def test_native_event_chain_and_timestamp_mutations(self):
        original = sample_evidence("no-match")
        self.assertTrue(events_valid(original, "no-match", "complete"))
        changes = [("number", 24000), ("type", 1), ("window", 0), ("accepted", False),
                   ("constructed", 999), ("delivered", 999), ("acceptedTimestamp", 999), ("requested", float("nan")),
                   ("screen", [0, 0]), ("local", [0, 0]), ("observedScreen", [0, 0]), ("observedLocal", [0, 0]),
                   ("acceptedScreen", [0, 0]), ("acceptedOwner", "details"), ("acceptedTarget", 1), ("type", True)]
        for key, value in changes:
            data = copy.deepcopy(original); data["events"][3][key] = value
            self.assertFalse(events_valid(data, "no-match", "complete"), key)
        for key, value in (("overflow", True), ("pollAfterCrossing", True), ("sameEnvelope", False),
                           ("selected", True), ("crossingStart", False), ("crossingEnd", 9), ("stage", "first-trap")):
            data = copy.deepcopy(original); data[key] = value
            self.assertFalse(events_valid(data, "no-match", "complete"), key)
        self.assertIsNone(parse_evidence(encode(original).replace('"overflow":false', '"overflow":false,"overflow":false'), "no-match", "complete"))
        self.assertIsNone(parse_evidence(EVENT_PREFIX + "NaN", "no-match", "complete"))
        self.assertFalse(events_valid({**original, "extra": True}, "no-match", "complete"))

    def test_swift_half_ties_preserve_exact_native_stationary_coordinates(self):
        for value, expected in ((750.5, 751), (-750.5, -751), (512.5, 513), (-512.5, -513),
                                (750.49, 750), (-750.49, -750), (0.0, 0), (-0.0, 0),
                                (math.nextafter(0.5, 0), 0), (math.nextafter(-0.5, 0), 0)):
            self.assertEqual(swift_rounded(value), expected)
        # Include Run62's actual screen corridor and a negative-origin mirror.
        for corridor in ([368, 733, 288, 35], [-656, -768, 288, 35],
                         [368.5, 733, 288, 35], [-656.5, -768, 288, 35]):
            data = sample_evidence("no-match", "first-trap", red=True, corridor=corridor)
            self.assertTrue(events_valid(data, "no-match", "first-trap", red=True))
            midpoint = [corridor[0] + corridor[2] / 2, corridor[1] + corridor[3] / 2]
            wrong = copy.deepcopy(data)
            even_center = [round(value) for value in midpoint]
            for row in wrong["events"][wrong["crossingEnd"]:]:
                row["screen"] = row["observedScreen"] = row["acceptedScreen"] = even_center
                row["local"] = row["observedLocal"] = [even_center[0] + 900, even_center[1] + 700]
            self.assertFalse(events_valid(wrong, "no-match", "first-trap", red=True))
            out, err = sample_red()
            original = encode(sample_evidence("no-match", "first-trap", red=True))
            self.assertTrue(red_valid(0, out.replace(original, encode(data)), err))
            self.assertFalse(red_valid(0, out.replace(original, encode(wrong)), err))

    def test_exact_red_not_crash_timeout_or_other_failure(self):
        out, err = sample_red()
        self.assertTrue(red_valid(0, out, err))
        for code, stdout, stderr in ((1, out, err), (-9, out, err), (0, out, ""),
                (0, out, err.replace(REASON, "wrong")), (0, out, err + "\nerror: failed build"),
                (0, out, err + "\nSMOKE_STAGE: music bounded 100-second deadline exceeded"),
                (0, out, err + "\nSMOKE_STAGE: music unrelated valid=false"),
                (0, out + "\n" + FAILURE, err), (0, out.replace(SETUP, ""), err),
                (0, out, err.replace("first trap has complete queued native evidence with no live-pointer exit", "missing"))):
            self.assertFalse(red_valid(code, stdout, stderr))
        self.assertFalse(red_valid(0, out.replace('"details":false', '"details":true'), err))

    def test_harness_only_fixed110_overlay(self):
        with tempfile.TemporaryDirectory() as temp:
            stage, receipt = prepare(Path(temp))
            self.assertEqual(receipt["baselineCommit"], BASELINE_COMMIT)
            self.assertEqual(receipt["changedFiles"], [HARNESS_PATH])
            self.assertEqual(set(receipt["before"]), set(receipt["after"]))
            for path in receipt["before"]:
                if path != HARNESS_PATH:
                    self.assertEqual(receipt["before"][path], receipt["after"][path])
            self.assertEqual(list(stage.rglob("*.pyc")), [])

    def test_independent_old_deadlines_and_shutdown_contract(self):
        source = (ROOT / HARNESS_PATH).read_text()
        self.assertIn('gestureRecoveryOnly ? 100 : (lyricsRecoveryOnly ? 90 : (pointerVerificationOnly ? 45 : 150))', source)
        self.assertIn('[pointerVerificationOnly, lyricsRecoveryOnly, gestureRecoveryOnly].filter({ $0 }).count <= 1', source)
        fixture = source[source.index('private func runGestureRecoveryVerification'):source.index('private struct LyricsRecoveryFixture')]
        self.assertNotIn('smokePointer(', fixture)
        self.assertIn('NSApp.postEvent(event, atStart: false)', fixture)
        self.assertIn('NSEvent.removeMonitor(monitor)', fixture)
        self.assertIn('return event', fixture)
        self.assertIn(SHUTDOWN, (ROOT / 'Sources/CodexNotchMeter/AppController.swift').read_text())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--self-test", action="store_true")
    mode.add_argument("--prepare-only", action="store_true")
    mode.add_argument("--red-green", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        result = unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(SelfTests))
        if result.wasSuccessful():
            print("GESTURE_RECOVERY_SELF_TEST_OK: nativeAppRun=false")
        return 0 if result.wasSuccessful() else 1
    try:
        require(args.prepare_only or sys.platform == "darwin", "Native execution requires macOS; --self-test and --prepare-only are offline checks only")
        dist = ROOT / "dist"
        require(not dist.is_symlink(), "Refusing symlinked dist")
        dist.mkdir(exist_ok=True)
        output = Path(tempfile.mkdtemp(prefix="gesture-recovery-", dir=dist))
        print("GESTURE_RECOVERY_EVIDENCE: " + str(output), flush=True)
        if args.prepare_only or args.red_green:
            stage, preparation = prepare(output)
            print("GESTURE_RECOVERY_PREPARED: baseline=" + BASELINE_COMMIT + " harnessSHA256=" + preparation["harnessSHA256"]
                  + " changedFiles=MusicRendering.swift productionSourcesUnchanged=true nativeAppRun=false", flush=True)
            if args.red_green:
                native_red_green(output, stage, preparation)
        else:
            candidate, binding = processes.candidate_binding(ROOT)
            result = processes.run_process([candidate, *FLAGS], ROOT, output / "candidate-green", RUN_TIMEOUT_SECONDS)
            require(result[0] == 0 and receipts_valid(result[1], result[2]), "Native gesture recovery or orderly-shutdown contract failed")
            require(processes.candidate_binding(ROOT)[1] == binding, "Candidate source or binary changed during run")
        return 0
    except (ValidationError, OSError, subprocess.SubprocessError, UnicodeError, ValueError) as error:
        print("GESTURE_RECOVERY_FAILED: " + str(error), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
