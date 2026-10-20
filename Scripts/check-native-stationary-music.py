#!/usr/bin/env python3
"""Bounded own-window stationary-hover gate; never claims global input/scanout."""
import copy
import json
import math
import importlib.util
import os
import tempfile
from pathlib import Path
import subprocess
import sys

sys.dont_write_bytecode = True
PREFIX = "MUSIC_STATIONARY_HOVER_JSON: "
GATE = "MUSIC_STATIONARY_HOVER_OK: nativeLocal=true naturalPoll=true synthetic=true"
SHUTDOWN = "SMOKE_OK: native island geometry, expansion and orderly shutdown completed; demo-only"


def need(value, label):
    if not value:
        raise ValueError(label)


def number(value):
    return type(value) in (int, float) and math.isfinite(value)


def vector(value, count):
    return type(value) is list and len(value) == count and all(number(v) for v in value)


def strict_object(pairs):
    result = {}
    for key, value in pairs:
        need(key not in result, "duplicate JSON key")
        result[key] = value
    return result


def validate_edge(case, name, red=False):
    need(case["name"] == name, "edge order")
    for key in (("freshPlaying", "noLyricsSelected", "unavailableLyrics", "nativeSourceReady") if red else ("naturalPaint", "noLyricsSelected", "leaveCollapsed")):
        need(case[key] is True, key)
    center, corridor = case["center"], case["corridor"]
    need(vector(center, 2) and vector(corridor, 4), "geometry")
    need(corridor[2] >= 48 and corridor[3] >= 4, "corridor dimensions")
    expected_x = corridor[0] + 20 if name == "left" else corridor[0] + corridor[2] - 20
    need(center == [expected_x, corridor[1] + 2], "actual edge center")
    need(type(case["sourceWindowNumber"]) is int and case["sourceWindowNumber"] > 0, "own source window")
    need(type(case["playbackReads"]) is int and case["playbackReads"] >= 4, "fresh playback reads")
    events, receipts = case["events"], case["receipts"]
    need(type(events) is list and len(events) == 16, "sixteen delivered events")
    need(type(receipts) is list and 31 <= len(receipts) <= 256, "bounded mixed receipt count")
    event_receipts = [r for r in receipts if r["kind"] == "event"]
    need(len(event_receipts) == 16, "no extra or missing event")
    for i, event in enumerate(events):
        need(event["eventNumber"] == 31001 + i, "event identities")
        need(number(event["sourceAt"]) and number(event["deliveredAt"])
             and 0 <= event["deliveredAt"] - event["sourceAt"] < 1, "actual delivery deadline")
        expected = [center[0] + (-1 if i % 2 == 0 else 1), center[1]]
        need(event["point"] == expected and vector(event["localPoint"], 2), "micro movement coordinates")
        receipt = event_receipts[i]
        need(receipt["timestamp"] == event["sourceAt"] and receipt["point"] == event["point"], "production event receipt")
        if i:
            previous = events[i - 1]
            gap = event["deliveredAt"] - previous["deliveredAt"]
            need(0.30 <= gap <= 0.45 and abs(gap - event["gap"]) < 1e-8, "measured event cadence")
            need(event["sourceAt"] > previous["sourceAt"], "source timestamp order")
            polls = event["polls"]
            need(type(polls) is list and 1 <= len(polls) <= 8, "actual intervening polls")
            actual = [r for r in receipts if r["kind"] == "poll"
                      and previous["deliveredAt"] < r["timestamp"] < event["deliveredAt"]]
            need(len(actual) == len(polls), "complete poll accounting")
            for poll, real in zip(polls, actual):
                need(number(poll["timestamp"]) and poll["timestamp"] - previous["deliveredAt"] > 0.25,
                     "actual quiet guard")
                need(poll == {key: real[key] for key in ("timestamp", "point", "owner", "target")}, "production poll receipt")
    for r in receipts:
        need(r["kind"] in ("event", "poll") and number(r["timestamp"]), "native ingress only")
        need(vector(r["point"], 2) and abs(r["point"][0] - center[0]) <= 1
             and r["point"][1] == center[1], "no corridor crossing or exit")
        need(r["owner"] in ("idle", "details") and number(r["target"]) and r["target"] in (0, 1), "no lyrics ownership")
        if "hover" in r:
            h = r["hover"]
            need(number(h["timestamp"]) and h["timestamp"] >= r["timestamp"]
                 and h["inside"] is True and type(h["expandedBefore"]) is bool
                 and type(h["expandedAfter"]) is bool, "native hover clock")
    if red:
        need(events[-1]["deliveredAt"] - events[0]["deliveredAt"] >= 4.5, "complete red observation window")
        need(all(r["owner"] == "idle" and r["target"] == 0 for r in receipts), "red remains idle")
        need(not any(r.get("hover", {}).get("expandedAfter") is True for r in receipts), "red never recovered")
        need(case["inputState"]["needsCorridorExit"] is False
             and case["inputState"]["gestureSuppressed"] is False, "fresh edge rather than failed crossing")
        return
    recovered = [r["hover"] for r in receipts if r.get("hover", {}).get("expandedAfter") is True]
    need(bool(recovered), "ordinary edge hover starved")
    recovered_at = recovered[0]["timestamp"]
    need(case["recoveryAt"] == recovered_at and number(case["recoverySeconds"])
         and abs(case["recoverySeconds"] - (recovered_at - events[0]["deliveredAt"])) < 1e-8
         and 0.12 <= case["recoverySeconds"] < 2, "bounded ordinary hover recovery")
    duration = events[-1]["deliveredAt"] - events[0]["deliveredAt"]
    need(number(case["duration"]) and abs(case["duration"] - duration) < 1e-8 and duration >= 4.5,
         "more than three old reservation windows")
    need(event_receipts[-1]["owner"] == "details" and event_receipts[-1]["target"] == 1, "sustained details")
    paint = case["paint"]
    need(number(paint["observedAt"]) and paint["observedAt"] >= recovered_at and paint["progress"] == 1,
         "natural recovered paint")
    need(vector(paint["nativeFrame"], 4) and paint["nativeFrame"] == paint["expectedFrame"]
         and paint["viewport"] == paint["expectedFrame"][2:], "natural native frame and viewport")


