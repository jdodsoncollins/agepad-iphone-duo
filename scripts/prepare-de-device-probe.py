#!/usr/bin/env python3
"""Sign an isolated iPhone/iPad DE launch probe from a private Simulator candidate.

This does not stage game data, provide Steam services, install, or prove play.
"""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess

from agepad_device_config import ICON_SIZES, universal_info
from agepad_distribution import (dependency_rewrites, distribution_info, framework_plan,
                                 inspect_bundle, macho_metadata, signing_entitlements)
from agepad_ipc_entry import validate_helper_entry

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--candidate-root', type=Path, required=True)
parser.add_argument('--steam-client', type=Path, help='Steam client chain folder (default: CANDIDATE/package/game-client)')
parser.add_argument('--boundary', type=Path, required=True, help='Output of build-de-device-runtime.py')
parser.add_argument('--output', type=Path, required=True, help='Fresh .app path')
parser.add_argument('--profile', type=Path)
parser.add_argument('--identity')
parser.add_argument('--signing-mode', choices=('development', 'app-store'), default='development',
                    help='Development remains the default; app-store requires a distribution profile')
parser.add_argument('--unsigned', action='store_true',
                    help='Stage and inspect only; remove ad hoc signatures and do not identity-sign or embed a profile')
parser.add_argument('--framework-layout', action='store_true',
                    help='Embed dylibs as flat frameworks with exact load-path rewrites and a runtime image map')
parser.add_argument('--version', help='CFBundleShortVersionString for this fresh candidate')
parser.add_argument('--build-number', help='CFBundleVersion for this fresh candidate')
parser.add_argument('--ipc-load-probe', type=Path, help='Output of build-de-device-ipc-probe.py')
parser.add_argument('--original-steam-module', type=Path,
                    help='Owned unmodified Mac libsteam_api.dylib; staged as inert data for exact module validation')
parser.add_argument('--bundle-id', default='local.agepad.device-de-probe')
parser.add_argument('--steam-app-manifest', type=Path,
                    help="Mac Steam's appmanifest_813780.acf (read only): the installed build the imported files match")
parser.add_argument('--increased-memory-limit', action='store_true',
                    help='Request com.apple.developer.kernel.increased-memory-limit; the profile must grant it')
parser.add_argument('--launch-env', type=Path,
                    help='AGEPAD_* KEY=VALUE settings baked in for tap-to-play launches (AgePadLaunch.env)')
parser.add_argument('--asset-profile', type=Path,
                    help='Private phone_asset_profile.py manifest; assets are imported separately through Files')
parser.add_argument('--game-artwork', type=Path,
                    help='Optional private JPEG for the game card; omitted builds use a system icon')
args = parser.parse_args()
if args.game_artwork and not args.asset_profile:
    parser.error('--game-artwork requires --asset-profile')
if args.game_artwork and (not args.game_artwork.is_file() or
                          args.game_artwork.read_bytes()[:3] != b'\xff\xd8\xff'):
    parser.error('--game-artwork must be an existing JPEG')
if args.signing_mode == 'app-store' and not args.framework_layout:
    parser.error('App Store packaging requires --framework-layout')
if not args.unsigned and (not args.profile or not args.identity):
    parser.error('Signing requires both --profile and --identity; use --unsigned for private staging')
if args.unsigned and args.identity:
    parser.error('--unsigned must not specify a signing identity')
if args.increased_memory_limit and not args.profile:
    parser.error('A profile is required to verify the increased memory grant')
root = args.candidate_root.resolve(strict=True)
boundary = args.boundary.resolve(strict=True)
output = args.output.resolve()
if output.exists():
    parser.error('Output already exists; preserve the previous candidate')
if output.suffix != '.app':
    parser.error('Output must be a fresh .app bundle path')
link = json.loads((boundary / 'device-link-result.json').read_text())
if not link['libraries'] or any(item['exit'] or item['platform'] != 'IOS'
                                for item in link['libraries'].values()):
    parser.error('Device boundary link report is incomplete or failed')
