#!/usr/bin/env python3
"""Package an existing universal app without installing or launching anything.

Run after: bash Scripts/build-app.sh --universal
Requires macOS and Xcode Command Line Tools; no third-party Python packages.
No Finder AppleEvents, background installers, login registration, or Gatekeeper
changes are used. The existing ZIP and source app are never modified.
"""

import argparse
import hashlib
import os
from pathlib import Path
import plistlib
import re
import shutil
import signal
import stat
import subprocess
import sys
import tempfile


VERSION = "0.1.4"
APP_NAME = "Codex Notch Meter.app"
IMAGE_NAME = f"CodexNotchMeter-{VERSION}-universal.dmg"
INSTRUCTIONS_NAME = "Install - 安装说明.txt"
MAX_APP_BYTES = 128 * 1024 * 1024
MAX_IMAGE_BYTES = 256 * 1024 * 1024
MAX_ENTRIES = 4096
INSTRUCTIONS = f"""CODEX NOTCH METER  {VERSION}
macOS 13+  ·  Apple Silicon + Intel

安装
1. 将 Codex Notch Meter 拖到此窗口中的 Applications 文件夹。
2. 从“应用程序”打开已安装的副本，然后推出此磁盘映像。
3. 如需开机自动启动，请在应用的“设置”中自行开启“登录时启动”。
   此磁盘映像不会自动安装应用，也不会更改登录项。

开发预览：应用仅有 ad-hoc 临时签名，没有 Apple Developer ID 签名，
也未经 Apple 公证。macOS 可能阻止打开。请先确认来源和校验值；
若被阻止，请停止并查看项目发布说明。不要关闭系统安全保护。

INSTALL
1. Drag Codex Notch Meter to the Applications folder in this window.
2. Open the installed copy from Applications, then eject this disk image.
3. If wanted, enable Launch at Login yourself in the app's Settings.
   This disk image never installs the app or changes login items automatically.

Developer preview: the app is ad-hoc signed only. It has no Apple Developer ID
signature and is not notarized by Apple. macOS may block it. Verify the source
and checksum first; if blocked, stop and consult the project's release notes.
Do not disable system security protections.

Needs the official Codex desktop app or CLI, already signed in to ChatGPT.
需要已登录 ChatGPT 的官方 Codex 桌面应用或 CLI。
""".encode("utf-8")


def run(arguments, timeout=30):
    """No shell, interactive stdin, unbounded subprocess, or downloaded tool."""
    result = subprocess.run(
        [str(part) for part in arguments], stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout,
    )
    if result.returncode:
        detail = result.stderr.decode("utf-8", errors="replace")[-4000:]
        raise RuntimeError(f"{arguments[0]} failed ({result.returncode}): {detail}")
    return result


def sha256(path, maximum):
    if not stat.S_ISREG(path.lstat().st_mode) or not 0 < path.stat().st_size <= maximum:
        raise RuntimeError(f"Expected a nonempty, bounded regular file: {path.name}")
    digest = hashlib.sha256()
    total = 0
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            total += len(chunk)
            if total > maximum:
                raise RuntimeError(f"File exceeded size limit: {path.name}")
            digest.update(chunk)
    return digest.hexdigest()


def app_manifest(app):
    """Compare contents/modes without following links or accepting special files."""
    if app.is_symlink() or not app.is_dir():
        raise RuntimeError("Expected a real application directory")
    root = app.resolve(strict=True)
    entries = {}
    total = 0
    for directory, folders, files in os.walk(app, followlinks=False):
        for name in sorted(folders + files):
            path = Path(directory) / name
            relative = path.relative_to(app).as_posix()
            info = path.lstat()
            mode = stat.S_IMODE(info.st_mode)
            if stat.S_ISLNK(info.st_mode):
                target = os.readlink(path)
                # Reject external links, including links into host Applications.
                try:
                    path.resolve(strict=True).relative_to(root)
                except (OSError, RuntimeError, ValueError) as error:
                    raise RuntimeError(f"App symlink escapes its bundle: {relative}") from error
                entries[relative] = ("link", target)
            elif stat.S_ISDIR(info.st_mode):
                entries[relative] = ("directory", mode)
            elif stat.S_ISREG(info.st_mode):
                total += info.st_size
                if total > MAX_APP_BYTES:
                    raise RuntimeError("Application exceeds the 128 MiB packaging limit")
                # Empty resources are legal, unlike an empty executable or image.
                digest = hashlib.sha256(b"").hexdigest() if info.st_size == 0 else sha256(path, MAX_APP_BYTES)
                entries[relative] = ("file", mode, digest)
            else:
                raise RuntimeError(f"Unsupported app file type: {relative}")
            if len(entries) > MAX_ENTRIES:
                raise RuntimeError("Application exceeds the 4096-entry packaging limit")
    return entries


