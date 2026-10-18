"""Compile AgePad's own app icon with Apple's iPhoneOS asset compiler.

This stages only resources. It never signs, installs, opens a Simulator, or
changes the source artwork or the app's Info.plist.
"""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import re
import shutil
import subprocess


APP_ICON = 'AgePadAppIcon'
# Include explicit iPhone and iPad sets, plus the opaque App Store artwork.
ICON_SLOTS = [
    ('iphone', '20x20', '2x', 40), ('iphone', '20x20', '3x', 60),
    ('iphone', '29x29', '2x', 58), ('iphone', '29x29', '3x', 87),
    ('iphone', '40x40', '2x', 80), ('iphone', '40x40', '3x', 120),
    ('iphone', '60x60', '2x', 120), ('iphone', '60x60', '3x', 180),
    ('ipad', '20x20', '1x', 20), ('ipad', '20x20', '2x', 40),
    ('ipad', '29x29', '1x', 29), ('ipad', '29x29', '2x', 58),
    ('ipad', '40x40', '1x', 40), ('ipad', '40x40', '2x', 80),
    ('ipad', '76x76', '1x', 76), ('ipad', '76x76', '2x', 152),
    ('ipad', '83.5x83.5', '2x', 167),
    ('ios-marketing', '1024x1024', '1x', 1024),
]


def _run(command):
    run = subprocess.run([str(part) for part in command], capture_output=True, text=True)
    if run.returncode:
        raise RuntimeError(f'{command[0]} failed ({run.returncode}):\n{run.stderr or run.stdout}')
    return run.stdout


def image_properties(path):
    output = _run(['sips', '-g', 'pixelWidth', '-g', 'pixelHeight', '-g', 'hasAlpha', path])
    values = dict(re.findall(r'^\s+(pixelWidth|pixelHeight|hasAlpha):\s*(\S+)\s*$', output, re.M))
    if set(values) != {'pixelWidth', 'pixelHeight', 'hasAlpha'}:
        raise ValueError('Cannot read icon image geometry and alpha channel')
    return {'width': int(values['pixelWidth']), 'height': int(values['pixelHeight']),
            'alpha': values['hasAlpha'] == 'yes'}