profile = args.profile.resolve(strict=True) if args.profile else None
decoded = plistlib.loads(subprocess.check_output(['security', 'cms', '-D', '-i', str(profile)])) if profile else None
try:
    entitlements = signing_entitlements(decoded, args.bundle_id, args.signing_mode,
                                       increased_memory_limit=args.increased_memory_limit) if decoded else None
except ValueError as error:
    parser.error(str(error))
spec = importlib.util.spec_from_file_location('de_adapter', ROOT / 'scripts/prepare-de-load-image.py')
adapter = importlib.util.module_from_spec(spec)
spec.loader.exec_module(adapter)
app_source = root / 'candidate.app'
client_source = args.steam_client.resolve(strict=True) if args.steam_client else root / 'package/game-client'
if not (app_source / 'DEOriginalGame').is_file() or not client_source.is_dir():
    parser.error('Candidate root has no complete Simulator game/client package')
boundary_manifest = root / 'artifacts/candidate.app-art/boundary-manifest.json'
public_api = (json.loads(boundary_manifest.read_text()).get('runtime_policy', {}).get('public_api') is True
              if boundary_manifest.is_file() else False)
if args.signing_mode == 'app-store' and not public_api:
    parser.error('App Store staging requires a freshly generated --public-api boundary candidate')
shutil.copytree(app_source, output)
# On the iPad the game program runs as the app's own executable (DEOriginalGame).
# The Simulator-era copies (OriginalEngine, the unmodified program; Engine.dylib,
# the dylib form) are never used there: 184 MB less to install and sideload.
if json.loads((output / 'BoundaryDiagnostic.json').read_text()).get('engine_is_main_executable'):
    for unused in ('OriginalEngine', 'Engine.dylib'):
        (output / unused).unlink(missing_ok=True)
if args.signing_mode == 'app-store':
    (output / 'DELoaderProbe').unlink(missing_ok=True)
frameworks = output / 'Frameworks'
frameworks.mkdir(exist_ok=True)
staged = []

def platform(path):
    result = subprocess.run(['xcrun', 'vtool', '-show-build', str(path)],
                            capture_output=True, text=True)
    match = re.search(r'^\s*platform\s+(\w+)$', result.stdout, re.M) if result.returncode == 0 else None
    return match.group(1) if match else None

def stage(source, destination):
    device_boundary = boundary / destination.name
    if destination.name.startswith(('DEBoundary_', 'DEClientBoundary_')) and device_boundary.is_file():
        shutil.copy2(device_boundary, destination)
        action = 'device-boundary-link'
    else:
        original_platform = platform(source)
        if original_platform not in ('IOSSIMULATOR', 'MACOS'):
            raise ValueError(f'Unexpected source platform {original_platform}: {source}')
        temp = destination.with_name(destination.name + '.device-temp')
        result = adapter.prepare(source, temp, platform='ios-device',
                                 preserve_executable=destination.name in ('DEOriginalGame', 'DELoaderProbe', 'OriginalEngine'))
        temp.replace(destination)
        action = 'retargeted-' + original_platform
        if not all(section['equal'] for section in result['sections']):
            raise ValueError('Original executable section changed: ' + str(source))
    if platform(destination) != 'IOS':
        raise ValueError('Wrong output platform: ' + str(destination))
    staged.append({'path': str(destination.relative_to(output)), 'action': action})

for file in sorted(output.rglob('*')):
    if file.is_file() and not file.is_symlink() and platform(file):
        source = app_source / file.relative_to(output)
        stage(source, file)
for file in sorted(client_source.glob('*.dylib')):
    if file.name.startswith('original-'):
        continue
    stage(file, frameworks / file.name)