def verify_app(app):
    info_path = app / "Contents/Info.plist"
    if not stat.S_ISREG(info_path.lstat().st_mode) or info_path.stat().st_size > 65536:
        raise RuntimeError("Application Info.plist is not a bounded regular file")
    info = plistlib.loads(info_path.read_bytes())
    expected = {
        "CFBundleIdentifier": "org.codexnotchmeter.app",
        "CFBundleExecutable": "CodexNotchMeter",
        "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": VERSION,
        "LSMinimumSystemVersion": "13.0",
    }
    if not isinstance(info, dict) or any(info.get(key) != value for key, value in expected.items()):
        raise RuntimeError(f"Expected the Codex Notch Meter {VERSION} macOS 13+ app")
    if not isinstance(info.get("CFBundleVersion"), str) or not info["CFBundleVersion"]:
        raise RuntimeError("Application build number is missing")
    executable = app / "Contents/MacOS/CodexNotchMeter"
    if not stat.S_ISREG(executable.lstat().st_mode) or not os.access(executable, os.X_OK):
        raise RuntimeError("Application executable is missing or not executable")
    architectures = run(["/usr/bin/lipo", "-archs", executable]).stdout.decode().split()
    if set(architectures) != {"arm64", "x86_64"} or len(architectures) != 2:
        raise RuntimeError(f"Expected exactly arm64 and x86_64, got {architectures}")
    for architecture in ("arm64", "x86_64"):
        run(["/usr/bin/codesign", "--verify", "--deep", "--strict", "--arch", architecture, app])
        signature = run(["/usr/bin/codesign", "--display", "--verbose=4", "--arch", architecture, app])
        details = (signature.stdout + signature.stderr).decode("utf-8", errors="replace").splitlines()
        if "Signature=adhoc" not in details:
            raise RuntimeError(f"Expected an ad-hoc signature for {architecture}")
    return info


def owned_images(image):
    """Only records identifying this exact private temporary image are eligible."""
    info = plistlib.loads(run(["/usr/bin/hdiutil", "info", "-plist"]).stdout)
    if not isinstance(info, dict) or not isinstance(info.get("images"), list):
        raise RuntimeError("Could not establish attached-image ownership")
    matches = []
    for record in info["images"]:
        path = record.get("image-path")
        if isinstance(path, str) and Path(path).is_absolute() and Path(path).resolve() == image.resolve():
            matches.append(record)
    return matches


def detach_owned(image, mount):
    """No force detach; preserve temporary files if ownership/cleanup is uncertain."""
    records = owned_images(image)
    if os.path.ismount(mount) and not records:
        raise RuntimeError("Verification mount has no matching owned-image record; leaving it untouched")
    for record in records:
        entities = record.get("system-entities", [])
        devices = {
            entity.get("dev-entry") for entity in entities
            if re.fullmatch(r"/dev/disk[0-9]+", str(entity.get("dev-entry", "")))
        }
        if len(devices) == 1:
            target = devices.pop()
        elif any(entity.get("mount-point") == str(mount) for entity in entities) and os.path.ismount(mount):
            target = str(mount)
        else:
            raise RuntimeError("Could not identify this image's exact device or mount; leaving it attached")
        run(["/usr/bin/hdiutil", "detach", target], timeout=30)
    if owned_images(image) or os.path.ismount(mount):
        raise RuntimeError("Owned disk image did not detach cleanly; preserving temporary files")


def verify_image(image, mount, expected_manifest):
    sha256(image, MAX_IMAGE_BYTES)
    metadata = plistlib.loads(run(["/usr/bin/hdiutil", "imageinfo", "-plist", image]).stdout)
    if not isinstance(metadata, dict) or metadata.get("Format") != "UDZO":
        raise RuntimeError("Final disk image must be compressed, read-only UDZO")
    run(["/usr/bin/hdiutil", "verify", image], timeout=90)
    attached = plistlib.loads(run([
        "/usr/bin/hdiutil", "attach", "-readonly", "-nobrowse", "-noautoopen",
        "-mountpoint", mount, "-plist", image,
    ], timeout=60).stdout)
    if not any(entity.get("mount-point") == str(mount) for entity in attached.get("system-entities", [])):
        raise RuntimeError("Final image did not mount at its private verification mount")
    if not os.path.ismount(mount) or not (os.statvfs(mount).f_flag & os.ST_RDONLY):
        raise RuntimeError("Final image verification mount is not read-only")
    visible = {path.name for path in mount.iterdir() if not path.name.startswith(".")}
    if visible != {APP_NAME, "Applications", INSTRUCTIONS_NAME}:
        raise RuntimeError(f"Unexpected visible installer contents: {sorted(visible)}")
    applications = mount / "Applications"
    if not applications.is_symlink() or os.readlink(applications) != "/Applications":
        raise RuntimeError("Applications must be a real symlink with the exact target /Applications")
    instructions = mount / INSTRUCTIONS_NAME
    if not stat.S_ISREG(instructions.lstat().st_mode) or instructions.read_bytes() != INSTRUCTIONS:
        raise RuntimeError("Bilingual installer instructions were changed or omitted")
    app = mount / APP_NAME
    if app_manifest(app) != expected_manifest:
        raise RuntimeError("Mounted application differs from the original signed app")
    info = verify_app(app)
    print(f"DMG_VERIFY_OK: {VERSION} (build {info['CFBundleVersion']}); arm64 + x86_64; "
          "ad-hoc signatures; exact /Applications link; UDZO integrity; read-only mount", flush=True)