def compile_app_icons(icon: Path, bundle: Path, output_root: Path, minimum_os='15.0'):
    """Stage a fresh catalog and return actool's icon Info.plist updates.

    ``bundle`` must already exist; ``output_root`` must be fresh and outside it.
    Existing compiled app resources are never replaced. On failure, diagnostic
    inputs and compiler output remain under ``output_root`` for inspection.
    """
    icon = Path(icon).resolve(strict=True)
    bundle = Path(bundle).resolve(strict=True)
    output_root = Path(output_root).resolve()
    if not icon.is_file() or not bundle.is_dir():
        raise ValueError('Expected an icon file and an existing app bundle directory')
    if not re.fullmatch(r'[1-9]\d*\.\d+(?:\.\d+)?', minimum_os):
        raise ValueError('Minimum OS must be a numeric iOS version')
    if output_root.exists() or output_root.is_symlink():
        raise ValueError('Icon build output must be fresh')
    if output_root == bundle or bundle in output_root.parents:
        raise ValueError('Icon build output must be outside the app bundle')
    if (bundle / 'Assets.car').exists() or (bundle / 'Assets.car').is_symlink():
        raise ValueError('Refuse to replace an existing asset catalog in the app')
    properties = image_properties(icon)
    if (properties['width'], properties['height']) != (1024, 1024):
        raise ValueError('App Store icon source must be exactly 1024 by 1024 pixels')
    source_hash = hashlib.sha256(icon.read_bytes()).hexdigest()
    output_root.mkdir(parents=True)
    catalog = output_root / 'AgePad.xcassets'
    images = catalog / (APP_ICON + '.appiconset')
    images.mkdir(parents=True)
    (catalog / 'Contents.json').write_text(json.dumps({'info': {'author': 'xcode', 'version': 1}}, indent=2) + '\n')
    opaque = output_root / 'icon-opaque.png'
    if properties['alpha']:
        # sips' JPEG writer produces RGB without an alpha channel. Keep this
        # high-quality intermediate outside the catalog and never alter source.
        rgb = output_root / 'icon-rgb.jpg'
        _run(['sips', '-s', 'format', 'jpeg', '-s', 'formatOptions', 'best', icon, '--out', rgb])
        _run(['sips', '-s', 'format', 'png', rgb, '--out', opaque])
    else:
        _run(['sips', '-s', 'format', 'png', icon, '--out', opaque])
    if image_properties(opaque) != {'width': 1024, 'height': 1024, 'alpha': False}:
        raise ValueError('App Store icon preparation did not produce opaque 1024-pixel artwork')
    entries = []
    for idiom, size, scale, pixels in ICON_SLOTS:
        filename = f'{idiom}-{size}@{scale}.png'
        target = images / filename
        if pixels == 1024:
            shutil.copy2(opaque, target)
        else:
            _run(['sips', '-s', 'format', 'png', '-z', pixels, pixels, opaque, '--out', target])
        entries.append({'idiom': idiom, 'size': size, 'scale': scale, 'filename': filename})
    (images / 'Contents.json').write_text(json.dumps({'images': entries, 'info': {'author': 'xcode', 'version': 1}}, indent=2) + '\n')
    compiled = output_root / 'compiled'
    compiled.mkdir()
    partial = output_root / 'asset-info.plist'
    command = ['xcrun', 'actool', '--compile', compiled, '--platform', 'iphoneos',
               '--minimum-deployment-target', minimum_os, '--app-icon', APP_ICON,
               '--target-device', 'iphone', '--target-device', 'ipad',
               '--output-partial-info-plist', partial, '--output-format', 'xml1',
               '--warnings', '--errors', '--notices', '--compress-pngs', catalog]
    run = subprocess.run([str(part) for part in command], capture_output=True, text=True)
    (output_root / 'actool.log').write_text(run.stdout + run.stderr)
    if run.returncode:
        raise RuntimeError('App icon asset compilation failed; inspect ' + str(output_root / 'actool.log'))
    if not (compiled / 'Assets.car').is_file() or not partial.is_file():
        raise ValueError('Asset compiler did not emit a catalog and partial Info.plist')
    updates = {key: value for key, value in plistlib.loads(partial.read_bytes()).items()
               if key in ('CFBundleIcons', 'CFBundleIcons~ipad', 'CFBundleIconName')}
    for key in ('CFBundleIcons', 'CFBundleIcons~ipad'):
        if updates.get(key, {}).get('CFBundlePrimaryIcon', {}).get('CFBundleIconName') != APP_ICON:
            raise ValueError('Asset compiler did not provide the expected phone and iPad primary icon names')
    resources = sorted(compiled.iterdir())
    if any(not path.is_file() or path.is_symlink() for path in resources):
        raise ValueError('Unexpected nested or linked compiler output')
    if any((bundle / path.name).exists() or (bundle / path.name).is_symlink() for path in resources):
        raise ValueError('Compiled app icon would replace an existing app resource')
    if hashlib.sha256(icon.read_bytes()).hexdigest() != source_hash:
        raise ValueError('Source artwork changed during icon compilation')
    for resource in resources:
        shutil.copy2(resource, bundle / resource.name)
    (output_root / 'icon-build.json').write_text(json.dumps({
        'scope': 'iPhoneOS icon resource compilation only; no signing or installation',
        'source_sha256': source_hash, 'source_had_alpha': properties['alpha'],
        'minimum_os': minimum_os, 'platform': 'iphoneos',
        'bundle_resources': [path.name for path in resources], 'info_updates': updates,
    }, indent=2) + '\n')
    return updates


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--icon', required=True, type=Path)
    parser.add_argument('--bundle', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--minimum-os', default='15.0')
    args = parser.parse_args()
    print(json.dumps(compile_app_icons(args.icon, args.bundle, args.output, args.minimum_os), indent=2))


if __name__ == '__main__':
    main()