if args.ipc_load_probe:
    for image, dependency in (
        (frameworks / 'steamclient.dylib', '/usr/lib/libSystem.B.dylib'),
        # Valve's support library supplies the Steam client's process ID.
        (frameworks / 'libtier0_s.dylib', '/usr/lib/libSystem.B.dylib'),
        (frameworks / 'SteamModuleSimulator.dylib', '/usr/lib/libSystem.B.dylib'),
        (output / 'Vendor_libsteam_api.dylib.dylib', '@loader_path/DEBoundary_libSystem_B.dylib'),
    ):
        temp = image.with_name(image.name + '.device-ipc-temp')
        result = adapter.prepare(image, temp, platform='ios-device', dependency_map={
            dependency: '@loader_path/IPCSystemCompat.dylib' if image.parent == frameworks
                        else '@executable_path/Frameworks/IPCSystemCompat.dylib'},
            preserve_executable=image.name == 'DEOriginalGame')
        if result['instructions_changed'] or not all(item['equal'] for item in result['sections']):
            raise ValueError('Original Steam section changed in IPC probe: ' + str(image))
        temp.replace(image)
        for item in staged:
            if item['path'] == str(image.relative_to(output)):
                item['action'] += '+local-ipc-dependency'
                break
if args.original_steam_module:
    config_path = output / 'SteamModuleCompat.json'
    config = json.loads(config_path.read_text())
    original = args.original_steam_module.resolve(strict=True)
    if hashlib.sha256(original.read_bytes()).hexdigest() != config['original_sha256']:
        parser.error('Owned original Steam module does not match the pinned build')
    # Wrapped so signing tools don't sign (and so change) it; see SteamModuleCompat.m.
    (output / 'OriginalSteamModule.wrapped').write_bytes(b'AGEPAD-MODULE-1\n' + original.read_bytes())
    # The game's own Metal shader library runs unchanged on the iPad (verified on
    # hardware, 26 Sep), so ship the owned file itself rather than a rebuild.
    shader = original.parents[1] / 'Resources/feral.metallib'  # Contents/Frameworks/libsteam_api.dylib -> Contents
    if shader.is_file():
        for name in ('feral.metallib', 'feral-retargeted.metallib'):
            shutil.copy2(shader, output / name)
    # What a complete copy of the game data holds (file count and bytes, not
    # names or contents), so the app can tell a finished Finder copy from a
    # partial one. Hidden files are skipped, as the app does.
    game_data = original.parents[3] / 'AgeOfEmpires2Data'
    if game_data.is_dir():
        count = size = 0
        for folder, dirs, names in os.walk(game_data):
            dirs[:] = [d for d in dirs if not d.startswith('.')]
            for name in names:
                path = Path(folder) / name
                if not name.startswith('.') and path.is_file() and not path.is_symlink():
                    count += 1
                    size += path.stat().st_size
        (output / 'GameDataInventory.json').write_text(json.dumps({'files': count, 'bytes': size}) + '\n')
if args.asset_profile:
    from phone_asset_profile import relative_path
    raw_profile=args.asset_profile.read_bytes()
    if len(raw_profile) > 16 << 20:
        parser.error('Asset profile is too large')
    asset_profile=json.loads(raw_profile)
    manifest_build = re.search(r'"buildid"\s+"(\d+)"', args.steam_app_manifest.read_text()) if args.steam_app_manifest else None
    if not manifest_build or asset_profile.get('steam_build_id') != manifest_build.group(1):
        parser.error('Asset profile must match the supplied owned Steam build manifest')
    source_inventory=json.loads((output / 'GameDataInventory.json').read_text())
    if (asset_profile.get('schema_version') != 1 or asset_profile.get('steam_app_id') != 813780 or
        asset_profile.get('source_files') != source_inventory['files'] or asset_profile.get('source_bytes') != source_inventory['bytes'] or
        not isinstance(asset_profile.get('entries'),list) or not asset_profile['entries']):
        parser.error('Asset profile does not match the complete owned source inventory')
    paths=set()
    for item in asset_profile['entries'] + asset_profile.get('excluded',[]):
        relative_path(item['path'])
        if item['path'] in paths or type(item['bytes']) is not int or item['bytes'] < 0:
            parser.error('Invalid or duplicate asset profile entry')
        paths.add(item['path'])
    if len(asset_profile['entries']) != asset_profile['files'] or sum(item['bytes'] for item in asset_profile['entries']) != asset_profile['bytes']:
        parser.error('Asset profile totals do not match its entries')
    (output / 'GameDataProfile.json').write_bytes(raw_profile)
    if args.game_artwork:
        shutil.copy2(args.game_artwork, output / 'AoE2DEHeader.jpg')
    (output / 'ThirdPartyNotices.txt').write_text((ROOT / 'port/third_party/README.md').read_text() + '\n' + (ROOT / 'port/third_party/zstd/LICENSE').read_text() + '\n' + (ROOT / 'port/third_party/xz/COPYING').read_text())
