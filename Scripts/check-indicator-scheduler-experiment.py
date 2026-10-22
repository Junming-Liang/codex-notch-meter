#!/usr/bin/env python3
"""Fixed, diagnostic-only ABBA experiment. Never a release or full-CI gate."""
from copy import deepcopy
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import selectors
import signal
import subprocess
import sys
import time

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parent.parent
SPEC = importlib.util.spec_from_file_location("existing_cache_gate", ROOT / "Scripts/check-native-music-cache.py")
CACHE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CACHE)
ORDER = ("A1", "B1", "B2", "A2")
SCHEDULERS = {"A": "foundation-timer", "B": "strict-dispatch"}
TIMING = "MUSIC_INDICATOR_TIMING_JSON: "
DIAGNOSTIC = "MUSIC_INDICATOR_DIAGNOSTIC_JSON: "
EXPECTED_FAILURES = ["MUSIC_RENDER_CACHE_FAILED: music-indicator-native-evidence-bounded",
                     "MUSIC_RENDER_CACHE_FAILED: bounded-verification",
                     "SMOKE_FAILED: native island checks failed"]
MAX_LOG_BYTES = 2 * 1024 * 1024
BAD_RUNTIME = re.compile(r"fatal error|error:|exception|deadline exceeded|crash", re.I)


def decode_one(output, prefix):
    lines = [line for line in output.splitlines() if prefix.strip() in line]
    if len(lines) != 1 or not lines[0].startswith(prefix):
        raise ValueError("missing, malformed or duplicate receipt")
    return json.loads(lines[0][len(prefix):], object_pairs_hook=CACHE.strict_object,
                      parse_constant=lambda value: (_ for _ in ()).throw(ValueError(value)))


def wake_metrics(output, scheduler):
    try:
        value = decode_one(output, TIMING)
        if (not isinstance(value, dict) or set(value) != {"schema", "timing", "wakeSchema", "wakeScheduler", "wakeCapacity", "droppedWakes", "wakes"}
                or type(value["schema"]) is not int or value["schema"] != 1
                or type(value["wakeSchema"]) is not int or value["wakeSchema"] != 1
                or value["wakeScheduler"] != scheduler
                or type(value["wakeCapacity"]) is not int or value["wakeCapacity"] != 256
                or type(value["droppedWakes"]) is not int or value["droppedWakes"] != 0
                or not isinstance(value["timing"], list)
                or not isinstance(value["wakes"], list) or not 1 <= len(value["wakes"]) <= 256):
            return None
        previous = 0
        for index, row in enumerate(value["wakes"]):
            if (not isinstance(row, dict) or set(row) != {"sequence", "stage", "target", "interval", "armed", "fired", "resumed"}
                    or type(row["sequence"]) is not int or row["sequence"] != index + 1
                    or not isinstance(row["stage"], str) or not row["stage"] or len(row["stage"]) > 80
                    or not all(CACHE.finite(row[k]) and 0 <= row[k] <= 40 for k in ("target", "interval", "armed", "fired", "resumed"))
                    or row["interval"] <= 0 or not previous <= row["armed"] <= row["fired"] <= row["resumed"]):
                return None
            previous = row["resumed"]
        late = [max(0, row["fired"] - row["target"]) for row in value["wakes"]]
        hops = [row["resumed"] - row["fired"] for row in value["wakes"]]
        return dict(count=len(late), maxFireLateness=max(late), totalFireLateness=sum(late),
                    meanFireLateness=sum(late) / len(late), maxResumeDelay=max(hops), totalResumeDelay=sum(hops))
    except (ValueError, TypeError, KeyError, OverflowError):
        return None


def exact_deadline_failure(output):
    """An observed failed assertion, never counted as an application PASS."""
    if BAD_RUNTIME.search(output) or "_OK:" in output or CACHE.PREFIX in output:
        return False
    failures = [line for line in output.splitlines() if "FAILED" in line]
    if failures != EXPECTED_FAILURES:
        return False
    try:
        evidence = decode_one(output, DIAGNOSTIC)
        return (isinstance(evidence, dict) and evidence.get("schema") == 2
                and evidence.get("deadlineSeconds") == 3.0
                and evidence.get("periodSeconds") == 1.6 and evidence.get("observationDeadlineSeconds") == 2.1
                and isinstance(evidence.get("finalState"), dict)
                and CACHE.finite(evidence["finalState"].get("time")) and evidence["finalState"]["time"] > 3.0
                and isinstance(evidence.get("lifecycle"), list) and bool(evidence["lifecycle"])
                and evidence["lifecycle"][-1].get("stage") == "dismantled-reconfigure")
    except (ValueError, TypeError, KeyError, AttributeError):
        return False