def validate(log):
    need(len(log) <= 1_000_000, "bounded output")
    lines = log.splitlines()
    need(not any(line != line.lstrip() and line.lstrip().startswith("MUSIC_STATIONARY_HOVER_") for line in lines), "hidden gate")
    selected = [line for line in lines if line.startswith("MUSIC_STATIONARY_HOVER_")]
    need(len(selected) == 2 and selected[0].startswith(PREFIX) and selected[1] == GATE, "unique success gates")
    need(lines.count(SHUTDOWN) == 1 and lines.index(SHUTDOWN) > lines.index(GATE), "orderly shutdown")
    need(not any("FAILED:" in line for line in lines), "failure marker")
    value = json.loads(selected[0][len(PREFIX):], object_pairs_hook=strict_object)
    need(type(value["schema"]) is int and value["schema"] == 1 and type(value["deadlineSeconds"]) is int and value["deadlineSeconds"] == 60, "schema and bound")
    need(number(value["elapsed"]) and 9 <= value["elapsed"] < 60, "native elapsed")
    for key in ("syntheticPollLocation", "nativeLocalEvents", "actualTimerPolling", "naturalPaint"):
        need(value[key] is True, key)
    need(value["globalSystemDelivery"] is False, "honest synthetic scope")
    cases = value["cases"]
    need(type(cases) is list and len(cases) == 3, "case coverage")
    validate_edge(cases[0], "left")
    validate_edge(cases[1], "right")
    need(cases[2] == dict(name="controls", genuineRight=True, genuineReverse=True,
                         pauseResume=True, trackChange=True, ordinaryRecovery=True, nativeEvents=True), "state and crossing controls")
    return value