info_path = output / 'Info.plist'
if args.steam_app_manifest:
    # The in-app Steam engine's install record for the imported game: same build
    # and depots as the Mac install the files were copied (and verified) from.
    # Personal fields are dropped; "update only when launched through Steam"
    # (AgePad never does) keeps the engine from downloading on its own.
    lines = [line for line in args.steam_app_manifest.read_text().splitlines()
             if not re.search(r'"(LastOwner|LastPlayed|LastUpdated)"', line)]
    text = re.sub(r'("AutoUpdateBehavior"\s+)"\d+"', r'\1"1"', '\n'.join(lines) + '\n')
    if '"buildid"' not in text or '"813780"' not in text:
        parser.error('Not the AoE II: DE app manifest: ' + str(args.steam_app_manifest))
    (output / 'SteamAppManifest_813780.acf').write_text(text)
info = universal_info(plistlib.loads(info_path.read_bytes()))
info.update({'CFBundleIdentifier': args.bundle_id, 'CFBundleDisplayName': 'AgePad', 'CFBundleName': 'AgePad',
             'CFBundleSupportedPlatforms': ['iPhoneOS'], 'LSRequiresIPhoneOS': True})
sdk_version = subprocess.check_output(['xcrun', '--sdk', 'iphoneos', '--show-sdk-version'], text=True).strip()
sdk_build = subprocess.check_output(['xcrun', '--sdk', 'iphoneos', '--show-sdk-build-version'], text=True).strip()
xcode_lines = subprocess.check_output(['xcodebuild', '-version'], text=True).splitlines()
xcode_number = xcode_lines[0].split()[-1].split('.')
xcode_number = ''.join((xcode_number + ['0', '0'])[:3])
info = distribution_info(info, sdk_version=sdk_version, sdk_build=sdk_build,
                         xcode_version=xcode_number, xcode_build=xcode_lines[1].split()[-1],
                         version=args.version, build_number=args.build_number)
# AgePad's own Home Screen icon (assets/agepad-icon-1024.png, a two-column
# "II"), replacing the game's icon files the bundle already lists.
icon = ROOT / 'assets/agepad-icon-1024.png'
if args.signing_mode == 'app-store':
    from agepad_app_icons import compile_app_icons
    # These are the exact reserved loose icon names this device packager has
    # always replaced. Preserve all other copied game resources.
    for name in ICON_SIZES:
        (output / name).unlink(missing_ok=True)
    info.update(compile_app_icons(icon, output, output.parent / 'app-icon-build',
                                 minimum_os=info['MinimumOSVersion']))
else:
    for name, px in ICON_SIZES.items():
        subprocess.run(['sips', '-s', 'format', 'png', '-z', str(px), str(px), str(icon), '--out', str(output / name)],
                       check=True, capture_output=True)
# Tap-to-play reaches the Mac helper on the home network; iPadOS asks once.
# Players copy the game files in through Finder's iPad view or the Files app.
info['UIFileSharingEnabled'] = True
info['LSSupportsOpeningDocumentsInPlace'] = True
info['NSLocalNetworkUsageDescription'] = ('AgePad connects to the AgePad helper on your Mac, '
                                          'which lets the game use your Mac\'s Steam sign-in.')
