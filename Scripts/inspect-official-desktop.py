#!/usr/bin/env python3
"""Bounded, read-only official desktop artifact check; never execute downloaded code."""
import hashlib
import os
from pathlib import Path
import plistlib
import shutil
import signal
import sys
import subprocess
import tempfile
import time

URL = "https://persistent.oaistatic.com/codex-app-prod/Codex.dmg"
MAXIMUM = 1_073_741_824
TEST_COMMAND = [
    "swift", "test", "--filter",
    "OfficialDesktopArtifactTests.testOfficialMountedDesktopResolvesWithinProductionDeadline",
]
TEST_TIMEOUT = 150
TAIL_BYTES = 100_000
RETIRE_TIMEOUT = 3


def print_test_tails(stdout, stderr):
    """TimeoutExpired may contain bytes even when Popen uses text mode."""
    for name, value in (("stdout", stdout), ("stderr", stderr)):
        data = value if isinstance(value, bytes) else (value or "").encode("utf-8", errors="replace")
        tail = data[-TAIL_BYTES:]
        print(f"OFFICIAL_TEST_LOG_BEGIN: stream={name} observedBytes={len(data)} tailBytes={len(tail)}", flush=True)
        print(tail.decode("utf-8", errors="replace"), flush=True)
        print(f"OFFICIAL_TEST_LOG_END: stream={name}", flush=True)


def retire_test_group(process, stdout, stderr):
    """Only this Popen's new session/group is signalled; never search by name."""
    def signal_group(sig):
        try:
            os.killpg(process.pid, sig)
        except ProcessLookupError:
            pass  # The entire owned group has already exited.
        except OSError as error:
            print(f"OFFICIAL_TEST_RETIRE_FAILED: signal={sig} {error}", file=sys.stderr, flush=True)

    if process.returncode is None:
        # Do not poll, wait, or communicate between these signals: retaining the
        # unreaped session leader pins its PID/PGID, preventing group-ID reuse.
        signal_group(signal.SIGTERM)
        try:
            time.sleep(RETIRE_TIMEOUT)
        finally:
            signal_group(signal.SIGKILL)
    else:
        # An already-reaped leader no longer proves ownership of that numeric
        # group ID. Never risk signalling a different process group.
        print("OFFICIAL_TEST_RETIRE_FAILED: leader-already-reaped; group-signals-skipped",
              file=sys.stderr, flush=True)
    try:
        stdout, stderr = process.communicate(timeout=RETIRE_TIMEOUT)
    except subprocess.TimeoutExpired as error:
        stdout = error.output if error.output is not None else stdout
        stderr = error.stderr if error.stderr is not None else stderr
        for stream in (process.stdout, process.stderr):
            if stream is not None:
                try:
                    stream.close()
                except OSError as close_error:
                    print(f"OFFICIAL_TEST_RETIRE_FAILED: close-pipe {close_error}", file=sys.stderr, flush=True)
        try:
            process.wait(timeout=RETIRE_TIMEOUT)
        except Exception as reap_error:
            print(f"OFFICIAL_TEST_RETIRE_FAILED: reap {reap_error}", file=sys.stderr, flush=True)
    except Exception as error:
        print(f"OFFICIAL_TEST_RETIRE_FAILED: kill-wait {error}", file=sys.stderr, flush=True)
        try:
            process.wait(timeout=RETIRE_TIMEOUT)
        except Exception as reap_error:
            print(f"OFFICIAL_TEST_RETIRE_FAILED: reap {reap_error}", file=sys.stderr, flush=True)
    return stdout, stderr


def run_official_test(environment):
    process = subprocess.Popen(TEST_COMMAND, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               text=True, env=environment, start_new_session=True)
    try:
        stdout, stderr = process.communicate(timeout=TEST_TIMEOUT)
    except BaseException as error:
        if isinstance(error, subprocess.TimeoutExpired):
            print(f"OFFICIAL_TEST_TIMEOUT: deadline={TEST_TIMEOUT} ownedProcessGroup={process.pid}", flush=True)
        else:
            print(f"OFFICIAL_TEST_ABORT: {type(error).__name__} ownedProcessGroup={process.pid}", flush=True)
        stdout, stderr = retire_test_group(process, getattr(error, "output", None), getattr(error, "stderr", None))
        print_test_tails(stdout, stderr)
        raise  # Preserve the timeout or other original test failure unchanged.
    print_test_tails(stdout, stderr)
    if process.returncode != 0 or "OFFICIAL_DISCOVERY_OK:" not in stdout:
        raise RuntimeError("Official helper discovery test failed or did not execute")


