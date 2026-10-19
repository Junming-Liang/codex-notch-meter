#!/usr/bin/env python3
"""Dependency-free public-source preflight; not a replacement for Swift tests."""
from pathlib import Path
import json
import re
import subprocess
import sys

root = Path(__file__).resolve().parent.parent
sources = list((root / 'Sources').rglob('*.swift'))
failures = []
for path in sources:
    content = path.read_text()
    for forbidden in ('thread/start', 'turn/start', 'account/login/start', 'account/logout', 'account/usage/read'):
        if forbidden in content:
            failures.append(f'{path.relative_to(root)}: forbidden RPC {forbidden}')
    for forbidden in ('AXIsProcessTrusted', 'CGRequestScreenCaptureAccess', 'CGEvent.tapCreate', 'auth.json', 'sessions/', 'MediaRemotePrivate'):
        if forbidden in content:
            failures.append(f'{path.relative_to(root)}: forbidden integration {forbidden}')
    # Only the optional, separately consented lyrics boundary may construct a
    # network session. Quota/discovery/other application sources remain barred.
    if 'URLSession' in content and path.relative_to(root).as_posix() != 'Sources/CodexNotchMeter/LyricsProvider.swift':
        failures.append(f'{path.relative_to(root)}: network outside optional lyrics boundary')
    if re.search(r'/(Users|workspace|root)/', content):
        failures.append(f'{path.relative_to(root)}: machine-specific absolute path')
lyrics_transport = (root / 'Sources/CodexNotchMeter/LyricsProvider.swift').read_text()
for guard in ('URLSessionConfiguration.ephemeral', 'config.httpCookieStorage = nil',
              'config.urlCredentialStorage = nil', 'config.urlCache = nil',
              'willPerformHTTPRedirection', 'completionHandler(nil)',
              'LRCLIBLookup.isAllowed(url: request.url)', 'request.maximumResponseBytes'):
    if guard not in lyrics_transport:
        failures.append(f'Optional lyrics transport safety guard missing: {guard}')
lyrics_policy = (root / 'Sources/NotchCore/LyricsLookup.swift').read_text()
for guard in ('guard consent else', 'components.host = "lrclib.net"', 'parts.percentEncodedPath == "/api/get"',
              'parts.percentEncodedPath == "/api/search"', 'maximumRequestsPerLookup = 3',
              'guard let url = components.url, isAllowed(url: url)'):
    if guard not in lyrics_policy:
        failures.append(f'Optional lyrics request safety guard missing: {guard}')
rpc = (root / 'Sources/NotchCore/RPC.swift').read_text()
for required in ('refreshToken": false', 'F_SETNOSIGPIPE', 'SIGKILL', '4_194_304'):
    if required not in rpc:
        failures.append(f'RPC safety guard missing: {required}')
# Reject stale package/client/tag pins before the native build. Historical docs
# and comments are not release targets and deliberately are not scanned here.
app_build = (root / 'Scripts/build-app.sh').read_text()
versions = re.findall(r'^version="([0-9]+\.[0-9]+\.[0-9]+)"$', app_build, re.MULTILINE)
releases = re.findall(r'^release_version="([^"\n]+)"$', app_build, re.MULTILINE)
builds = re.findall(r'<key>CFBundleVersion</key><string>([0-9]+)</string>', app_build)
if len(versions) != 1 or len(releases) != 1 or len(builds) != 1:
    failures.append('Application bundle/release version and build must be uniquely declared')
