"""Exercise compact-pack boundaries and export isolation with synthetic assets."""
import hashlib
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
from phone_asset_profile import build_profile, exclusion_reason, export_profile, relative_path


class PhoneAssetProfileTests(unittest.TestCase):
    def test_content_boundaries(self):
        for name in ('resources/_common/drs/core.sld', 'resources/en/strings.txt',
                     'widgetui/textures/atlas/core.dds', 'wwise/en/core.bnk'):
            self.assertIsNone(exclusion_reason(name), name)
        for name in ('modes/Pompeii/data.bin', 'extras/soundtrack.mp3', 'Docs/manual.pdf',
                     'resources/fr/strings.txt', 'wwise/Pompeii.bnk', 'wwise/en/Pompeii.bnk',
                     'widgetui/textures/campaign/art.dds', 'resources/_common/movie.webm'):
            self.assertIsNotNone(exclusion_reason(name), name)
        self.assertIsNone(exclusion_reason('widgetui/textures/campaign/art.dds', campaigns=True))

    def test_export_preserves_bytes_and_isolates_source(self):
        with tempfile.TemporaryDirectory() as tmp:
            source, dest = Path(tmp) / 'Source', Path(tmp) / 'Export'
            (source / 'resources/_common').mkdir(parents=True)
            core = source / 'resources/_common/core.sld'
            core.write_bytes(b'unchanged core sprites')
            (source / 'extras').mkdir()
            (source / 'extras/bonus').write_bytes(b'optional')
            profile = build_profile(source, '25464371')
            self.assertEqual(profile['files'], 1)
            self.assertEqual(profile['source_files'], 2)
            self.assertEqual(profile['entries'][0]['sha256'], hashlib.sha256(core.read_bytes()).hexdigest())
            export_profile(source, dest, profile)
            copied = dest / 'resources/_common/core.sld'
            self.assertEqual(copied.read_bytes(), core.read_bytes())
            copied.write_bytes(b'changed export')
            self.assertEqual(core.read_bytes(), b'unchanged core sprites')
            self.assertFalse((dest / 'extras').exists())
            with self.assertRaises(ValueError):
                export_profile(source, dest, profile)

    def test_rejects_unsafe_inputs(self):
        for name in ('/escape', '../escape', 'a/../b', 'a//b', 'a\\b', 'a\0b'):
            with self.assertRaises(ValueError):
                relative_path(name)
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / 'program').write_bytes(b'MZ\x00\x00native program')
            with self.assertRaises(ValueError):
                build_profile(root, '1')
            (root / 'program').unlink()
            (root / 'alias').symlink_to(root, target_is_directory=True)
            with self.assertRaises(ValueError):
                build_profile(root, '1')


if __name__ == '__main__':
    unittest.main()
