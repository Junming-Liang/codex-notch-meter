#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "App packaging requires macOS and Xcode Command Line Tools." >&2
  exit 1
fi
version="1.1.3"
release_version="1.1.3"
args=(-c release --product CodexNotchMeter)
path_args=(-c release --show-bin-path)
if [[ "${1:-}" == "--universal" ]]; then
  args+=(--arch arm64 --arch x86_64)
  path_args+=(--arch arm64 --arch x86_64)
elif [[ "${1:-}" == "--app-only" && $# -eq 1 ]]; then
  : # Focused native diagnostic: sign and bind the app, but create no release archive.
elif [[ $# -gt 0 ]]; then
  echo "Usage: $0 [--universal|--app-only]" >&2; exit 2
fi
# A source-bound package must not attribute dirty tracked code to an older commit.
if [[ -n "$(git status --porcelain --untracked-files=no)" || -n "$(git ls-files --others --exclude-standard Sources Scripts Package.swift)" ]]; then
  echo "Commit source changes before creating a source-bound application package." >&2
  exit 1
fi
swift build "${args[@]}"
bin_dir="$(swift build "${path_args[@]}")"
app="dist/Codex Notch Meter.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin_dir/CodexNotchMeter" "$app/Contents/MacOS/CodexNotchMeter"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>org.codexnotchmeter.app</string>
<key>CFBundleName</key><string>Codex Notch Meter</string>
<key>CFBundleDisplayName</key><string>Codex Notch Meter</string>
<key>CFBundleExecutable</key><string>CodexNotchMeter</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$version</string>
<key>CFBundleVersion</key><string>20</string>
<key>CodexNotchMeterReleaseVersion</key><string>$release_version</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
<key>NSPrefersDisplaySafeAreaCompatibilityMode</key><false/>
<key>NSHighResolutionCapable</key><true/>
<key>NSAppleEventsUsageDescription</key><string>启用 Apple Music 歌词后，读取 Music 当前歌曲与播放位置以显示歌词；不会控制播放或修改音乐资料库。</string>
<key>NSHumanReadableCopyright</key><string>Copyright © 2026 Codex Notch Meter contributors. MIT License.</string>
</dict></plist>
PLIST
swift Scripts/make-icon.swift dist/AppIcon.png
iconset="dist/AppIcon.iconset"
mkdir -p "$iconset"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" dist/AppIcon.png --out "$iconset/icon_${size}x${size}.png" >/dev/null
  twice=$((size * 2))
  sips -z "$twice" "$twice" dist/AppIcon.png --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$app/Contents/Resources/AppIcon.icns"
cp LICENSE "$app/Contents/Resources/LICENSE.txt"
python3 - "$version" "$app/Contents/Resources/build-source.json" <<'SOURCE'
import json, os, pathlib, subprocess, sys
metadata = {
    "commit": subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip(),
    "tree": subprocess.check_output(["git", "rev-parse", "HEAD^{tree}"], text=True).strip(),
    "run_id": os.environ.get("GITHUB_RUN_ID", "0"),
    "repository": os.environ.get("GITHUB_REPOSITORY", "Junming-Liang/codex-notch-meter"),
    "version": sys.argv[1],
}
encoded = (json.dumps(metadata, sort_keys=True, indent=2) + "\n").encode()
pathlib.Path(sys.argv[2]).write_bytes(encoded)
pathlib.Path("dist/release-source.json").write_bytes(encoded)
SOURCE
plutil -lint "$app/Contents/Info.plist"
# Ad-hoc signing uses no identity, certificate, account or paid developer service.
codesign --force --sign - --timestamp=none "$app"
codesign --verify --deep --strict --verbose=2 "$app"
archs="$(lipo -archs "$app/Contents/MacOS/CodexNotchMeter" | tr ' ' '-')"
if [[ "${1:-}" == "--universal" ]]; then
  lipo "$app/Contents/MacOS/CodexNotchMeter" -verify_arch arm64 x86_64
  archs="universal"
fi
if [[ "${1:-}" == "--app-only" ]]; then
  echo "Built source-bound diagnostic app only; releaseEligible=false."
  exit 0
fi
archive="dist/CodexNotchMeter-${release_version}-${archs}.zip"
ditto -c -k --sequesterRsrc --keepParent "$app" "$archive"
(cd dist && shasum -a 256 "$(basename "$archive")" > "$(basename "$archive").sha256")
echo "Built $archive (ad-hoc signed; not Developer ID signed or notarized)."
