"""Portable regression checks for iOS metadata and physical-device selection.

Synthetic fixtures only. These do not establish iPhone/Duo runtime support.
"""
import copy
import importlib.util
import json
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
MODULE_PATH = ROOT / 'scripts/agepad_device_config.py'
spec = importlib.util.spec_from_file_location('agepad_device_config', MODULE_PATH)
config = importlib.util.module_from_spec(spec)
spec.loader.exec_module(config)


def device(udid='fixture-ipad', family='iPad', **connection):
    return {'identifier': 'core-device-' + udid,
            'hardwareProperties': {'udid': udid, 'reality': 'physical', 'deviceType': family},
            'connectionProperties': {'pairingState': 'paired', 'transportType': 'wired', **connection}}


def inventory(*devices):
    return {'result': {'devices': list(devices)}}


class UniversalMetadataTests(unittest.TestCase):
    def test_older_sdk_warns_without_prohibiting_ipad_builds(self):
        self.assertIn('SDK 27.1', config.duo_sdk_warning('26.5'))
        self.assertIn('SDK 27.1', config.duo_sdk_warning('27.0'))
        self.assertEqual(config.duo_sdk_warning('27.1'), '')
        self.assertEqual(config.duo_sdk_warning('27.1.2'), '')
        self.assertEqual(config.duo_sdk_warning('28'), '')

    def test_ipad_only_candidate_becomes_resizable_universal_bundle(self):
        source = {'CFBundleIdentifier': 'fixture.game', 'CFBundleExecutable': 'fixture',
                  'MinimumOSVersion': '15.0', 'UIDeviceFamily': [2],
                  'UIRequiresFullScreen': True, 'UIRequiresFullScreen~ipad': True,
                  'UISupportedInterfaceOrientations': ['UIInterfaceOrientationLandscapeLeft'],
                  'UISupportedInterfaceOrientations~ipad': ['UIInterfaceOrientationLandscapeLeft'],
                  'UISupportedInterfaceOrientations~iphone': ['UIInterfaceOrientationLandscapeLeft'],
                  'CFBundleIcons': {'CFBundlePrimaryIcon': {'CFBundleIconName': 'VendorIcon'}},
                  'FixtureNestedData': {'retained': ['value']}}
        original = copy.deepcopy(source)
        result = plistlib.loads(plistlib.dumps(config.universal_info(source)))
        self.assertEqual(result['UIDeviceFamily'], [1, 2])
        self.assertEqual(result['CFBundleSupportedPlatforms'], ['iPhoneOS'])
        self.assertTrue(result['LSRequiresIPhoneOS'])
        self.assertNotIn('UIRequiresFullScreen', result)
        self.assertNotIn('UIRequiresFullScreen~ipad', result)
        self.assertNotIn('UISupportedInterfaceOrientations~iphone', result)
        self.assertEqual(result['UISupportedInterfaceOrientations'], config.PHONE_ORIENTATIONS)
        self.assertEqual(set(result['UISupportedInterfaceOrientations~ipad']), set(config.ORIENTATIONS))
        self.assertEqual(result['MinimumOSVersion'], '15.0')
        self.assertEqual(result['CFBundleExecutable'], 'fixture')
        self.assertEqual(result['FixtureNestedData'], original['FixtureNestedData'])
        self.assertEqual(source, original)

    def test_scene_metadata_uses_single_game_scene(self):
        scene = config.universal_info({})['UIApplicationSceneManifest']
        self.assertFalse(scene['UIApplicationSupportsMultipleScenes'])
        self.assertEqual(scene['UISceneConfigurations'], {
            'UIWindowSceneSessionRoleApplication': [{
                'UISceneConfigurationName': 'AgePad Game',
                'UISceneDelegateClassName': 'DEProbeSceneDelegate'}]})

    def test_simulator_keeps_its_platform(self):
        info = config.universal_info({}, supported_platform='iPhoneSimulator')
        self.assertEqual(info['CFBundleSupportedPlatforms'], ['iPhoneSimulator'])
        self.assertEqual(info['UIDeviceFamily'], [1, 2])

    def test_phone_and_ipad_icons_have_home_screen_variants(self):
        info = config.universal_info({'CFBundleIconFile': 'VendorIcon.icns',
                                      'CFBundleIconFiles': ['VendorIcon']})
        self.assertNotIn('CFBundleIconFile', info)
        self.assertNotIn('CFBundleIconFiles', info)
        self.assertIn('AppIcon60x60', info['CFBundleIcons']['CFBundlePrimaryIcon']['CFBundleIconFiles'])
        self.assertIn('AppIcon76x76', info['CFBundleIcons~ipad']['CFBundlePrimaryIcon']['CFBundleIconFiles'])
        self.assertEqual(config.ICON_SIZES['AppIcon60x60@3x.png'], 180)
        self.assertEqual(config.ICON_SIZES['AppIcon83.5x83.5@2x~ipad.png'], 167)


class PhysicalDeviceSelectionTests(unittest.TestCase):
    def test_single_ipad_retains_automatic_selection(self):
        self.assertEqual(config.select_device(inventory(device())), 'fixture-ipad')

    def test_single_phone_can_be_selected_automatically(self):
        self.assertEqual(config.select_device(inventory(device('fixture-phone', 'iPhone'))), 'fixture-phone')

    def test_reachable_network_phone_is_allowed(self):
        self.assertEqual(config.select_device(inventory(
            device('fixture-phone', 'iPhone', transportType='network'))), 'fixture-phone')

    def test_simulators_unpaired_unreachable_and_other_families_are_ignored(self):
        simulator = device('fixture-simulator', 'iPhone')
        simulator['hardwareProperties']['reality'] = 'simulated'
        self.assertEqual(config.select_device(inventory(
            simulator, device('unpaired', pairingState='unpaired'),
            device('unreachable', transportType=None), device('watch', 'AppleWatch'), device())), 'fixture-ipad')

    def test_ambiguous_devices_require_explicit_selection(self):
        devices = inventory(device(), device('fixture-phone', 'iPhone'))
        with self.assertRaisesRegex(ValueError, 'AGEPAD_UDID'):
            config.select_device(devices)
        self.assertEqual(config.select_device(devices, 'fixture-phone'), 'fixture-phone')
        self.assertEqual(config.select_device(devices, 'core-device-fixture-ipad'), 'fixture-ipad')

    def test_explicit_unreachable_or_unknown_device_is_rejected(self):
        with self.assertRaisesRegex(ValueError, 'AGEPAD_UDID'):
            config.select_device(inventory(device('offline', transportType=None), device()), 'offline')
        with self.assertRaisesRegex(ValueError, 'AGEPAD_UDID'):
            config.select_device(inventory(device()), 'missing')

    def test_no_device_is_an_error(self):
        with self.assertRaisesRegex(ValueError, 'No paired'):
            config.select_device(inventory())

    def test_cli_prints_only_selected_udid_and_refuses_ambiguity(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / 'devices.json'
            path.write_text(json.dumps(inventory(device(), device('fixture-phone', 'iPhone'))))
            command = [sys.executable, str(MODULE_PATH), str(path)]
            failure = subprocess.run(command, capture_output=True, text=True)
            self.assertEqual(failure.returncode, 1)
            self.assertEqual(failure.stdout, '')
            self.assertIn('AGEPAD_UDID', failure.stderr)
            selected = subprocess.run(command + ['--udid', 'fixture-phone'], capture_output=True, text=True)
            self.assertEqual(selected.returncode, 0)
            self.assertEqual(selected.stdout, 'fixture-phone\n')
            self.assertEqual(selected.stderr, '')


if __name__ == '__main__':
    unittest.main()