info_path.write_bytes(plistlib.dumps(info))
# AgePad's page in the iPad Settings app: who is signed in to Steam, and a
# switch that signs out the next time AgePad opens.
settings = output / 'Settings.bundle'
settings.mkdir(exist_ok=True)
(settings / 'Root.plist').write_bytes(plistlib.dumps({'PreferenceSpecifiers': [
    {'Type': 'PSGroupSpecifier', 'Title': 'Steam',
     'FooterText': 'Signing out removes the Steam sign-in from this iPad the next time you open AgePad; '
                   'you then sign in again with the QR code. To also remove the iPad from your Steam account, '
                   'revoke "AgePad (iPad)" under Steam > Settings > Security.'},
    {'Type': 'PSTitleValueSpecifier', 'Title': 'Signed in as', 'Key': 'AgePadSteamAccountName', 'DefaultValue': 'Not signed in'},
    {'Type': 'PSToggleSwitchSpecifier', 'Title': 'Sign out of Steam', 'Key': 'AgePadSteamSignOut', 'DefaultValue': False},
]}))
# The original localized InfoPlist.strings would rename the app back to the game's name.
for localized in output.rglob('InfoPlist.strings'):
    localized.unlink()
# Normal launch shows the setup screen. Steam relay and original startup are
# opt-in diagnostics; imported data lives only in the app's Documents folder.
(output / 'DeviceSetupGate').write_text('hardware diagnostic; setup shown without opt-in relay\n')
if args.launch_env:
    lines = [line for line in args.launch_env.read_text().splitlines() if line.startswith('AGEPAD_') and '=' in line]
    (output / 'AgePadLaunch.env').write_text('\n'.join(lines) + '\n')
sdk = subprocess.check_output(['xcrun', '--sdk', 'iphoneos', '--show-sdk-path'], text=True).strip()
child = output / 'DeviceChildProbe'
if args.signing_mode == 'development':
    subprocess.run(['xcrun', 'clang', '-target', 'arm64-apple-ios15.0', '-isysroot', sdk,
                    str(ROOT / 'port/de/DeviceChildProbe.c'), '-o', str(child)], check=True)
else:
    child.unlink(missing_ok=True)
ipc_images = []
ipc_original = None
ipc_entry_metadata = None
if args.ipc_load_probe:
    ipc_root = args.ipc_load_probe.resolve(strict=True)
    try:
        ipc_build = json.loads((ipc_root / 'manifest.json').read_text())
        ipc_entry_metadata = json.loads((ipc_root / 'IPCHelperEntry.json').read_text())
        ipc_original = Path(ipc_build['helper']['source']).resolve(strict=True).read_bytes()
        if (ipc_build.get('entry_metadata') != ipc_entry_metadata or
                hashlib.sha256(ipc_original).hexdigest() != ipc_build['helper']['source_sha256']):
            raise ValueError('IPC helper build/source pin mismatch')
        validate_helper_entry(ipc_entry_metadata, ipc_original, (ipc_root / 'IPCHelperDevice.dylib').read_bytes())
    except (OSError, KeyError, ValueError, TypeError) as error:
        parser.error('IPC helper requires matching validated entry metadata: ' + str(error))
    for name in ('IPCSystemCompat.dylib', 'IPCHelperDevice.dylib'):
        source_image = ipc_root / name
        if platform(source_image) != 'IOS':
            parser.error('IPC load probe is not an IOS image: ' + str(source_image))
        destination = frameworks / name
        shutil.copy2(source_image, destination)
        ipc_images.append(destination)