def self_test():
    # Parser-only fabricated records. Never presented as native execution proof.
    def edge(name, cadence=.31, poll_delay=.27):
        center = [20 if name == "left" else 200, 2]
        events, receipts = [], []
        for i in range(16):
            t = 10 + i * cadence
            p = [center[0] + (-1 if i % 2 == 0 else 1), 2]
            e = dict(eventNumber=31001 + i, sourceAt=t, deliveredAt=t + .001, point=p, localPoint=p)
            if i:
                previous = events[-1]
                poll = dict(timestamp=previous["deliveredAt"] + poll_delay, point=previous["point"],
                            owner="details" if i >= 5 else "idle", target=1 if i >= 5 else 0)
                receipts.append(dict(kind="poll", **poll))
                e.update(gap=e["deliveredAt"] - previous["deliveredAt"], polls=[poll])
            r = dict(kind="event", timestamp=t, point=p, owner="details" if i >= 4 else "idle", target=1 if i >= 4 else 0)
            if i >= 4:
                r["hover"] = dict(timestamp=t + .002, inside=True, expandedBefore=i > 4, expandedAfter=True)
            receipts.append(r); events.append(e)
        recovery = receipts[8]["hover"]["timestamp"]
        return dict(name=name, events=events, receipts=receipts, center=center, corridor=[0, 0, 220, 32],
                    sourceWindowNumber=12, playbackReads=5, naturalPaint=True, noLyricsSelected=True,
                    leaveCollapsed=True, recoveryAt=recovery, recoverySeconds=recovery - events[0]["deliveredAt"],
                    duration=events[-1]["deliveredAt"] - events[0]["deliveredAt"],
                    paint=dict(observedAt=16, progress=1, nativeFrame=[0, 0, 440, 260],
                               expectedFrame=[0, 0, 440, 260], viewport=[440, 260]))
    payload = dict(schema=1, deadlineSeconds=60, elapsed=15, syntheticPollLocation=True, nativeLocalEvents=True,
                   actualTimerPolling=True, globalSystemDelivery=False, naturalPaint=True,
                   cases=[edge("left"), edge("right"), dict(name="controls", genuineRight=True,
                   genuineReverse=True, pauseResume=True, trackChange=True, ordinaryRecovery=True, nativeEvents=True)])
    def text(p):
        return PREFIX + json.dumps(p) + "\n" + GATE + "\n" + SHUTDOWN + "\n"
    validate(text(payload))
    # A native Timer may run after +0.30. Receipt-aware scheduling may wait
    # for it, but only within the original measured 0.30...0.45 s bound.
    delayed = copy.deepcopy(payload)
    delayed["cases"][:2] = [edge("left", .40, .34), edge("right", .40, .34)]
    validate(text(delayed))
    mutations = [lambda p: p.update(globalSystemDelivery=True), lambda p: p.update(elapsed=61),
                 lambda p: p["cases"][0]["events"][1].update(polls=[]),
                 lambda p: p["cases"][0].update(recoverySeconds=3),
                 lambda p: p["cases"][0]["events"][1].update(point=[100, 2]),
                 lambda p: p["cases"][1]["paint"].update(observedAt=0),
                 lambda p: p["cases"][2].update(genuineReverse=False),
                 lambda p: p["cases"][0].update(playbackReads=1),
                 lambda p: p["cases"].__setitem__(0, edge("left", .46, .34)),
                 lambda p: p["cases"][0]["events"][1]["polls"][0].update(timestamp=10.20)]
    for mutate in mutations:
        damaged = copy.deepcopy(payload); mutate(damaged)
        try:
            validate(text(damaged))
        except (ValueError, KeyError, TypeError):
            continue
        raise AssertionError("invalid evidence accepted")
    for damaged in (text(payload) + GATE, text(payload).replace(SHUTDOWN, ""),
                    text(payload) + "MUSIC_STATIONARY_HOVER_FAILED: sample\n"):
        try:
            validate(damaged)
        except ValueError:
            continue
        raise AssertionError("invalid log accepted")
    red = copy.deepcopy(payload["cases"][0])
    red.update(freshPlaying=True, unavailableLyrics=True, nativeSourceReady=True,
               inputState=dict(needsCorridorExit=False, gestureSuppressed=False))
    for receipt in red["receipts"]:
        receipt.update(owner="idle", target=0); receipt.pop("hover", None)
    for event in red["events"]:
        for poll in event.get("polls", []):
            poll.update(owner="idle", target=0)
    def red_log(value):
        return ("MUSIC_STATIONARY_HOVER_DIAGNOSTIC_JSON: " + json.dumps(value)
                + "\nMUSIC_STATIONARY_HOVER_FAILED: ordinary-edge-hover-starved-left"
                + "\nSMOKE_FAILED: native island checks failed\n")
    validate_red(0, red_log(red), "")
    for code, log in [(1, red_log(red)), (0, red_log(red).replace("starved-left", "other-failure")),
                      (0, red_log(red) + "MUSIC_STATIONARY_HOVER_FAILED: watchdog\n")]:
        try:
            validate_red(code, log, "")
        except ValueError:
            continue
        raise AssertionError("false red accepted")
    for mutate in [lambda p: p.update(freshPlaying=False), lambda p: p["events"][1].update(polls=[]),
                   lambda p: p["inputState"].update(needsCorridorExit=True),
                   lambda p: p["receipts"][-1].update(owner="details", target=1)]:
        damaged = copy.deepcopy(red); mutate(damaged)
        try:
            validate_red(0, red_log(damaged), "")
        except ValueError:
            continue
        raise AssertionError("invalid red evidence accepted")
    print("MUSIC_STATIONARY_HOVER_PARSER_SELF_TEST_OK: assertions=23 nativeAppRun=false")