else:
    expected_version, expected_release, expected_build = versions[0], releases[0], builds[0]
    # The formal release identity must exactly equal its numeric bundle version.
    # A beta tag/archive cannot pass by being parsed only through its numeric prefix.
    if expected_release != expected_version:
        failures.append('Formal release must match the numeric bundle version exactly')
    if app_build.count('<key>CFBundleShortVersionString</key><string>$version</string>') != 1:
        failures.append('Bundle short version must use the numeric version')
    if app_build.count('<key>CodexNotchMeterReleaseVersion</key><string>$release_version</string>') != 1:
        failures.append('Bundle release identity must use the explicit release version')
    if app_build.count('archive="dist/CodexNotchMeter-${release_version}-${archs}.zip"') != 1:
        failures.append('Archive name must use the explicit release version')
    version_pins = [
        ('Scripts/build-dmg.py', r'^VERSION = "([^"\n]+)"$', expected_version),
        ('Scripts/build-dmg.py', r'^RELEASE_VERSION = "([^"\n]+)"$', expected_release),
        ('Scripts/test-build-dmg.py', r'"CFBundleShortVersionString": "([^"\n]+)"', expected_version),
        ('Scripts/test-build-dmg.py', r'"CodexNotchMeterReleaseVersion": "([^"\n]+)"', expected_release),
        ('Scripts/test-build-dmg.py', r'"CFBundleVersion": "([^"\n]+)"', expected_build),
        ('Scripts/test-build-dmg.py', r'assertRaisesRegex\(RuntimeError, "([0-9]+\.[0-9]+\.[0-9]+)"\)', expected_version),
        ('Sources/NotchCore/LyricsLookup.swift', r'CodexNotchMeter/([^ "\n]+) ', expected_release),
        ('Tests/NotchCoreTests/LyricsLookupTests.swift', r'contains\("CodexNotchMeter/([^ "\n]+) "\)', expected_release),
        ('Sources/NotchCore/RPC.swift', r'"version": "([^"\n]+)"', expected_release),
        ('Sources/CodexNotchMeter/Views.swift', r'Text\("v([^ "\n]+) · 正式版"\)', expected_release),
        ('.github/workflows/macos.yml', r'CodexNotchMeter-([0-9][A-Za-z0-9.+-]*)-universal', expected_release),
        ('.github/workflows/macos.yml', r'--version ([0-9]+\.[0-9]+\.[0-9]+)', expected_release),
        ('.github/workflows/macos.yml', r'--bundle-build ([0-9]+)', expected_build),
        ('.github/workflows/macos.yml', r'(?:refs/tags/v|release create v|tag_name == "v|description: Publish v|## Codex Notch Meter v|--title "v)([0-9][A-Za-z0-9.+-]*)', expected_release),
    ]
    for filename, pattern, expected in version_pins:
        observed = re.findall(pattern, (root / filename).read_text(), re.MULTILINE)
        # Workflow targets repeat intentionally; single-source declarations do not.
        duplicate_single_pin = filename != '.github/workflows/macos.yml' and len(observed) != 1
        if not observed or set(observed) != {expected} or duplicate_single_pin:
            failures.append(f'{filename}: missing or mismatched release version/build; expected {expected}, found {observed}')
    dmg_build = (root / 'Scripts/build-dmg.py').read_text()
    for required in ('IMAGE_NAME = f"CodexNotchMeter-{RELEASE_VERSION}-universal.dmg"',
                     '"CodexNotchMeterReleaseVersion": RELEASE_VERSION,'):
        if dmg_build.count(required) != 1:
            failures.append('DMG identity must use the explicit release version')
    if '--prerelease' in (root / '.github/workflows/macos.yml').read_text():
        failures.append('Formal release must not retain the prerelease flag')
workflow = (root / '.github/workflows/macos.yml').read_text()
notes = (root / 'docs/RELEASE-1.0.2.md').read_text().rstrip()
inline_notes = re.search(r"          cat > notes.md <<'NOTES'\n(.*?)\n          NOTES", workflow, re.DOTALL)
if not inline_notes or "\n".join(line[10:] for line in inline_notes.group(1).splitlines()).rstrip() != notes:
    failures.append('Workflow release notes must match the reviewed bilingual source document exactly')
for guard in ('build-source.json', 'dist/release-source.json', 'HEAD^{tree}', 'GITHUB_RUN_ID', 'git status --porcelain --untracked-files=no'):
    if guard not in app_build:
        failures.append(f'Packaged source binding missing: {guard}')
subprocess.run(['bash', '-n', str(root / 'Scripts/build-app.sh')], check=True)
summary = {'swift_source_files': len(sources), 'swift_test_files': len(list((root / 'Tests').rglob('*.swift'))),
           'static_checks': 'FAIL' if failures else 'PASS', 'failures': failures,
           'note': 'Static checks only. Native compile, Swift tests and UI require separate verification.'}
print(json.dumps(summary, indent=2))
sys.exit(bool(failures))
