#!/usr/bin/env python3
"""Source binding and checksum checks for already-built release files.

This does not build, extract, mount, sign, launch, upload, or publish anything.
An optional release-assets.json records hashes of the existing release assets;
no input asset is changed, and an existing differing manifest is never replaced.
The caller must separately establish that the artifact came from the intended
successful CI run and review that run's actual native PNGs before publication.
A matching manifest is provenance metadata, not a reproducible-build proof.
"""

import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import plistlib
import re
import stat
import subprocess
import sys
import zipfile


APP_NAME = "Codex Notch Meter.app"
MANIFEST_MEMBER = f"{APP_NAME}/Contents/Resources/build-source.json"
PLIST_MEMBER = f"{APP_NAME}/Contents/Info.plist"
MAX_METADATA_BYTES = 65536
MAX_ARCHIVE_BYTES = 256 * 1024 * 1024
MAX_ZIP_ENTRIES = 4096
MAX_PNG_BYTES = 32 * 1024 * 1024
MAX_PNG_FILES = 256
MANIFEST_FIELDS = {"commit", "tree", "run_id", "repository", "version"}


class VerificationError(RuntimeError):
    """An input cannot safely be bound to the requested source or release."""


def require(condition, message):
    if not condition:
        raise VerificationError(message)


def file_size(path, maximum):
    info = path.lstat()
    require(stat.S_ISREG(info.st_mode), f"Expected a regular file: {path.name}")
    require(0 < info.st_size <= maximum, f"Invalid file size: {path.name}")
    return info.st_size


def read_bounded(path, maximum=MAX_METADATA_BYTES):
    file_size(path, maximum)
    with path.open("rb") as source:
        data = source.read(maximum + 1)
    require(0 < len(data) <= maximum, f"Invalid file size: {path.name}")
    return data


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, "Duplicate JSON field")
        result[key] = value
    return result


def parse_manifest(data):
    try:
        value = json.loads(data.decode("utf-8"), object_pairs_hook=unique_object)
    except (UnicodeError, ValueError) as error:
        raise VerificationError("Invalid UTF-8 source manifest JSON") from error
    require(isinstance(value, dict) and set(value) == MANIFEST_FIELDS,
            "Unexpected source manifest fields")
    require(all(isinstance(item, str) for item in value.values()),
            "Source manifest values must all be strings")
    return value


def git_read(checkout, arguments):
    # Disable optional fsmonitor hooks and never execute a checked-out program.
    result = subprocess.run(
        ["git", "-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null",
         "-C", str(checkout), *arguments],
        stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        timeout=15, check=False, text=True,
    )
    require(result.returncode == 0, "Cannot verify the source Git checkout")
    return result.stdout.strip()


def verify_git(checkout, commit):
    require(checkout.is_dir() and not checkout.is_symlink(),
            "Expected a real source checkout directory")
    require(git_read(checkout, ["rev-parse", "--verify", "HEAD"]) == commit,
            "Source checkout HEAD does not match the requested commit")
    tree = git_read(checkout, ["rev-parse", "--verify", "HEAD^{tree}"])
    require(re.fullmatch(r"[0-9a-f]{40}", tree) is not None,
            "Invalid source Git tree")
    # Packaging outputs may be untracked; tracked source must remain unchanged.
    require(not git_read(checkout, ["status", "--porcelain", "--untracked-files=no"]),
            "Source checkout contains changed tracked files")
    return tree


def verify_checksum(path):
    """Parse one exact checksum line; never delegate filenames to a shell."""
    checksum = read_bounded(path.with_name(path.name + ".sha256"))
    try:
        line = checksum.decode("ascii")
    except UnicodeError as error:
        raise VerificationError("Checksum file must be ASCII") from error
    match = re.fullmatch(r"([0-9a-f]{64}) [ *]" + re.escape(path.name) + r"\n?", line)
    require(match is not None, f"Invalid checksum entry for {path.name}")
    actual = hash_file(path, MAX_ARCHIVE_BYTES)["sha256"]
    require(actual == match.group(1), f"SHA-256 mismatch: {path.name}")
    return actual