ROOT = Path(__file__).resolve().parent.parent
BASELINE_COMMIT = "c08bc17fa69fec23df9fbb37281849f460cd578d"
HARNESS_PATH = "Sources/CodexNotchMeter/MusicStationaryHoverChecks.swift"
CONTROLLER_PATH = "Sources/CodexNotchMeter/AppController.swift"
FLAGS = ("--music-test", "--music-cache-test", "--music-stationary-hover-test")
METHOD = b'''    private func runStationaryMusicTest() {
        guard CommandLine.arguments.contains("--music-test") else { requestQuit(); return }
        stationaryMusicHarness = MusicStationaryHoverChecks { [weak self] valid in
            self?.smokeReady = valid; self?.requestQuit()
        }
        stationaryMusicHarness?.start()
    }
'''


def helpers():
    def load(name, filename):
        spec = importlib.util.spec_from_file_location(name, ROOT / "Scripts" / filename)
        module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
        return module
    return (load("stationary_common", "check-native-baseline.py"),
            load("stationary_processes", "check-native-lyrics-redgreen.py"))


def wire_controller(original):
    replacements = [
        (b"    private var musicCacheHarness: MusicRenderCacheChecks?\n",
         b"    private var musicCacheHarness: MusicRenderCacheChecks?\n    private var stationaryMusicHarness: MusicStationaryHoverChecks?\n"),
        (b'            else if CommandLine.arguments.contains("--music-cache-test") { runMusicCacheTest() }',
         b'            else if CommandLine.arguments.contains("--music-stationary-hover-test") { runStationaryMusicTest() }\n            else if CommandLine.arguments.contains("--music-cache-test") { runMusicCacheTest() }'),
        (b"musicCacheHarness?.stop();", b"musicCacheHarness?.stop(); stationaryMusicHarness?.stop();"),
        (b"    private func runMusicCacheTest() {", METHOD + b"    private func runMusicCacheTest() {")]
    patched = original
    for before, after in replacements:
        need(patched.count(before) == 1 and after not in patched, "unique baseline harness wiring")
        patched = patched.replace(before, after, 1)
    restored = patched
    for before, after in reversed(replacements):
        need(restored.count(after) == 1, "reversible harness wiring")
        restored = restored.replace(after, before, 1)
    need(restored == original, "baseline controller production bytes unchanged")
    return patched