def classify_cache(run, directory, scheduler):
    stdout, stderr = run["stdout"], run["stderr"]
    result = dict(status="invalid-or-unrelated-failure", metrics=None)
    if run["returncode"] != 0 or run["timedOut"] or run["outputLimited"] or BAD_RUNTIME.search(stdout + "\n" + stderr):
        return result
    # Receipts belong on stdout only; stderr cannot hide a second gate result.
    if any(token in stderr for token in ("FAILED", "_OK:", "_JSON:")):
        return result
    result["metrics"] = wake_metrics(stdout, scheduler)
    if result["metrics"] is None:
        return result
    if CACHE.valid(stdout):
        receipt = decode_one(stdout, CACHE.PREFIX)
        if CACHE.valid_indicator_files(directory, receipt):
            result.update(status="original-gate-pass", indicatorElapsed=receipt["indicator"]["elapsed"],
                          observationDuration=receipt["indicator"]["observationDuration"])
    elif exact_deadline_failure(stdout):
        result.update(status="observed-original-deadline-failure",
                      indicatorElapsed=decode_one(stdout, DIAGNOSTIC)["finalState"]["time"])
    return result


def decision(cache_runs, hover_runs):
    if (len(cache_runs) != 4 or [r.get("name") for r in cache_runs] != list(ORDER)
            or len(hover_runs) != 2 or not all(r.get("originalGatePassed") is True for r in hover_runs)):
        return "inconclusive-stop"
    if [r.get("status") for r in cache_runs] != ["observed-original-deadline-failure", "original-gate-pass", "original-gate-pass", "observed-original-deadline-failure"]:
        return "inconclusive-stop"
    a, b = [cache_runs[i]["metrics"] for i in (0, 3)], [cache_runs[i]["metrics"] for i in (1, 2)]
    # Descriptive separation, not a statistical claim or a new acceptance limit.
    if any(not isinstance(row, dict) for row in a + b):
        return "inconclusive-stop"
    for key in ("maxFireLateness", "meanFireLateness"):
        if not all(CACHE.finite(row.get(key)) for row in a + b) or max(row[key] for row in b) >= min(row[key] for row in a):
            return "inconclusive-stop"
    return "supports-fixture-scheduler-followup-only"


