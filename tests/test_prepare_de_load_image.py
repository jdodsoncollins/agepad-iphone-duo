"""Synthetic Mach-O checks for linked SDK selection and private kit replay.

No Apple tools, game software, signing identities or devices are required.
"""
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import plistlib
import struct
import tempfile
import unittest
from unittest import mock
import zipfile

ROOT = Path(__file__).resolve().parents[1]


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, ROOT / path)
    loaded = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(loaded)
    return loaded


adapter = module('load_image', 'scripts/prepare-de-load-image.py')
kit = module('load_image_kit', 'scripts/agepad-kit.py')


def fixture_image():
    """A thin ARM64 main executable with distinct text and data section bytes."""
    commands = []
    payloads = [(b'__TEXT', b'__text', 4096, b'synthetic-text!!'),
                (b'__DATA', b'__data', 4128, b'synthetic-data!!')]
    for segment, section, offset, payload in payloads:
        commands.append(struct.pack('<II16sQQQQiiII', 0x19, 152, segment,
                                    0x100000000 + offset, 4096, offset, len(payload), 7, 5, 1, 0)
                        + struct.pack('<16s16sQQIIIIIIII', section, segment,
                                      0x100000000 + offset, len(payload), offset, 4, 0, 0, 0, 0, 0, 0))
    commands.append(struct.pack('<6I', 0x32, 24, 1, 11 << 16, 26 << 16, 0))
    commands.append(struct.pack('<IIQQ', 0x80000028, 24, 4096, 0))
    header = struct.pack('<8I', 0xfeedfacf, 0x100000c, 0, 2, len(commands),
                         sum(map(len, commands)), 0x200000, 0)
    image = bytearray(header + b''.join(commands))
    image.extend(bytes(4144 - len(image)))
    for _, _, offset, payload in payloads:
        image[offset:offset + len(payload)] = payload
    return bytes(image)


def build_version(image):
    return next(struct.unpack_from('<III', body, 8)
                for command, body in kit.commands(image) if command == 0x32)


def zerofill_fixture(section_type):
    image = bytearray(fixture_image())
    count, size = struct.unpack_from('<II', image, 16)
    command = (struct.pack('<II16sQQQQiiII', 0x19, 152, b'__DATA',
                           0x100002000, 4096, 0, 0, 7, 3, 1, 0)
               + struct.pack('<16s16sQQIIIIIIII', b'__thread_bss', b'__DATA',
                             0x100002000, 4096, 96, 4, 0, 0, section_type, 0, 0, 0))
    image[32 + size:32 + size + len(command)] = command
    struct.pack_into('<II', image, 16, count + 1, size + len(command))
    return bytes(image)


