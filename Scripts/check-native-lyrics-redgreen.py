#!/usr/bin/env python3
"""Fixed-source lyrics regression red/green gate, without fetch or publication.

--prepare-only validates the isolated archive on any OS; it is not native proof.
Native mode requires an existing clean-HEAD source-bound macOS packaged app.
Only MusicRendering.swift is overlaid on the fixed historical baseline. The
controller-only gate does not establish native input, perception or scanout.
"""
from __future__ import annotations

import argparse
from contextlib import redirect_stdout
import importlib.util
import io
import json
import os
from pathlib import Path
import re
import selectors
import subprocess
import sys
import tempfile
import time
import unittest

# Loading local validation helpers must not create untracked build inputs.
# Source binding intentionally continues to reject every untracked Scripts file.
sys.dont_write_bytecode = True

ROOT = Path(__file__).resolve().parent.parent
BASELINE_COMMIT = "6f98d9e749fcc636974128926dd6852b26e291cd"
HARNESS_PATH = "Sources/CodexNotchMeter/MusicRendering.swift"
FLAGS = ("--music-test", "--lyrics-recovery-test")
REASON = "fresh exact same-track snapshot restores the original bound document, source and selected mode"
RED_RECEIPTS = ["MUSIC_LYRICS_RECOVERY_FAILED: native synthetic recovery contract failed",
                "SMOKE_FAILED: native island checks failed"]
MAX_LOG_BYTES = 8 * 1024 * 1024
DIAGNOSTIC_TAIL_BYTES = 128 * 1024
DIAGNOSTIC_RECEIPT_BYTES = 64 * 1024
DIAGNOSTIC_RECEIPT_PREFIXES = (b"MUSIC_LYRICS_RECOVERY_", b"SMOKE_OK:", b"SMOKE_FAILED:")
RED_SETUP = (
    "recovery starts from actual usable lyrics and explicit selected mode",
    "deliver real pending recovery source failure",
    "soft source failure preserves only the explicit selected mode",
)


