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
for guard in ('guard consent else', 'components.host = "lrclib.net"', 'components.path = "/api/get"'):
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
builds = re.findall(r'<key>CFBundleVersion</key><string>([0-9]+)</string>', app_build)
if len(versions) != 1 or len(builds) != 1:
    failures.append('Application version/build must be uniquely declared')
else:
    expected_version, expected_build = versions[0], builds[0]
    version_pins = [
        ('Scripts/build-dmg.py', r'^VERSION = "([^"\n]+)"$', expected_version),
        ('Scripts/test-build-dmg.py', r'"CFBundleShortVersionString": "([^"\n]+)"', expected_version),
        ('Scripts/test-build-dmg.py', r'"CFBundleVersion": "([^"\n]+)"', expected_build),
        ('Scripts/test-build-dmg.py', r'assertRaisesRegex\(RuntimeError, "([0-9]+\.[0-9]+\.[0-9]+)"\)', expected_version),
        ('Sources/NotchCore/LyricsLookup.swift', r'CodexNotchMeter/([0-9]+\.[0-9]+\.[0-9]+) ', expected_version),
        ('Sources/NotchCore/RPC.swift', r'"version": "([^"\n]+)"', expected_version),
        ('Sources/CodexNotchMeter/Views.swift', r'Text\("v([0-9]+\.[0-9]+\.[0-9]+) · 开源预览版"\)', expected_version),
        ('.github/workflows/macos.yml', r'CodexNotchMeter-([0-9]+\.[0-9]+\.[0-9]+)-universal', expected_version),
        ('.github/workflows/macos.yml', r'(?:refs/tags/v|release create v|tag_name == "v|description: Publish v|## Codex Notch Meter v|--title "v)([0-9]+\.[0-9]+\.[0-9]+)', expected_version),
    ]
    for filename, pattern, expected in version_pins:
        observed = re.findall(pattern, (root / filename).read_text(), re.MULTILINE)
        # Workflow targets repeat intentionally; single-source declarations do not.
        duplicate_single_pin = filename != '.github/workflows/macos.yml' and len(observed) != 1
        if not observed or set(observed) != {expected} or duplicate_single_pin:
            failures.append(f'{filename}: missing or mismatched release version/build; expected {expected}, found {observed}')
subprocess.run(['bash', '-n', str(root / 'Scripts/build-app.sh')], check=True)
summary = {'swift_source_files': len(sources), 'swift_test_files': len(list((root / 'Tests').rglob('*.swift'))),
           'static_checks': 'FAIL' if failures else 'PASS', 'failures': failures,
           'note': 'Static checks only. Native compile, Swift tests and UI require separate verification.'}
print(json.dumps(summary, indent=2))
sys.exit(bool(failures))