class LoadImageSDKTests(unittest.TestCase):
    def prepare_fixture(self, directory, **kwargs):
        source, destination = directory / 'source', directory / 'adapted'
        source.write_bytes(fixture_image())
        result = adapter.prepare(source, destination, preserve_executable=True, **kwargs)
        return source, destination, result

    def test_device_uses_selected_sdk_and_preserves_text_data_and_minimum_os(self):
        with tempfile.TemporaryDirectory() as temporary, \
                mock.patch.object(adapter.subprocess, 'check_output', return_value='27.1\n') as selected, \
                mock.patch.object(adapter.subprocess, 'run') as signing:
            source, destination, report = self.prepare_fixture(Path(temporary), platform='ios-device')
            selected.assert_called_once_with(['xcrun', '--sdk', 'iphoneos', '--show-sdk-version'], text=True)
            self.assertEqual(build_version(destination.read_bytes()), (2, 15 << 16, (27 << 16) | (1 << 8)))
            self.assertEqual(source.read_bytes(), fixture_image())
            self.assertEqual(kit.sections_digest(source.read_bytes()), kit.sections_digest(destination.read_bytes()))
            self.assertEqual(len(report['sections']), 2)
            self.assertTrue(all(section['equal'] for section in report['sections']))
            self.assertFalse(report['instructions_changed'])
            self.assertEqual(report['changes'][0]['sdk'], '27.1')
            signing.assert_called_once()

    def test_simulator_queries_its_own_sdk(self):
        with tempfile.TemporaryDirectory() as temporary, \
                mock.patch.object(adapter.subprocess, 'check_output', return_value='27.1.2\n') as selected, \
                mock.patch.object(adapter.subprocess, 'run'):
            _, destination, _ = self.prepare_fixture(Path(temporary))
            selected.assert_called_once_with(['xcrun', '--sdk', 'iphonesimulator', '--show-sdk-version'], text=True)
            self.assertEqual(build_version(destination.read_bytes()), (7, 15 << 16, (27 << 16) | (1 << 8) | 2))

    def test_older_sdk_remains_usable_for_ipad(self):
        with tempfile.TemporaryDirectory() as temporary, \
                mock.patch.object(adapter.subprocess, 'check_output', return_value='26.5\n'), \
                mock.patch.object(adapter.subprocess, 'run'):
            _, destination, _ = self.prepare_fixture(Path(temporary), platform='ios-device')
            self.assertEqual(build_version(destination.read_bytes())[2], (26 << 16) | (5 << 8))

    def test_recorded_sdk_does_not_need_xcode(self):
        with tempfile.TemporaryDirectory() as temporary, \
                mock.patch.object(adapter.subprocess, 'check_output', side_effect=AssertionError('Xcode queried')), \
                mock.patch.object(adapter.subprocess, 'run'):
            _, destination, _ = self.prepare_fixture(Path(temporary), platform='ios-device', sdk_version='27.1')
            self.assertEqual(kit.linked_sdk(destination.read_bytes()), '27.1.0')

    def test_section_preservation_guard_rejects_changed_program_bytes(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            def changed_by_signing(*args, **kwargs):
                destination = directory / 'adapted'
                data = bytearray(destination.read_bytes())
                data[4096] ^= 1
                destination.write_bytes(data)
            with mock.patch.object(adapter.subprocess, 'run', side_effect=changed_by_signing):
                with self.assertRaisesRegex(ValueError, 'Original section changed'):
                    self.prepare_fixture(directory, sdk_version='27.1')

    def test_invalid_or_truncated_sdk_versions_are_rejected(self):
        for version in ('27.beta', '27.1.2.3', '27.-1', '27.256', '65536.1', ''):
            with self.subTest(version=version), self.assertRaises(ValueError):
                adapter.packed_version(version)

    def test_sdk_271_normalizes_virtual_section_offsets_without_touching_payload(self):
        for section_type in (1, 0xc, 0x12):
            with self.subTest(section_type=section_type), tempfile.TemporaryDirectory() as temporary, \
                    mock.patch.object(adapter.subprocess, 'run'):
                source, destination = Path(temporary) / 'source', Path(temporary) / 'adapted'
                original = zerofill_fixture(section_type)
                source.write_bytes(original)
                report = adapter.prepare(source, destination, sdk_version='27.1')
                sections = [body for cmd, body in kit.commands(destination.read_bytes()) if cmd == 0x19]
                self.assertEqual(struct.unpack_from('<I', sections[-1], 120)[0], 0)
                self.assertEqual(struct.unpack_from('<QQ', sections[-1], 104), (0x100002000, 4096))
                self.assertEqual(original[4096:], destination.read_bytes()[4096:])
                self.assertEqual(kit.sections_digest(original), kit.sections_digest(destination.read_bytes()))
                self.assertEqual(len(report['sections']), 2)
                self.assertIn({'zerofill_file_offset':96,'normalized_to':0}, report['changes'])

    def test_legacy_sdk_keeps_virtual_section_header_for_recipe_replay(self):
        with tempfile.TemporaryDirectory() as temporary, mock.patch.object(adapter.subprocess, 'run'):
            source, destination = Path(temporary) / 'source', Path(temporary) / 'adapted'
            source.write_bytes(zerofill_fixture(0x12))
            adapter.prepare(source, destination, sdk_version='26.5')
            sections = [body for cmd, body in kit.commands(destination.read_bytes()) if cmd == 0x19]
            self.assertEqual(struct.unpack_from('<I', sections[-1], 120)[0], 96)


class KitSDKReplayTests(unittest.TestCase):
    def test_legacy_kit_keeps_its_fixed_sdk_without_xcode(self):
        with mock.patch.object(adapter.subprocess, 'check_output', side_effect=AssertionError('Xcode queried')):
            image = kit.transform(fixture_image(), [{'platform': 'ios-device', 'map': {}, 'preserve': True}])
        self.assertEqual(kit.linked_sdk(image), '26.5.0')
        self.assertEqual(kit.sections_digest(image), kit.sections_digest(fixture_image()))

    def test_new_recipe_pins_sdk_and_replays_without_xcode(self):
        with tempfile.TemporaryDirectory() as temporary, \
                mock.patch.object(adapter.subprocess, 'check_output', side_effect=AssertionError('Xcode queried')), \
                mock.patch.object(adapter.subprocess, 'run'), contextlib.redirect_stdout(io.StringIO()):
            directory = Path(temporary)
            game, app = directory / 'game', directory / 'Fixture.app'
            game.mkdir()
            app.mkdir()
            source = game / 'original'
            source.write_bytes(fixture_image())
            game_info = {'CFBundleIdentifier': 'fixture.game', 'CFBundleExecutable': 'original'}
            info = plistlib.dumps(game_info)
            (game / 'Info.plist').write_bytes(info)
            app_info = {**game_info, 'UIDeviceFamily': [1, 2], 'UIApplicationSceneManifest': {
                'UIApplicationSupportsMultipleScenes': False}}
            (app / 'Info.plist').write_bytes(plistlib.dumps(app_info))
            adapter.prepare(source, app / 'adapted', platform='ios-device',
                            preserve_executable=True, sdk_version='27.1')
            path = directory / 'recipe.json'
            self.assertEqual(kit.recipe(app, path, game, directory / 'no-steam'), 0)
            entry = next(entry for entry in json.loads(path.read_text())['files'] if entry['op'] == 'header')
            self.assertEqual(entry['edits'][0]['sdk'], '27.1.0')
            self.assertTrue(entry['verified'])
            rebuilt = kit.transform(source.read_bytes(), entry['edits'])
            self.assertEqual(kit.header_key(rebuilt), kit.header_key((app / 'adapted').read_bytes()))
            self.assertEqual(kit.sections_digest(rebuilt), kit.sections_digest(source.read_bytes()))
            base, injected = directory / 'base.ipa', directory / 'mine.ipa'
            kit.base(app, path, base)
            kit.inject(base, injected, game, directory / 'no-steam')
            with zipfile.ZipFile(injected) as archive:
                image = archive.read('Payload/Fixture.app/adapted')
                self.assertEqual(kit.linked_sdk(image), '27.1.0')
                self.assertEqual(kit.header_key(image), kit.header_key(rebuilt))
                self.assertEqual(plistlib.loads(archive.read('Payload/Fixture.app/Info.plist')), app_info)


if __name__ == '__main__':
    unittest.main()
