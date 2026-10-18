"""Exercise the production bundle resolver against synthetic signed-layout maps."""
import pathlib
import plistlib
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]


class BundleImagePathTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.build = tempfile.TemporaryDirectory()
        directory = pathlib.Path(cls.build.name)
        source = directory / 'resolver.c'
        source.write_text('''#include "BundleImagePaths.h"
int main(int argc, char **argv) {
    if (argc != 3) return 64;
    char path[PATH_MAX];
    if (!DECopyBundleImagePathAtRoot(argv[1], argv[2], path, sizeof(path))) return 2;
    puts(path); return 0;
}
''')
        cls.binary = directory / 'resolver'
        subprocess.run(['xcrun', 'clang', '-I', str(ROOT / 'port/de'), str(source),
                        '-framework', 'CoreFoundation', '-o', str(cls.binary)], check=True,
                       capture_output=True)

    @classmethod
    def tearDownClass(cls):
        cls.build.cleanup()

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = pathlib.Path(self.temporary.name).resolve() / 'AgePad.app'
        self.root.mkdir()
        self.legacy = 'Frameworks/steamclient.dylib'
        self.target = 'Frameworks/steamclient.framework/steamclient'
        image = self.root / self.target
        image.parent.mkdir(parents=True)
        image.write_bytes(b'synthetic non-executable fixture')

    def write_map(self, mapping):
        (self.root / 'AgePadLibraryMap.plist').write_bytes(plistlib.dumps(mapping))

    def resolve(self, relative=None):
        return subprocess.run([str(self.binary), str(self.root), relative or self.legacy],
                              capture_output=True, text=True)

    def test_development_bundle_without_map_uses_original_relative_path(self):
        result = self.resolve()
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout.strip(), str(self.root / self.legacy))

    def test_framework_map_resolves_real_code_location(self):
        self.write_map({self.legacy: self.target})
        result = self.resolve()
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout.strip(), str(self.root / self.target))

    def test_existing_map_never_falls_back_for_missing_entry(self):
        self.write_map({'DEBoundary_AppKit.dylib': self.target})
        result = self.resolve()
        self.assertEqual(result.returncode, 2)
        self.assertEqual(result.stdout, '')

    def test_malformed_empty_or_non_dictionary_map_fails(self):
        for mapping in ({}, [], {self.legacy: True}, {self.legacy: 1}):
            with self.subTest(mapping=mapping):
                self.write_map(mapping)
                self.assertEqual(self.resolve().returncode, 2)
        (self.root / 'AgePadLibraryMap.plist').write_bytes(b'not a property list')
        self.assertEqual(self.resolve().returncode, 2)

    def test_rejects_traversal_absolute_and_non_framework_destinations(self):
        for value in ('../outside', '/tmp/outside', 'Frameworks/../outside',
                      'Frameworks/x.dylib', 'Frameworks/x.framework/y',
                      'Frameworks/x.framework/x/other', 'Frameworks//x.framework/x'):
            with self.subTest(value=value):
                self.write_map({self.legacy: value})
                self.assertEqual(self.resolve().returncode, 2)
        self.write_map({self.legacy: self.target})
        for value in ('../steamclient.dylib', '/tmp/outside', './Frameworks/steamclient.dylib'):
            self.assertEqual(self.resolve(value).returncode, 2)

    def test_invalid_other_map_record_invalidates_whole_map(self):
        self.write_map({self.legacy: self.target, 'other.dylib': '../outside'})
        self.assertEqual(self.resolve().returncode, 2)

    def test_binary_plist_embedded_null_and_non_ascii_never_truncate_validation(self):
        for mapping in ({self.legacy: self.target + '\x00/../outside'},
                        {self.legacy: self.target, 'other.dylib\x00/../outside': self.target},
                        {self.legacy: 'Frameworks/caf\u00e9.framework/caf\u00e9'}):
            with self.subTest(mapping=mapping):
                (self.root / 'AgePadLibraryMap.plist').write_bytes(plistlib.dumps(mapping, fmt=plistlib.FMT_BINARY))
                self.assertEqual(self.resolve().returncode, 2)

    def test_missing_image_and_symlink_escape_fail(self):
        self.write_map({self.legacy: self.target})
        image = self.root / self.target
        image.unlink()
        self.assertEqual(self.resolve().returncode, 2)
        outside = self.root.parent / 'outside'
        outside.write_bytes(b'outside fixture')
        image.symlink_to(outside)
        self.assertEqual(self.resolve().returncode, 2)

    def test_bounded_map_count_and_bytes(self):
        self.write_map({f'lib{i}.dylib': self.target for i in range(257)})
        self.assertEqual(self.resolve().returncode, 2)
        (self.root / 'AgePadLibraryMap.plist').write_bytes(b' ' * ((1 << 20) + 1))
        self.assertEqual(self.resolve().returncode, 2)


if __name__ == '__main__':
    unittest.main()
