#!/usr/bin/env python3
"""Build a private, version-pinned Files import pack without changing Steam files."""
import argparse
import ctypes
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import shutil

ROOT = Path(__file__).resolve().parents[1]


def relative_path(value):
    if not isinstance(value, str) or not value or '\0' in value or '\\' in value:
        raise ValueError('Invalid asset path')
    path = PurePosixPath(value)
    if path.is_absolute() or any(p in ('', '.', '..') for p in value.split('/')):
        raise ValueError('Asset path must stay inside the data folder')
    return path


def exclusion_reason(value, campaigns=False):
    path = relative_path(value)
    if any(p.startswith('.') for p in path.parts) or path.name == 'update_hosts_cached.vdf':
        return 'transfer metadata/cache'
    if path.parts[0] in ('Docs', 'extras'):
        return 'manuals and bonus soundtrack'
    if path.parts[0] == 'modes' or value.startswith(('wwise/Pompeii', 'wwise/en/Pompeii')):
        return 'additional game mode'
    if len(path.parts) > 1 and path.parts[0] == 'resources' and path.parts[1] not in ('_common', 'en'):
        return 'other text languages'
    if not campaigns and (value.startswith('widgetui/textures/campaign/') or path.suffix.lower() in ('.webm', '.wmv')):
        return 'optional campaign presentation'
    return None


def build_profile(source, build_id, campaigns=False):
    source = Path(source).resolve(strict=True)
    entries, excluded = [], []
    source_bytes = 0
    for folder, dirs, names in os.walk(source, followlinks=False):
        if any((Path(folder) / name).is_symlink() for name in dirs):
            raise ValueError('Symbolic links are not accepted as game assets')
        dirs[:] = sorted(d for d in dirs if not d.startswith('.'))
        for name in sorted(names):
            path = Path(folder) / name
            if path.is_symlink():
                raise ValueError('Symbolic links are not accepted as game assets')
            if not path.is_file() or name.startswith('.') or name == 'update_hosts_cached.vdf':
                continue
            relative = path.relative_to(source).as_posix()
            size = path.stat().st_size
            source_bytes += size
            record = {'path': relative, 'bytes': size}
            reason = exclusion_reason(relative, campaigns)
            if reason:
                excluded.append({**record, 'reason': reason})
                continue
            digest = hashlib.sha256()
            with path.open('rb') as stream:
                prefix = stream.read(4)
                if prefix[:2] == b'MZ' or prefix in (b'\xcf\xfa\xed\xfe', b'\xfe\xed\xfa\xcf', b'\xca\xfe\xba\xbe'):
                    raise ValueError('Native programs cannot be delivered by the asset importer')
                digest.update(prefix)
                for chunk in iter(lambda: stream.read(1 << 20), b''):
                    digest.update(chunk)
            entries.append({**record, 'sha256': digest.hexdigest()})
    if not entries:
        raise ValueError('No supported game assets found')
    return {'schema_version': 1, 'profile_id': 'aoe2de-phone-' + ('campaigns' if campaigns else 'core') + '-v1',
            'steam_app_id': 813780, 'steam_build_id': str(build_id), 'language': 'en',
            'content': ['core matches'] + (['base campaigns'] if campaigns else []),
            'files': len(entries), 'bytes': sum(e['bytes'] for e in entries),
            'source_files': len(entries) + len(excluded), 'source_bytes': source_bytes,
            'entries': entries, 'excluded': excluded}


def export_profile(source, destination, profile):
    source, destination = Path(source).resolve(strict=True), Path(destination).resolve()
    if destination.exists():
        raise ValueError('Export must use a fresh directory')
    destination.mkdir(parents=True)
    clone = getattr(ctypes.CDLL(None, use_errno=True), 'clonefile', None)
    if clone:
        clone.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_int]
        clone.restype = ctypes.c_int
    for entry in profile['entries']:
        path = relative_path(entry['path'])
        src, dst = source / path, destination / path
        if src.is_symlink() or not src.resolve().is_relative_to(source):
            raise ValueError('Asset source escaped the selected folder')
        dst.parent.mkdir(parents=True, exist_ok=True)
        if not clone or clone(os.fsencode(src), os.fsencode(dst), 0):
            shutil.copy2(src, dst)
    (destination / '.agepad-profile.json').write_text(json.dumps(profile, separators=(',', ':')) + '\n')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path, help='Owned AgeOfEmpires2Data folder')
    parser.add_argument('--build-id', required=True)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--export', type=Path, help='Fresh private folder for Files transfer')
    parser.add_argument('--with-campaigns', action='store_true')
    args = parser.parse_args()
    for path in (args.output, args.export):
        if path and not path.resolve().is_relative_to(ROOT / 'generated'):
            parser.error('Private manifests and game exports must stay under generated/')
    if args.output.exists():
        parser.error('Output already exists; preserve the prior measurement')
    profile = build_profile(args.source, args.build_id, args.with_campaigns)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(profile, separators=(',', ':')) + '\n')
    if args.export:
        export_profile(args.source, args.export, profile)
    print(json.dumps({k: profile[k] for k in ('profile_id', 'files', 'bytes', 'source_files', 'source_bytes')}))


if __name__ == '__main__':
    main()
