"""Synthetic distribution/profile fixtures; no credentials or game bytes."""
import datetime
import importlib.util
from pathlib import Path
import plistlib
import struct
import tempfile
import unittest
from unittest import mock

spec = importlib.util.spec_from_file_location('agepad_distribution', Path(__file__).resolve().parents[1] / 'scripts/agepad_distribution.py')
distribution = importlib.util.module_from_spec(spec)
spec.loader.exec_module(distribution)
NOW = datetime.datetime(2026, 1, 1, tzinfo=datetime.timezone.utc)


def profile(*, development=False):
    result = {'TeamIdentifier': ['TEAMFIXTURE'], 'ApplicationIdentifierPrefix': ['PREFIXFIXTURE'],
              'Platform': ['iOS'], 'ExpirationDate': NOW + datetime.timedelta(days=30),
              'Entitlements': {'application-identifier': 'PREFIXFIXTURE.org.fixture.game',
                               'com.apple.developer.team-identifier': 'TEAMFIXTURE',
                               'get-task-allow': development}}
    if development:
        result['ProvisionedDevices'] = ['fixture-device']
    else:
        result['Entitlements']['beta-reports-active'] = True
        result['Entitlements']['keychain-access-groups'] = ['PREFIXFIXTURE.*']
    return result


def image(file_type=6, *, platform=2, dependencies=(), install_name=None):
    commands = [struct.pack('<6I', 0x32, 24, platform, 15 << 16, 27 << 16, 0)]
    for command, name in ([(0xc, value) for value in dependencies] + ([(0xd, install_name)] if install_name else [])):
        encoded = name.encode() + b'\0'
        size = (24 + len(encoded) + 7) & ~7
        commands.append(struct.pack('<6I', command, size, 24, 0, 0x10000, 0x10000) + encoded + b'\0' * (size - 24 - len(encoded)))
    blob = b''.join(commands)
    return struct.pack('<8I', 0xfeedfacf, 0x100000c, 0, file_type, len(commands), len(blob), 0, 0) + blob


def info():
    return {'CFBundleExecutable': 'Game', 'CFBundleIdentifier': 'org.fixture.game',
            'CFBundlePackageType': 'APPL', 'CFBundleVersion': '1',
            'CFBundleShortVersionString': '1.0', 'CFBundleSupportedPlatforms': ['iPhoneOS'],
            'DTPlatformName': 'iphoneos', 'MinimumOSVersion': '15.0',
            'CFBundleIcons': {'CFBundlePrimaryIcon': {'CFBundleIconName': 'AppIcon'}}}


