#!/usr/bin/env python3
"""Compile the public launcher boundary and exercise its real preferences policy.

Host-only checks: no Simulator, account, install, signing or game execution.
"""
from pathlib import Path
import os
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


def checked(command):
    run = subprocess.run(command, cwd=ROOT, capture_output=True, text=True)
    if run.returncode:
        raise AssertionError(f'{command[0]} failed ({run.returncode}):\n{run.stderr[-7000:]}')
    return run.stdout


class PublicLauncherTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix='agepad-public-launcher-')
        cls.output = Path(cls.temp.name)
        text = (ROOT / 'port/de/LoaderProbe.m').read_text()
        start = text.index('static void DEApplyPublicLauncherPolicy(')
        end = text.index('\n#endif', start)
        source = cls.output / 'policy.m'
        source.write_text('#import <Foundation/Foundation.h>\n#include "UnsupportedBoundary.h"\n' + text[start:end] + '''
int main(int argc,char **argv) { @autoreleasepool {
    if (argc != 2) return 64;
    DEApplyPublicLauncherPolicy(@(argv[1]));
    return 0;
} }
''')
        cls.executable = cls.output / 'policy'
        checked(['xcrun', 'clang', '-fobjc-arc', '-I', str(ROOT / 'port/de'), str(source),
                 '-framework', 'Foundation', '-o', str(cls.executable)])

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def policy(self, content, expected=0):
        path = self.output / self.id().split('.')[-1]
        if content is not None:
            path.write_text(content)
        run = subprocess.run([str(self.executable), str(path)], capture_output=True, text=True)
        self.assertEqual(run.returncode, expected, run.stderr)
        return path.read_text() if path.exists() else None

    def test_existing_preferences_preserved(self):
        old = '<key name="Setup"><value name="GameOptionsDialogShouldShow" type="integer">1</value>' \
              '<value name="AllowSendUsageData" type="integer">1</value></key>' \
              '<value name="UI Scale" type="integer">100</value>'
        self.assertEqual(self.policy(old), old.replace('>1</value>', '>0</value>', 1))

    def test_missing_launcher_setting_inserted(self):
        old = '<registry><key name="Setup"><value name="Other" type="integer">7</value></key></registry>'
        result = self.policy(old)
        self.assertIn('name="GameOptionsDialogShouldShow" type="integer">0</value>', result)
        self.assertIn('<value name="Other" type="integer">7</value>', result)

    def test_already_disabled_is_identical(self):
        old = '<key name="Setup"><value name="GameOptionsDialogShouldShow" type="integer">0</value></key>'
        self.assertEqual(self.policy(old), old)

    def test_duplicate_launcher_settings_rejected_without_write(self):
        old = '<key name="Setup">' + '<value name="GameOptionsDialogShouldShow" type="integer">1</value>' * 2 + '</key>'
        self.assertEqual(self.policy(old, 78), old)

    def test_unrecognized_preferences_rejected_without_write(self):
        old = '<registry><key name="Unrecognized"/></registry>'
        self.assertEqual(self.policy(old, 78), old)

    def test_missing_preferences_rejected(self):
        self.assertIsNone(self.policy(None, 78))

    def test_legacy_host_is_compiled_out(self):
        source = self.output / 'host.m'
        includes = ['AppLifecycleCompat.m', 'SteamModuleCompat.m', 'ScreenCompat.m',
                    'LoaderProbe.m', 'AlertCompat.m', 'DefaultCursorCompat.m',
                    'EventCompat.m', 'ImageCompat.m', 'MenuCompat.m', 'PasteboardCompat.m',
                    'TrackingAreaCompat.m', 'WindowViewCompat.m']
        source.write_text('#define DE_EMBEDDED_DELEGATE 1\n' +
                          ''.join(f'#include "{name}"\n' for name in includes))
        sdk = checked(['xcrun', '--sdk', 'iphonesimulator', '--show-sdk-path']).strip()
        base = ['xcrun', 'clang', '-target', 'arm64-apple-ios15.0-simulator', '-isysroot', sdk,
                '-fobjc-arc', '-I', str(ROOT / 'port/de'), str(source)]
        public = checked(base + ['-DAGEPAD_PUBLIC_API=1', '-E', '-P'])
        legacy = checked(base + ['-E', '-P'])
        for marker in ('WebThreadLock', 'WAKWindow', 'WAKView', 'DELegacyHost', 'DEWebLock'):
            self.assertIn(marker, legacy, marker)
            self.assertNotIn(marker, public, marker)
        self.assertIn('DEApplyPublicLauncherPolicy', public)
        self.assertNotIn('DEApplyPublicLauncherPolicy', legacy)
        checked(base + ['-DAGEPAD_PUBLIC_API=1', '-fsyntax-only'])
        checked(base + ['-fsyntax-only'])

    def test_public_webkit_links_for_both_platforms(self):
        source = self.output / 'WebKit.m'
        source.write_text('#include "PublicLauncherCompat.m"\n')
        for sdk_name, target in [('iphonesimulator', 'arm64-apple-ios15.0-simulator'),
                                 ('iphoneos', 'arm64-apple-ios15.0')]:
            with self.subTest(sdk=sdk_name):
                sdk = checked(['xcrun', '--sdk', sdk_name, '--show-sdk-path']).strip()
                output = self.output / (sdk_name + '.dylib')
                command = ['xcrun', 'clang', '-target', target, '-isysroot', sdk, '-fobjc-arc',
                           '-dynamiclib', '-I', str(ROOT / 'port/de'), str(source),
                           '-framework', 'Foundation', '-framework', 'UIKit',
                           '-Wl,-reexport_framework,WebKit', '-o', str(output)]
                for name in ('WebView', 'WebScriptObject', 'WebUndefined'):
                    for kind in ('CLASS', 'METACLASS'):
                        command.append(f'-Wl,-alias,_OBJC_{kind}_$_DEPublicDesktop{name},_OBJC_{kind}_$_{name}')
                checked(command)
                symbols = checked(['xcrun', 'nm', '-gU', str(output)])
                for name in ('WebView', 'WebScriptObject', 'WebUndefined'):
                    self.assertIn('_OBJC_CLASS_$_' + name, symbols)
                    self.assertIn('_OBJC_CLASS_$_DEPublicDesktop' + name, symbols)


if __name__ == '__main__':
    unittest.main()