def cleanup(work, mount, mounted, primary_error):
    try:
        if mounted:
            detached = subprocess.run(["/usr/bin/hdiutil", "detach", str(mount)], timeout=30)
            if detached.returncode != 0:
                raise RuntimeError("Read-only official volume did not detach cleanly")
        # Never remove a still-mounted tree after a failed detach.
        shutil.rmtree(work)
    except Exception as error:
        if primary_error is None:
            raise
        print(f"OFFICIAL_INSPECTION_CLEANUP_FAILED: {type(error).__name__}: {error}; "
              f"preserving {type(primary_error).__name__}; retainedWork={work}", file=sys.stderr, flush=True)
        if hasattr(primary_error, "add_note"):
            primary_error.add_note(f"Official inspection cleanup also failed: {error}")


def inspect():
    work = Path(tempfile.mkdtemp(prefix="codex-official-inspection-"))
    image = work / "Codex.dmg"
    mount = work / "readonly-volume"
    mount.mkdir()
    mounted = False
    primary_error = None
    try:
        subprocess.run([
            "/usr/bin/curl", "--fail", "--silent", "--show-error", "--proto", "=https",
            "--max-time", "120", "--max-filesize", str(MAXIMUM), "--output", str(image), URL,
        ], check=True, timeout=125)
        if not 0 < image.stat().st_size <= MAXIMUM:
            raise RuntimeError("Official DMG exceeded the bounded download size")
        digest = hashlib.sha256()
        with image.open("rb") as source:
            for chunk in iter(lambda: source.read(1_048_576), b""):
                digest.update(chunk)
        print(f"Official DMG: {image.stat().st_size} bytes; SHA256 {digest.hexdigest()}", flush=True)
        # readonly prevents installation or bundle mutation; nobrowse never opens the desktop app.
        # Attempt detachment even if hdiutil times out after the volume became mounted.
        mounted = True
        subprocess.run([
            "/usr/bin/hdiutil", "attach", "-readonly", "-nobrowse", "-mountpoint", str(mount), str(image),
        ], check=True, timeout=60)
        applications = []
        for app in mount.glob("*.app"):
            if not app.resolve().is_relative_to(mount.resolve()):
                continue
            metadata = (app / "Contents/Info.plist").resolve(strict=True)
            if not metadata.is_relative_to(app.resolve()) or not metadata.is_file():
                raise RuntimeError("Official bundle metadata escaped its application or is not a regular file")
            with metadata.open("rb") as source:
                data = source.read(65_537)
            if len(data) > 65_536:
                continue
            info = plistlib.loads(data)
            if info.get("CFBundleIdentifier") == "com.openai.codex":
                applications.append((app, info))
        if len(applications) != 1:
            raise RuntimeError("Expected exactly one official desktop identity in the mounted DMG")
        app, info = applications[0]
        print(f"Official bundle: {info['CFBundleIdentifier']}; version {info.get('CFBundleShortVersionString', 'missing')}", flush=True)
        environment = os.environ.copy()
        environment["CODEX_TEST_OFFICIAL_APP"] = str(app)
        environment["CODEX_PUBLIC_ARTIFACT_TRACE"] = "1"
        # The test calls the production bounded signature/helper resolver, not app-server.
        run_official_test(environment)
    except BaseException as error:
        primary_error = error
        raise
    finally:
        cleanup(work, mount, mounted, primary_error)


