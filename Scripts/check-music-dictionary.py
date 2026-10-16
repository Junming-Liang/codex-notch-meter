#!/usr/bin/env python3
"""Inspect only Apple's installed public scripting dictionary; never launch Music.

This checks the PID-addressed adapter's property codes on the hosted macOS SDK
image. It grants no Automation permission and reads no library/account data.
"""
from pathlib import Path
import plistlib
import sys
import xml.etree.ElementTree as ET


def main() -> int:
    if sys.platform != 'darwin':
        print('Music dictionary inspection requires macOS.', file=sys.stderr)
        return 1
    app = Path('/System/Applications/Music.app')
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    if info.get('CFBundleIdentifier') != 'com.apple.Music':
        raise RuntimeError('Unexpected system application identity')
    path = app / 'Contents/Resources/Music.sdef'
    if path.stat().st_size > 2_097_152:
        raise RuntimeError('Scripting dictionary exceeds inspection bound')
    data = path.read_bytes()
    # No external entity/network retrieval; inspect this one vendor file only.
    tree = ET.fromstring(data)
    properties = {
        'current track': 'pTrk', 'player state': 'pPlS', 'player position': 'pPos',
        'name': 'pnam', 'artist': 'pArt', 'album': 'pAlb',
        'duration': 'pDur', 'persistent ID': 'pPIS',
    }
    for name, expected in properties.items():
        found = {node.get('code') for node in tree.iter('property') if node.get('name') == name}
        if expected not in found:
            raise RuntimeError(f'Public Music property code unavailable: {name}')
    for name, expected in {'playing': 'kPSP', 'paused': 'kPSp', 'stopped': 'kPSS'}.items():
        found = {node.get('code') for node in tree.iter('enumerator') if node.get('name') == name}
        if expected not in found:
            raise RuntimeError(f'Public Music playback code unavailable: {name}')
    print('MUSIC_DICTIONARY_OK: public property/state codes verified; Music launched=false; Automation requested=false')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