def hash_file(path, maximum):
    """Hash only bounded regular files, recording the number of bytes read."""
    expected_size = file_size(path, maximum)
    digest = hashlib.sha256()
    total = 0
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            total += len(chunk)
            require(total <= maximum, f"File exceeded size limit: {path.name}")
            digest.update(chunk)
    require(total == expected_size, f"File changed while hashing: {path.name}")
    return {"name": path.name, "bytes": total, "sha256": digest.hexdigest()}


def zip_metadata(archive, name):
    info = archive.getinfo(name)
    require(not info.is_dir(), f"ZIP metadata is a directory: {name}")
    file_type = stat.S_IFMT(info.external_attr >> 16)
    require(file_type in (0, stat.S_IFREG), f"ZIP metadata is not a regular file: {name}")
    require(0 < info.file_size <= MAX_METADATA_BYTES, f"ZIP metadata exceeds size limit: {name}")
    with archive.open(info) as source:
        data = source.read(MAX_METADATA_BYTES + 1)
    require(len(data) == info.file_size, f"ZIP metadata size mismatch: {name}")
    return data


def verify_zip(path, manifest_bytes, version, bundle_build):
    """Read only two bounded metadata entries, without extracting any ZIP member."""
    with zipfile.ZipFile(path) as archive:
        entries = archive.infolist()
        require(0 < len(entries) <= MAX_ZIP_ENTRIES, "Invalid ZIP entry count")
        names = set()
        expanded_bytes = 0
        for info in entries:
            name = info.filename
            parts = PurePosixPath(name).parts
            require(name not in names, "Duplicate ZIP member")
            names.add(name)
            require(bool(parts) and not name.startswith("/") and "\\" not in name
                    and "\x00" not in name and ".." not in parts
                    and str(PurePosixPath(name)) == name.rstrip("/")
                    and parts[0] in (APP_NAME, "__MACOSX"), "Unsafe ZIP member path")
            require(not info.flag_bits & 1, "Encrypted ZIP members are not supported")
            require(info.compress_type in (zipfile.ZIP_STORED, zipfile.ZIP_DEFLATED),
                    "Unsupported ZIP compression")
            expanded_bytes += info.file_size
            require(expanded_bytes <= MAX_ARCHIVE_BYTES, "ZIP expanded size exceeds limit")
        require(MANIFEST_MEMBER in names and PLIST_MEMBER in names,
                "ZIP is missing source or bundle metadata")
        embedded = zip_metadata(archive, MANIFEST_MEMBER)
        require(embedded == manifest_bytes,
                "ZIP embedded source manifest differs from release-source.json")
        try:
            info = plistlib.loads(zip_metadata(archive, PLIST_MEMBER))
        except (ValueError, plistlib.InvalidFileException) as error:
            raise VerificationError("Invalid ZIP Info.plist") from error
        expected = {
            "CFBundleIdentifier": "org.codexnotchmeter.app",
            "CFBundleExecutable": "CodexNotchMeter",
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": version,
            "CFBundleVersion": bundle_build,
            "CodexNotchMeterReleaseVersion": version,
        }
        require(isinstance(info, dict) and all(info.get(key) == value for key, value in expected.items()),
                "ZIP bundle identity, release version or build does not match")


def verify_release(dist, checkout, *, commit, run_id, repository, version, bundle_build):
    require(re.fullmatch(r"[0-9a-f]{40}", commit) is not None, "Expected an exact 40-character commit")
    require(re.fullmatch(r"[1-9][0-9]*", run_id) is not None, "Expected a positive source run ID")
    require(re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository) is not None,
            "Expected an owner/repository name")
    require(re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version) is not None, "Expected a formal release version")
    require(re.fullmatch(r"[1-9][0-9]*", bundle_build) is not None, "Expected a positive bundle build")
    require(dist.is_dir() and not dist.is_symlink(), "Expected a real artifact directory")
    tree = verify_git(checkout, commit)
    expected = {"commit": commit, "tree": tree, "run_id": run_id,
                "repository": repository, "version": version}
    manifest_bytes = read_bounded(dist / "release-source.json")
    require(parse_manifest(manifest_bytes) == expected,
            "Source manifest does not match the requested commit, tree, run, repository or version")
    checksums = {}
    for extension in ("zip", "dmg"):
        path = dist / f"CodexNotchMeter-{version}-universal.{extension}"
        checksums[path.name] = verify_checksum(path)
    verify_zip(dist / f"CodexNotchMeter-{version}-universal.zip", manifest_bytes, version, bundle_build)
    return {"source": expected, "sha256": checksums,
            "source_manifest_sha256": hashlib.sha256(manifest_bytes).hexdigest()}