def run_owned(arguments, cwd, timeout, limit=MAX_LOG_BYTES):
    """Bound output and wall time; terminate only the child process group we own."""
    began = time.monotonic()
    result = dict(returncode=None, timedOut=False, outputLimited=False, stdout="", stderr="")
    chunks = {"stdout": bytearray(), "stderr": bytearray()}
    with selectors.DefaultSelector() as selector:
        process = subprocess.Popen(arguments, cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
        for stream, name in ((process.stdout, "stdout"), (process.stderr, "stderr")):
            selector.register(stream, selectors.EVENT_READ, name)
        killed = False
        def kill_owned():
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass  # The owned group exited between the deadline check and kill.
        while selector.get_map():
            if not killed and time.monotonic() - began >= timeout:
                result["timedOut"] = True
                kill_owned()
                killed = True
            # A descendant holding a pipe cannot extend the bound indefinitely.
            if killed and time.monotonic() - began >= timeout + 3:
                break
            for key, _ in selector.select(.05):
                data = os.read(key.fileobj.fileno(), 65536)
                if not data:
                    selector.unregister(key.fileobj)
                    key.fileobj.close()
                    continue
                room = limit - sum(map(len, chunks.values()))
                chunks[key.data].extend(data[:max(0, room)])
                if len(data) > room and not killed:
                    result["outputLimited"] = True
                    kill_owned()
                    killed = True
        try:
            process.wait(timeout=max(.01, timeout - (time.monotonic() - began)))
        except subprocess.TimeoutExpired:
            result["timedOut"] = True
            kill_owned()
            process.wait(timeout=3)
        for stream in (process.stdout, process.stderr):
            stream.close()
    result.update(returncode=process.returncode, seconds=time.monotonic() - began,
                  stdout=chunks["stdout"].decode("utf-8", errors="replace"),
                  stderr=chunks["stderr"].decode("utf-8", errors="replace"))
    return result


def store_run(directory, run):
    directory.mkdir(parents=True, exist_ok=True)
    for name in ("stdout", "stderr"):
        (directory / (name + ".log")).write_text(run[name])
    metadata = {k: v for k, v in run.items() if k not in ("stdout", "stderr")}
    metadata["logSHA256"] = {name: hashlib.sha256(run[name].encode()).hexdigest() for name in ("stdout", "stderr")}
    (directory / "process.json").write_text(json.dumps(metadata, indent=2) + "\n")
    print(json.dumps(dict(directory=directory.name, **metadata)), flush=True)


def self_test():
    count = 0
    def check(condition):
        nonlocal count
        assert condition
        count += 1
    sample = dict(schema=1, timing=[], wakeSchema=1, wakeScheduler="foundation-timer", wakeCapacity=256, droppedWakes=0,
                  wakes=[dict(sequence=1, stage="cycle-sample", target=.1, interval=.08, armed=.02, fired=.2, resumed=.201)])
    output = lambda value: TIMING + json.dumps(value) + "\n"
    check(wake_metrics(output(sample), "foundation-timer") is not None)
    for key, replacement in (("schema", True), ("wakeSchema", 2), ("wakeScheduler", "strict-dispatch"), ("wakeCapacity", 999), ("droppedWakes", 1), ("wakes", [])):
        bad = deepcopy(sample); bad[key] = replacement
        check(wake_metrics(output(bad), "foundation-timer") is None)
    for key, replacement in (("sequence", 2), ("sequence", True), ("stage", ""), ("target", float("nan")), ("interval", 0), ("fired", .01), ("resumed", .19)):
        bad = deepcopy(sample); bad["wakes"][0][key] = replacement
        check(wake_metrics(output(bad), "foundation-timer") is None)
    for key in sample["wakes"][0]:
        bad = deepcopy(sample); del bad["wakes"][0][key]
        check(wake_metrics(output(bad), "foundation-timer") is None)
    for bad in (output(sample) * 2, " " + output(sample), output(sample).replace('"schema": 1', '"schema": 1, "schema": 1')):
        check(wake_metrics(bad, "foundation-timer") is None)
    # An early dispatch fire is not falsified: nativePause must recheck target.
    early = deepcopy(sample); early["wakes"][0].update(fired=.09, resumed=.091)
    check(wake_metrics(output(early), "foundation-timer")["maxFireLateness"] == 0)
    evidence = dict(schema=2, deadlineSeconds=3.0, periodSeconds=1.6, observationDeadlineSeconds=2.1,
                    finalState=dict(time=3.05), lifecycle=[dict(stage="dismantled-reconfigure")])
    red = DIAGNOSTIC + json.dumps(evidence) + "\n" + "\n".join(EXPECTED_FAILURES)
    check(exact_deadline_failure(red))
    for bad in (red + "\n" + EXPECTED_FAILURES[0], red.replace(EXPECTED_FAILURES[0], "MUSIC_RENDER_CACHE_FAILED: unrelated"),
                red.replace("3.05", "2.99"), red.replace("dismantled-reconfigure", "started"),
                red + "\nMUSIC_RENDER_CACHE_OK: false", red + "\nfatal error", " " + red,
                red + "\n" + DIAGNOSTIC + json.dumps(evidence)):
        check(not exact_deadline_failure(bad))
    rows = [dict(name=name, status="observed-original-deadline-failure" if name[0] == "A" else "original-gate-pass",
                 metrics=dict(maxFireLateness=.1 if name[0] == "A" else .01, meanFireLateness=.08 if name[0] == "A" else .005)) for name in ORDER]
    hover = [dict(originalGatePassed=True), dict(originalGatePassed=True)]
    check(decision(rows, hover) == "supports-fixture-scheduler-followup-only")
    for index in range(4):
        for status in ("invalid-or-unrelated-failure", "original-gate-pass" if index in (0, 3) else "observed-original-deadline-failure"):
            bad = deepcopy(rows); bad[index]["status"] = status
            check(decision(bad, hover) == "inconclusive-stop")
    for key in ("maxFireLateness", "meanFireLateness"):
        bad = deepcopy(rows); bad[1]["metrics"][key] = .1
        check(decision(bad, hover) == "inconclusive-stop")
    check(decision(rows[::-1], hover) == "inconclusive-stop")
    check(decision(rows, [dict(originalGatePassed=True), dict(originalGatePassed=False)]) == "inconclusive-stop")
    check(decision(rows, hover[:1]) == "inconclusive-stop")
    native_red = dict(returncode=0, timedOut=False, outputLimited=False,
                      stdout=output(sample) + red, stderr="")
    check(classify_cache(native_red, ROOT, "foundation-timer")["status"] == "observed-original-deadline-failure")
    check(classify_cache(native_red, ROOT, "strict-dispatch")["status"] == "invalid-or-unrelated-failure")
    for key, value in (("returncode", 1), ("returncode", -9), ("timedOut", True), ("outputLimited", True),
                       ("stderr", "fatal error"), ("stderr", "SMOKE_OK: unexpected"), ("stderr", "OTHER_JSON: {}")):
        bad = deepcopy(native_red); bad[key] = value
        check(classify_cache(bad, ROOT, "foundation-timer")["status"] == "invalid-or-unrelated-failure")
    # Real subprocess negative controls, without launching an application.
    for code, timeout, limit, expected in (("print('retained')", 2, 1000, "normal"),
                                         ("import time; print('partial', flush=True); time.sleep(2)", .1, 1000, "timedOut"),
                                         ("print('x' * 5000)", 2, 100, "outputLimited")):
        run = run_owned([sys.executable, "-c", code], ROOT, timeout, limit)
        check(run[expected] if expected != "normal" else run["returncode"] == 0 and "retained" in run["stdout"])
        check(len(run["stdout"].encode()) + len(run["stderr"].encode()) <= limit)
    print(f"INDICATOR_SCHEDULER_EXPERIMENT_SELF_TEST_OK: assertions={count} nativeAppRun=false")
    return 0


def main():
    if sys.argv[1:] == ["--self-test"]:
        return self_test()
    if sys.argv[1:]:
        raise SystemExit("usage: check-indicator-scheduler-experiment.py [--self-test]")
    if sys.platform != "darwin":
        raise SystemExit("Native experiment requires macOS; no synthetic substitute")
    output = ROOT / "dist/scheduler-experiment"
    output.mkdir(parents=True, exist_ok=False)  # Never reuse an earlier run's evidence.
    binary = ROOT / "dist/Codex Notch Meter.app/Contents/MacOS/CodexNotchMeter"
    summary = dict(schema=1, diagnosticOnly=True, releaseEligible=False, fullCI=False,
                   order=list(ORDER), cache=[], hover=[], decision="incomplete-stop")
    summary["sourceCommit"] = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
    summary["sourceTree"] = subprocess.check_output(["git", "rev-parse", "HEAD^{tree}"], cwd=ROOT, text=True).strip()
    summary["binarySHA256"] = hashlib.sha256(binary.read_bytes()).hexdigest()
    metadata_path = binary.parent.parent / "Resources/build-source.json"
    build_source = json.loads(metadata_path.read_text(), object_pairs_hook=CACHE.strict_object)
    if build_source.get("commit") != summary["sourceCommit"] or build_source.get("tree") != summary["sourceTree"]:
        raise SystemExit("Built application does not match the current source commit/tree")
    (output / "build-source.json").write_text(json.dumps(build_source, indent=2) + "\n")
    def save():
        (output / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    def hover(name):
        run = run_owned([sys.executable, str(ROOT / "Scripts/check-native-motion.py")], ROOT, 55)
        store_run(output / name, run)
        summary["hover"].append(dict(name=name, originalGatePassed=run["returncode"] == 0 and not run["timedOut"] and not run["outputLimited"]))
        save()
    try:
        save()
        hover("hover-before")
        for name in ORDER:
            directory = output / name
            directory.mkdir()
            args = [str(binary), "--music-test", "--music-cache-test"]
            if name[0] == "B":
                args.append("--indicator-strict-dispatch-test")
            run = run_owned(args, directory, 40)
            store_run(directory, run)
            summary["cache"].append(dict(name=name, scheduler=SCHEDULERS[name[0]], **classify_cache(run, directory, SCHEDULERS[name[0]])))
            save()
        hover("hover-after")
        summary["decision"] = decision(summary["cache"], summary["hover"])
    finally:
        save()
        print("INDICATOR_SCHEDULER_EXPERIMENT_JSON: " + json.dumps(summary, sort_keys=True), flush=True)
    # Even the supported result only authorizes proposing a follow-up change.
    # It is never substituted for any original acceptance gate or release check.
    return 0 if summary["decision"] == "supports-fixture-scheduler-followup-only" else 1


if __name__ == "__main__":
    raise SystemExit(main())
