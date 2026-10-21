#!/usr/bin/env python3
"""Synthetic, offline checks for the read-only release-source verifier.

These do not establish that a real DMG mounts, an app runs, CI passed, or native
renderings were visually reviewed. No GitHub, signing or publication calls run.
"""

import hashlib
import importlib.util
import json
from pathlib import Path
import plistlib
import stat
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock
import warnings
import zipfile


sys.dont_write_bytecode = True
SPEC = importlib.util.spec_from_file_location(
    "verify_release_source", Path(__file__).resolve().with_name("verify-release-source.py")
)
verify = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(verify)


class ReleaseSourceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="release-source-tests-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.dist = self.root / "dist"
        self.dist.mkdir()
        self.checkout = self.root / "source"
        self.checkout.mkdir()
        self.commit, self.tree = "a" * 40, "b" * 40
        self.arguments = dict(commit=self.commit, run_id="12345", repository="example/notch",
                              version="1.1.3", bundle_build="20")
        self.manifest = {"commit": self.commit, "tree": self.tree, "run_id": "12345",
                         "repository": "example/notch", "version": "1.1.3"}
        self.manifest_bytes = json.dumps(self.manifest, sort_keys=True).encode() + b"\n"
        self.manifest_path = self.dist / "release-source.json"
        self.manifest_path.write_bytes(self.manifest_bytes)
        self.info = {
            "CFBundleIdentifier": "org.codexnotchmeter.app",
            "CFBundleExecutable": "CodexNotchMeter", "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "1.1.3", "CFBundleVersion": "20",
            "CodexNotchMeterReleaseVersion": "1.1.3",
        }
        self.zip_path = self.dist / "CodexNotchMeter-1.1.3-universal.zip"
        self.dmg_path = self.dist / "CodexNotchMeter-1.1.3-universal.dmg"
        self.dmg_path.write_bytes(b"Synthetic DMG fixture; not a mountable image.")
        self.write_checksum(self.dmg_path)
        self.write_zip()
        # All subprocesses fail closed unless a test explicitly injects Git output.
        self.subprocess = mock.patch.object(
            verify.subprocess, "run", side_effect=AssertionError("No subprocess allowed")
        )
        self.subprocess.start()
        self.addCleanup(self.subprocess.stop)

    def write_checksum(self, path):
        path.with_name(path.name + ".sha256").write_text(
            hashlib.sha256(path.read_bytes()).hexdigest() + "  " + path.name + "\n"
        )

    def write_zip(self, *, embedded=None, omit=None, extra=(), info_bytes=None):
        with warnings.catch_warnings():
            warnings.simplefilter("ignore", UserWarning)
            with zipfile.ZipFile(self.zip_path, "w", compression=zipfile.ZIP_DEFLATED) as archive:
                entries = [
                    (verify.MANIFEST_MEMBER, self.manifest_bytes if embedded is None else embedded),
                    (verify.PLIST_MEMBER, plistlib.dumps(self.info) if info_bytes is None else info_bytes),
                    (f"{verify.APP_NAME}/Contents/MacOS/CodexNotchMeter", b"Never executed"),
                    (f"__MACOSX/{verify.APP_NAME}/Contents/._Info.plist", b"ditto metadata fixture"),
                ]
                for name, data in [*entries, *extra]:
                    if name != omit:
                        archive.writestr(name, data)
        self.write_checksum(self.zip_path)

    def check(self, **overrides):
        with mock.patch.object(verify, "verify_git", return_value=self.tree):
            return verify.verify_release(self.dist, self.checkout, **(self.arguments | overrides))

    def test_exact_source_and_existing_bytes_pass_without_mutation(self):
        before = {path.name: path.read_bytes() for path in self.dist.iterdir()}
        result = self.check()
        self.assertEqual(result["source"], self.manifest)
        self.assertEqual(set(result["sha256"]), {self.zip_path.name, self.dmg_path.name})
        self.assertEqual(before, {path.name: path.read_bytes() for path in self.dist.iterdir()})

    def test_all_manifest_fields_are_bound(self):
        for field in self.manifest:
            with self.subTest(field=field):
                changed = self.manifest | {field: "different"}
                self.manifest_path.write_text(json.dumps(changed))
                with self.assertRaisesRegex(verify.VerificationError, "does not match"):
                    self.check()

    def test_missing_extra_and_nonstring_manifest_fields_fail(self):
        candidates = [self.manifest | {"run_id": 12345}, self.manifest | {"extra": "x"},
                      {key: value for key, value in self.manifest.items() if key != "tree"}, []]
        for candidate in candidates:
            with self.subTest(candidate=candidate):
                self.manifest_path.write_text(json.dumps(candidate))
                with self.assertRaises(verify.VerificationError):
                    self.check()

    def test_duplicate_manifest_field_fails(self):
        self.manifest_path.write_bytes(self.manifest_bytes.rstrip()[:-1] + b', "tree": "other"}')
        with self.assertRaisesRegex(verify.VerificationError, "Duplicate"):
            self.check()

    def test_invalid_json_or_utf8_fails(self):
        for data in (b"{", b"\xff"):
            self.manifest_path.write_bytes(data)
            with self.assertRaisesRegex(verify.VerificationError, "Invalid UTF-8"):
                self.check()

    def test_manifest_must_match_zip_byte_for_byte(self):
        self.write_zip(embedded=json.dumps(self.manifest, indent=2).encode())
        with self.assertRaisesRegex(verify.VerificationError, "differs"):
            self.check()

    def test_both_checksums_are_verified(self):
        for path in (self.zip_path, self.dmg_path):
            with self.subTest(path=path.name):
                original = path.read_bytes()
                path.write_bytes(original + b"Changed")
                with self.assertRaisesRegex(verify.VerificationError, "SHA-256 mismatch"):
                    self.check()
                path.write_bytes(original)

    def test_checksum_cannot_name_another_file_or_multiple_files(self):
        checksum_path = self.dmg_path.with_name(self.dmg_path.name + ".sha256")
        original = checksum_path.read_text()
        for content in (original.replace(self.dmg_path.name, "../outside"), original * 2,
                        original.replace("  ", " "), "not a checksum", original + "extra"):
            checksum_path.write_text(content)
            with self.assertRaisesRegex(verify.VerificationError, "Invalid checksum"):
                self.check()

    def test_binary_checksum_marker_allowed(self):
        checksum_path = self.dmg_path.with_name(self.dmg_path.name + ".sha256")
        checksum_path.write_text(checksum_path.read_text().replace("  ", " *"))
        self.check()

    def test_symlinked_release_file_rejected(self):
        for path in (self.manifest_path, self.zip_path, self.dmg_path,
                     self.dmg_path.with_name(self.dmg_path.name + ".sha256")):
            with self.subTest(path=path.name):
                saved = path.with_name(path.name + ".saved")
                path.rename(saved)
                path.symlink_to(saved)
                with self.assertRaisesRegex(verify.VerificationError, "regular file"):
                    self.check()
                path.unlink()
                saved.rename(path)

    def test_empty_and_oversized_metadata_rejected(self):
        for data in (b"", b"x" * (verify.MAX_METADATA_BYTES + 1)):
            self.manifest_path.write_bytes(data)
            with self.assertRaisesRegex(verify.VerificationError, "Invalid file size"):
                self.check()

    def test_empty_archive_rejected(self):
        self.dmg_path.write_bytes(b"")
        self.write_checksum(self.dmg_path)
        with self.assertRaisesRegex(verify.VerificationError, "Invalid file size"):
            self.check()

    def test_version_and_build_must_match_bundle(self):
        for key in self.info:
            with self.subTest(key=key):
                value = self.info[key]
                self.info[key] = "wrong"
                self.write_zip()
                with self.assertRaisesRegex(verify.VerificationError, "bundle identity"):
                    self.check()
                self.info[key] = value

    def test_missing_zip_metadata_rejected(self):
        for member in (verify.MANIFEST_MEMBER, verify.PLIST_MEMBER):
            self.write_zip(omit=member)
            with self.assertRaisesRegex(verify.VerificationError, "missing"):
                self.check()

    def test_duplicate_zip_member_rejected(self):
        self.write_zip(extra=[(verify.MANIFEST_MEMBER, self.manifest_bytes)])
        with self.assertRaisesRegex(verify.VerificationError, "Duplicate ZIP"):
            self.check()

    def test_unsafe_zip_paths_rejected_without_extraction(self):
        for name in ("../escape", "/absolute", f"{verify.APP_NAME}/../escape",
                     f"{verify.APP_NAME}//alias", f"{verify.APP_NAME}/./alias",
                     f"{verify.APP_NAME}\\alias", "other-root/file"):
            with self.subTest(name=name):
                self.write_zip(extra=[(name, b"unused")])
                with self.assertRaisesRegex(verify.VerificationError, "Unsafe ZIP"):
                    self.check()
        self.assertFalse((self.root / "escape").exists())

    def test_symlinked_zip_metadata_rejected(self):
        self.write_zip(omit=verify.PLIST_MEMBER)
        link = zipfile.ZipInfo(verify.PLIST_MEMBER)
        link.create_system = 3
        link.external_attr = (stat.S_IFLNK | 0o777) << 16
        with zipfile.ZipFile(self.zip_path, "a") as archive:
            archive.writestr(link, "../../outside")
        self.write_checksum(self.zip_path)
        with self.assertRaisesRegex(verify.VerificationError, "not a regular file"):
            self.check()

    def test_oversized_zip_metadata_rejected(self):
        self.write_zip(embedded=b"x" * (verify.MAX_METADATA_BYTES + 1))
        with self.assertRaisesRegex(verify.VerificationError, "metadata exceeds size"):
            self.check()

    def test_zip_entry_and_expanded_size_limits(self):
        with mock.patch.object(verify, "MAX_ZIP_ENTRIES", 1):
            with self.assertRaisesRegex(verify.VerificationError, "entry count"):
                self.check()
        # Exercise the central-directory accounting without allocating a bomb.
        with mock.patch.object(verify, "MAX_ARCHIVE_BYTES", 2):
            with self.assertRaisesRegex(verify.VerificationError, "expanded size"):
                verify.verify_zip(self.zip_path, self.manifest_bytes, "1.1.3", "20")

    def test_unsupported_zip_compression_rejected(self):
        with zipfile.ZipFile(self.zip_path, "a") as archive:
            archive.writestr(f"{verify.APP_NAME}/extra", b"x", compress_type=zipfile.ZIP_BZIP2)
        self.write_checksum(self.zip_path)
        with self.assertRaisesRegex(verify.VerificationError, "Unsupported ZIP compression"):
            self.check()

    def test_invalid_zip_and_plist_fail(self):
        self.zip_path.write_bytes(b"not a zip")
        self.write_checksum(self.zip_path)
        with self.assertRaises(zipfile.BadZipFile):
            self.check()
        self.write_zip(info_bytes=b"not a plist")
        with self.assertRaisesRegex(verify.VerificationError, "Invalid ZIP Info.plist"):
            self.check()

    def test_invalid_input_values_rejected(self):
        for key, values in {"commit": ["main", "a" * 39, "A" * 40, "-" * 40],
                            "run_id": ["0", "12/3", "123;false"],
                            "repository": ["owner", "owner/repo/extra", "owner/repo\n"],
                            "version": ["1.1.3-beta.1", "../1.1.3"],
                            "bundle_build": ["0", "20\n"]}.items():
            for value in values:
                with self.subTest(key=key, value=value):
                    with self.assertRaises(verify.VerificationError):
                        self.check(**{key: value})

    def test_git_head_tree_and_clean_tracked_source_are_checked(self):
        with mock.patch.object(verify, "git_read", side_effect=[self.commit, self.tree, ""]) as calls:
            self.assertEqual(verify.verify_git(self.checkout, self.commit), self.tree)
        self.assertEqual([call.args[1] for call in calls.call_args_list], [
            ["rev-parse", "--verify", "HEAD"], ["rev-parse", "--verify", "HEAD^{tree}"],
            ["status", "--porcelain", "--untracked-files=no"],
        ])

    def test_wrong_git_head_invalid_tree_and_dirty_source_fail(self):
        for outputs, message in [(["c" * 40], "HEAD"),
                                 ([self.commit, "bad-tree"], "Git tree"),
                                 ([self.commit, self.tree, " M source.swift"], "tracked files")]:
            with mock.patch.object(verify, "git_read", side_effect=outputs):
                with self.assertRaisesRegex(verify.VerificationError, message):
                    verify.verify_git(self.checkout, self.commit)

    def test_git_is_bounded_noninteractive_and_hooks_disabled(self):
        with mock.patch.object(verify.subprocess, "run", return_value=SimpleNamespace(
            returncode=0, stdout="value\n", stderr=""
        )) as call:
            self.assertEqual(verify.git_read(self.checkout, ["rev-parse", "HEAD"]), "value")
        arguments, options = call.call_args.args[0], call.call_args.kwargs
        self.assertEqual(arguments[0], "git")
        self.assertIn("core.fsmonitor=false", arguments)
        self.assertIn("core.hooksPath=/dev/null", arguments)
        self.assertEqual(options["timeout"], 15)
        self.assertEqual(options["stdin"], verify.subprocess.DEVNULL)
        self.assertNotIn("shell", options)

    def test_git_failure_fails_closed(self):
        with mock.patch.object(verify.subprocess, "run", return_value=SimpleNamespace(
            returncode=1, stdout="", stderr="private diagnostic not reproduced"
        )):
            with self.assertRaisesRegex(verify.VerificationError, "Cannot verify"):
                verify.git_read(self.checkout, ["rev-parse", "HEAD"])

    def make_pngs(self):
        # Signature fixtures only, not claimed to be native screenshots.
        for name in ("perimeter-closed.png", "perimeter-motion-01.png"):
            (self.dist / name).write_bytes(b"\x89PNG\r\n\x1a\nSynthetic test only")

    def test_asset_manifest_covers_only_exact_release_and_png_assets(self):
        self.make_pngs()
        (self.dist / "unrelated.txt").write_text("Not a release asset")
        (self.dist / "unrelated.png").write_bytes(b"Not selected")
        result = self.check()
        output = self.dist / "release-assets.json"
        manifest = verify.write_asset_manifest(self.dist, output, result)
        self.assertEqual({key: value for key, value in manifest.items() if key != "assets"}, self.manifest)
        self.assertEqual(len(manifest["assets"]), 7)
        names = [asset["name"] for asset in manifest["assets"]]
        self.assertEqual(names, sorted(names))
        self.assertNotIn(output.name, names)
        self.assertNotIn("unrelated.png", names)
        self.assertNotIn("unrelated.txt", names)
        for asset in manifest["assets"]:
            data = (self.dist / asset["name"]).read_bytes()
            self.assertEqual(asset["bytes"], len(data))
            self.assertEqual(asset["sha256"], hashlib.sha256(data).hexdigest())
        self.assertEqual(json.loads(output.read_bytes()), manifest)
        self.assertEqual(verify.write_asset_manifest(self.dist, output, result), manifest)

    def test_asset_manifest_requires_png_evidence(self):
        with self.assertRaisesRegex(verify.VerificationError, "native perimeter PNGs"):
            verify.write_asset_manifest(self.dist, self.dist / "release-assets.json", self.check(),
                                        require_review_images=True)

    def test_asset_manifest_without_pngs_is_allowed_unless_required(self):
        manifest = verify.write_asset_manifest(self.dist, self.dist / "release-assets.json", self.check())
        self.assertEqual(len(manifest["assets"]), 5)

    def test_asset_manifest_rejects_invalid_and_symlink_pngs(self):
        path = self.dist / "perimeter-test.png"
        path.write_bytes(b"Not PNG")
        with self.assertRaisesRegex(verify.VerificationError, "PNG signature"):
            verify.write_asset_manifest(self.dist, self.dist / "release-assets.json", self.check())
        path.unlink()
        path.symlink_to(self.dmg_path)
        with self.assertRaisesRegex(verify.VerificationError, "regular file"):
            verify.write_asset_manifest(self.dist, self.dist / "release-assets.json", self.check())

    def test_asset_manifest_rejects_png_control_characters(self):
        (self.dist / "perimeter-bad\nname.png").write_bytes(b"\x89PNG\r\n\x1a\n")
        with self.assertRaisesRegex(verify.VerificationError, "filename"):
            verify.write_asset_manifest(self.dist, self.dist / "release-assets.json", self.check())

    def test_asset_manifest_never_replaces_differing_file(self):
        self.make_pngs()
        output = self.dist / "release-assets.json"
        output.write_bytes(b"Keep the existing review identity")
        with self.assertRaisesRegex(verify.VerificationError, "refusing to replace"):
            verify.write_asset_manifest(self.dist, output, self.check())
        self.assertEqual(output.read_bytes(), b"Keep the existing review identity")

    def test_asset_manifest_rejects_changes_since_first_record(self):
        self.make_pngs()
        output = self.dist / "release-assets.json"
        result = self.check()
        verify.write_asset_manifest(self.dist, output, result)
        (self.dist / "perimeter-closed.png").write_bytes(b"\x89PNG\r\n\x1a\nChanged")
        with self.assertRaisesRegex(verify.VerificationError, "refusing to replace"):
            verify.write_asset_manifest(self.dist, output, result)

    def test_asset_manifest_rejects_output_outside_dist_or_symlink(self):
        self.make_pngs()
        for output in (self.root / "release-assets.json", self.dist / "other.json"):
            with self.assertRaisesRegex(verify.VerificationError, "inside the artifact directory"):
                verify.write_asset_manifest(self.dist, output, self.check())
        output = self.dist / "release-assets.json"
        output.symlink_to(self.manifest_path)
        with self.assertRaisesRegex(verify.VerificationError, "regular file"):
            verify.write_asset_manifest(self.dist, output, self.check())

    def test_asset_manifest_rejects_changed_archive_after_verification(self):
        self.make_pngs()
        result = self.check()
        self.dmg_path.write_bytes(b"Changed after verification")
        self.write_checksum(self.dmg_path)
        with self.assertRaisesRegex(verify.VerificationError, "Archive changed"):
            verify.write_asset_manifest(self.dist, self.dist / "release-assets.json", result)

    def test_asset_manifest_rechecks_checksum_files(self):
        self.make_pngs()
        result = self.check()
        checksum = self.dmg_path.with_name(self.dmg_path.name + ".sha256")
        checksum.write_text("0" * 64 + "  " + self.dmg_path.name + "\n")
        with self.assertRaisesRegex(verify.VerificationError, "SHA-256 mismatch"):
            verify.write_asset_manifest(self.dist, self.dist / "release-assets.json", result)

    def test_asset_manifest_rejects_changed_source_after_verification(self):
        self.make_pngs()
        result = self.check()
        self.manifest_path.write_text(json.dumps(self.manifest | {"tree": "c" * 40}))
        with self.assertRaisesRegex(verify.VerificationError, "Source manifest changed"):
            verify.write_asset_manifest(self.dist, self.dist / "release-assets.json", result)

    def test_asset_manifest_rejects_reformatted_source_after_verification(self):
        self.make_pngs()
        result = self.check()
        self.manifest_path.write_text(json.dumps(self.manifest, indent=2))
        with self.assertRaisesRegex(verify.VerificationError, "Source manifest changed"):
            verify.write_asset_manifest(self.dist, self.dist / "release-assets.json", result)


if __name__ == "__main__":
    unittest.main()