def self_test():
    """Only mocked processes/filesystem cleanup; never downloads or mounts."""
    import contextlib
    import io
    import unittest
    from unittest.mock import Mock, call, patch

    class Checks(unittest.TestCase):
        def process(self, effects, returncode=0):
            process = Mock(pid=7319, returncode=returncode)
            process.communicate.side_effect = effects
            return process

        def test_success_owns_session_and_keeps_deadline(self):
            process = self.process([("OFFICIAL_DISCOVERY_OK: fixture", "diagnostic")])
            with patch.object(subprocess, "Popen", return_value=process) as popen, \
                 patch.object(os, "killpg") as killpg, contextlib.redirect_stdout(io.StringIO()) as output:
                run_official_test({"FIXTURE": "yes"})
            popen.assert_called_once_with(TEST_COMMAND, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                text=True, env={"FIXTURE": "yes"}, start_new_session=True)
            process.communicate.assert_called_once_with(timeout=150)
            killpg.assert_not_called()
            self.assertIn("OFFICIAL_DISCOVERY_OK: fixture", output.getvalue())
            self.assertIn("diagnostic", output.getvalue())

        def test_missing_receipt_and_nonzero_still_fail(self):
            for stdout, code in (("no receipt", 0), ("OFFICIAL_DISCOVERY_OK:", 1)):
                with self.subTest(code=code), patch.object(subprocess, "Popen",
                    return_value=self.process([(stdout, "")], code)), contextlib.redirect_stdout(io.StringIO()):
                    with self.assertRaisesRegex(RuntimeError, "failed or did not execute"):
                        run_official_test({})

        def test_timeout_signals_before_reaping_and_keeps_original(self):
            primary = subprocess.TimeoutExpired(TEST_COMMAND, 150, output=b"initial", stderr=b"initial-error")
            process = self.process([primary, ("final-output", "final-error")], returncode=None)
            history = Mock()
            history.attach_mock(process.communicate, "communicate")
            with patch.object(subprocess, "Popen", return_value=process), patch.object(os, "killpg") as killpg, \
                 patch.object(time, "sleep") as sleep, contextlib.redirect_stdout(io.StringIO()) as output:
                history.attach_mock(killpg, "killpg"); history.attach_mock(sleep, "sleep")
                with self.assertRaises(subprocess.TimeoutExpired) as raised:
                    run_official_test({})
            self.assertIs(raised.exception, primary)
            self.assertEqual(history.mock_calls, [call.communicate(timeout=150),
                call.killpg(7319, signal.SIGTERM), call.sleep(3), call.killpg(7319, signal.SIGKILL),
                call.communicate(timeout=3)])
            self.assertIn("final-output", output.getvalue()); self.assertIn("final-error", output.getvalue())
            self.assertIn("deadline=150", output.getvalue())

        def test_unclosed_pipes_are_closed_and_direct_child_reaped(self):
            primary = subprocess.TimeoutExpired(TEST_COMMAND, 150)
            late = subprocess.TimeoutExpired(TEST_COMMAND, 3, output=b"captured", stderr=b"captured-error")
            process = self.process([primary, late], returncode=None)
            with patch.object(subprocess, "Popen", return_value=process), patch.object(os, "killpg"), \
                 patch.object(time, "sleep"), contextlib.redirect_stdout(io.StringIO()) as output:
                with self.assertRaises(subprocess.TimeoutExpired) as raised:
                    run_official_test({})
            self.assertIs(raised.exception, primary)
            process.stdout.close.assert_called_once(); process.stderr.close.assert_called_once()
            process.wait.assert_called_once_with(timeout=3)
            self.assertIn("captured-error", output.getvalue())

        def test_retirement_errors_never_replace_timeout(self):
            primary = subprocess.TimeoutExpired(TEST_COMMAND, 150, output=b"original-tail")
            for signal_error in (ProcessLookupError("already-exited"), OSError("signal-failed")):
                with self.subTest(signal_error=type(signal_error).__name__):
                    late = subprocess.TimeoutExpired(TEST_COMMAND, 3)
                    process = self.process([primary, late], returncode=None)
                    process.stdout.close.side_effect = OSError("close-failed")
                    process.wait.side_effect = subprocess.TimeoutExpired(TEST_COMMAND, 3)
                    with patch.object(subprocess, "Popen", return_value=process), \
                         patch.object(os, "killpg", side_effect=signal_error), patch.object(time, "sleep"), \
                         contextlib.redirect_stdout(io.StringIO()) as output, \
                         contextlib.redirect_stderr(io.StringIO()):
                        with self.assertRaises(subprocess.TimeoutExpired) as raised:
                            run_official_test({})
                    self.assertIs(raised.exception, primary)
                    process.wait.assert_called_once_with(timeout=3)
                    self.assertIn("original-tail", output.getvalue())

        def test_reaped_leader_never_signals_potentially_reused_group(self):
            primary = subprocess.TimeoutExpired(TEST_COMMAND, 150, output=b"initial")
            process = self.process([primary, ("final", "")], returncode=0)
            with patch.object(subprocess, "Popen", return_value=process), patch.object(os, "killpg") as killpg, \
                 patch.object(time, "sleep") as sleep, contextlib.redirect_stdout(io.StringIO()), \
                 contextlib.redirect_stderr(io.StringIO()) as errors:
                with self.assertRaises(subprocess.TimeoutExpired) as raised:
                    run_official_test({})
            self.assertIs(raised.exception, primary)
            killpg.assert_not_called(); sleep.assert_not_called()
            self.assertIn("leader-already-reaped", errors.getvalue())

        def test_non_timeout_failures_also_retire_and_preserve_primary(self):
            errors = (OSError("read-failed"), UnicodeDecodeError("utf-8", b"\xff", 0, 1, "invalid"), KeyboardInterrupt())
            for primary in errors:
                with self.subTest(error=type(primary).__name__):
                    process = self.process([primary, ("partial-output", "partial-error")], returncode=None)
                    with patch.object(subprocess, "Popen", return_value=process), \
                         patch.object(os, "killpg") as killpg, patch.object(time, "sleep"), \
                         contextlib.redirect_stdout(io.StringIO()):
                        with self.assertRaises(type(primary)) as raised:
                            run_official_test({})
                    self.assertIs(raised.exception, primary)
                    self.assertEqual(killpg.call_args_list, [call(7319, signal.SIGTERM), call(7319, signal.SIGKILL)])
                    self.assertEqual(process.communicate.call_args_list, [call(timeout=150), call(timeout=3)])

        def test_tail_output_is_bounded_and_decodes_timeout_bytes(self):
            with contextlib.redirect_stdout(io.StringIO()) as output:
                print_test_tails(b"DISCARDED" + b"a" * TAIL_BYTES, b"error\xff")
            text = output.getvalue()
            self.assertNotIn("DISCARDED", text)
            self.assertIn(f"tailBytes={TAIL_BYTES}", text)
            self.assertIn("error\ufffd", text)
            self.assertLess(len(text), TAIL_BYTES + 500)

        def test_clean_detach_then_remove(self):
            with patch.object(subprocess, "run", return_value=Mock(returncode=0)) as run, \
                 patch.object(shutil, "rmtree") as remove:
                cleanup(Path("/owned-work"), Path("/owned-work/mount"), True, None)
            run.assert_called_once_with(["/usr/bin/hdiutil", "detach", "/owned-work/mount"], timeout=30)
            remove.assert_called_once_with(Path("/owned-work"))

        def test_busy_detach_preserves_primary_and_retains_work(self):
            primary = subprocess.TimeoutExpired(TEST_COMMAND, 150)
            with patch.object(subprocess, "run", return_value=Mock(returncode=16)), \
                 patch.object(shutil, "rmtree") as remove, contextlib.redirect_stderr(io.StringIO()) as errors:
                with self.assertRaises(subprocess.TimeoutExpired) as raised:
                    try:
                        raise primary
                    finally:
                        cleanup(Path("/owned-work"), Path("/owned-work/mount"), True, primary)
            self.assertIs(raised.exception, primary)
            remove.assert_not_called()
            self.assertIn("preserving TimeoutExpired", errors.getvalue())

        def test_cleanup_failure_without_primary_still_fails(self):
            with patch.object(subprocess, "run", return_value=Mock(returncode=16)), \
                 patch.object(shutil, "rmtree") as remove:
                with self.assertRaisesRegex(RuntimeError, "did not detach"):
                    cleanup(Path("/owned-work"), Path("/owned-work/mount"), True, None)
            remove.assert_not_called()

        def test_detach_timeout_or_remove_failure_preserves_primary(self):
            primary = RuntimeError("original-failure")
            for mounted in (True, False):
                with self.subTest(mounted=mounted), \
                     patch.object(subprocess, "run", side_effect=subprocess.TimeoutExpired("detach", 30)), \
                     patch.object(shutil, "rmtree", side_effect=OSError("remove-failure")), \
                     contextlib.redirect_stderr(io.StringIO()) as errors:
                    cleanup(Path("/owned-work"), Path("/owned-work/mount"), mounted, primary)
                self.assertIn("preserving RuntimeError", errors.getvalue())

    suite = unittest.defaultTestLoader.loadTestsFromTestCase(Checks)
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    if result.wasSuccessful():
        print(f"OFFICIAL_INSPECTION_SELF_TEST_OK: tests={result.testsRun} mockedOnly=true")
        return 0
    return 1


if __name__ == "__main__":
    if sys.argv[1:] == ["--self-test"]:
        raise SystemExit(self_test())
    if sys.argv[1:]:
        raise SystemExit("usage: inspect-official-desktop.py [--self-test]")
    inspect()