image_map = {}
framework_checks = []
if args.framework_layout:
    image_map = framework_plan(output)
    # Rewrite while every old source path still exists, then move the exact
    # outputs. The adapter asserts every file-backed section stays identical.
    rewritten = []
    for file in sorted(output.rglob('*')):
        if not file.is_file() or file.is_symlink():
            continue
        with file.open('rb') as stream:
            if stream.read(4) != b'\xcf\xfa\xed\xfe':
                continue
        metadata = macho_metadata(file.read_bytes())
        rewrites = dependency_rewrites(output, file, metadata, image_map)
        if not rewrites:
            continue
        temporary = file.with_name(file.name + '.framework-temp')
        try:
            result = adapter.prepare(file, temporary, platform='ios-device', dependency_map=rewrites,
                                     preserve_executable=metadata['file_type'] == 2)
        except ValueError as error:
            raise ValueError('Framework rewrite failed for ' + str(file.relative_to(output)) + ': ' + str(error)) from error
        if result['instructions_changed'] or not all(section['equal'] for section in result['sections']):
            raise ValueError('Framework packaging changed a native section')
        framework_checks.append({'source_path': str(file.relative_to(output)),
                                 'section_count': len(result['sections']),
                                 'file_backed_sections_unchanged': True})
        rewritten.append((temporary, file))
    for temporary, file in rewritten:
        temporary.replace(file)
    for old, new in image_map.items():
        destination = output / new
        if destination.exists():
            if destination.read_bytes() != (output / old).read_bytes():
                raise ValueError('Duplicate libraries differ after framework rewriting: ' + old)
            (output / old).unlink()
            continue
        destination.parent.mkdir(parents=True, exist_ok=True)
        (output / old).replace(destination)
        name = destination.name
        identifier = re.sub('[^A-Za-z0-9.-]', '-', name)
        framework_info = {key: value for key, value in info.items() if key.startswith('DT')}
        framework_info.update({'CFBundleExecutable': name, 'CFBundleName': name,
                               'CFBundleIdentifier': args.bundle_id + '.framework.' + identifier,
                               'CFBundlePackageType': 'FMWK', 'CFBundleVersion': info['CFBundleVersion'],
                               'CFBundleShortVersionString': info['CFBundleShortVersionString'],
                               'CFBundleSupportedPlatforms': ['iPhoneOS'], 'MinimumOSVersion': '15.0'})
        (destination.parent / 'Info.plist').write_bytes(plistlib.dumps(framework_info))
    (output / 'AgePadLibraryMap.plist').write_bytes(plistlib.dumps(image_map))
    for item in staged:
        item['path'] = image_map.get(item['path'], item['path'])
    ipc_images = [output / image_map.get(str(image.relative_to(output)), str(image.relative_to(output)))
                  for image in ipc_images]
if ipc_entry_metadata:
    staged_helper = output / image_map.get('Frameworks/IPCHelperDevice.dylib', 'Frameworks/IPCHelperDevice.dylib')
    validate_helper_entry(ipc_entry_metadata, ipc_original, staged_helper.read_bytes())
    (output / 'IPCHelperEntry.json').write_text(json.dumps(ipc_entry_metadata, indent=2) + '\n')
if args.original_steam_module:
    translated = output / image_map.get('Frameworks/SteamModuleSimulator.dylib', 'Frameworks/SteamModuleSimulator.dylib')
    config['device_translated_sha256'] = hashlib.sha256(
        translated.read_bytes()).hexdigest()
    # Also a digest of the module's sections only, which stays valid when the
    # app is signed again by someone else (a sideloading tool).
    kit_spec = importlib.util.spec_from_file_location('agepad_kit', ROOT / 'scripts/agepad-kit.py')
    kit = importlib.util.module_from_spec(kit_spec)
    kit_spec.loader.exec_module(kit)
    config['device_translated_sections_sha256'] = kit.sections_digest(
        translated.read_bytes())
    config_path.write_text(json.dumps(config, indent=2) + '\n')
