#!/usr/bin/env python3
"""Inspect Apple's installed public dictionary without launching Music or OSA.

Resolve OSAScriptingDefinition from bundle metadata, not an assumed filename.
The only fallback is one direct Resources/*.sdef file when the key is absent.
Dynamic dictionaries fail closed: asking OSA/sdef to extract one can send events.
"""
from pathlib import Path
import hashlib
import json
import os
import plistlib
import stat
import sys
import xml.etree.ElementTree as ET


MAX_BYTES = 2_097_152
MAX_RESOURCE_ENTRIES = 4096
PROPERTIES = {
    'current track': 'pTrk', 'player state': 'pPlS', 'player position': 'pPos',
    'name': 'pnam', 'artist': 'pArt', 'album': 'pAlb',
    'duration': 'pDur', 'persistent ID': 'pPIS',
}
STATES = {'playing': 'kPSP', 'paused': 'kPSp', 'stopped': 'kPSS'}


def checked_path(path: Path, root: Path, directory: bool = False) -> Path:
    """Reject links/escape/special files, including intermediate components."""
    path.relative_to(root)
    for component in (root, *[root.joinpath(*path.relative_to(root).parts[:i])
                             for i in range(1, len(path.relative_to(root).parts) + 1)]):
        if component.is_symlink():
            raise RuntimeError('Linked dictionary bundle resource is not allowed')
    if not path.resolve(strict=True).is_relative_to(root.resolve(strict=True)):
        raise RuntimeError('Dictionary resource escapes the application bundle')
    mode = path.stat().st_mode
    if not (stat.S_ISDIR(mode) if directory else stat.S_ISREG(mode)):
        raise RuntimeError('Dictionary resource has an unsupported file type')
    return path


def read_bounded(path: Path, root: Path) -> bytes:
    checked_path(path, root)
    # O_NONBLOCK also prevents an unexpected FIFO replacement from blocking.
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(descriptor, 'rb') as stream:
        metadata = os.fstat(stream.fileno())
        if not stat.S_ISREG(metadata.st_mode) or not 0 < metadata.st_size <= MAX_BYTES:
            raise RuntimeError('Dictionary resource exceeds inspection bound or is empty')
        data = stream.read(MAX_BYTES + 1)
    if not 0 < len(data) <= MAX_BYTES:
        raise RuntimeError('Dictionary resource exceeds inspection bound or is empty')
    return data


def dictionary_path(app: Path, info: dict) -> tuple[Path, str]:
    resources = checked_path(app / 'Contents/Resources', app, directory=True)
    if 'OSAScriptingDefinition' in info:
        declared = info['OSAScriptingDefinition']
        if (not isinstance(declared, str) or not declared or len(declared.encode('utf-8')) > 255
                or declared.strip() != declared or declared.lower() == 'dynamic'
                or declared in ('.', '..') or '/' in declared or '\\' in declared
                or any(ord(char) < 32 for char in declared)):
            raise RuntimeError('Invalid or dynamic OSAScriptingDefinition declaration')
        # Apple documents both a filename and an extensionless base name.
        filename = declared if declared.lower().endswith('.sdef') else declared + '.sdef'
        return checked_path(resources / filename, app), 'declared-resource'

    candidates = []
    with os.scandir(resources) as entries:
        for count, entry in enumerate(entries, start=1):
            if count > MAX_RESOURCE_ENTRIES:
                raise RuntimeError('Resource directory exceeds inspection bound')
            if entry.name.lower().endswith('.sdef'):
                candidates.append(checked_path(Path(entry.path), app))
    if len(candidates) != 1:
        raise RuntimeError(f'Expected one undeclared direct scripting dictionary; found {len(candidates)}')
    return candidates[0], 'unique-direct-resource'


def verify_dictionary(data: bytes) -> None:
    # ElementTree does not load external DTDs or expand XInclude. Reject entity
    # declarations too; the gate needs only ordinary terminology elements.
    if b'<!ENTITY' in data.upper():
        raise RuntimeError('Dictionary entity declarations are not allowed')
    tree = ET.fromstring(data)
    if tree.tag != 'dictionary':
        raise RuntimeError('Unexpected scripting dictionary root')
    for element, expected_codes in (('property', PROPERTIES), ('enumerator', STATES)):
        for name, expected in expected_codes.items():
            found = {node.get('code') for node in tree.iter(element) if node.get('name') == name}
            if found != {expected}:
                raise RuntimeError(f'Public Music {element} code unavailable or conflicting: {name}')


def inspect_app(app: Path) -> dict:
    checked_path(app, app, directory=True)
    info = plistlib.loads(read_bounded(app / 'Contents/Info.plist', app))
    if not isinstance(info, dict) or info.get('CFBundleIdentifier') != 'com.apple.Music':
        raise RuntimeError('Unexpected system application identity')
    path, method = dictionary_path(app, info)
    data = read_bounded(path, app)
    verify_dictionary(data)
    return {'method': method, 'resource': path.relative_to(app).as_posix(),
            'bytes': len(data), 'sha256': hashlib.sha256(data).hexdigest()}


def main() -> int:
    if sys.platform != 'darwin':
        print('Music dictionary inspection requires macOS.', file=sys.stderr)
        return 1
    try:
        receipt = inspect_app(Path('/System/Applications/Music.app'))
    except (OSError, ValueError, RuntimeError, ET.ParseError, plistlib.InvalidFileException) as error:
        print(f'Music dictionary inspection failed: {error}', file=sys.stderr)
        return 1
    print('MUSIC_DICTIONARY_RESOURCE: ' + json.dumps(receipt, sort_keys=True))
    print('MUSIC_DICTIONARY_OK: public property/state codes verified; Music launched=false; Automation requested=false')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
