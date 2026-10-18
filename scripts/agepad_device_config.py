"""Portable device selection and bundle metadata for AgePad's iOS build.

Declaring a device family does not establish that the game fits that device's
memory budget or works on it. The signed device probe still needs validation.
"""
import argparse
import copy
import json
from pathlib import Path
import sys


ORIENTATIONS = ['UIInterfaceOrientationPortrait',
                'UIInterfaceOrientationLandscapeLeft',
                'UIInterfaceOrientationLandscapeRight',
                'UIInterfaceOrientationPortraitUpsideDown']
PHONE_ORIENTATIONS = ['UIInterfaceOrientationLandscapeLeft',
                      'UIInterfaceOrientationLandscapeRight']

ICON_SIZES = {
    'AppIcon20x20@2x.png': 40, 'AppIcon20x20@3x.png': 60,
    'AppIcon29x29@2x.png': 58, 'AppIcon29x29@3x.png': 87,
    'AppIcon40x40@2x.png': 80, 'AppIcon40x40@3x.png': 120,
    'AppIcon60x60@2x.png': 120, 'AppIcon60x60@3x.png': 180,
    'AppIcon20x20~ipad.png': 20, 'AppIcon20x20@2x~ipad.png': 40,
    'AppIcon29x29~ipad.png': 29, 'AppIcon29x29@2x~ipad.png': 58,
    'AppIcon40x40~ipad.png': 40, 'AppIcon40x40@2x~ipad.png': 80,
    'AppIcon76x76~ipad.png': 76, 'AppIcon76x76@2x~ipad.png': 152,
    'AppIcon83.5x83.5@2x~ipad.png': 167,
}


def duo_sdk_warning(version):
    """Older SDKs remain usable for iPad builds, but cannot opt into Duo's full layout."""
    parts = [int(value) for value in version.split('.')]
    if tuple((parts + [0])[:2]) < (27, 1):
        return ('iOS SDK ' + version + ': iPhone Duo edge-to-edge layout requires SDK 27.1 or newer. '
                'Select a newer Xcode for Duo testing; existing iPad builds can still use this SDK.')
    return ''


def universal_info(source, *, supported_platform='iPhoneOS'):
    """Return device metadata without inheriting the iPad-only probe's limits.

    iPhone Duo changes scene bounds while the app is running. Support rotation
    and resizable windows, rather than opting into fixed-size compatibility.
    The game's layout must follow its actual view bounds, not the device idiom.
    """
    info = copy.deepcopy(source)
    info['UIDeviceFamily'] = [1, 2]
    info['CFBundleSupportedPlatforms'] = [supported_platform]
    info['LSRequiresIPhoneOS'] = True
    # The desktop RTS HUD needs landscape on a conventional phone. Duo's
    # inner display remains resizable regardless of this orientation mask.
    info['UISupportedInterfaceOrientations'] = list(PHONE_ORIENTATIONS)
    info['UISupportedInterfaceOrientations~ipad'] = list(ORIENTATIONS)
    for key in ('UIRequiresFullScreen', 'UIRequiresFullScreen~ipad',
                'UIRequiresFullScreen~iphone', 'UISupportedInterfaceOrientations~iphone'):
        info.pop(key, None)
    info['UIApplicationSceneManifest'] = {
        'UIApplicationSupportsMultipleScenes': False,
        'UISceneConfigurations': {'UIWindowSceneSessionRoleApplication': [{
            'UISceneConfigurationName': 'AgePad Game',
            'UISceneDelegateClassName': 'DEProbeSceneDelegate',
        }]},
    }
    # These are AgePad's own icons, including the iPhone @3x Home Screen icon.
    info.pop('CFBundleIconFile', None)
    info.pop('CFBundleIconFiles', None)
    info['CFBundleIcons'] = {'CFBundlePrimaryIcon': {
        'CFBundleIconFiles': ['AppIcon20x20', 'AppIcon29x29', 'AppIcon40x40', 'AppIcon60x60'],
        'UIPrerenderedIcon': False}}
    info['CFBundleIcons~ipad'] = {'CFBundlePrimaryIcon': {
        'CFBundleIconFiles': ['AppIcon20x20', 'AppIcon29x29', 'AppIcon40x40',
                              'AppIcon76x76', 'AppIcon83.5x83.5'],
        'UIPrerenderedIcon': False}}
    return info


def select_device(inventory, explicit=None):
    """Select a paired physical iOS device, requiring a choice if ambiguous.

    Read-only: never pair, boot, launch, install or change a device. Return its
    hardware UDID so devicectl and the USB sync tool address the same device.
    """
    devices = inventory['result']['devices']
    eligible = []
    for device in devices:
        hardware = device.get('hardwareProperties', {})
        connection = device.get('connectionProperties', {})
        if (hardware.get('reality') == 'physical'
                and hardware.get('deviceType') in ('iPhone', 'iPad')
                and hardware.get('udid')
                and connection.get('pairingState') == 'paired'
                and connection.get('transportType')):
            eligible.append(device)
    if explicit:
        for device in eligible:
            if explicit in (device['hardwareProperties']['udid'], device.get('identifier')):
                return device['hardwareProperties']['udid']
        raise ValueError('AGEPAD_UDID does not identify a paired, reachable physical iPhone or iPad. '
                         'Check xcrun devicectl list devices, unlock the device and tap Trust.')
    if not eligible:
        raise ValueError('No paired, reachable physical iPhone or iPad. Connect it by USB, unlock it '
                         'and tap Trust; enable Settings > Privacy & Security > Developer Mode.')
    if len(eligible) != 1:
        choices = ', '.join(device['hardwareProperties']['deviceType'] + ' '
                            + device['hardwareProperties']['udid'] for device in eligible)
        raise ValueError('Several iPhones/iPads are reachable. Set AGEPAD_UDID to the device you '
                         'intend to use: ' + choices)
    return eligible[0]['hardwareProperties']['udid']


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('inventory', type=Path, help='devicectl list devices --json-output file')
    parser.add_argument('--udid', default='', help='Explicit AGEPAD_UDID (hardware UDID or devicectl identifier)')
    args = parser.parse_args()
    try:
        print(select_device(json.loads(args.inventory.read_text()), args.udid))
    except (OSError, ValueError, KeyError, TypeError) as error:
        print('Could not select an AgePad device: ' + str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