if args.signing_mode == 'app-store':
    # Required-reason declarations for AgePad's own implementation. Vendor
    # collection/API purposes remain a separate review, not inferred here.
    privacy_source = ROOT / 'assets/PrivacyInfo.xcprivacy'
    privacy = plistlib.loads(privacy_source.read_bytes())
    shutil.copy2(privacy_source, output / 'PrivacyInfo.xcprivacy')
    owned_reasons = {item['NSPrivacyAccessedAPIType']: item
                     for item in privacy['NSPrivacyAccessedAPITypes']}
    placements = {
        'DE_AppKit': None,
        'DE_libSystem_B': {'NSPrivacyAccessedAPICategoryFileTimestamp': ['C617.1']},
        'DE_CoreVideo': {'NSPrivacyAccessedAPICategorySystemBootTime': ['8FFB.1']},
        'DE_Metal': {'NSPrivacyAccessedAPICategorySystemBootTime': ['35F9.1']},
        'SC_CoreGraphics': {'NSPrivacyAccessedAPICategorySystemBootTime': ['35F9.1']},
        'SC_ApplicationServices': {'NSPrivacyAccessedAPICategorySystemBootTime': ['35F9.1']},
    }
    for name, categories in placements.items():
        target = output / 'Frameworks' / (name + '.framework')
        if not target.is_dir():
            continue
        declaration = privacy if categories is None else {'NSPrivacyAccessedAPITypes': [
            {'NSPrivacyAccessedAPIType': category, 'NSPrivacyAccessedAPITypeReasons': reasons}
            for category, reasons in categories.items()
            if category in owned_reasons
        ]}
        (target / 'PrivacyInfo.xcprivacy').write_bytes(plistlib.dumps(declaration))

preflight_path = output.parent / 'device-distribution-preflight.json'
preflight = inspect_bundle(output, args.signing_mode, require_profile=False, require_signature=False)
preflight_path.write_text(json.dumps(preflight, indent=2) + '\n')
if args.signing_mode == 'app-store' and preflight['blockers'] and not args.unsigned:
    raise SystemExit('Distribution structure preflight failed; no identity signing attempted. See ' + str(preflight_path))
entitlements_path = output.parent / 'device-probe-entitlements.plist'
if args.unsigned:
    (output / 'embedded.mobileprovision').unlink(missing_ok=True)
    shutil.rmtree(output / '_CodeSignature', ignore_errors=True)
    for image in preflight['images']:
        subprocess.run(['codesign', '--remove-signature', str(output / image['path'])],
                       check=True, capture_output=True)
else:
    shutil.copy2(profile, output / 'embedded.mobileprovision')
    entitlements_path.write_bytes(plistlib.dumps(entitlements))
    code_paths = []
    for image in preflight['images']:
        file = output / image['path']
        if file.name == info['CFBundleExecutable'] and file.parent == output:
            continue
        code_paths.append(file.parent if file.parent.suffix == '.framework' else file)
    for file in code_paths:
        subprocess.run(['codesign', '--force', '--sign', args.identity, str(file)], check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    subprocess.run(['codesign', '--force', '--sign', args.identity, '--entitlements',
                    str(entitlements_path), str(output)], check=True)
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(output)], check=True)
preflight = inspect_bundle(output, args.signing_mode)
preflight_path.write_text(json.dumps(preflight, indent=2) + '\n')
report = {'scope': 'device launch probe; signing alone proves no Steam session, data import or gameplay',
          'bundle_id': args.bundle_id, 'images': staged,
          'signing_mode': args.signing_mode, 'signed': not args.unsigned,
          'public_api_boundary_policy': public_api, 'framework_count': len(set(image_map.values())),
          'framework_rewrite_checks': framework_checks,
          'preflight_ready': preflight['ready'], 'preflight_blockers': len(preflight['blockers']),
          'device_families': info['UIDeviceFamily'],
          'interface_orientations': info['UISupportedInterfaceOrientations'],
          'increased_memory_limit_requested': args.increased_memory_limit,
          'main_sha256': hashlib.sha256((output / info['CFBundleExecutable']).read_bytes()).hexdigest(),
          'child_probe_sha256': hashlib.sha256(child.read_bytes()).hexdigest() if child.exists() else None,
          'ipc_load_probe': [image.name for image in ipc_images]}
(output.parent / 'device-probe-manifest.json').write_text(json.dumps(report, indent=2) + '\n')
print(f'{"Staged without identity signing" if args.unsigned else "Signed"} {len(staged)} IOS images in {output}')
print(f'Local preflight: {len(preflight["blockers"])} blockers; runtime and Apple validation are separate')
if args.signing_mode == 'app-store' and not args.unsigned and not preflight['ready']:
    raise SystemExit('Signed distribution preflight failed. See ' + str(preflight_path))
