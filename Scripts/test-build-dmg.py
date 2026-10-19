#!/usr/bin/env python3
"""Synthetic DMG packaging safety tests; never run native tools or install an app.

Run with: python3 Scripts/test-build-dmg.py
These mocks do not establish that a real macOS image mounts or passes codesign.
Native packaging must still pass separately on macOS.
"""

from contextlib import ExitStack, redirect_stderr, redirect_stdout
import importlib.util
import io
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock


# Import the local test subject without leaving generated files in the source tree.
sys.dont_write_bytecode = True
SPEC = importlib.util.spec_from_file_location(
    "build_dmg", Path(__file__).resolve().with_name("build-dmg.py")
)
dmg = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(dmg)


class PackagingTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="codex-dmg-tests-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.app = self.root / dmg.APP_NAME
        (self.app / "Contents/MacOS").mkdir(parents=True)
        self.executable = self.app / "Contents/MacOS/CodexNotchMeter"
        self.executable.write_bytes(b"Synthetic executable fixture; never run.")
        self.executable.chmod(0o755)
        self.info = {
            "CFBundleIdentifier": "org.codexnotchmeter.app",
            "CFBundleExecutable": "CodexNotchMeter",
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "1.1.0",
            "CFBundleVersion": "17",
            "CodexNotchMeterReleaseVersion": "1.1.0",
            "LSMinimumSystemVersion": "13.0",
        }
        (self.app / "Contents/Info.plist").write_bytes(plistlib.dumps(self.info))
        self.context = ExitStack()
        self.addCleanup(self.context.close)
        # A missed mock fails closed, including when these tests run on macOS.
        self.context.enter_context(mock.patch.object(
            dmg.subprocess, "run",
            side_effect=AssertionError("Synthetic tests must never execute a subprocess"),
        ))
        # Keep fake success markers out of CI logs: only native builds should emit them.
        self.stdout, self.stderr = io.StringIO(), io.StringIO()
        self.context.enter_context(redirect_stdout(self.stdout))
        self.context.enter_context(redirect_stderr(self.stderr))

    @staticmethod
    def native_success(arguments, **_kwargs):
        if arguments[0] == "/usr/bin/lipo":
            return SimpleNamespace(stdout=b"arm64 x86_64\n", stderr=b"")
        return SimpleNamespace(stdout=b"", stderr=b"Signature=adhoc\n")

    def test_manifest_detects_changes(self):
        first = dmg.app_manifest(self.app)
        self.executable.write_bytes(b"Changed synthetic contents")
        self.assertNotEqual(first, dmg.app_manifest(self.app))

    def test_internal_links_allowed(self):
        (self.app / "Contents/alias").symlink_to("MacOS/CodexNotchMeter")
        self.assertEqual(
            dmg.app_manifest(self.app)["Contents/alias"],
            ("link", "MacOS/CodexNotchMeter"),
        )

    def test_external_link_rejected(self):
        (self.app / "Contents/alias").symlink_to("/Applications")
        with self.assertRaisesRegex(RuntimeError, "escapes"):
            dmg.app_manifest(self.app)

    def test_special_file_rejected(self):
        os.mkfifo(self.app / "Contents/fifo")
        with self.assertRaisesRegex(RuntimeError, "Unsupported"):
            dmg.app_manifest(self.app)

    def test_arch_and_signatures(self):
        with mock.patch.object(dmg, "run", side_effect=self.native_success) as calls:
            self.assertEqual(dmg.verify_app(self.app), self.info)
            self.assertEqual(calls.call_count, 5)
            for architecture in ("arm64", "x86_64"):
                self.assertTrue(any(
                    "--verify" in call.args[0] and architecture in call.args[0]
                    for call in calls.call_args_list
                ))

    def test_old_version_rejected_before_native_commands(self):
        self.info["CFBundleShortVersionString"] = "0.1.2"
        (self.app / "Contents/Info.plist").write_bytes(plistlib.dumps(self.info))
        with mock.patch.object(dmg, "run") as calls:
            with self.assertRaisesRegex(RuntimeError, "1.1.0"):
                dmg.verify_app(self.app)
            calls.assert_not_called()

    def test_missing_or_wrong_build_rejected_before_native_commands(self):
        for build in (None, "", "16", "18", 17):
            with self.subTest(build=build):
                if build is None:
                    self.info.pop("CFBundleVersion", None)
                else:
                    self.info["CFBundleVersion"] = build
                (self.app / "Contents/Info.plist").write_bytes(plistlib.dumps(self.info))
                with mock.patch.object(dmg, "run") as calls:
                    with self.assertRaisesRegex(RuntimeError, "Expected application build 17"):
                        dmg.verify_app(self.app)
                    calls.assert_not_called()

    def test_missing_or_wrong_release_identity_rejected_before_native_commands(self):
        for label in (None, "1.0.0-beta.1", "1.0.0"):
            with self.subTest(label=label):
                if label is None:
                    self.info.pop("CodexNotchMeterReleaseVersion", None)
                else:
                    self.info["CodexNotchMeterReleaseVersion"] = label
                (self.app / "Contents/Info.plist").write_bytes(plistlib.dumps(self.info))
                with mock.patch.object(dmg, "run") as calls:
                    with self.assertRaisesRegex(RuntimeError, "Expected the Codex Notch Meter"):
                        dmg.verify_app(self.app)
                    calls.assert_not_called()

    def test_nonuniversal_rejected(self):
        result = SimpleNamespace(stdout=b"arm64", stderr=b"")
        with mock.patch.object(dmg, "run", return_value=result):
            with self.assertRaisesRegex(RuntimeError, "exactly"):
                dmg.verify_app(self.app)

    def test_wrong_signing_rejected(self):
        def result(arguments, **_kwargs):
            if arguments[0] == "/usr/bin/lipo":
                return self.native_success(arguments)
            return SimpleNamespace(stdout=b"", stderr=b"Authority=Developer ID\n")

        with mock.patch.object(dmg, "run", side_effect=result):
            with self.assertRaisesRegex(RuntimeError, "ad-hoc"):
                dmg.verify_app(self.app)

    def make_publish_inputs(self):
        work = self.root / "work"
        work.mkdir()
        image = work / dmg.IMAGE_NAME
        image.write_bytes(b"Fake image, not mountable")
        checksum = work / f"{dmg.IMAGE_NAME}.sha256"
        checksum.write_text("Synthetic checksum", encoding="ascii")
        return image, checksum

    def test_publish_exclusive_checksum_and_zip_preservation(self):
        image, checksum = self.make_publish_inputs()
        zipfile = self.root / "unchanged.zip"
        zipfile.write_bytes(b"Original synthetic ZIP")
        dmg.publish(image, checksum, self.root)
        self.assertTrue(os.path.samefile(image, self.root / dmg.IMAGE_NAME))
        self.assertEqual(zipfile.read_bytes(), b"Original synthetic ZIP")
        with self.assertRaisesRegex(RuntimeError, "replace"):
            dmg.publish(image, checksum, self.root)

    def test_failed_second_publish_removes_only_owned_first_link(self):
        image, checksum = self.make_publish_inputs()
        original_link = os.link

        def link(source, destination):
            if str(destination).endswith(".sha256"):
                raise OSError("Synthetic publication failure")
            original_link(source, destination)

        with mock.patch.object(dmg.os, "link", side_effect=link):
            with self.assertRaises(OSError):
                dmg.publish(image, checksum, self.root)
        self.assertFalse((self.root / dmg.IMAGE_NAME).exists())
        self.assertTrue(image.exists())

    def test_cleanup_detaches_only_identified_owned_disk(self):
        record = {"system-entities": [
            {"dev-entry": "/dev/disk123"},
            {"dev-entry": "/dev/disk123s1", "mount-point": str(self.root / "mount")},
        ]}
        with ExitStack() as stack:
            stack.enter_context(mock.patch.object(dmg, "owned_images", side_effect=[[record], []]))
            stack.enter_context(mock.patch.object(dmg.os.path, "ismount", return_value=False))
            calls = stack.enter_context(mock.patch.object(dmg, "run"))
            dmg.detach_owned(self.root / "ours.dmg", self.root / "mount")
            calls.assert_called_once_with(
                ["/usr/bin/hdiutil", "detach", "/dev/disk123"], timeout=30,
            )

    def test_cleanup_refuses_unowned_mount(self):
        with ExitStack() as stack:
            stack.enter_context(mock.patch.object(dmg, "owned_images", return_value=[]))
            stack.enter_context(mock.patch.object(dmg.os.path, "ismount", return_value=True))
            calls = stack.enter_context(mock.patch.object(dmg, "run"))
            with self.assertRaisesRegex(RuntimeError, "owned-image"):
                dmg.detach_owned(self.root / "ours.dmg", self.root / "mount")
            calls.assert_not_called()

    def test_owned_images_filters_other_images(self):
        ours = self.root / "ours.dmg"
        data = {"images": [
            {"image-path": str(ours)},
            {"image-path": str(self.root / "unrelated.dmg")},
            {"image-path": "relative.dmg"},
        ]}
        result = SimpleNamespace(stdout=plistlib.dumps(data))
        with mock.patch.object(dmg, "run", return_value=result):
            self.assertEqual(dmg.owned_images(ours), [{"image-path": str(ours)}])

    def test_run_is_bounded_without_shell_or_input(self):
        result = SimpleNamespace(returncode=0, stdout=b"", stderr=b"")
        with mock.patch.object(dmg.subprocess, "run", return_value=result) as call:
            dmg.run(["/usr/bin/hdiutil", "verify", "owned.dmg"], timeout=90)
            self.assertEqual(call.call_args.kwargs["timeout"], 90)
            self.assertEqual(call.call_args.kwargs["stdin"], subprocess.DEVNULL)
            self.assertNotIn("shell", call.call_args.kwargs)

    def setup_mock_mount(self, readonly=True):
        mount = self.root / "mount"
        mount.mkdir()
        shutil.move(str(self.app), mount / dmg.APP_NAME)
        (mount / "Applications").symlink_to("/Applications")
        (mount / dmg.INSTRUCTIONS_NAME).write_bytes(dmg.INSTRUCTIONS)
        image = self.root / "test.dmg"
        image.write_bytes(b"Fake final image, not mountable")
        manifest = dmg.app_manifest(mount / dmg.APP_NAME)

        def native(arguments, **_kwargs):
            if "imageinfo" in arguments:
                stdout = plistlib.dumps({"Format": "UDZO"})
            elif "attach" in arguments:
                stdout = plistlib.dumps({"system-entities": [{"mount-point": str(mount)}]})
            else:
                stdout = b""
            return SimpleNamespace(stdout=stdout, stderr=b"")

        self.context.enter_context(mock.patch.object(dmg, "run", side_effect=native))
        self.context.enter_context(mock.patch.object(dmg.os.path, "ismount", return_value=True))
        flags = SimpleNamespace(f_flag=os.ST_RDONLY if readonly else 0)
        self.context.enter_context(mock.patch.object(dmg.os, "statvfs", return_value=flags))
        self.context.enter_context(mock.patch.object(dmg, "verify_app", return_value=self.info))
        return mount, image, manifest

    def test_mounted_payload_contract(self):
        mount, image, manifest = self.setup_mock_mount()
        dmg.verify_image(image, mount, manifest)
        self.assertIn("DMG_VERIFY_OK:", self.stdout.getvalue())

    def test_readwrite_mount_rejected(self):
        mount, image, manifest = self.setup_mock_mount(readonly=False)
        with self.assertRaisesRegex(RuntimeError, "read-only"):
            dmg.verify_image(image, mount, manifest)

    def test_wrong_applications_link_rejected(self):
        mount, image, manifest = self.setup_mock_mount()
        (mount / "Applications").unlink()
        (mount / "Applications").symlink_to("/tmp")
        with self.assertRaisesRegex(RuntimeError, "exact target"):
            dmg.verify_image(image, mount, manifest)

    def test_modified_instructions_rejected(self):
        mount, image, manifest = self.setup_mock_mount()
        (mount / dmg.INSTRUCTIONS_NAME).write_bytes(b"Changed instructions")
        with self.assertRaisesRegex(RuntimeError, "instructions"):
            dmg.verify_image(image, mount, manifest)

    def run_main_simulation(self, fail_attach=False, fail_detach=False):
        root = self.root / "repo"
        (root / "Scripts").mkdir(parents=True)
        destination = root / "dist"
        destination.mkdir()
        shutil.move(str(self.app), destination / dmg.APP_NAME)
        original = dmg.app_manifest(destination / dmg.APP_NAME)
        zipfile = destination / "original.zip"
        zipfile.write_bytes(b"Untouched synthetic ZIP")
        state = {"attached": False}

        def native(arguments, **_kwargs):
            arguments = [str(argument) for argument in arguments]
            if arguments[0] in ("/usr/bin/lipo", "/usr/bin/codesign"):
                return self.native_success(arguments)
            if arguments[0] == "/usr/bin/ditto":
                shutil.copytree(arguments[1], arguments[2], symlinks=True)
                stdout = b""
            elif arguments[1] == "create":
                state["image"] = Path(arguments[-1])
                state["stage"] = Path(arguments[arguments.index("-srcfolder") + 1])
                state["image"].write_bytes(b"Final mock image, not mountable")
                stdout = b""
            elif arguments[1] == "imageinfo":
                stdout = plistlib.dumps({"Format": "UDZO"})
            elif arguments[1] == "verify":
                stdout = b""
            elif arguments[1] == "attach":
                self.assertIn("-readonly", arguments)
                self.assertIn("-nobrowse", arguments)
                self.assertIn("-noautoopen", arguments)
                state["mount"] = Path(arguments[arguments.index("-mountpoint") + 1])
                state["attached"] = True
                shutil.copytree(state["stage"], state["mount"], symlinks=True, dirs_exist_ok=True)
                if fail_attach:
                    raise subprocess.TimeoutExpired(arguments, 60)
                stdout = plistlib.dumps({"system-entities": [{"mount-point": str(state["mount"])}]})
            elif arguments[1] == "info":
                records = []
                if state["attached"]:
                    records.append({
                        "image-path": str(state["image"]),
                        "system-entities": [
                            {"dev-entry": "/dev/disk123"},
                            {"mount-point": str(state["mount"])},
                        ],
                    })
                stdout = plistlib.dumps({"images": records})
            elif arguments[1] == "detach":
                if fail_detach:
                    raise RuntimeError("Synthetic detach failure")
                self.assertEqual(arguments, ["/usr/bin/hdiutil", "detach", "/dev/disk123"])
                state["attached"] = False
                stdout = b""
            else:
                raise AssertionError(f"Unexpected native command: {arguments}")
            return SimpleNamespace(stdout=stdout, stderr=b"")

        with ExitStack() as stack:
            stack.enter_context(mock.patch.object(dmg, "__file__", str(root / "Scripts/build-dmg.py")))
            stack.enter_context(mock.patch.object(dmg.sys, "platform", "darwin"))
            stack.enter_context(mock.patch.object(dmg.sys, "argv", ["build-dmg.py"]))
            stack.enter_context(mock.patch.object(dmg, "run", side_effect=native))
            stack.enter_context(mock.patch.object(
                dmg.os.path, "ismount",
                side_effect=lambda path: state["attached"] and Path(path) == state.get("mount"),
            ))
            stack.enter_context(mock.patch.object(
                dmg.os, "statvfs", return_value=SimpleNamespace(f_flag=os.ST_RDONLY),
            ))
            if fail_attach or fail_detach:
                with self.assertRaises((RuntimeError, subprocess.TimeoutExpired)):
                    dmg.main()
                self.assertFalse((destination / dmg.IMAGE_NAME).exists())
                self.assertNotIn("DMG_CLEANUP_OK:", self.stdout.getvalue())
            else:
                dmg.main()
                checksum = (destination / f"{dmg.IMAGE_NAME}.sha256").read_text(encoding="ascii")
                digest = dmg.sha256(destination / dmg.IMAGE_NAME, dmg.MAX_IMAGE_BYTES)
                self.assertEqual(checksum, f"{digest}  {dmg.IMAGE_NAME}\n")
                output = self.stdout.getvalue()
                self.assertEqual(output.count("DMG_CLEANUP_OK:"), 1)
                self.assertLess(output.index("DMG_VERIFY_OK:"), output.index("DMG_CLEANUP_OK:"))
                self.assertFalse(state["attached"])
        self.assertEqual(zipfile.read_bytes(), b"Untouched synthetic ZIP")
        self.assertEqual(dmg.app_manifest(destination / dmg.APP_NAME), original)
        temporary = list(destination.glob(".codex-notch-dmg-*"))
        self.assertEqual(len(temporary), 1 if fail_detach else 0)

    def test_full_packaging_flow(self):
        self.run_main_simulation()

    def test_partial_attach_timeout_is_cleaned(self):
        self.run_main_simulation(fail_attach=True)

    def test_failed_detach_preserves_private_files(self):
        self.run_main_simulation(fail_detach=True)


if __name__ == "__main__":
    print("DMG safety tests: synthetic mocks only; no native tools or applications are run.", flush=True)
    unittest.main()
