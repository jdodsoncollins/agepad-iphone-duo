"""Compare the native and packaging section digests using synthetic images."""
import hashlib
from pathlib import Path
import struct
import subprocess
import tempfile
import unittest

import test_prepare_de_load_image as fixtures

ROOT = Path(__file__).resolve().parents[1]


class SteamModuleDigestTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.directory = tempfile.TemporaryDirectory(prefix='agepad-module-digest-')
        cls.addClassCleanup(cls.directory.cleanup)
        cls.folder = Path(cls.directory.name)
        source = cls.folder / 'digest.m'
        cls.binary = cls.folder / 'digest'
        source.write_text('''#import "SteamModuleDigest.h"
int main(int argc,char **argv) {
    @autoreleasepool {
        NSString *digest=DESteamModuleSectionsDigest(@(argv[1]));
        if(!digest)return 1;
        printf("%s\\n",digest.UTF8String);
    }
    return 0;
}
''')
        subprocess.run(['xcrun', 'clang', '-fobjc-arc', '-Wno-deprecated-declarations',
                        '-I', str(ROOT / 'port/de'), str(source), '-framework', 'Foundation',
                        '-o', str(cls.binary)], check=True, capture_output=True)

    def native_digest(self, image):
        path = self.folder / 'image'
        path.write_bytes(image)
        return subprocess.check_output([str(self.binary), str(path)], text=True).strip()

    def test_small_virtual_sections_match_packaging(self):
        for section_type in (1, 0xc, 0x12):
            with self.subTest(section_type=section_type):
                image = bytearray(fixtures.zerofill_fixture(section_type))
                command = 32 + struct.unpack_from('<I', fixtures.fixture_image(), 20)[0]
                struct.pack_into('<Q', image, command + 72 + 40, 16)
                self.assertEqual(self.native_digest(image), fixtures.kit.sections_digest(image))
                struct.pack_into('<I', image, command + 72 + 48, 0)
                self.assertEqual(self.native_digest(image), fixtures.kit.sections_digest(image))

    def test_signature_changes_are_ignored_but_section_changes_are_detected(self):
        original = bytearray(fixtures.fixture_image())
        count, size = struct.unpack_from('<II', original, 16)
        original[32 + size:32 + size + 16] = struct.pack('<4I', 0x1d, 16, len(original), 16)
        struct.pack_into('<II', original, 16, count + 1, size + 16)
        original.extend(b'fixture-signing!')
        digest = self.native_digest(original)
        self.assertEqual(digest, fixtures.kit.sections_digest(original))
        changed_signature = bytearray(original)
        changed_signature[-1] ^= 1
        self.assertNotEqual(hashlib.sha256(original).digest(), hashlib.sha256(changed_signature).digest())
        self.assertEqual(self.native_digest(changed_signature), digest)
        changed_section = bytearray(original)
        changed_section[4096] ^= 1
        self.assertNotEqual(self.native_digest(changed_section), digest)
        self.assertEqual(self.native_digest(changed_section), fixtures.kit.sections_digest(changed_section))


if __name__ == '__main__':
    unittest.main()