def load_helper(name, filename):
    spec = importlib.util.spec_from_file_location(name, ROOT / "Scripts" / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


common = load_helper("lyrics_redgreen_common", "check-native-baseline.py")
recovery = load_helper("lyrics_redgreen_receipts", "check-native-lyrics-recovery.py")
require, ValidationError = common.require, common.ValidationError


def validate_overlay(before, after, harness_sha):
    changed = sorted(path for path in before.keys() | after.keys()
                     if before.get(path) != after.get(path))
    require(changed == [HARNESS_PATH], "Baseline overlay must change only MusicRendering.swift")
    require(after[HARNESS_PATH] == harness_sha, "Baseline and candidate harness hashes differ")
    return changed


def prepare(root, output):
    require(common.git(root, "rev-parse", "--verify", BASELINE_COMMIT + "^{commit}").decode().strip()
            == BASELINE_COMMIT, "Fixed baseline unavailable; no fetch is performed")
    archive = common.git(root, "archive", "--format=tar", BASELINE_COMMIT)
    harness = common.bounded_read(root / HARNESS_PATH)
    require(REASON.encode() in harness and b"--lyrics-recovery-test" in harness,
            "Current recovery harness is missing its exact regression assertion")
    stage = output / "baseline-source"
    stage.mkdir()
    common.extract_archive(archive, stage)
    before = common.source_manifest(stage)
    require(HARNESS_PATH in before, "Historical harness missing")
    (stage / HARNESS_PATH).write_bytes(harness)
    after = common.source_manifest(stage)
    sha = common.digest(harness)
    changed = validate_overlay(before, after, sha)
    manifest = {
        "schema": 1, "baselineCommit": BASELINE_COMMIT,
        "archiveSHA256": common.digest(archive), "harnessSHA256": sha,
        "changedFiles": changed, "before": before, "after": after,
        "productionSourcesUnchanged": True, "flags": list(FLAGS),
        "expectedFailure": REASON, "nativeAppRun": False,
    }
    write_json(output / "preparation.json", manifest)
    return stage, manifest


def write_json(path, value):
    with path.open("x") as stream:
        json.dump(value, stream, indent=2, sort_keys=True, allow_nan=False)
        stream.write("\n")


def red_valid(code, stdout, stderr):
    """A crash/nonzero exit is never the expected semantic regression."""
    if code != 0:
        return False
    out, err = stdout.splitlines(), stderr.splitlines()
    receipts = [line for line in out if line.startswith(("MUSIC_", "SMOKE_"))
                and not line.startswith("MUSIC_FAILURE_SOURCE:")]
    if receipts != RED_RECEIPTS:
        return False
    fixtures = [line for line in out if line.startswith("MUSIC_FAILURE_SOURCE:")]
    if len(fixtures) != 8:
        return False
    for index, line in enumerate(fixtures):
        if not re.match(rf'^MUSIC_FAILURE_SOURCE: fixture={index} enabled=true ', line):
            return False
    assertion = "SMOKE_STAGE: music " + REASON + " valid=false"
    failure = "SMOKE_STAGE: music failed: " + REASON
    if err.count(assertion) != 1 or err.count(failure) != 1 or err.index(assertion) >= err.index(failure):
        return False
    # The failure must be the first restoration check, after all eight fixtures
    # were genuinely loaded and interrupted. A failure string alone is no proof.
    if [line for line in out + err if REASON in line] != [assertion, failure]:
        return False
    for label in RED_SETUP:
        receipt = "SMOKE_STAGE: music " + label + " valid=true"
        if err.count(receipt) != 8 or any(index >= err.index(assertion)
                                         for index, line in enumerate(err) if line == receipt):
            return False
    for line in out + err:
        if line != line.lstrip() and line.lstrip().startswith(("MUSIC_", "SMOKE_")):
            return False
        if ("valid=false" in line or "music failed:" in line) and line not in (assertion, failure):
            return False
        if re.search(r"fatal error|error:|deadline exceeded|cancelled or fixture|timed out|traceback", line, re.I):
            return False
        if re.search(r"\b[A-Z_]+_FAILED\b", line) and line not in RED_RECEIPTS:
            return False
    return True


def green_valid(code, stdout, stderr):
    return (code == 0 and recovery.receipts_valid(stdout)
            and not re.search(r"valid=false|music failed:|[A-Z_]+_FAILED|fatal error|error:|deadline exceeded|cancelled or fixture",
                              stderr, re.I))


def print_saved_evidence(prefix, observed, completed, *, include_receipts=False):
    """Print bounded saved evidence even when a child times out or cannot build.

    Native green receipts preceding the retained tail are emitted in full once;
    receipts already inside the tail are not duplicated. These processes handle
    only archived source and synthetic fixtures, never user Music/file content.
    """
    for index, stream in enumerate(("stdout", "stderr")):
        path = prefix.with_suffix("." + stream + ".log")
        try:
            with path.open("rb") as source:
                saved_bytes = source.seek(0, os.SEEK_END)
                tail_start = max(0, saved_bytes - DIAGNOSTIC_TAIL_BYTES)
                if include_receipts and index == 0 and tail_start:
                    source.seek(0)
                    preceding = source.read(min(saved_bytes, MAX_LOG_BYTES))
                    position, receipt_bytes = 0, 0
                    for line in preceding.splitlines(keepends=True):
                        if position >= tail_start:
                            break
                        if line.startswith(DIAGNOSTIC_RECEIPT_PREFIXES):
                            if receipt_bytes + len(line) > DIAGNOSTIC_RECEIPT_BYTES:
                                print("LYRICS_REDGREEN_RECEIPTS_TRUNCATED: run=" + prefix.name, flush=True)
                                break
                            print(line.decode("utf-8", errors="replace"), end="" if line.endswith(b"\n") else "\n", flush=True)
                            receipt_bytes += len(line)
                        position += len(line)
                source.seek(tail_start)
                tail = source.read(DIAGNOSTIC_TAIL_BYTES)
            print(f"LYRICS_REDGREEN_LOG_BEGIN: run={prefix.name} stream={stream} "
                  f"observedBytes={observed[index]} savedBytes={saved_bytes} tailBytes={len(tail)} "
                  f"tailTruncated={str(tail_start > 0).lower()} "
                  f"captureTruncated={str(observed[index] > saved_bytes).lower()} "
                  f"streamComplete={str(completed[index]).lower()}", flush=True)
            print(tail.decode("utf-8", errors="replace"), end="" if not tail or tail.endswith(b"\n") else "\n", flush=True)
            print(f"LYRICS_REDGREEN_LOG_END: run={prefix.name} stream={stream}", flush=True)
        except OSError as error:
            # Diagnostics cannot replace the original child/validation result.
            print(f"LYRICS_REDGREEN_LOG_UNAVAILABLE: run={prefix.name} stream={stream} error={error}", flush=True)


def run_process(arguments, cwd, prefix, timeout, *, include_receipts=False):
    """Bound both captured streams while running; kill only our exact child."""
    paths = [prefix.with_suffix(".stdout.log"), prefix.with_suffix(".stderr.log")]
    require(all(not p.exists() for p in paths), "Refusing to overwrite run evidence")
    captured = [bytearray(), bytearray()]
    observed, completed = [0, 0], [False, False]
    try:
        with paths[0].open("xb") as out, paths[1].open("xb") as err:
            process = subprocess.Popen([str(a) for a in arguments], cwd=cwd,
                                       stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            try:
                deadline = time.monotonic() + timeout
                with selectors.DefaultSelector() as selector:
                    selector.register(process.stdout, selectors.EVENT_READ, (0, out))
                    selector.register(process.stderr, selectors.EVENT_READ, (1, err))
                    while selector.get_map():
                        require(time.monotonic() < deadline, f"Owned child exceeded {timeout}s: {prefix.name}")
                        for key, _ in selector.select(min(0.1, max(0, deadline - time.monotonic()))):
                            index, stream = key.data
                            data = os.read(key.fileobj.fileno(), 65536)
                            if not data:
                                completed[index] = True
                                selector.unregister(key.fileobj)
                                continue
                            observed[index] += len(data)
                            room = MAX_LOG_BYTES - len(captured[index])
                            stream.write(data[:room])
                            captured[index].extend(data[:room])
                            require(len(data) <= room, "Child output exceeded bounded log limit: " + prefix.name)
                    code = process.wait(timeout=max(0.001, deadline - time.monotonic()))
            finally:
                if process.poll() is None:
                    process.kill()
                    process.wait(timeout=5)
                process.stdout.close()
                process.stderr.close()
    finally:
        print_saved_evidence(prefix, observed, completed, include_receipts=include_receipts)
    return code, *(bytes(data).decode("utf-8", errors="replace") for data in captured)


def checked_command(arguments, cwd, prefix, timeout):
    code, stdout, stderr = run_process(arguments, cwd, prefix, timeout)
    require(code == 0, f"Build command failed: {prefix.name}; never accepted as expected red")
    require(not re.search(r"\berror:", stdout + stderr, re.I), "Compiler error is not expected red")
    return stdout


def candidate_binding(root):
    binary = root / "dist/Codex Notch Meter.app/Contents/MacOS/CodexNotchMeter"
    metadata = binary.parent.parent / "Resources/build-source.json"
    manifest = common.strict_json(common.bounded_read(metadata).decode())
    commit = common.git(root, "rev-parse", "--verify", "HEAD").decode().strip()
    tree = common.git(root, "rev-parse", "HEAD^{tree}").decode().strip()
    require(manifest.get("commit") == commit and manifest.get("tree") == tree,
            "Packaged candidate is not source-bound to this HEAD and tree")
    require(not common.git(root, "status", "--porcelain", "--untracked-files=no").strip(),
            "Tracked candidate source is dirty")
    require(not common.git(root, "ls-files", "--others", "--exclude-standard", "Sources", "Scripts", "Package.swift").strip(),
            "Untracked candidate build inputs")
    require(os.access(binary, os.X_OK), "Packaged candidate is not executable")
    require(common.bounded_read(root / HARNESS_PATH) == common.git(root, "show", "HEAD:" + HARNESS_PATH),
            "Current harness is not exactly the candidate HEAD harness")
    return binary, {"commit": commit, "tree": tree, "binarySHA256": common.digest(common.bounded_read(binary)),
                    "metadataSHA256": common.digest(common.bounded_read(metadata))}


def run_native(root, output, stage, preparation):
    require(sys.platform == "darwin", "Native red/green requires macOS; preparation and self-tests are offline only")
    candidate, binding = candidate_binding(root)
    checked_command(["swift", "build", "-c", "release", "--product", "CodexNotchMeter"],
                    stage, output / "baseline-build", 600)
    bin_path = checked_command(["swift", "build", "-c", "release", "--show-bin-path"],
                               stage, output / "baseline-bin-path", 60).strip()
    baseline = Path(bin_path) / "CodexNotchMeter"
    require(baseline.resolve().is_relative_to((stage / ".build").resolve())
            and not (stage / ".build").is_symlink() and os.access(baseline, os.X_OK),
            "Baseline executable must remain inside isolated build directory")
    require(common.source_manifest(stage) == preparation["after"], "Baseline production changed during build")
    baseline_sha = common.digest(common.bounded_read(baseline))
    red = run_process([baseline, *FLAGS], stage, output / "baseline-red", recovery.RUN_TIMEOUT_SECONDS)
    require(red_valid(*red), "Baseline did not fail at the unique expected first recovery assertion; inspect bounded logs")
    print("LYRICS_REDGREEN_RED_OK: exactFirstRecoveryAssertion=true normalExit=true", flush=True)
    green = run_process([candidate, *FLAGS], root, output / "candidate-green", recovery.RUN_TIMEOUT_SECONDS,
                        include_receipts=True)
    require(green_valid(*green), "Candidate failed the complete strict recovery receipt contract")
    require(common.source_manifest(stage) == preparation["after"], "Baseline production changed during runs")
    require(candidate_binding(root)[1] == binding, "Candidate source or packaged binary changed during runs")
    require(common.digest(common.bounded_read(baseline)) == baseline_sha, "Baseline binary changed during runs")
    require(common.digest(common.bounded_read(root / HARNESS_PATH)) == preparation["harnessSHA256"],
            "Candidate and baseline used inconsistent harness bytes")
    result = {"schema": 1, "baselineCommit": BASELINE_COMMIT, "candidate": binding,
              "harnessSHA256": preparation["harnessSHA256"], "baselineExecutableSHA256": baseline_sha,
              "flags": list(FLAGS), "expectedFailure": REASON, "expectedRed": True,
              "strictGreen": True, "nativeAppRun": True, "controllerOnly": True,
              "productionSourcesUnchanged": True, "nativeIngress": False, "scanout": False,
              "logs": {path.name: common.digest(common.bounded_read(path)) for path in sorted(output.glob("*.log"))}}
    write_json(output / "result.json", result)
    print("LYRICS_REDGREEN_OK: sameHarnessSHA256=" + preparation["harnessSHA256"]
          + " expectedRed=true strictGreen=true controllerOnly=true scanout=false")


class SelfTests(unittest.TestCase):
    def test_exact_red_and_negative_evidence(self):
        stdout = "\n".join([f"MUSIC_FAILURE_SOURCE: fixture={i} enabled=true synthetic" for i in range(8)] + RED_RECEIPTS)
        setup = "\n".join("SMOKE_STAGE: music " + label + " valid=true" for label in RED_SETUP for _ in range(8))
        stderr = setup + "\nSMOKE_STAGE: music " + REASON + " valid=false\nSMOKE_STAGE: music failed: " + REASON
        self.assertTrue(red_valid(0, stdout, stderr))
        for code, out, err in [
            (1, stdout, stderr), (-9, stdout, stderr), (0, stdout, ""),
            (0, stdout, stderr.replace(REASON, "other reason")),
            (0, stdout, stderr.replace(setup, "")),
            (0, stdout, stderr + "\nSMOKE_STAGE: music " + REASON + " valid=true"),
            (0, stdout, stderr + "\nerror: compile failure"),
            (0, stdout, stderr + "\nSMOKE_STAGE: music bounded 90-second deadline exceeded"),
            (0, stdout, stderr + "\nSMOKE_STAGE: music cancelled or fixture operation failed"),
            (0, stdout, stderr + "\nSMOKE_STAGE: music unrelated valid=false"),
            (0, stdout + "\n" + RED_RECEIPTS[0], stderr),
            (0, stdout.replace(RED_RECEIPTS[1], ""), stderr),
            (0, stdout.replace("fixture=7", "fixture=8"), stderr),
            (0, stdout + "\nMUSIC_LYRICS_RECOVERY_CASE_OK: fake", stderr),
            (0, stdout + "\n SMOKE_OK: forged", stderr),
        ]:
            with self.subTest(code=code, out=out, err=err):
                self.assertFalse(red_valid(code, out, err))

    def test_strict_green(self):
        stdout = "\n".join(recovery.expected_receipts() + [
            "MUSIC_LYRICS_RECOVERY_DONE: checks=240 elapsed=24.250 synthetic=true realPolling=true controllerOnly=true scanout=false",
            recovery.SHUTDOWN_RECEIPT])
        self.assertTrue(green_valid(0, stdout, ""))
        for line in stdout.splitlines():
            self.assertFalse(green_valid(0, stdout.replace(line, "", 1), ""))
        self.assertFalse(green_valid(0, stdout, "SMOKE_STAGE: music wrong valid=false"))
        self.assertFalse(green_valid(1, stdout, ""))
        self.assertFalse(green_valid(0, stdout.replace("controllers=23", "controllers=22"), ""))

    def test_overlay_rejects_production_change_and_different_fixture(self):
        before = {HARNESS_PATH: "old", "production.swift": "unchanged"}
        after = {HARNESS_PATH: "new", "production.swift": "unchanged"}
        self.assertEqual(validate_overlay(before, after, "new"), [HARNESS_PATH])
        for changed, sha in [(dict(after, **{"production.swift": "changed"}), "new"),
                             (after, "other-harness"), (before, "old"),
                             ({HARNESS_PATH: "new"}, "new")]:
            with self.assertRaises(ValidationError):
                validate_overlay(before, changed, sha)

    def test_process_timeout_and_build_error_are_not_red(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            diagnostics = io.StringIO()
            with redirect_stdout(diagnostics):
                with self.assertRaises(ValidationError):
                    run_process([sys.executable, "-c", "import time; print('before timeout', flush=True); time.sleep(2)"],
                                root, root / "timeout", 0.5)
                with self.assertRaises(ValidationError):
                    checked_command([sys.executable, "-c", "print('error: build failed'); raise SystemExit(1)"],
                                    root, root / "compiler", 5)
            report = diagnostics.getvalue()
            self.assertIn("before timeout", report)
            self.assertIn("error: build failed", report)
            for name in ("timeout", "compiler"):
                for stream in ("stdout", "stderr"):
                    self.assertIn(f"LYRICS_REDGREEN_LOG_BEGIN: run={name} stream={stream}", report)
            global MAX_LOG_BYTES
            old_limit = MAX_LOG_BYTES
            try:
                MAX_LOG_BYTES = 128
                diagnostics = io.StringIO()
                with redirect_stdout(diagnostics), self.assertRaises(ValidationError):
                    run_process([sys.executable, "-c", "print('x' * 4096)"], root, root / "oversize", 5)
                self.assertLessEqual((root / "oversize.stdout.log").stat().st_size, 128)
                counts = re.search(r"observedBytes=(\d+) savedBytes=128", diagnostics.getvalue())
                self.assertIsNotNone(counts)
                self.assertGreater(int(counts[1]), 128)
                self.assertIn("captureTruncated=true", diagnostics.getvalue())
            finally:
                MAX_LOG_BYTES = old_limit

    def test_bounded_tails_preserve_all_green_receipts_once(self):
        receipts = recovery.expected_receipts() + [
            "MUSIC_LYRICS_RECOVERY_DONE: checks=240 elapsed=24.250 synthetic=true realPolling=true controllerOnly=true scanout=false",
            recovery.SHUTDOWN_RECEIPT,
        ]
        stdout = ("\n".join(receipts) + "\n" + "a" * (DIAGNOSTIC_TAIL_BYTES + 100) + "\nstdout-tail\n").encode()
        stderr = ("b" * (DIAGNOSTIC_TAIL_BYTES + 100) + "\nstderr-tail\n").encode()
        with tempfile.TemporaryDirectory() as temp:
            prefix = Path(temp) / "candidate-green"
            for stream, data in (("stdout", stdout), ("stderr", stderr)):
                prefix.with_suffix("." + stream + ".log").write_bytes(data)
            diagnostics = io.StringIO()
            with redirect_stdout(diagnostics):
                print_saved_evidence(prefix, [len(stdout), len(stderr)], [True, True], include_receipts=True)
            report = diagnostics.getvalue()
            for receipt in receipts:
                self.assertEqual(report.splitlines().count(receipt), 1)
            self.assertEqual(report.count("tailTruncated=true"), 2)
            self.assertEqual(report.count("captureTruncated=false streamComplete=true"), 2)
            self.assertLess(len(report.encode()), 2 * DIAGNOSTIC_TAIL_BYTES + DIAGNOSTIC_RECEIPT_BYTES + 2048)
            self.assertIn("stdout-tail", report)
            self.assertIn("stderr-tail", report)
            self.assertNotIn("a" * (DIAGNOSTIC_TAIL_BYTES + 1), report)
            self.assertTrue(recovery.receipts_valid(report))

    def test_local_helper_import_does_not_create_bytecode(self):
        self.assertTrue(sys.dont_write_bytecode)
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            scripts = root / "Scripts"
            scripts.mkdir()
            for filename in ("check-native-lyrics-redgreen.py", "check-native-baseline.py", "check-native-lyrics-recovery.py"):
                (scripts / filename).write_bytes((ROOT / "Scripts" / filename).read_bytes())
            environment = dict(os.environ)
            environment.pop("PYTHONDONTWRITEBYTECODE", None)
            result = subprocess.run([sys.executable, "-c",
                                     "import runpy,sys; runpy.run_path(sys.argv[1], run_name='isolated_review'); assert sys.dont_write_bytecode",
                                     str(scripts / "check-native-lyrics-redgreen.py")],
                                    env=environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr.decode(errors="replace"))
            self.assertEqual(list(scripts.rglob("__pycache__")), [])
            self.assertEqual(list(scripts.rglob("*.pyc")), [])

    def test_preparation_keeps_fixed_production_and_has_no_bytecode(self):
        with tempfile.TemporaryDirectory() as temp:
            stage, manifest = prepare(ROOT, Path(temp))
            self.assertEqual(manifest["baselineCommit"], BASELINE_COMMIT)
            self.assertEqual(manifest["changedFiles"], [HARNESS_PATH])
            self.assertEqual(set(manifest["before"]), set(manifest["after"]))
            for path in manifest["before"]:
                if path != HARNESS_PATH:
                    self.assertEqual(manifest["before"][path], manifest["after"][path])
            self.assertEqual(list(stage.rglob("__pycache__")), [])
            self.assertEqual(list(stage.rglob("*.pyc")), [])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--self-test", action="store_true")
    mode.add_argument("--prepare-only", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        result = unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(SelfTests))
        if result.wasSuccessful():
            print("LYRICS_REDGREEN_SELF_TEST_OK: nativeAppRun=false")
        return 0 if result.wasSuccessful() else 1
    try:
        require(args.prepare_only or sys.platform == "darwin", "Native execution requires macOS; use --prepare-only on Linux")
        dist = ROOT / "dist"
        require(not dist.is_symlink(), "Refusing symlinked dist")
        dist.mkdir(exist_ok=True)
        # Retain every attempt separately, including failed build/run evidence.
        output = Path(tempfile.mkdtemp(prefix="lyrics-redgreen-", dir=dist))
        print("LYRICS_REDGREEN_EVIDENCE: " + str(output), flush=True)
        stage, receipt = prepare(ROOT, output)
        print("LYRICS_REDGREEN_PREPARED: baseline=" + BASELINE_COMMIT + " harnessSHA256="
              + receipt["harnessSHA256"] + " changedFiles=MusicRendering.swift productionSourcesUnchanged=true nativeAppRun=false")
        if not args.prepare_only:
            run_native(ROOT, output, stage, receipt)
        return 0
    except (ValidationError, OSError, subprocess.SubprocessError, UnicodeError, ValueError) as error:
        print("LYRICS_REDGREEN_FAILED: " + str(error), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
