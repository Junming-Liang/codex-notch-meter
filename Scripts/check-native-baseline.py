#!/usr/bin/env python3
"""Compare the current packaged app with a fixed, isolated v1.0.0 executable.

Only an identical synthetic comparison harness and its AppController test entry
are added to the archived baseline. Historical production motion, geometry and
input code remain byte-for-byte intact. No fetch, checkout, packaging, signing,
account access or publication is performed. Controller-level common inputs are
not proof of native event ingress, physical feel, equal designs or GPU scanout.
"""
from __future__ import annotations

import argparse
from contextlib import redirect_stdout
import copy
import difflib
import hashlib
import io
import json
import math
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest import mock

BASELINE_COMMIT = "473c27fc2240b011134d45b889bb313d812b689c"
GROUPS = ("ordinary", "steady-music", "playback-edge")
HARNESS_PATH = "Sources/CodexNotchMeter/BaselineMotionComparison.swift"
CONTROLLER_PATH = "Sources/CodexNotchMeter/AppController.swift"
RUN_TIMEOUT = 50  # Harness owns a stricter 45-second watchdog.
MAX_BYTES = 32 * 1024 * 1024
MAX_TRACE_ROWS = 20_000
MAX_LOGGED_RECEIPT_BYTES = 12_000_000
MAX_LOGGED_COMPARISON_BYTES = 1_000_000
METHOD = '''    private func runBaselineMotionTest() {
        guard CommandLine.arguments.contains("--music-test"), let screen = NSScreen.main else { requestQuit(); return }
        baselineMotionHarness = BaselineMotionComparisonHarness(screen: screen) { [weak self] valid in
            self?.smokeReady = valid; self?.requestQuit()
        }
        baselineMotionHarness?.start()
    }
'''
HOOKS = (
    ('    private var musicHarness: MusicRenderHarness?\n',
     '    private var musicHarness: MusicRenderHarness?\n    private var baselineMotionHarness: BaselineMotionComparisonHarness?\n'),
    ('            if CommandLine.arguments.contains("--music-test") { runMusicTest() }\n',
     '            if CommandLine.arguments.contains("--baseline-motion-test") { runBaselineMotionTest() }\n'
     '            else if CommandLine.arguments.contains("--music-test") { runMusicTest() }\n'),
    ('musicHarness?.stop(); animationHarness?.stop()',
     'musicHarness?.stop(); baselineMotionHarness?.stop(); animationHarness?.stop()'),
    ('    private func runMusicTest() {\n', METHOD + '    private func runMusicTest() {\n'),
)


class ValidationError(RuntimeError):
    pass


def require(condition, message):
    if not condition:
        raise ValidationError(message)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def strict_json(text):
    def pairs(items):
        result = {}
        for key, value in items:
            require(key not in result, f"Duplicate JSON key: {key}")
            result[key] = value
        return result
    def invalid(value):
        raise ValidationError(f"Nonfinite JSON number: {value}")
    try:
        return json.loads(text, object_pairs_hook=pairs, parse_constant=invalid)
    except (ValueError, TypeError) as error:
        raise ValidationError(f"Invalid JSON: {error}") from error


def bounded_read(path):
    require(path.is_file() and not path.is_symlink(), f"Expected regular file: {path.name}")
    require(path.stat().st_size <= MAX_BYTES, f"Oversized file: {path.name}")
    return path.read_bytes()


def patch_controller(original):
    require("BaselineMotionComparisonHarness" not in original, "Baseline already contains a comparison hook")
    patched = original
    for old, new in HOOKS:
        require(patched.count(old) == 1, "Fixed baseline AppController test-entry anchor changed")
        patched = patched.replace(old, new, 1)
    return patched


def extract_archive(data, target):
    require(len(data) <= MAX_BYTES, "Baseline archive exceeds size limit")
    seen, total = set(), 0
    with tarfile.open(fileobj=io.BytesIO(data), mode="r:") as archive:
        for member in archive:
            name = member.name.rstrip("/")
            parts = PurePosixPath(name).parts
            require(name and not name.startswith("/") and "\\" not in name
                    and all(part not in (".", "..") for part in parts)
                    and str(PurePosixPath(name)) == name, "Unsafe archive path")
            require(name not in seen and len(seen) < 4096, "Duplicate or excessive archive entries")
            seen.add(name)
            require(member.isdir() or member.isfile(), "Baseline archive contains a nonregular entry")
            require(not (member.mode & 0o7000), "Unexpected archive file permissions")
            destination = target.joinpath(*parts)
            if member.isdir():
                destination.mkdir(parents=True, exist_ok=True)
            else:
                total += member.size
                require(0 <= member.size <= MAX_BYTES and total <= MAX_BYTES, "Expanded baseline archive exceeds limit")
                destination.parent.mkdir(parents=True, exist_ok=True)
                with archive.extractfile(member) as source, destination.open("xb") as output:
                    shutil.copyfileobj(source, output)
                destination.chmod(0o755 if member.mode & 0o111 else 0o644)


def source_manifest(directory):
    result = {}
    for path in sorted(directory.rglob("*")):
        relative = path.relative_to(directory)
        if relative.parts[0] in (".build", ".swiftpm"):
            continue  # Only separately generated compiler state is excluded.
        require(not path.is_symlink(), "Prepared baseline contains a symbolic link")
        if path.is_file():
            result[relative.as_posix()] = digest(bounded_read(path))
        else:
            require(path.is_dir(), "Prepared baseline contains a special file")
    return result


def git(root, *arguments):
    process = subprocess.run(["git", "--no-replace-objects", "-C", str(root),
                              "-c", "core.hooksPath=/dev/null", *arguments],
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30, check=False)
    require(process.returncode == 0, "Local Git operation failed: " + process.stderr.decode(errors="replace")[:2000])
    require(len(process.stdout) <= MAX_BYTES, "Local Git result exceeds size limit")
    return process.stdout