def write_asset_manifest(dist, output, result, *, require_review_images=False):
    """Record the exact already-verified archives and the native PNG review set.

    A second invocation compares an existing manifest instead of overwriting it.
    PNGs must be root-level perimeter-*.png files. This identifies the evidence
    bytes; it does not substitute for native checks or actual visual review.
    """
    require(output.name == "release-assets.json" and output.parent.resolve() == dist.resolve(),
            "Asset manifest must be release-assets.json inside the artifact directory")
    pngs = sorted(dist.glob("perimeter-*.png"))
    require(len(pngs) <= MAX_PNG_FILES and (bool(pngs) or not require_review_images),
            "Expected a bounded set of native perimeter PNGs")
    assets = []
    for path in pngs:
        require(re.fullmatch(r"perimeter-[A-Za-z0-9._-]+\.png", path.name) is not None,
                "Invalid native PNG filename")
        file_size(path, MAX_PNG_BYTES)
        with path.open("rb") as source:
            require(source.read(8) == b"\x89PNG\r\n\x1a\n", "Native evidence does not have a PNG signature")
        assets.append(hash_file(path, MAX_PNG_BYTES))
    for name, verified_hash in result["sha256"].items():
        require(verify_checksum(dist / name) == verified_hash,
                "Archive changed after release source verification")
        asset = hash_file(dist / name, MAX_ARCHIVE_BYTES)
        require(asset["sha256"] == verified_hash, "Archive changed after release source verification")
        assets.extend([asset, hash_file(dist / (name + ".sha256"), MAX_METADATA_BYTES)])
    source_asset = hash_file(dist / "release-source.json", MAX_METADATA_BYTES)
    require(source_asset["sha256"] == result["source_manifest_sha256"],
            "Source manifest changed after release source verification")
    assets.append(source_asset)
    manifest = result["source"] | {"assets": sorted(assets, key=lambda item: item["name"])}
    encoded = (json.dumps(manifest, sort_keys=True, indent=2) + "\n").encode("utf-8")
    require(len(encoded) <= MAX_METADATA_BYTES, "Asset manifest exceeds metadata limit")
    if output.exists() or output.is_symlink():
        require(read_bounded(output) == encoded, "Existing asset manifest differs; refusing to replace it")
    else:
        # Exclusive create also closes the check/create race for this output path.
        with output.open("xb") as destination:
            destination.write(encoded)
    return manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dist", required=True, type=Path)
    parser.add_argument("--checkout", required=True, type=Path)
    parser.add_argument("--source-commit", required=True)
    parser.add_argument("--source-run-id", required=True)
    parser.add_argument("--repository", required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--bundle-build", required=True)
    parser.add_argument("--asset-manifest", type=Path,
                        help="Create or verify dist/release-assets.json for the original artifacts and PNGs")
    parser.add_argument("--require-review-images", action="store_true",
                        help="Require perimeter PNG evidence when creating or checking the asset manifest")
    args = parser.parse_args()
    try:
        require(not args.require_review_images or args.asset_manifest is not None,
                "--require-review-images requires --asset-manifest")
        result = verify_release(
            args.dist, args.checkout, commit=args.source_commit, run_id=args.source_run_id,
            repository=args.repository, version=args.version, bundle_build=args.bundle_build,
        )
        if args.asset_manifest is not None:
            manifest = write_asset_manifest(
                args.dist, args.asset_manifest, result, require_review_images=args.require_review_images
            )
            result["asset_manifest"] = {"name": args.asset_manifest.name, "asset_count": len(manifest["assets"])}
    except (VerificationError, OSError, ValueError, KeyError, zipfile.BadZipFile,
            subprocess.SubprocessError) as error:
        print(f"Release source verification failed: {error}", file=sys.stderr)
        return 1
    print(json.dumps(result, sort_keys=True, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
