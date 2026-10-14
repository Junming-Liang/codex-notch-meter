#!/usr/bin/env python3
"""Bounded, read-only official desktop artifact check; never execute downloaded code."""
import hashlib
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile

URL = "https://persistent.oaistatic.com/codex-app-prod/Codex.dmg"
MAXIMUM = 1_073_741_824
work = Path(tempfile.mkdtemp(prefix="codex-official-inspection-"))
image = work / "Codex.dmg"
mount = work / "readonly-volume"
mount.mkdir()
mounted = False
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
    result = subprocess.run([
        "swift", "test", "--filter", "OfficialDesktopArtifactTests.testOfficialMountedDesktopResolvesWithinProductionDeadline",
    ], capture_output=True, text=True, env=environment, timeout=150)
    print(result.stdout[-100_000:])
    print(result.stderr[-100_000:])
    if result.returncode != 0 or "OFFICIAL_DISCOVERY_OK:" not in result.stdout:
        raise RuntimeError("Official helper discovery test failed or did not execute")
finally:
    if mounted:
        detached = subprocess.run(["/usr/bin/hdiutil", "detach", str(mount)], timeout=30)
        if detached.returncode != 0:
            raise RuntimeError("Read-only official volume did not detach cleanly")
    shutil.rmtree(work)
