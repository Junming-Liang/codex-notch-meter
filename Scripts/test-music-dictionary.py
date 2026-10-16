#!/usr/bin/env python3
"""Synthetic bundle fixtures only; no installed Music, OSA, or subprocess use."""
import importlib.util
import os
from pathlib import Path
import plistlib
import sys
import tempfile
import unittest
from unittest import mock
import xml.etree.ElementTree as ET

sys.dont_write_bytecode = True
SPEC = importlib.util.spec_from_file_location('music_dictionary', Path(__file__).with_name('check-music-dictionary.py'))
dictionary = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(dictionary)


class DictionaryTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='synthetic-music-dictionary-')
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.app = self.root / 'Music.app'
        self.resources = self.app / 'Contents/Resources'
        self.resources.mkdir(parents=True)
        self.info = {'CFBundleIdentifier': 'com.apple.Music'}
        self.write_info()
        # Original minimal terminology fixture, not a copied Apple dictionary.
        tree = ET.Element('dictionary')
        suite = ET.SubElement(tree, 'suite')
        for tag, mapping in (('property', dictionary.PROPERTIES), ('enumerator', dictionary.STATES)):
            for name, code in mapping.items():
                ET.SubElement(suite, tag, name=name, code=code)
        self.xml = ET.tostring(tree)

    def write_info(self):
        (self.app / 'Contents/Info.plist').write_bytes(plistlib.dumps(self.info))

    def install(self, filename='VendorTerminology.sdef'):
        path = self.resources / filename
        path.write_bytes(self.xml)
        return path

    def test_declared_non_music_filename(self):
        self.info['OSAScriptingDefinition'] = 'VendorTerminology.sdef'
        self.write_info()
        self.install()
        self.install('Unrelated.sdef')
        result = dictionary.inspect_app(self.app)
        self.assertEqual(result['method'], 'declared-resource')
        self.assertEqual(result['resource'], 'Contents/Resources/VendorTerminology.sdef')
        self.assertEqual(result['bytes'], len(self.xml))

    def test_declared_extensionless_basename(self):
        self.info['OSAScriptingDefinition'] = 'VendorTerminology'
        self.write_info()
        self.install()
        self.assertEqual(dictionary.inspect_app(self.app)['method'], 'declared-resource')

    def test_unique_undeclared_resource(self):
        self.install()
        self.assertEqual(dictionary.inspect_app(self.app)['method'], 'unique-direct-resource')

    def test_declared_missing_never_falls_back(self):
        self.info['OSAScriptingDefinition'] = 'Missing.sdef'
        self.write_info()
        self.install()
        with self.assertRaises(FileNotFoundError):
            dictionary.inspect_app(self.app)

    def test_invalid_and_dynamic_declarations(self):
        self.install()
        for value in ('dynamic', 'DYNAMIC', '', '../outside.sdef', '/outside.sdef',
                      'nested/file.sdef', 'nested\\file.sdef', '.', '..', ' padded',
                      'bad\nname', 'a' * 256, 7, [], True):
            with self.subTest(value=value):
                self.info['OSAScriptingDefinition'] = value
                self.write_info()
                with self.assertRaisesRegex(RuntimeError, 'declaration'):
                    dictionary.inspect_app(self.app)

    def test_missing_dictionary_fails(self):
        with self.assertRaisesRegex(RuntimeError, 'found 0'):
            dictionary.inspect_app(self.app)

    def test_ambiguous_dictionary_fails(self):
        self.install()
        self.install('Other.sdef')
        with self.assertRaisesRegex(RuntimeError, 'found 2'):
            dictionary.inspect_app(self.app)

    def test_nested_dictionary_not_searched(self):
        nested = self.resources / 'Nested'
        nested.mkdir()
        (nested / 'Vendor.sdef').write_bytes(self.xml)
        with self.assertRaisesRegex(RuntimeError, 'found 0'):
            dictionary.inspect_app(self.app)

    def test_symlink_dictionary_rejected(self):
        outside = self.root / 'outside.sdef'
        outside.write_bytes(self.xml)
        (self.resources / 'linked.sdef').symlink_to(outside)
        with self.assertRaisesRegex(RuntimeError, 'Linked'):
            dictionary.inspect_app(self.app)

    def test_symlink_resources_rejected(self):
        self.resources.rmdir()
        outside = self.root / 'Resources'
        outside.mkdir()
        (outside / 'vendor.sdef').write_bytes(self.xml)
        self.resources.symlink_to(outside, target_is_directory=True)
        with self.assertRaisesRegex(RuntimeError, 'Linked'):
            dictionary.inspect_app(self.app)

    def test_symlink_info_rejected(self):
        path = self.app / 'Contents/Info.plist'
        outside = self.root / 'info.plist'
        path.rename(outside)
        path.symlink_to(outside)
        with self.assertRaisesRegex(RuntimeError, 'Linked'):
            dictionary.inspect_app(self.app)

    def test_symlink_app_rejected(self):
        link = self.root / 'alias.app'
        link.symlink_to(self.app, target_is_directory=True)
        with self.assertRaisesRegex(RuntimeError, 'Linked'):
            dictionary.inspect_app(link)

    def test_special_file_rejected_without_opening(self):
        os.mkfifo(self.resources / 'fifo.sdef')
        with self.assertRaisesRegex(RuntimeError, 'unsupported'):
            dictionary.inspect_app(self.app)

    def test_directory_resource_rejected(self):
        (self.resources / 'directory.sdef').mkdir()
        with self.assertRaisesRegex(RuntimeError, 'unsupported'):
            dictionary.inspect_app(self.app)

    def test_empty_and_oversized_dictionary_rejected(self):
        path = self.install()
        for data in (b'', b'x' * (dictionary.MAX_BYTES + 1)):
            path.write_bytes(data)
            with self.assertRaisesRegex(RuntimeError, 'bound or is empty'):
                dictionary.inspect_app(self.app)

    def test_resource_listing_bound(self):
        self.install()
        (self.resources / 'other.txt').write_text('fixture')
        with mock.patch.object(dictionary, 'MAX_RESOURCE_ENTRIES', 1):
            with self.assertRaisesRegex(RuntimeError, 'directory exceeds'):
                dictionary.inspect_app(self.app)

    def test_identity_and_plist_type_rejected(self):
        path = self.app / 'Contents/Info.plist'
        for info in ({'CFBundleIdentifier': 'other'}, [], 'bad'):
            path.write_bytes(plistlib.dumps(info))
            with self.assertRaisesRegex(RuntimeError, 'identity'):
                dictionary.inspect_app(self.app)

    def test_malformed_plist_rejected(self):
        (self.app / 'Contents/Info.plist').write_bytes(b'not a plist')
        with self.assertRaises(plistlib.InvalidFileException):
            dictionary.inspect_app(self.app)

    def test_missing_and_conflicting_public_codes_rejected(self):
        for original in (b'pTrk', b'pPIS', b'kPSP', b'kPSS'):
            with self.subTest(original=original):
                self.install().write_bytes(self.xml.replace(original, b'xxxx'))
                with self.assertRaisesRegex(RuntimeError, 'unavailable or conflicting'):
                    dictionary.inspect_app(self.app)
        self.install().write_bytes(self.xml.replace(b'</suite>', b'<property name="current track" code="xxxx" /></suite>'))
        with self.assertRaisesRegex(RuntimeError, 'conflicting'):
            dictionary.inspect_app(self.app)

    def test_malformed_xml_root_and_entity_rejected(self):
        for data, error in ((b'<dictionary>', ET.ParseError), (b'<other />', RuntimeError),
                            (b'<!DOCTYPE dictionary [<!ENTITY a "x">]>' + self.xml, RuntimeError)):
            self.install().write_bytes(data)
            with self.assertRaises(error):
                dictionary.inspect_app(self.app)


if __name__ == '__main__':
    unittest.main()
