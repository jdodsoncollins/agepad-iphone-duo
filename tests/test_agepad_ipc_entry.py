"""Synthetic Mach-O entry validation; no Steam binary or device execution."""
import copy
import importlib.util
from pathlib import Path
import struct
import unittest

spec = importlib.util.spec_from_file_location('agepad_ipc_entry', Path(__file__).resolve().parents[1] / 'scripts/agepad_ipc_entry.py')
entry = importlib.util.module_from_spec(spec)
spec.loader.exec_module(entry)


def name(value):
    return value.encode().ljust(16, b'\0')


def image(*, executable=True, entries=None, position=512, address=None, initprot=5):
    base = 0x100000000
    address = base + position if address is None else address
    section = name('__text') + name('__TEXT') + struct.pack('<QQ8I', address, 64, position, 2, 0, 0, 0x80000400, 0, 0, 0)
    segment = struct.pack('<II', 0x19, 152) + name('__TEXT') + struct.pack('<4Q4I', base, 4096, 0, 640, 7, initprot, 1, 0) + section
    entries = ([512] if executable else []) if entries is None else entries
    commands = [segment] + [struct.pack('<IIQQ', 0x80000028, 24, value, 0) for value in entries]
    blob = b''.join(commands)
    raw = bytearray(struct.pack('<8I', 0xfeedfacf, 0x100000c, 0, 2 if executable else 6, len(commands), len(blob), 0, 0) + blob)
    raw.extend(b'\0' * (640 - len(raw)))
    raw[position:position + 64] = bytes(range(64))
    return bytes(raw)


class IPCEntryTests(unittest.TestCase):
    def test_derives_header_relative_entry_from_lc_main_and_pins_source(self):
        source = image(entries=[528])
        metadata = entry.derive_helper_entry(source)
        self.assertEqual(metadata['header_relative_entry'], 528)
        self.assertEqual(metadata['entry_section'], {'segment': '__TEXT', 'section': '__text', 'file_offset': 512, 'size': 64})
        self.assertEqual(len(metadata['source_sha256']), 64)
        self.assertEqual(len(metadata['executable_sections_sha256']), 64)
        entry.validate_helper_entry(metadata, source, image(executable=False))

    def test_rejects_missing_duplicate_unaligned_and_outside_entry(self):
        for entries in ([], [512, 512], [513], [0], [508], [576], [6888]):
            with self.subTest(entries=entries), self.assertRaises(ValueError):
                entry.derive_helper_entry(image(entries=entries))

    def test_rejects_nonexecutable_or_inconsistent_text_geometry(self):
        for source in (image(executable=False), image(initprot=3), image(address=0x100000000 + 516)):
            with self.assertRaises(ValueError):
                entry.derive_helper_entry(source)

    def test_rejects_truncated_and_non_arm64_headers(self):
        source = bytearray(image())
        struct.pack_into('<I', source, 4, 0x1000007)
        for raw in (b'', image()[:120], bytes(source)):
            with self.assertRaises(ValueError):
                entry.derive_helper_entry(raw)

    def test_signing_trailer_changes_do_not_change_executable_section_digest(self):
        source = image()
        metadata = entry.derive_helper_entry(source)
        entry.validate_helper_entry(metadata, source, image(executable=False) + b'new signing trailer')

    def test_changed_executable_bytes_are_rejected(self):
        source = image()
        changed = bytearray(image(executable=False))
        changed[520] ^= 1
        with self.assertRaisesRegex(ValueError, 'sections changed'):
            entry.validate_helper_entry(entry.derive_helper_entry(source), source, bytes(changed))

    def test_source_and_metadata_tampering_are_rejected(self):
        source = image()
        metadata = entry.derive_helper_entry(source)
        changed = source + b'different exact source'
        with self.assertRaises(ValueError):
            entry.validate_helper_entry(metadata, changed, image(executable=False))
        for key, value in (('schema_version', True), ('header_relative_entry', 512.0), ('source_sha256', '0' * 64)):
            bad = copy.deepcopy(metadata)
            bad[key] = value
            with self.subTest(key=key), self.assertRaises(ValueError):
                entry.validate_helper_entry(bad, source, image(executable=False))

    def test_translated_must_be_dylib_without_lc_main(self):
        source = image()
        for changed in (image(), image(executable=False, entries=[512])):
            with self.assertRaises(ValueError):
                entry.validate_helper_entry(entry.derive_helper_entry(source), source, changed)


if __name__ == '__main__':
    unittest.main()