class ProfileTests(unittest.TestCase):
    def test_distribution_uses_profile_prefix_and_excludes_unrequested_grants(self):
        fixture = profile()
        fixture['Entitlements']['aps-environment'] = 'production'
        result = distribution.signing_entitlements(fixture, 'org.fixture.game', 'app-store', now=NOW)
        self.assertEqual(result, {'application-identifier': 'PREFIXFIXTURE.org.fixture.game',
                                 'com.apple.developer.team-identifier': 'TEAMFIXTURE', 'get-task-allow': False,
                                 'beta-reports-active': True,
                                 'keychain-access-groups': ['PREFIXFIXTURE.org.fixture.game']})

    def test_development_requires_development_profile(self):
        self.assertTrue(distribution.signing_entitlements(profile(development=True), 'org.fixture.game', 'development', now=NOW)['get-task-allow'])
        with self.assertRaisesRegex(ValueError, 'Development'):
            distribution.signing_entitlements(profile(), 'org.fixture.game', 'development', now=NOW)

    def test_distribution_rejects_debug_adhoc_enterprise_expired_and_wrong_app(self):
        for change in ('debug', 'devices', 'enterprise', 'expired', 'app', 'team', 'platform'):
            fixture = profile()
            if change == 'debug': fixture['Entitlements']['get-task-allow'] = True
            elif change == 'devices': fixture['ProvisionedDevices'] = ['fixture-device']
            elif change == 'enterprise': fixture['ProvisionsAllDevices'] = True
            elif change == 'expired': fixture['ExpirationDate'] = NOW
            elif change == 'app': fixture['Entitlements']['application-identifier'] = 'PREFIXFIXTURE.other.game'
            elif change == 'team': fixture['Entitlements']['com.apple.developer.team-identifier'] = 'OTHER'
            elif change == 'platform': fixture['Platform'] = ['macOS']
            with self.subTest(change=change), self.assertRaises(ValueError):
                distribution.signing_entitlements(fixture, 'org.fixture.game', 'app-store', now=NOW)

    def test_memory_is_requested_only_with_actual_grant(self):
        fixture = profile()
        with self.assertRaisesRegex(ValueError, 'memory'):
            distribution.signing_entitlements(fixture, 'org.fixture.game', 'app-store', increased_memory_limit=True, now=NOW)
        fixture['Entitlements'][distribution.MEMORY_ENTITLEMENT] = True
        self.assertNotIn(distribution.MEMORY_ENTITLEMENT, distribution.signing_entitlements(fixture, 'org.fixture.game', 'app-store', now=NOW))
        self.assertTrue(distribution.signing_entitlements(fixture, 'org.fixture.game', 'app-store', increased_memory_limit=True, now=NOW)[distribution.MEMORY_ENTITLEMENT])

    def test_wildcard_resolves_one_concrete_identifier(self):
        fixture = profile()
        fixture['Entitlements']['application-identifier'] = 'PREFIXFIXTURE.*'
        self.assertEqual(distribution.signing_entitlements(fixture, 'org.fixture.game', 'app-store', now=NOW)['application-identifier'], 'PREFIXFIXTURE.org.fixture.game')

    def test_testflight_requires_beta_report_and_app_default_keychain_grants(self):
        for grant in ('beta-reports-active', 'keychain-access-groups'):
            fixture = profile()
            fixture['Entitlements'].pop(grant)
            with self.subTest(grant=grant), self.assertRaises(ValueError):
                distribution.signing_entitlements(fixture, 'org.fixture.game', 'app-store', now=NOW)

    def test_exact_signed_entitlements_reject_unrequested_and_changed_grants(self):
        expected = distribution.signing_entitlements(profile(), 'org.fixture.game', 'app-store', now=NOW)
        distribution.validate_signed_entitlements(dict(expected), expected)
        for mutation in ({**expected, 'aps-environment': 'production'},
                         {**expected, 'get-task-allow': True},
                         {**expected, 'keychain-access-groups': ['PREFIXFIXTURE.*']}):
            with self.assertRaises(ValueError):
                distribution.validate_signed_entitlements(mutation, expected)


class BundleTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.bundle = Path(self.temporary.name) / 'Game.app'
        self.bundle.mkdir()
        (self.bundle / 'Info.plist').write_bytes(plistlib.dumps(info()))
        (self.bundle / 'Game').write_bytes(image(2))
        (self.bundle / 'Assets.car').write_bytes(b'fixture catalog; actual actool outputs checked separately')

    def audit(self, **kwargs):
        return distribution.inspect_bundle(self.bundle, **kwargs)

    def test_unsigned_report_never_claims_upload_ready(self):
        report = self.audit()
        self.assertFalse(report['ready'])
        self.assertEqual({item['code'] for item in report['blockers']}, {'missing-profile', 'unsigned-bundle'})
        self.assertTrue(self.audit(require_profile=False, require_signature=False)['ready'])

    def test_distribution_requires_compiled_app_icon_catalog(self):
        (self.bundle / 'Assets.car').unlink()
        self.assertIn('missing-app-icon-catalog', {item['code'] for item in self.audit()['blockers']})

    def test_detects_loose_libraries_extra_executable_private_markers_and_simulator(self):
        (self.bundle / 'Loose.dylib').write_bytes(image(platform=7) + b'WebThreadLock')
        (self.bundle / 'Child').write_bytes(image(2))
        codes = {item['code'] for item in self.audit()['blockers']}
        self.assertTrue({'standalone-dylib', 'extra-executable', 'private-api-reference', 'non-ios-image'} <= codes)

    def test_detects_missing_and_escaping_local_dependencies(self):
        (self.bundle / 'Game').write_bytes(image(2, dependencies=('@loader_path/missing.dylib', '@executable_path/../escape.dylib')))
        missing = [item for item in self.audit()['blockers'] if item['code'] == 'unresolved-dependency']
        self.assertEqual(len(missing), 2)

    def test_flat_framework_structure_and_install_name(self):
        folder = self.bundle / 'Frameworks/Boundary.framework'
        folder.mkdir(parents=True)
        binary = folder / 'Boundary'
        binary.write_bytes(image(install_name='@executable_path/Frameworks/Boundary.framework/Boundary'))
        (folder / 'Info.plist').write_bytes(plistlib.dumps({'CFBundleExecutable': 'Boundary', 'CFBundlePackageType': 'FMWK'}))
        (self.bundle / 'Game').write_bytes(image(2, dependencies=('@executable_path/Frameworks/Boundary.framework/Boundary',)))
        self.assertTrue(self.audit(require_profile=False, require_signature=False)['ready'])
        binary.write_bytes(image(install_name='@loader_path/old.dylib'))
        self.assertIn('invalid-framework-install-name', {item['code'] for item in self.audit()['blockers']})

    def test_framework_plan_and_exact_rewrites_include_repeated_suffixes(self):
        (self.bundle / 'Vendor_api.dylib.dylib').write_bytes(image(install_name='@loader_path/Vendor_api.dylib.dylib'))
        plan = distribution.framework_plan(self.bundle)
        self.assertEqual(plan, {'Vendor_api.dylib.dylib': 'Frameworks/V_api.framework/V_api'})
        metadata = distribution.macho_metadata(image(2, dependencies=('@loader_path/Vendor_api.dylib.dylib', '@loader_path/somewhere/Vendor_api.dylib.dylib')))
        self.assertEqual(distribution.dependency_rewrites(self.bundle, self.bundle / 'Game', metadata, plan),
                         {'@loader_path/Vendor_api.dylib.dylib': '@executable_path/Frameworks/V_api.framework/V_api'})

    def test_framework_collisions_are_rejected(self):
        (self.bundle / 'Same.dylib').write_bytes(image())
        (self.bundle / 'Frameworks').mkdir()
        (self.bundle / 'Frameworks/Same.dylib').write_bytes(image() + b'different')
        with self.assertRaisesRegex(ValueError, 'collision'):
            distribution.framework_plan(self.bundle)

    def test_identical_copies_share_one_framework(self):
        (self.bundle / 'Same.dylib').write_bytes(image())
        (self.bundle / 'Frameworks').mkdir()
        (self.bundle / 'Frameworks/Same.dylib').write_bytes(image())
        plan = distribution.framework_plan(self.bundle)
        self.assertEqual(len(plan), 2)
        self.assertEqual(len(set(plan.values())), 1)

    def test_escaping_symlink_is_rejected(self):
        (self.bundle / 'escape').symlink_to(self.bundle.parent)
        self.assertIn('escaping-symlink', {item['code'] for item in self.audit()['blockers']})

    def test_metadata_replaces_desktop_fields_with_selected_sdk(self):
        source = {'NSMainNibFile': 'MainMenu', 'NSPrincipalClass': 'NSApplication', 'LSMinimumSystemVersion': '15.0'}
        result = distribution.distribution_info(source, sdk_version='27.1', sdk_build='FIXTURESDK', xcode_version='2710', xcode_build='FIXTUREXCODE', version='1.2', build_number='3')
        self.assertNotIn('NSMainNibFile', result)
        self.assertEqual(result['DTSDKName'], 'iphoneos27.1')
        self.assertEqual(result['CFBundleVersion'], '3')
        self.assertEqual(source['NSMainNibFile'], 'MainMenu')
        with self.assertRaises(ValueError):
            distribution.distribution_info({}, sdk_version='27.1', sdk_build='x', xcode_version='2710', xcode_build='x', build_number='bad')

    def test_malformed_macho_is_explicit_failure(self):
        (self.bundle / 'Broken.dylib').write_bytes(b'\xcf\xfa\xed\xfe')
        self.assertIn('invalid-image', {item['code'] for item in self.audit()['blockers']})

    def test_signature_check_uses_attached_optional_extract_argument_and_profile_certificate(self):
        fixture = profile()
        fixture['ExpirationDate'] = datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None) + datetime.timedelta(days=30)
        fixture['DeveloperCertificates'] = [b'fixture-leaf-certificate']
        entitlements = distribution.signing_entitlements(fixture, 'org.fixture.game', 'app-store')

        def output(command, **_):
            return plistlib.dumps(fixture if command[0] == 'security' else entitlements)

        def run(command, **_):
            if '--display' in command:
                extraction = [arg for arg in command if arg.startswith('--extract-certificates=')]
                self.assertEqual(len(extraction), 1)
                Path(extraction[0].split('=', 1)[1] + '0').write_bytes(b'fixture-leaf-certificate')
            return None

        with mock.patch.object(distribution.subprocess, 'check_output', side_effect=output), \
                mock.patch.object(distribution.subprocess, 'run', side_effect=run):
            self.assertIsNone(distribution.verify_distribution_signature(self.bundle, 'org.fixture.game', 'app-store'))


if __name__ == '__main__':
    unittest.main()