def prepare(output):
    common, processes = helpers()
    need(common.git(ROOT, "rev-parse", "--verify", BASELINE_COMMIT + "^{commit}").decode().strip() == BASELINE_COMMIT,
         "fixed111 unavailable; no fetch performed")
    archive = common.git(ROOT, "archive", "--format=tar", BASELINE_COMMIT)
    stage = output / "baseline-source"; stage.mkdir()
    common.extract_archive(archive, stage)
    before = common.source_manifest(stage)
    original = common.bounded_read(stage / CONTROLLER_PATH)
    patched = wire_controller(original)
    harness = common.bounded_read(ROOT / HARNESS_PATH)
    need(not (stage / HARNESS_PATH).exists(), "fixture must be new on fixed111")
    (stage / HARNESS_PATH).write_bytes(harness)
    (stage / CONTROLLER_PATH).write_bytes(patched)
    after = common.source_manifest(stage)
    changed = sorted(p for p in before.keys() | after.keys() if before.get(p) != after.get(p))
    need(changed == sorted([HARNESS_PATH, CONTROLLER_PATH]), "only new fixture and exact entry wiring may change")
    result = dict(schema=1, baselineCommit=BASELINE_COMMIT, baselineVersion="1.1.1",
                  archiveSHA256=common.digest(archive), harnessSHA256=common.digest(harness),
                  originalControllerSHA256=common.digest(original), wiredControllerSHA256=common.digest(patched),
                  changedFiles=changed, before=before, after=after, productionSourcesUnchangedOutsideHarnessWiring=True,
                  flags=list(FLAGS), nativeAppRun=False, releaseEligible=False)
    processes.write_json(output / "preparation.json", result)
    return stage, result


def validate_red(code, stdout, stderr):
    need(code == 0, "red must exit normally; crash is not expected red")
    lines = stdout.splitlines()
    prefix = "MUSIC_STATIONARY_HOVER_DIAGNOSTIC_JSON: "
    selected = [line for line in lines if line.startswith("MUSIC_STATIONARY_HOVER_")]
    failure = "MUSIC_STATIONARY_HOVER_FAILED: ordinary-edge-hover-starved-left"
    need(len(selected) == 2 and selected[0].startswith(prefix) and selected[1] == failure, "exact old111 semantic failure")
    need(lines.count("SMOKE_FAILED: native island checks failed") == 1 and SHUTDOWN not in lines,
         "expected red orderly shutdown")
    allowed = (failure, "SMOKE_FAILED: native island checks failed")
    need(not any(("FAILED:" in line and line not in allowed) or "fatal error" in line.lower()
                 or "error:" in line.lower() or "deadline exceeded" in line.lower()
                 for line in lines + stderr.splitlines()), "unrelated red failure")
    value = json.loads(selected[0][len(prefix):], object_pairs_hook=strict_object)
    validate_edge(value, "left", red=True)
    return value


