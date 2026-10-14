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
    for forbidden in ('AXIsProcessTrusted', 'CGRequestScreenCaptureAccess', 'CGEvent.tapCreate', 'URLSession', 'auth.json', 'sessions/'):
        if forbidden in content:
            failures.append(f'{path.relative_to(root)}: forbidden integration {forbidden}')
    if re.search(r'/(Users|workspace|root)/', content):
        failures.append(f'{path.relative_to(root)}: machine-specific absolute path')
rpc = (root / 'Sources/NotchCore/RPC.swift').read_text()
for required in ('refreshToken": false', 'F_SETNOSIGPIPE', 'SIGKILL', '4_194_304'):
    if required not in rpc:
        failures.append(f'RPC safety guard missing: {required}')
subprocess.run(['bash', '-n', str(root / 'Scripts/build-app.sh')], check=True)
summary = {'swift_source_files': len(sources), 'swift_test_files': len(list((root / 'Tests').rglob('*.swift'))),
           'static_checks': 'FAIL' if failures else 'PASS', 'failures': failures,
           'note': 'Static checks only. Native compile, Swift tests and UI require separate verification.'}
print(json.dumps(summary, indent=2))
sys.exit(bool(failures))