def publish(image, checksum, destination):
    """Exclusive hard links publish verified bytes without replacing older assets."""
    output = destination / IMAGE_NAME
    sidecar = destination / f"{IMAGE_NAME}.sha256"
    if os.path.lexists(output) or os.path.lexists(sidecar):
        raise RuntimeError("Refusing to replace an existing DMG or checksum")
    os.link(image, output)
    try:
        os.link(checksum, sidecar)
    except BaseException:
        # Remove only the artifact this invocation just linked, never a replacement.
        if not output.is_symlink() and output.exists() and os.path.samefile(output, image):
            output.unlink()
        raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.parse_args()
    if sys.platform != "darwin":
        raise RuntimeError("DMG packaging requires macOS and Xcode Command Line Tools")
    root = Path(__file__).resolve().parent.parent
    destination = root / "dist"
    if destination.is_symlink() or not destination.is_dir():
        raise RuntimeError("Build dist/Codex Notch Meter.app with build-app.sh --universal first")
    if any(os.path.lexists(destination / name) for name in (IMAGE_NAME, f"{IMAGE_NAME}.sha256")):
        raise RuntimeError("Refusing to replace an existing DMG or checksum")
    app = destination / APP_NAME
    manifest = app_manifest(app)
    verify_app(app)
    work = Path(tempfile.mkdtemp(prefix=".codex-notch-dmg-", dir=destination)).resolve()
    work_identity = (work.stat().st_dev, work.stat().st_ino)
    stage, mount = work / "payload", work / "readonly-volume"
    image = work / IMAGE_NAME
    detached = False
    try:
        stage.mkdir()
        mount.mkdir()
        run(["/usr/bin/ditto", app, stage / APP_NAME], timeout=60)
        if app_manifest(stage / APP_NAME) != manifest:
            raise RuntimeError("Staging changed the signed application")
        (stage / "Applications").symlink_to("/Applications")
        (stage / INSTRUCTIONS_NAME).write_bytes(INSTRUCTIONS)
        run([
            "/usr/bin/hdiutil", "create", "-fs", "HFS+", "-format", "UDZO",
            "-imagekey", "zlib-level=9", "-volname", f"Codex Notch Meter {VERSION}",
            "-srcfolder", stage, image,
        ], timeout=180)
        verify_image(image, mount, manifest)
        detach_owned(image, mount)
        detached = True
        digest = sha256(image, MAX_IMAGE_BYTES)
        checksum = work / f"{IMAGE_NAME}.sha256"
        checksum_text = f"{digest}  {IMAGE_NAME}\n"
        checksum.write_text(checksum_text, encoding="ascii")
        # A release checksum is portable: only the artifact basename, never dist/ or a temp path.
        if checksum.read_text(encoding="ascii") != checksum_text or sha256(image, MAX_IMAGE_BYTES) != digest:
            raise RuntimeError("Final checksum verification failed")
        publish(image, checksum, destination)
        print(f"Built dist/{IMAGE_NAME}\nSHA-256: {digest}\n"
              "Ad-hoc signed app; no Developer ID or notarization. Existing ZIP preserved.", flush=True)
    finally:
        try:
            if not detached:
                detach_owned(image, mount)
            current = work.lstat()
            if not stat.S_ISDIR(current.st_mode) or (current.st_dev, current.st_ino) != work_identity:
                raise RuntimeError("Temporary directory identity changed; refusing cleanup")
        except BaseException:
            print(f"Temporary packaging files retained for safe cleanup: {work}", file=sys.stderr)
            raise
        else:
            # Never recurse through a mounted image or clean any unrelated directory.
            shutil.rmtree(work)
            if detached:
                print("DMG_CLEANUP_OK: owned verification image detached; "
                      "private temporary directory removed", flush=True)


def interrupted(_signal, _frame):
    raise KeyboardInterrupt("Packaging interrupted")


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, interrupted)
    try:
        main()
    except (OSError, RuntimeError, ValueError, subprocess.SubprocessError, KeyboardInterrupt) as error:
        print(f"DMG packaging failed: {error}", file=sys.stderr)
        sys.exit(1)