def red_green(output, stage, preparation):
    need(sys.platform == "darwin", "native red/green requires macOS")
    common, processes = helpers()
    candidate, binding = processes.candidate_binding(ROOT)
    processes.checked_command(["swift", "build", "-c", "release", "--product", "CodexNotchMeter"],
                              stage, output / "baseline-build", 600)
    bin_path = processes.checked_command(["swift", "build", "-c", "release", "--show-bin-path"],
                                        stage, output / "baseline-bin-path", 60).strip()
    baseline = Path(bin_path) / "CodexNotchMeter"
    need(baseline.resolve().is_relative_to((stage / ".build").resolve())
         and not (stage / ".build").is_symlink() and os.access(baseline, os.X_OK), "isolated baseline binary")
    need(common.source_manifest(stage) == preparation["after"], "baseline sources changed during build")
    baseline_sha = common.digest(common.bounded_read(baseline))
    red = processes.run_process([baseline, *FLAGS], stage, output / "baseline-red", 65)
    validate_red(*red)
    print("MUSIC_STATIONARY_REDGREEN_RED_OK: exactOld111Starvation=true normalExit=true", flush=True)
    green = processes.run_process([candidate, *FLAGS], ROOT, output / "candidate-green", 65)
    need(green[0] == 0, "candidate normal exit")
    validate(green[1] + green[2])
    need(common.source_manifest(stage) == preparation["after"], "baseline source mutation")
    need(processes.candidate_binding(ROOT)[1] == binding, "candidate binding mutation")
    need(common.digest(common.bounded_read(baseline)) == baseline_sha, "baseline executable mutation")
    need(common.digest(common.bounded_read(ROOT / HARNESS_PATH)) == preparation["harnessSHA256"], "identical harness mutation")
    processes.write_json(output / "result.json", dict(schema=1, baselineCommit=BASELINE_COMMIT,
        baselineVersion="1.1.1", candidate=binding, harnessSHA256=preparation["harnessSHA256"],
        baselineExecutableSHA256=baseline_sha, expectedRed=True, strictGreen=True, nativeAppRun=True,
        productionSourcesUnchangedOutsideHarnessWiring=True, releaseEligible=False,
        logs={p.name: common.digest(common.bounded_read(p)) for p in sorted(output.glob("*.log"))}))
    print("MUSIC_STATIONARY_REDGREEN_OK: fixed111=true expectedRed=true strictGreen=true nativePoll=true releaseEligible=false")


def main():
    if sys.argv[1:] == ["--self-test"]:
        self_test()
        with tempfile.TemporaryDirectory() as temp:
            stage, evidence = prepare(Path(temp))
            need(evidence["productionSourcesUnchangedOutsideHarnessWiring"] is True, "overlay isolation")
            need(not list(stage.rglob("*.pyc")), "no generated source inputs")
        print("MUSIC_STATIONARY_OVERLAY_SELF_TEST_OK: fixed111=true nativeAppRun=false")
        return 0
    if sys.argv[1:] in (["--red-green"], ["--prepare-only"]):
        if sys.argv[1] == "--red-green":
            need(sys.platform == "darwin", "native execution requires macOS")
        dist = ROOT / "dist"; need(not dist.is_symlink(), "refuse symlinked dist"); dist.mkdir(exist_ok=True)
        output = Path(tempfile.mkdtemp(prefix="stationary-music-", dir=dist))
        stage, evidence = prepare(output)
        print("MUSIC_STATIONARY_EVIDENCE: " + str(output), flush=True)
        if sys.argv[1] == "--red-green":
            red_green(output, stage, evidence)
        return 0
    if len(sys.argv) == 3 and sys.argv[1] == "--validate-log":
        validate(Path(sys.argv[2]).read_text()); return 0
    if len(sys.argv) > 2:
        raise ValueError("usage: check-native-stationary-music.py [APP_BINARY] | --self-test | --prepare-only | --red-green | --validate-log LOG")
    binary = Path(sys.argv[1] if len(sys.argv) == 2 else "dist/Codex Notch Meter.app/Contents/MacOS/CodexNotchMeter").resolve()
    result = subprocess.run([str(binary), "--music-test", "--music-cache-test", "--music-stationary-hover-test"],
                            capture_output=True, text=True, timeout=65)
    log = result.stdout + result.stderr
    output = Path("dist/music-stationary-hover.log"); output.parent.mkdir(parents=True, exist_ok=True); output.write_text(log)
    print(log, end="")
    need(result.returncode == 0, "native process exit")
    validate(log)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (ValueError, KeyError, TypeError, OSError, RuntimeError, subprocess.TimeoutExpired) as error:
        print("MUSIC_STATIONARY_HOVER_FAILED: " + str(error), file=sys.stderr)
        sys.exit(1)
