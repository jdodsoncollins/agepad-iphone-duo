#!/usr/bin/env python3
"""Actual iPhoneOS asset compilation and staging guards; no Simulator or signing."""
import hashlib
import importlib.util
import json
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('agepad_app_icons', ROOT / 'scripts/agepad_app_icons.py')
icons = importlib.util.module_from_spec(spec)
spec.loader.exec_module(icons)


class AppIconTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix='agepad-icon-regression-')
        cls.root = Path(cls.temp.name)
        cls.source = ROOT / 'assets/agepad-icon-1024.png'
        cls.original_hash = hashlib.sha256(cls.source.read_bytes()).hexdigest()
        cls.bundle = cls.root / 'Working.app'
        cls.bundle.mkdir()
        cls.original_info = plistlib.dumps({'CFBundleIdentifier': 'local.agepad.icon-test', 'UnrelatedKey': 'preserve'})
        (cls.bundle / 'Info.plist').write_bytes(cls.original_info)
        cls.build = cls.root / 'working-build'
        cls.updates = icons.compile_app_icons(cls.source, cls.bundle, cls.build)

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def fresh_bundle(self):
        path = self.root / (self.id().split('.')[-1] + '.app')
        path.mkdir()
        return path

    def test_source_and_existing_info_unchanged(self):
        self.assertEqual(hashlib.sha256(self.source.read_bytes()).hexdigest(), self.original_hash)
        self.assertEqual((self.bundle / 'Info.plist').read_bytes(), self.original_info)

    def test_compiler_provides_phone_and_ipad_metadata(self):
        self.assertEqual(set(self.updates), {'CFBundleIcons', 'CFBundleIcons~ipad'})
        for key in ('CFBundleIcons', 'CFBundleIcons~ipad'):
            primary = self.updates[key]['CFBundlePrimaryIcon']
            self.assertEqual(primary['CFBundleIconName'], icons.APP_ICON)
            self.assertTrue(primary['CFBundleIconFiles'])
        info = plistlib.loads(self.original_info)
        info.update(self.updates)
        self.assertEqual(info['UnrelatedKey'], 'preserve')
        self.assertEqual(info['CFBundleIdentifier'], 'local.agepad.icon-test')

    def test_declared_phone_ipad_and_marketing_artwork_opaque(self):
        appiconset = self.build / 'AgePad.xcassets' / (icons.APP_ICON + '.appiconset')
        entries = json.loads((appiconset / 'Contents.json').read_text())['images']
        self.assertEqual(len(entries), 18)
        self.assertEqual({entry['idiom'] for entry in entries}, {'iphone', 'ipad', 'ios-marketing'})
        for entry, slot in zip(entries, icons.ICON_SLOTS):
            properties = icons.image_properties(appiconset / entry['filename'])
            self.assertEqual(properties, {'width': slot[3], 'height': slot[3], 'alpha': False})

    def test_real_compiled_catalog_contains_required_opaque_renditions(self):
        data = subprocess.check_output(['xcrun', 'assetutil', '--info', str(self.bundle / 'Assets.car')], text=True)
        images = [item for item in json.loads(data) if item.get('AssetType') == 'Icon Image']
        self.assertTrue(images)
        self.assertTrue(all(item.get('Opaque') for item in images))
        actual = {(item.get('Idiom'), item.get('PixelWidth'), item.get('PixelHeight')) for item in images}
        for rendition in [('phone', 180, 180), ('pad', 167, 167), ('marketing', 1024, 1024)]:
            self.assertIn(rendition, actual)
        for resource in (self.build / 'compiled').iterdir():
            self.assertEqual((self.bundle / resource.name).read_bytes(), resource.read_bytes())

    def test_preexisting_catalog_is_preserved(self):
        bundle = self.fresh_bundle()
        (bundle / 'Assets.car').write_bytes(b'vendor catalog sentinel')
        output = self.root / 'catalog-conflict'
        with self.assertRaisesRegex(ValueError, 'existing asset catalog'):
            icons.compile_app_icons(self.source, bundle, output)
        self.assertEqual((bundle / 'Assets.car').read_bytes(), b'vendor catalog sentinel')
        self.assertFalse(output.exists())

    def test_compiled_name_collision_never_replaces_vendor_resource(self):
        bundle = self.fresh_bundle()
        existing = bundle / 'AgePadAppIcon60x60@2x.png'
        existing.write_bytes(b'vendor image sentinel')
        with self.assertRaisesRegex(ValueError, 'existing app resource'):
            icons.compile_app_icons(self.source, bundle, self.root / 'resource-conflict')
        self.assertEqual(existing.read_bytes(), b'vendor image sentinel')
        self.assertFalse((bundle / 'Assets.car').exists())

    def test_working_directory_must_be_fresh_and_outside_app(self):
        bundle = self.fresh_bundle()
        existing = self.root / 'preexisting-output'
        existing.mkdir()
        with self.assertRaisesRegex(ValueError, 'fresh'):
            icons.compile_app_icons(self.source, bundle, existing)
        with self.assertRaisesRegex(ValueError, 'outside'):
            icons.compile_app_icons(self.source, bundle, bundle / 'accidental-shipped-source')
        self.assertEqual(list(bundle.iterdir()), [])

    def test_invalid_geometry_and_os_rejected_before_staging(self):
        bundle = self.fresh_bundle()
        small = self.root / 'small.png'
        subprocess.run(['sips', '-z', '180', '180', str(self.source), '--out', str(small)], check=True, capture_output=True)
        for source, version, message in [(small, '15.0', '1024'), (self.source, '15.0;invalid', 'numeric')]:
            output = self.root / ('invalid-' + str(len(version)))
            with self.assertRaisesRegex(ValueError, message):
                icons.compile_app_icons(source, bundle, output, minimum_os=version)
            self.assertFalse(output.exists())

    def test_opaque_source_needs_no_jpeg_intermediate(self):
        bundle = self.fresh_bundle()
        output = self.root / 'opaque-source'
        updates = icons.compile_app_icons(self.build / 'icon-opaque.png', bundle, output)
        self.assertIn('CFBundleIcons~ipad', updates)
        self.assertFalse((output / 'icon-rgb.jpg').exists())
        self.assertFalse(json.loads((output / 'icon-build.json').read_text())['source_had_alpha'])


if __name__ == '__main__':
    unittest.main()