def prepare(root):
    """Create/revalidate an isolated archive; never remove an existing directory."""
    dist = root / "dist"
    require(not dist.is_symlink(), "Refusing a symlinked dist directory")
    dist.mkdir(exist_ok=True)
    destination, receipt_path = dist / "baseline-source", dist / "baseline-prepare.json"
    require(not destination.is_symlink(), "Refusing a symlinked baseline directory")
    require(git(root, "rev-parse", "--verify", BASELINE_COMMIT + "^{commit}").decode().strip() == BASELINE_COMMIT,
            "Fixed v1.0.0 baseline commit unavailable; this runner never fetches")
    archive = git(root, "archive", "--format=tar", BASELINE_COMMIT)
    harness = bounded_read(root / HARNESS_PATH)
    require(b"BaselineMotionComparisonHarness" in harness, "Shared comparison harness is missing")
    with tempfile.TemporaryDirectory(prefix=".baseline-stage-", dir=dist) as temporary:
        stage = Path(temporary) / "source"
        stage.mkdir()
        extract_archive(archive, stage)
        before = source_manifest(stage)
        require(HARNESS_PATH not in before, "Historical baseline already contains the new harness")
        controller = stage / CONTROLLER_PATH
        original = controller.read_text()
        patched = patch_controller(original)
        controller.write_text(patched)
        (stage / HARNESS_PATH).write_bytes(harness)
        after = source_manifest(stage)
        changed = sorted(path for path in before.keys() | after.keys() if before.get(path) != after.get(path))
        require(changed == sorted((CONTROLLER_PATH, HARNESS_PATH)), "Baseline patch exceeds the two allowed files")
        receipt = {
            "schema": 1, "baselineCommit": BASELINE_COMMIT, "archiveSHA256": digest(archive),
            "harnessSHA256": digest(harness), "changedFiles": changed,
            "productionSourcesUnchanged": True, "controllerLevelInput": True,
            "nativeIngress": False, "scanout": False,
            "before": before, "after": after,
            "appControllerPatch": "".join(difflib.unified_diff(
                original.splitlines(keepends=True), patched.splitlines(keepends=True),
                fromfile="v1.0.0/" + CONTROLLER_PATH, tofile="test-hook/" + CONTROLLER_PATH)),
        }
        if destination.exists():
            require(destination.is_dir() and receipt_path.is_file(), "Existing baseline has no preparation receipt")
            require(source_manifest(destination) == after, "Existing baseline differs from the exact allowed preparation")
            require(strict_json(bounded_read(receipt_path).decode()) == receipt, "Existing baseline preparation receipt differs")
        else:
            require(not receipt_path.exists(), "Preparation receipt exists without its baseline; refusing replacement")
            stage.rename(destination)
            with receipt_path.open("x") as output:
                json.dump(receipt, output, indent=2, sort_keys=True, allow_nan=False)
                output.write("\n")
    print("BASELINE_PREPARED: fixedCommit=" + BASELINE_COMMIT
          + " changedFiles=AppController.swift,BaselineMotionComparison.swift productionMotionGeometryInputUnchanged=true")
    return destination, receipt


def number(value, label, minimum=None, maximum=None):
    require(type(value) in (int, float) and math.isfinite(value), "Nonfinite or nonnumeric " + label)
    require(minimum is None or value >= minimum, label + " is below its bound")
    require(maximum is None or value <= maximum, label + " exceeds its bound")
    return value


def vector(value, count, label, positive_size=False):
    require(isinstance(value, list) and len(value) == count, "Malformed " + label)
    for entry in value:
        number(entry, label)
    if positive_size:
        require(all(value[index] > 0 for index in range(count - 2, count)), "Nonpositive " + label)


def ordered_rows(rows, label, sequence=True):
    require(isinstance(rows, list) and 2 <= len(rows) <= MAX_TRACE_ROWS, "Missing or excessive " + label)
    previous_time, previous_sequence = -1, -1
    for row in rows:
        require(isinstance(row, dict), "Malformed " + label + " row")
        time = number(row["t"], label + ".t", 0, RUN_TIMEOUT)
        require(time >= previous_time, "Unordered " + label + " timestamps")
        previous_time = time
        if sequence:
            require(type(row["sequence"]) is int and row["sequence"] > previous_sequence, "Unordered " + label + " sequence")
            previous_sequence = row["sequence"]


def parse_receipt(stdout, group, role, source):
    require(len(stdout.encode()) <= MAX_BYTES, "Native output exceeds limit")
    require("FAILED" not in stdout, "Native harness reported failure")
    rows = re.findall(r"^BASELINE_MOTION_JSON: (.+)$", stdout, re.MULTILINE)
    require(len(rows) == 1, "Expected exactly one native JSON receipt")
    data = strict_json(rows[0])
    try:
        require(type(data["schema"]) is int and data["schema"] == 1, "Unsupported receipt schema")
        require(data["role"] == role and data["group"] == group and data["sourceCommit"] == source,
                "Receipt group/role/source identity mismatch")
        for key, value in {"success": True, "historyOverflow": False, "synthetic": True, "controllerLevelInput": True, "nativeIngress": False,
                           "scanout": False, "baselineHasMusicWings": False}.items():
            require(data[key] is value, "Unexpected evidence boundary: " + key)
        require(data["paintCollection"] == "latest-receipt-observer", "Paint evidence collection boundary missing")
        require(type(data["paintSequenceGaps"]) is int and data["paintSequenceGaps"] >= 0, "Paint sequence gaps missing")
        require(isinstance(data["inputPlan"], dict) and data["inputPlan"], "Missing common input plan")
        plan_hash = data["inputPlanSHA256"]
        require(isinstance(plan_hash, str) and re.fullmatch(r"[0-9a-f]{64}", plan_hash), "Invalid input-plan digest")
        canonical = json.dumps(data["inputPlan"], sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()
        require(digest(canonical) == plan_hash, "Input-plan digest does not match its canonical JSON")
        inputs = data["inputs"]
        require(isinstance(inputs, list) and 2 <= len(inputs) <= 100, "Missing or excessive delivered inputs")
        last_planned, last_delivered, last_pointer_timestamp = -1, -1, -1
        for index, row in enumerate(inputs):
            require(row["index"] == index and type(row["index"]) is int, "Unordered delivered inputs")
            planned = number(row["planned"], "input planned", 0, RUN_TIMEOUT)
            delivered = number(row["delivered"], "input delivered", 0, RUN_TIMEOUT)
            require(planned >= last_planned and delivered >= last_delivered and delivered + 0.001 >= planned,
                    "Input timing is unordered or delivered before its plan")
            require(isinstance(row["kind"], str) and row["kind"] and "value" in row, "Malformed delivered input")
            if row["kind"] == "pointer":
                vector(row["point"], 2, "global pointer point")
                timestamp = number(row["timestamp"], "pointer timestamp", 0)
                require(timestamp > last_pointer_timestamp, "Unordered original pointer timestamps")
                last_pointer_timestamp = timestamp
            last_planned, last_delivered = planned, delivered
        validate_delivered_plan(data)
        frames, paints, settlements = data["frames"], data["paints"], data["settlements"]
        ordered_rows(frames, "frames")
        ordered_rows(paints, "paints")
        for row in frames:
            for field in ("progress", "target", "renderedProgress"):
                number(row[field], "frame " + field, 0, 1)
            number(row["velocity"], "frame velocity")
            number(row["scheduled"], "frame scheduled")
            require(type(row["generation"]) is int and row["generation"] >= 0, "Invalid frame generation")
            require(isinstance(row["source"], str) and row["source"] and isinstance(row["owner"], str), "Missing frame provenance")
            vector(row["frame"], 4, "frame", True)
            vector(row["contentBounds"], 4, "content bounds", True)
            vector(row["viewport"], 2, "viewport", True)
        for row in paints:
            number(row["collectedAt"], "paint collection time", row["t"], RUN_TIMEOUT)
            number(row["progress"], "paint progress", 0, 1)
            for field in ("viewport", "actualViewport"):
                vector(row[field], 2, field, True)
            for field in ("bodyBounds", "railBounds"):
                vector(row[field], 4, field)
            require(isinstance(row["contour"], (dict, list)), "Missing painted contour")
        require(isinstance(settlements, list) and settlements, "No convergence observations")
        names = set()
        for row in settlements:
            require(isinstance(row["name"], str) and row["name"] not in names, "Duplicate settlement")
            names.add(row["name"])
            require(type(row["inputIndex"]) is int and 0 <= row["inputIndex"] < len(inputs), "Unknown settlement input")
            number(row["target"], "settled target", 0, 1)
            started = number(row["targetStarted"], "target start", 0, RUN_TIMEOUT)
            settled = number(row["t"], "settlement time", started, RUN_TIMEOUT)
            latency = number(row["latency"], "settlement latency", 0, RUN_TIMEOUT)
            require(abs(settled - started - latency) <= 0.001, "Settlement latency contradicts trace")
            vector(row["frame"], 4, "settled frame", True)
            require(isinstance(row["owner"], str) and row["owner"], "Missing settled owner")
        expected_names = {"pre-hover", "details-open", "details-reopened", "final"}
        if group == "playback-edge":
            expected_names |= {"paused", "reconnected"}
        require(names == expected_names, "Missing or unexpected convergence checkpoints")
        modes = data["modeSamples"]
        require(isinstance(modes, list) and modes, "Missing mode observations")
        require(len({row["name"] for row in modes}) == len(modes), "Duplicate mode observation")
        for row in modes:
            number(row["t"], "mode sample time", 0, RUN_TIMEOUT)
            number(row["progress"], "mode progress", 0, 1)
            number(row["target"], "mode target", 0, 1)
            vector(row["frame"], 4, "mode frame", True)
            require(type(row["playing"]) is bool and isinstance(row["owner"], str), "Malformed mode state")
        mode_by_name = {row["name"]: row for row in modes}
        require(mode_by_name.keys() == expected_names, "Missing or unexpected mode checkpoints")
        for name in ("details-open", "details-reopened"):
            row = mode_by_name[name]
            require(row["target"] == 1 and abs(row["progress"] - 1) <= 0.001 and row["owner"] == "details",
                    "Details checkpoint is not converged")
        idle_names = {"pre-hover", "final"} if group == "ordinary" else ({"paused"} if group == "playback-edge" else set())
        for name in idle_names:
            row = mode_by_name[name]
            require(row["target"] == 0 and abs(row["progress"]) <= 0.001 and row["owner"] == "idle",
                    "Idle checkpoint is not converged")
        for row in settlements:
            mode = mode_by_name[row["name"]]
            require(row["target"] == mode["target"] and row["owner"] == mode["owner"]
                    and row["frame"] == mode["frame"] and abs(mode["progress"] - row["target"]) <= 0.001,
                    "Convergence checkpoint contradicts its observed mode")
        metrics = data["metrics"]
        require(metrics["frameCount"] == len(frames) and metrics["paintCount"] == len(paints), "Trace count mismatch")
        for key in ("maxCallbackGap", "maxApplyDuration", "minScheduledLead", "maxScheduledLead"):
            number(metrics[key], "metric " + key)
        require(type(metrics["targetChanges"]) is int and metrics["targetChanges"] >= 1, "Missing target transitions")
        number(data["elapsed"], "native elapsed", last_delivered, 45)
        marker = (f"BASELINE_MOTION_OK: group={group} role={role} inputPlanSHA256={plan_hash} "
                  "controllerLevel=true nativeIngress=false scanout=false")
        require(stdout.splitlines().count(marker) == 1
                and sum(line.startswith("BASELINE_MOTION_OK:") for line in stdout.splitlines()) == 1,
                "Missing, duplicate or contradictory success marker")
        shutdown = [line for line in stdout.splitlines() if line.startswith("SMOKE_OK:")]
        require(len(shutdown) == 1 and stdout.index(shutdown[0]) > stdout.index(marker), "Orderly shutdown missing or out of order")
    except (KeyError, TypeError, IndexError) as error:
        raise ValidationError(f"Malformed native receipt: {error}") from error
    return data



def validate_delivered_plan(data):
    """Bind actual global coordinates/content to the hashed common input plan."""
    plan = data["inputPlan"]
    require(plan["schema"] == 1 and plan["group"] == data["group"]
            and plan["inputLevel"] == "controller-fixed-global-point", "Unexpected input-plan identity")
    require(plan["reduceMotion"] is False and plan["motionProfile"] == "adaptive",
            "Comparison must use the unchanged production motion profile")
    require(plan["enabled"] is (data["group"] != "ordinary"), "Plan Music enable state differs from its group")
    vector(plan["screen"], 4, "input screen", True)
    vector(plan["rawNotch"], 4, "input raw notch", True)
    vector(plan["inside"], 2, "input inside point")
    vector(plan["outside"], 2, "input outside point")
    notch, screen = plan["rawNotch"], plan["screen"]
    require(plan["contentHeight"] == 260, "Common comparison content-height plan changed")
    # Both historical/current constructors cap the common full height at screen
    # height minus 32pt. The pointer exits 12pt below that shared full-height body.
    content_height = min(notch[3] + 8 + plan["contentHeight"], screen[3] - 32) - notch[3] - 8
    outside = [notch[0] + notch[2] / 2, screen[1] + screen[3] - notch[3] - 8 - content_height - 12]
    require(plan["inside"] == [notch[0] + notch[2] / 2, notch[1] - 2]
            and plan["outside"] == outside, "Pointer plan is not anchored to the fixed global notch/full-height shell")
    require(screen[0] <= outside[0] < screen[0] + screen[2]
            and screen[1] <= outside[1] < screen[1] + screen[3], "Common outside point must remain on screen")
    require(isinstance(plan["steps"], list) and 2 <= len(plan["steps"]) <= 100, "Missing common plan steps")
    expected = [{"index": 0, "planned": 0, "kind": "enabled", "value": plan["enabled"]}]
    for index, step in enumerate(plan["steps"], 1):
        require(set(step) == ({"at", "kind", "value", "point"} if step["kind"] == "pointer" else {"at", "kind", "value"}),
                "Unexpected common plan step fields")
        row = {"index": index, "planned": step["at"], "kind": step["kind"], "value": step["value"]}
        if step["kind"] == "pointer":
            require(step["value"] in ("inside", "outside") and step["point"] == plan[step["value"]],
                    "Planned pointer coordinate differs from its fixed global anchor")
            row["point"] = step["point"]
        expected.append(row)
    observed = [{key: value for key, value in row.items() if key not in ("delivered", "timestamp")} for row in data["inputs"]]
    require(observed == expected, "Delivered input coordinates/content do not match the hashed plan")


def compare(baseline, candidate):
    require(baseline["group"] == candidate["group"], "Comparison group mismatch")
    require(baseline["inputPlan"] == candidate["inputPlan"]
            and baseline["inputPlanSHA256"] == candidate["inputPlanSHA256"], "Baseline/candidate input plans differ")
    require([{key: value for key, value in row.items() if key not in ("delivered", "timestamp")} for row in baseline["inputs"]]
            == [{key: value for key, value in row.items() if key not in ("delivered", "timestamp")} for row in candidate["inputs"]],
            "Delivered input content/global coordinates differ between roles")
    baseline_settlements = {row["name"]: row for row in baseline["settlements"]}
    candidate_settlements = {row["name"]: row for row in candidate["settlements"]}
    require(baseline_settlements.keys() == candidate_settlements.keys(), "Convergence sequence differs")
    return {
        "group": baseline["group"], "inputPlanSHA256": baseline["inputPlanSHA256"], "sameInputPlan": True,
        "controllerLevelInput": True, "nativeIngress": False, "scanout": False,
        "designParityAsserted": False, "metricsReported": True, "perceptualAcceptance": False,
        "paintObservationBoundary": {"method": "latest-receipt-observer", "baselineSequenceGaps": baseline["paintSequenceGaps"], "candidateSequenceGaps": candidate["paintSequenceGaps"]},
        "designBoundary": "v1.0.0 has automatic compact music; it has no artwork wings or button-free gesture mode.",
        "metricDifferencesCandidateMinusBaseline": {
            key: candidate["metrics"][key] - baseline["metrics"][key] for key in baseline["metrics"]
            if type(baseline["metrics"][key]) in (int, float) and type(candidate["metrics"].get(key)) in (int, float)},
        "settlements": [{"name": name, "baseline": baseline_settlements[name], "candidate": candidate_settlements[name],
                         "latencyDifference": candidate_settlements[name]["latency"] - baseline_settlements[name]["latency"]}
                        for name in baseline_settlements],
        "modeSamples": {"baseline": baseline["modeSamples"], "candidate": candidate["modeSamples"]},
        "elapsed": {"baseline": baseline["elapsed"], "candidate": candidate["elapsed"]},
        "inputTimingDifferences": [{"index": left["index"], "kind": left["kind"], "planned": left["planned"],
                                    "baselineDelivered": left["delivered"], "candidateDelivered": right["delivered"],
                                    "deliveryDifference": right["delivered"] - left["delivered"]}
                                   for left, right in zip(baseline["inputs"], candidate["inputs"])],
    }


def print_diagnostic_tail(prefix, limit=16_384):
    for suffix in (".stdout.log", ".stderr.log"):
        path = prefix.with_suffix(suffix)
        if not path.is_file() or path.is_symlink():
            continue
        with path.open("rb") as stream:
            stream.seek(max(0, path.stat().st_size - limit))
            tail = stream.read(limit).decode(errors="replace")
        print(f"BASELINE_DIAGNOSTIC_TAIL: {prefix.name}{suffix}\n{tail}", file=sys.stderr, flush=True)


def run_process(arguments, cwd, prefix, timeout):
    """Keep raw output, kill only the owned process on timeout, and fail closed."""
    stdout_path, stderr_path = prefix.with_suffix(".stdout.log"), prefix.with_suffix(".stderr.log")
    require(not stdout_path.exists() and not stderr_path.exists(), "Refusing to replace existing run evidence")
    timed_out = False
    with stdout_path.open("xb") as output, stderr_path.open("xb") as errors:
        process = subprocess.Popen([str(arg) for arg in arguments], cwd=cwd, stdout=output, stderr=errors)
        try:
            code = process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            timed_out = True
            process.kill()
            code = process.wait(timeout=5)
    if timed_out or code != 0 or stdout_path.stat().st_size > MAX_BYTES or stderr_path.stat().st_size > MAX_BYTES:
        print_diagnostic_tail(prefix)
        require(not timed_out, f"Owned process exceeded {timeout}s: {prefix.name}")
        require(code == 0, f"Command failed ({prefix.name}); raw stdout/stderr retained and diagnostic tails printed")
        raise ValidationError("Command output exceeds bounded log size: " + prefix.name)
    return bounded_read(stdout_path).decode(errors="replace")


def run_native(root, prepared, preparation):
    require(sys.platform == "darwin", "Native A/B comparison requires macOS; use --self-test or --prepare-only elsewhere")
    candidate_app = root / "dist/Codex Notch Meter.app"
    candidate_binary = candidate_app / "Contents/MacOS/CodexNotchMeter"
    require(candidate_binary.is_file() and os.access(candidate_binary, os.X_OK), "Current packaged executable missing")
    manifest = strict_json(bounded_read(candidate_app / "Contents/Resources/build-source.json").decode())
    source = git(root, "rev-parse", "--verify", "HEAD").decode().strip()
    require(manifest["commit"] == source and manifest["tree"] == git(root, "rev-parse", "HEAD^{tree}").decode().strip(),
            "Current packaged executable is not bound to this checkout")
    require(not git(root, "status", "--porcelain", "--untracked-files=no").strip(), "Current tracked source is dirty")
    require(not git(root, "ls-files", "--others", "--exclude-standard", "Sources", "Scripts", "Package.swift").strip(),
            "Current build inputs include untracked files")
    output = root / "dist/baseline-comparison"
    require(not output.exists(), "Comparison evidence already exists; refusing to overwrite")
    output.mkdir()
    current_binary_digest = digest(bounded_read(candidate_binary))
    require(not (prepared / ".build").is_symlink(), "Refusing a symlinked baseline build directory")
    run_process(["swift", "build", "-c", "release", "--product", "CodexNotchMeter"], prepared,
                output / "baseline-build", 600)
    path_text = run_process(["swift", "build", "-c", "release", "--show-bin-path"], prepared,
                            output / "baseline-build-path", 60).strip()
    binary = Path(path_text) / "CodexNotchMeter"
    require(binary.resolve().is_relative_to(prepared.resolve())
            and binary.resolve().is_relative_to((prepared / ".build").resolve()) and binary.is_file()
            and os.access(binary, os.X_OK), "Baseline executable escaped its isolated build directory")
    results = []
    logged_receipt_bytes = 0
    for group in GROUPS:
        pair = {}
        for role, executable, commit in (("baseline", binary, BASELINE_COMMIT), ("candidate", candidate_binary, source)):
            prefix = output / f"{group}-{role}"
            capture_dir = output / f"{group}-{role}-captures"
            capture_dir.mkdir()
            stdout = run_process([executable, "--music-test", "--motion-test", "--baseline-motion-test",
                                  "--baseline-motion-group=" + group, "--baseline-motion-role=" + role,
                                  "--baseline-motion-source=" + commit, "--baseline-motion-output=" + str(capture_dir)],
                                 root, prefix, RUN_TIMEOUT)
            raw_receipts = re.findall(r"^BASELINE_MOTION_JSON: (.+)$", stdout, re.MULTILINE)
            if len(raw_receipts) == 1:
                logged_receipt_bytes += len(raw_receipts[0].encode())
                require(logged_receipt_bytes <= MAX_LOGGED_RECEIPT_BYTES, "Six native receipts exceed the CI log budget")
                print("BASELINE_MOTION_JSON: " + raw_receipts[0], flush=True)
            try:
                pair[role] = parse_receipt(stdout, group, role, commit)
            except ValidationError:
                print_diagnostic_tail(prefix)
                raise
            prefix.with_suffix(".json").write_text(json.dumps(pair[role], indent=2, sort_keys=True, allow_nan=False) + "\n")
            print(f"BASELINE_CASE_CHECKED: group={group} role={role} frames={len(pair[role]['frames'])} paints={len(pair[role]['paints'])}")
        results.append(compare(pair["baseline"], pair["candidate"]))
    require(source_manifest(prepared) == preparation["after"], "Baseline source changed during build/run")
    require(digest(bounded_read(candidate_binary)) == current_binary_digest, "Current packaged executable changed during A/B run")
    require(digest(bounded_read(root / HARNESS_PATH)) == preparation["harnessSHA256"]
            and not git(root, "status", "--porcelain", "--untracked-files=no").strip(),
            "Current comparison source changed during A/B run")
    result = {"schema": 1, "baselineCommit": BASELINE_COMMIT, "candidateCommit": source,
              "harnessSHA256": preparation["harnessSHA256"], "baselineExecutableSHA256": digest(bounded_read(binary)),
              "candidateExecutableSHA256": current_binary_digest, "groups": results,
              "controllerLevelInput": True, "nativeIngress": False, "scanout": False, "designParityAsserted": False,
              "metricsReported": True, "perceptualAcceptance": False}
    (output / "comparison.json").write_text(json.dumps(result, indent=2, sort_keys=True, allow_nan=False) + "\n")
    compact_result = json.dumps(result, separators=(",", ":"), sort_keys=True, allow_nan=False)
    require(len(compact_result.encode()) <= MAX_LOGGED_COMPARISON_BYTES, "Aggregate comparison exceeds CI log budget")
    print("BASELINE_COMPARISON_JSON: " + compact_result, flush=True)
    print("BASELINE_COMPARISON_OK: groups=ordinary,steady-music,playback-edge sameInputPlans=true "
          "baselineProductionUnchanged=true controllerLevel=true nativeIngress=false designParity=false "
          "metricsReported=true perceptualAcceptance=false scanout=false")


def self_test():
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(SelfTests)
    result = unittest.TextTestRunner(verbosity=1).run(suite)
    require(result.wasSuccessful(), "Baseline runner self-tests failed")
    print(f"BASELINE_RUNNER_SELF_TEST_OK: tests={result.testsRun} synthetic=true native=false")


class SelfTests(unittest.TestCase):
    def test_fixed_baseline_identity(self):
        self.assertEqual(BASELINE_COMMIT, "473c27fc2240b011134d45b889bb313d812b689c")

    def test_hook_only_changes_exact_anchors(self):
        source = "prefix\n" + "\n".join(old for old, _ in HOOKS) + "suffix\n"
        patched = patch_controller(source)
        for old, new in reversed(HOOKS):
            patched = patched.replace(new, old, 1)
        self.assertEqual(patched, source)

    def test_missing_duplicate_or_reapplied_hook_rejected(self):
        source = "\n".join(old for old, _ in HOOKS)
        for bad in ("", source + HOOKS[0][0], patch_controller(source)):
            with self.subTest(source=bad[:40]), self.assertRaises(ValidationError):
                patch_controller(bad)

    def test_strict_json_duplicate_nonfinite_rejected(self):
        for value in ('{"a":1,"a":2}', '{"a":NaN}', '{"a":Infinity}', 'invalid'):
            with self.subTest(value=value), self.assertRaises(ValidationError):
                strict_json(value)

    @staticmethod
    def archive(name="file.txt", kind=tarfile.REGTYPE):
        data = io.BytesIO()
        with tarfile.open(fileobj=data, mode="w") as archive:
            entry = tarfile.TarInfo(name)
            entry.type = kind
            entry.size = 1 if kind == tarfile.REGTYPE else 0
            archive.addfile(entry, io.BytesIO(b"a") if entry.size else None)
        return data.getvalue()

    def test_regular_archive_extracts(self):
        with tempfile.TemporaryDirectory() as temporary:
            extract_archive(self.archive("nested/file.txt"), Path(temporary))
            self.assertEqual((Path(temporary) / "nested/file.txt").read_bytes(), b"a")

    def test_unsafe_archive_paths_rejected(self):
        for name in ("../escape", "/absolute", "a/../b", "a\\b", "./a", "a//b"):
            with self.subTest(name=name), tempfile.TemporaryDirectory() as temporary, self.assertRaises(ValidationError):
                extract_archive(self.archive(name), Path(temporary))

    def test_links_and_special_archive_entries_rejected(self):
        for kind in (tarfile.SYMTYPE, tarfile.LNKTYPE, tarfile.FIFOTYPE, tarfile.CHRTYPE):
            with self.subTest(kind=kind), tempfile.TemporaryDirectory() as temporary, self.assertRaises(ValidationError):
                extract_archive(self.archive(kind=kind), Path(temporary))

    def test_manifest_detects_source_mutation(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "source.swift").write_text("before")
            before = source_manifest(root)
            (root / "source.swift").write_text("after")
            self.assertNotEqual(before, source_manifest(root))
            (root / ".build").mkdir()
            (root / ".build/generated").write_text("compiler output")
            self.assertEqual(set(source_manifest(root)), {"source.swift"})

    def test_manifest_rejects_symlink(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "link").symlink_to("/tmp")
            with self.assertRaises(ValidationError):
                source_manifest(root)



    @staticmethod
    def fixture(group="ordinary", role="baseline"):
        source = BASELINE_COMMIT if role == "baseline" else "a" * 40
        enabled = group != "ordinary"
        inputs = [{"index": 0, "planned": 0, "delivered": 0.01, "kind": "enabled", "value": enabled},
                  {"index": 1, "planned": 1, "delivered": 1.01, "kind": "pointer", "value": "inside", "point": [500, 366], "timestamp": 1001.01},
                  {"index": 2, "planned": 2, "delivered": 2.01, "kind": "pointer", "value": "outside", "point": [500, 88], "timestamp": 1002.01}]
        plan = {"schema": 1, "group": group, "inputLevel": "controller-fixed-global-point",
                "screen": [0, 0, 1000, 400], "rawNotch": [390, 368, 220, 32],
                "inside": [500, 366], "outside": [500, 88], "contentHeight": 260, "reduceMotion": False,
                "motionProfile": "adaptive", "enabled": enabled,
                "steps": [{"at": row["planned"], "kind": row["kind"], "value": row["value"], "point": row["point"]} for row in inputs[1:]]}
        plan_hash = digest(json.dumps(plan, sort_keys=True, separators=(",", ":")).encode())
        frame = [0, 0, 400, 200]
        names = ["pre-hover", "details-open", "details-reopened", "final"]
        if group == "playback-edge":
            names = ["pre-hover", "paused", "reconnected", "details-open", "details-reopened", "final"]
        settlements, modes = [], []
        for index, name in enumerate(names):
            target = 1 if name.startswith("details-") else 0
            owner = "details" if target else "idle"
            settlements.append({"name": name, "inputIndex": min(index, 2), "target": target,
                                "targetStarted": index, "t": index + 0.5, "latency": 0.5,
                                "frame": frame, "owner": owner})
            modes.append({"name": name, "t": index + 0.5, "progress": target, "target": target,
                          "frame": frame, "owner": owner, "playing": group != "ordinary"})
        data = {"schema": 1, "group": group, "role": role, "sourceCommit": source,
                "success": True, "historyOverflow": False, "synthetic": True, "controllerLevelInput": True, "nativeIngress": False,
                "scanout": False, "baselineHasMusicWings": False,
                "paintCollection": "latest-receipt-observer", "paintSequenceGaps": 1,
                "inputPlan": plan, "inputPlanSHA256": plan_hash, "inputs": inputs,
                "frames": [{"sequence": i, "t": i, "scheduled": i + 0.01, "generation": 1,
                            "source": "synthetic-fixture", "progress": i / 3, "velocity": 0,
                            "target": 1, "owner": "details", "frame": frame,
                            "contentBounds": frame, "viewport": frame[2:], "renderedProgress": i / 3}
                           for i in range(4)],
                "paints": [{"sequence": i, "t": i, "collectedAt": i + 0.01, "progress": i / 3,
                            "viewport": frame[2:], "actualViewport": frame[2:], "contour": {},
                            "bodyBounds": frame, "railBounds": frame} for i in range(4)],
                "settlements": settlements, "modeSamples": modes,
                "metrics": {"frameCount": 4, "paintCount": 4, "maxCallbackGap": 0.02,
                            "maxApplyDuration": 0.001, "minScheduledLead": 0, "maxScheduledLead": 0.02,
                            "targetChanges": 3}, "elapsed": 8}
        return data

    @staticmethod
    def output(data):
        return ("BASELINE_MOTION_JSON: " + json.dumps(data, separators=(",", ":")) + "\n"
                + f"BASELINE_MOTION_OK: group={data['group']} role={data['role']} inputPlanSHA256={data['inputPlanSHA256']} "
                + "controllerLevel=true nativeIngress=false scanout=false\nSMOKE_OK: synthetic orderly shutdown\n")

    def parse(self, data):
        return parse_receipt(self.output(data), data["group"], data["role"], data["sourceCommit"])

    def test_all_six_synthetic_receipts_parse(self):
        for group in GROUPS:
            for role in ("baseline", "candidate"):
                with self.subTest(group=group, role=role):
                    self.assertEqual(self.parse(self.fixture(group, role))["group"], group)

    def test_missing_top_level_fields_rejected(self):
        data = self.fixture()
        for key in data:
            if key in ("role", "group", "sourceCommit", "inputPlanSHA256"):
                continue  # These also construct the synthetic success marker.
            changed = copy.deepcopy(data)
            del changed[key]
            with self.subTest(key=key), self.assertRaises(ValidationError):
                self.parse(changed)

    def test_duplicate_missing_or_misordered_receipts_rejected(self):
        data = self.fixture()
        output = self.output(data)
        for line in output.splitlines():
            for altered in (output.replace(line + "\n", ""), output + line + "\n"):
                with self.subTest(line=line[:40]), self.assertRaises(ValidationError):
                    parse_receipt(altered, "ordinary", "baseline", BASELINE_COMMIT)
        with self.assertRaises(ValidationError):
            parse_receipt("\n".join(reversed(output.splitlines())), "ordinary", "baseline", BASELINE_COMMIT)

    def test_identity_mismatch_rejected(self):
        output = self.output(self.fixture())
        for args in (("steady-music", "baseline", BASELINE_COMMIT), ("ordinary", "candidate", BASELINE_COMMIT),
                     ("ordinary", "baseline", "a" * 40)):
            with self.subTest(args=args), self.assertRaises(ValidationError):
                parse_receipt(output, *args)

    def test_evidence_boundary_mutations_rejected(self):
        for key in ("success", "historyOverflow", "synthetic", "controllerLevelInput", "nativeIngress", "scanout", "baselineHasMusicWings"):
            data = self.fixture()
            data[key] = not data[key]
            with self.subTest(key=key), self.assertRaises(ValidationError):
                self.parse(data)

    def test_input_hash_and_time_mutations_rejected(self):
        for mutate in (lambda d: d["inputPlan"].update({"different": True}),
                       lambda d: d["inputs"][1].update({"index": 0}),
                       lambda d: d["inputs"][1].update({"delivered": 0}),
                       lambda d: d["inputs"][1].update({"planned": -1})):
            data = self.fixture()
            mutate(data)
            with self.assertRaises(ValidationError):
                self.parse(data)

    def test_frame_trace_mutations_rejected(self):
        for key, value in (("t", -1), ("sequence", 0), ("progress", 1.1), ("velocity", float("nan")),
                           ("target", -1), ("frame", [0, 0, 0, 10]), ("viewport", [0, 10])):
            data = self.fixture()
            data["frames"][1][key] = value
            with self.subTest(key=key), self.assertRaises(ValidationError):
                self.parse(data)

    def test_paint_trace_mutations_rejected(self):
        for key, value in (("collectedAt", 0), ("sequence", 0), ("progress", 1.1), ("actualViewport", [0, 10])):
            data = self.fixture()
            data["paints"][1][key] = value
            with self.subTest(key=key), self.assertRaises(ValidationError):
                self.parse(data)

    def test_missing_or_contradictory_convergence_rejected(self):
        for mutate in (lambda d: d["settlements"].pop(),
                       lambda d: d["settlements"][0].update({"latency": 4}),
                       lambda d: d["settlements"][0].update({"latency": 0}),
                       lambda d: d["modeSamples"][1].update({"progress": 0.8}),
                       lambda d: d["modeSamples"][1].update({"owner": "idle"}),
                       lambda d: d["modeSamples"][0].update({"target": 1})):
            data = self.fixture()
            mutate(data)
            with self.assertRaises(ValidationError):
                self.parse(data)

    def test_metrics_and_elapsed_mutations_rejected(self):
        for mutate in (lambda d: d["metrics"].update({"frameCount": 2}),
                       lambda d: d["metrics"].update({"targetChanges": 0}),
                       lambda d: d.update({"elapsed": 46}),
                       lambda d: d.update({"paintSequenceGaps": -1})):
            data = self.fixture()
            mutate(data)
            with self.assertRaises(ValidationError):
                self.parse(data)

    def test_comparison_reports_differences_without_design_parity(self):
        baseline, candidate = self.fixture("steady-music"), self.fixture("steady-music", "candidate")
        candidate["metrics"]["maxCallbackGap"] = 0.03
        candidate["modeSamples"][0]["frame"] = [0, 0, 300, 40]
        result = compare(baseline, candidate)
        self.assertTrue(result["sameInputPlan"])
        self.assertFalse(result["designParityAsserted"])
        self.assertTrue(result["metricsReported"])
        self.assertFalse(result["perceptualAcceptance"])
        self.assertAlmostEqual(result["metricDifferencesCandidateMinusBaseline"]["maxCallbackGap"], 0.01)

    def test_comparison_rejects_changed_global_point_or_plan(self):
        baseline = self.fixture()
        for mutate in (lambda d: d["inputs"][1].update({"point": [101, 100]}),
                       lambda d: d["inputPlan"].update({"different": True}),
                       lambda d: d["settlements"].pop()):
            candidate = self.fixture(role="candidate")
            mutate(candidate)
            with self.assertRaises(ValidationError):
                compare(baseline, candidate)

    def test_comparison_rejects_pointer_timestamp_reversal(self):
        data = self.fixture()
        data["inputs"][2]["timestamp"] = 1000
        with self.assertRaises(ValidationError):
            self.parse(data)

    def test_delivered_point_must_match_hashed_plan(self):
        data = self.fixture()
        data["inputs"][1]["point"] = [501, 366]
        with self.assertRaises(ValidationError):
            self.parse(data)

    def test_comparison_allows_real_delivery_time_differences(self):
        baseline, candidate = self.fixture(), self.fixture(role="candidate")
        candidate["inputs"][1]["delivered"] += 0.01
        candidate["inputs"][1]["timestamp"] += 100
        candidate["inputs"][2]["timestamp"] += 100
        self.assertTrue(compare(baseline, candidate)["sameInputPlan"])

    def make_preparation_fixture(self, root):
        files = {CONTROLLER_PATH: "prefix\n" + "\n".join(old for old, _ in HOOKS) + "suffix\n",
                 "Sources/CodexNotchMeter/MotionFrames.swift": "untouched historical motion",
                 "Sources/CodexNotchMeter/IslandPanel.swift": "untouched historical panel"}
        data = io.BytesIO()
        with tarfile.open(fileobj=data, mode="w") as archive:
            for name, content in files.items():
                encoded = content.encode()
                entry = tarfile.TarInfo(name)
                entry.size = len(encoded)
                archive.addfile(entry, io.BytesIO(encoded))
        (root / HARNESS_PATH).parent.mkdir(parents=True)
        (root / HARNESS_PATH).write_text("// Synthetic fixture BaselineMotionComparisonHarness")
        def git_fixture(_root, *args):
            if args[0] == "rev-parse":
                return (BASELINE_COMMIT + "\n").encode()
            if args == ("archive", "--format=tar", BASELINE_COMMIT):
                return data.getvalue()
            raise AssertionError("Unexpected Git call")
        return git_fixture

    def test_prepare_only_allows_dirty_worktree_and_changes_exactly_two_files(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            fixture = self.make_preparation_fixture(root)
            with mock.patch(__name__ + ".git", side_effect=fixture), redirect_stdout(io.StringIO()):
                directory, receipt = prepare(root)
                again, repeated = prepare(root)
            self.assertEqual(directory, again)
            self.assertEqual(receipt, repeated)
            self.assertEqual(receipt["changedFiles"], sorted((CONTROLLER_PATH, HARNESS_PATH)))
            self.assertEqual((directory / "Sources/CodexNotchMeter/MotionFrames.swift").read_text(), "untouched historical motion")
            self.assertFalse((directory / ".build").exists())

    def test_prepare_refuses_existing_mutated_baseline(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            fixture = self.make_preparation_fixture(root)
            with mock.patch(__name__ + ".git", side_effect=fixture), redirect_stdout(io.StringIO()):
                directory, _ = prepare(root)
                (directory / "Sources/CodexNotchMeter/MotionFrames.swift").write_text("unexpected mutation")
                with self.assertRaises(ValidationError):
                    prepare(root)
            self.assertEqual((directory / "Sources/CodexNotchMeter/MotionFrames.swift").read_text(), "unexpected mutation")

    def test_prepare_refuses_unreceipted_directory(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            fixture = self.make_preparation_fixture(root)
            (root / "dist/baseline-source").mkdir(parents=True)
            with mock.patch(__name__ + ".git", side_effect=fixture), self.assertRaises(ValidationError):
                prepare(root)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--self-test", action="store_true", help="Offline synthetic safety/parser checks only")
    mode.add_argument("--prepare-only", action="store_true", help="Extract/audit fixed baseline without building or running")
    args = parser.parse_args()
    if args.self_test:
        self_test()
        return
    root = Path(__file__).resolve().parent.parent
    prepared, receipt = prepare(root)
    if not args.prepare_only:
        run_native(root, prepared, receipt)


if __name__ == "__main__":
    try:
        main()
    except (ValidationError, OSError, subprocess.SubprocessError, tarfile.TarError) as error:
        print("BASELINE_COMPARISON_FAILED: " + str(error), file=sys.stderr)
        raise SystemExit(1)
