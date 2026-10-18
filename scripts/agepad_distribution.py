"""Local iOS packaging checks; a passing result is not App Store approval.

These functions never fetch credentials, provision accounts, sign, or upload.
They intentionally keep development staging separate from distribution.
"""
import copy
import datetime
import fnmatch
import hashlib
from pathlib import Path
import plistlib
import re
import struct
import subprocess
import tempfile


MEMORY_ENTITLEMENT = 'com.apple.developer.kernel.increased-memory-limit'
PRIVATE_API_MARKERS = (b'/System/Library/PrivateFrameworks/', b'WebThreadLock',
                       b'WAKWindow', b'WAKView')


def signing_entitlements(profile, bundle_id, mode, *, increased_memory_limit=False, now=None):
    """Derive only the app's required entitlements from an actual decoded profile.

    Development profiles are never silently treated as App Store profiles.
    App identifier prefixes can differ from the team identifier.
    """
    if mode not in ('development', 'app-store'):
        raise ValueError('Unknown signing mode')
    if not re.fullmatch(r'[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+', bundle_id):
        raise ValueError('Invalid bundle identifier')
    grants = profile.get('Entitlements', {})
    teams = profile.get('TeamIdentifier', [])
    if len(teams) != 1 or not isinstance(teams[0], str) or not teams[0]:
        raise ValueError('Profile must identify exactly one team')
    team = teams[0]
    if grants.get('com.apple.developer.team-identifier') != team:
        raise ValueError('Profile team entitlement is inconsistent')
    prefixes = profile.get('ApplicationIdentifierPrefix', [])
    covered = grants.get('application-identifier', '')
    identifiers = [prefix + '.' + bundle_id for prefix in prefixes
                   if isinstance(prefix, str) and covered in (prefix + '.*', prefix + '.' + bundle_id)]
    if len(identifiers) != 1:
        raise ValueError('Provisioning profile does not cover this bundle identifier')
    platforms = profile.get('Platform', [])
    if 'iOS' not in platforms:
        raise ValueError('Provisioning profile does not cover iOS')
    expiry = profile.get('ExpirationDate')
    now = now or datetime.datetime.now(datetime.timezone.utc)
    if not isinstance(expiry, datetime.datetime):
        raise ValueError('Provisioning profile has no expiration date')
    if expiry.tzinfo is None:
        expiry = expiry.replace(tzinfo=datetime.timezone.utc)
    if now.tzinfo is None:
        now = now.replace(tzinfo=datetime.timezone.utc)
    if expiry <= now:
        raise ValueError('Provisioning profile has expired')
    debug = grants.get('get-task-allow')
    if mode == 'app-store':
        if debug is not False:
            raise ValueError('App Store distribution forbids get-task-allow')
        if profile.get('ProvisionedDevices') or profile.get('ProvisionsAllDevices'):
            raise ValueError('A device-list or enterprise profile is not an App Store profile')
        if grants.get('beta-reports-active') is not True:
            raise ValueError('App Store/TestFlight signing requires the profile beta-reports-active grant')
    elif debug is not True or not profile.get('ProvisionedDevices'):
        raise ValueError('Development signing requires a development device-list profile')
    result = {'application-identifier': identifiers[0],
              'com.apple.developer.team-identifier': team, 'get-task-allow': debug}
    if mode == 'app-store':
        result['beta-reports-active'] = True
    groups = grants.get('keychain-access-groups', [])
    if not isinstance(groups, list) or not all(isinstance(group, str) for group in groups):
        raise ValueError('Profile keychain groups are malformed')
    if any(fnmatch.fnmatchcase(identifiers[0], group) for group in groups):
        # The Steam credential code uses only this app's default group, never
        # the wildcard or another app's group granted by a broad profile.
        result['keychain-access-groups'] = [identifiers[0]]
    elif mode == 'app-store':
        raise ValueError('Profile does not grant this app default keychain group')
    if increased_memory_limit:
        if grants.get(MEMORY_ENTITLEMENT) is not True:
            raise ValueError('Provisioning profile does not grant the increased memory limit')
        result[MEMORY_ENTITLEMENT] = True
    return result


def validate_signed_entitlements(actual, expected):
    if not isinstance(actual, dict) or actual != expected:
        raise ValueError('Signed entitlements differ from the exact requested profile-derived grants')


def distribution_info(source, *, sdk_version, sdk_build, xcode_version, xcode_build,
                      version=None, build_number=None):
    """Record the selected SDK rather than inheriting Simulator/Mac metadata."""
    result = copy.deepcopy(source)
    for key in ('NSMainNibFile', 'NSPrincipalClass', 'LSMinimumSystemVersion', 'LSArchitecturePriority'):
        result.pop(key, None)
    result.update({'CFBundleSupportedPlatforms': ['iPhoneOS'], 'LSRequiresIPhoneOS': True,
                   'CFBundlePackageType': 'APPL', 'DTPlatformName': 'iphoneos',
                   'DTPlatformVersion': sdk_version, 'DTSDKName': 'iphoneos' + sdk_version,
                   'DTSDKBuild': sdk_build, 'DTPlatformBuild': sdk_build,
                   'DTXcode': xcode_version, 'DTXcodeBuild': xcode_build})
    for value, key in ((version, 'CFBundleShortVersionString'), (build_number, 'CFBundleVersion')):
        if value is not None:
            if not re.fullmatch(r'[0-9]+(?:\.[0-9]+){0,2}', value):
                raise ValueError('Invalid ' + key)
            result[key] = value
    return result


def verify_distribution_signature(bundle, bundle_id, mode):
    """Verify actual CMS/profile grants, signed entitlements and leaf certificate."""
    bundle = Path(bundle)
    try:
        profile = plistlib.loads(subprocess.check_output(
            ['security', 'cms', '-D', '-i', str(bundle / 'embedded.mobileprovision')], stderr=subprocess.DEVNULL))
        actual = plistlib.loads(subprocess.check_output(
            ['codesign', '--display', '--entitlements', ':-', str(bundle)], stderr=subprocess.DEVNULL))
        expected = signing_entitlements(profile, bundle_id, mode,
                                        increased_memory_limit=actual.get(MEMORY_ENTITLEMENT) is True)
        validate_signed_entitlements(actual, expected)
        subprocess.run(['codesign', '--verify', '--deep', '--strict', str(bundle)],
                       check=True, capture_output=True)
        with tempfile.TemporaryDirectory(prefix='agepad-signature-check-') as temporary:
            prefix = str(Path(temporary) / 'certificate')
            subprocess.run(['codesign', '--display', '--extract-certificates=' + prefix, str(bundle)],
                           check=True, capture_output=True)
            leaf = Path(prefix + '0').read_bytes()
            if leaf not in profile.get('DeveloperCertificates', []):
                return 'The signing certificate is not included in the provisioning profile'
    except (OSError, subprocess.CalledProcessError, plistlib.InvalidFileException, ValueError, TypeError):
        return 'Could not verify the actual signature, profile type, profile expiry, entitlements and certificate'
    return None


def macho_metadata(data):
    """Read the thin arm64 files this packager produces, without executing them."""
    if data[:4] != b'\xcf\xfa\xed\xfe':
        return None
    if len(data) < 32:
        raise ValueError('Truncated Mach-O header')
    _, cpu, _, file_type, count, command_bytes, _, _ = struct.unpack_from('<8I', data)
    if cpu != 0x100000c or 32 + command_bytes > len(data):
        raise ValueError('Invalid arm64 Mach-O header')
    platform, dependencies, rpaths, install_name = None, [], [], None
    offset = 32
    for _ in range(count):
        if offset + 8 > 32 + command_bytes:
            raise ValueError('Truncated Mach-O command')
        command, size = struct.unpack_from('<II', data, offset)
        if size < 8 or offset + size > 32 + command_bytes:
            raise ValueError('Invalid Mach-O command size')
        if command == 0x32:
            if size < 24:
                raise ValueError('Truncated platform command')
            platform = struct.unpack_from('<I', data, offset + 8)[0]
        if command in (0xc, 0xd, 0x80000018, 0x8000001f, 0x80000023, 0x8000001c):
            if size < 12:
                raise ValueError('Truncated dependency command')
            name_offset = struct.unpack_from('<I', data, offset + 8)[0]
            if name_offset < 12 or name_offset >= size:
                raise ValueError('Invalid dependency string offset')
            name = data[offset + name_offset:offset + size].split(b'\0', 1)[0].decode('utf-8')
            if command == 0xd:
                install_name = name
            else:
                (rpaths if command == 0x8000001c else dependencies).append(name)
        offset += size
    if offset != 32 + command_bytes:
        raise ValueError('Inconsistent Mach-O command count')
    return {'platform': platform, 'file_type': file_type, 'dependencies': dependencies,
            'rpaths': rpaths, 'install_name': install_name}


def framework_plan(bundle):
    """Map each loose thin arm64 dylib to a flat embedded framework.

    This only plans moves. The caller must rewrite all Mach-O load commands,
    preserve section contents, emit the map, and use a map-aware runtime.
    """
    bundle = Path(bundle)
    plan, destinations = {}, {}
    for path in sorted(bundle.rglob('*')):
        if not path.is_file() or path.is_symlink():
            continue
        with path.open('rb') as source:
            if source.read(4) != b'\xcf\xfa\xed\xfe':
                continue
        data = path.read_bytes()
        metadata = macho_metadata(data)
        if metadata['file_type'] != 6:
            continue
        old = path.relative_to(bundle).as_posix()
        if any(part.endswith('.framework') for part in path.relative_to(bundle).parts):
            continue
        name = path.name
        while name.endswith('.dylib'):
            name = name[:-6]
        for prefix, replacement in (('DEBoundary_', 'DE_'), ('DEClientBoundary_', 'SC_'), ('Vendor_', 'V_')):
            if name.startswith(prefix):
                name = replacement + name[len(prefix):]
                break
        if not re.fullmatch(r'[A-Za-z0-9_-]+', name):
            raise ValueError('Unsafe framework name: ' + name)
        destination = 'Frameworks/' + name + '.framework/' + name
        digest = hashlib.sha256(data).hexdigest()
        if (destination in destinations and destinations[destination] != digest) or (bundle / destination).exists():
            raise ValueError('Framework destination collision: ' + name)
        plan[old] = destination
        destinations[destination] = digest
    return plan


def dependency_rewrites(bundle, image, metadata, plan):
    """Map exact local load commands; never guess by a library basename."""
    bundle, image = Path(bundle).resolve(), Path(image).resolve()
    rewrites = {}
    for dependency in metadata['dependencies']:
        candidates = []
        if dependency.startswith('@loader_path/'):
            candidates = [image.parent / dependency.removeprefix('@loader_path/')]
        elif dependency.startswith('@executable_path/'):
            candidates = [bundle / dependency.removeprefix('@executable_path/')]
        elif dependency.startswith('@rpath/'):
            tail = dependency.removeprefix('@rpath/')
            for rpath in metadata['rpaths'] + [str(bundle / 'Frameworks'), str(bundle)]:
                candidates.append(Path(rpath.replace('@loader_path', str(image.parent)).replace('@executable_path', str(bundle))) / tail)
        for candidate in candidates:
            candidate = candidate.resolve()
            if candidate.is_relative_to(bundle):
                key = candidate.relative_to(bundle).as_posix()
                if key in plan:
                    rewrites[dependency] = '@executable_path/' + plan[key]
                    break
    key = image.relative_to(bundle).as_posix()
    if metadata.get('install_name') and key in plan:
        rewrites[metadata['install_name']] = '@executable_path/' + plan[key]
    return rewrites


def inspect_bundle(bundle, mode='app-store', *, require_profile=True, require_signature=True):
    """Produce explicit local blockers, never infer readiness from a filename."""
    bundle = Path(bundle).resolve(strict=True)
    blockers, images = [], []

    def block(code, detail, path=None):
        entry = {'code': code, 'detail': detail}
        if path is not None:
            entry['path'] = str(path.relative_to(bundle))
        blockers.append(entry)

    try:
        info = plistlib.loads((bundle / 'Info.plist').read_bytes())
    except (OSError, plistlib.InvalidFileException):
        return {'format': 1, 'mode': mode, 'ready': False, 'images': [],
                'blockers': [{'code': 'invalid-info', 'detail': 'Missing or invalid Info.plist'}]}
    executable = info.get('CFBundleExecutable', '')
    if not isinstance(executable, str) or '/' in executable or not executable or not (bundle / executable).is_file():
        block('missing-main', 'CFBundleExecutable must name the bundle main executable')
    if info.get('CFBundleSupportedPlatforms') != ['iPhoneOS']:
        block('wrong-platform-metadata', 'Bundle must declare iPhoneOS only')
    if info.get('CFBundlePackageType') != 'APPL':
        block('wrong-package-type', 'Bundle must declare APPL')
    for key in ('CFBundleIdentifier', 'CFBundleVersion', 'CFBundleShortVersionString', 'MinimumOSVersion'):
        if not isinstance(info.get(key), str) or not info[key]:
            block('missing-metadata', key + ' is required')
    if mode == 'app-store' and info.get('DTPlatformName') != 'iphoneos':
        block('missing-sdk-metadata', 'Distribution requires selected device SDK metadata')
    if mode == 'app-store':
        icons = info.get('CFBundleIcons', {})
        primary = icons.get('CFBundlePrimaryIcon', {}) if isinstance(icons, dict) else {}
        icon_name = primary.get('CFBundleIconName') if isinstance(primary, dict) else None
        if not icon_name or not (bundle / 'Assets.car').is_file():
            block('missing-app-icon-catalog', 'Compile the app icon asset catalog including its 1024-point App Store image')
    if require_profile and not (bundle / 'embedded.mobileprovision').is_file():
        block('missing-profile', 'No App Store provisioning profile is embedded')
    if require_signature and not (bundle / '_CodeSignature/CodeResources').is_file():
        block('unsigned-bundle', 'Bundle has not been distribution signed')
    elif require_signature and require_profile and (bundle / 'embedded.mobileprovision').is_file():
        signature_error = verify_distribution_signature(bundle, info.get('CFBundleIdentifier', ''), mode)
        if signature_error:
            block('invalid-distribution-signature', signature_error)
    for path in sorted(bundle.rglob('*')):
        if path.is_symlink():
            if not path.resolve().is_relative_to(bundle):
                block('escaping-symlink', 'Symlink points outside the bundle', path)
            continue
        if not path.is_file():
            continue
        with path.open('rb') as source:
            prefix = source.read(4)
        if prefix in (b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca', b'\xca\xfe\xba\xbf', b'\xbf\xba\xfe\xca'):
            block('uninspected-fat-image', 'Expected thin arm64 image; universal image needs explicit architecture audit', path)
            continue
        if prefix != b'\xcf\xfa\xed\xfe':
            continue
        data = path.read_bytes()
        try:
            metadata = macho_metadata(data)
        except (ValueError, UnicodeDecodeError) as error:
            block('invalid-image', str(error), path)
            continue
        record = {'path': str(path.relative_to(bundle)), 'sha256': hashlib.sha256(data).hexdigest(), **metadata}
        images.append(record)
        if metadata['platform'] != 2:
            block('non-ios-image', 'Every packaged native image must target IOS', path)
        if mode == 'app-store':
            if metadata['file_type'] == 2 and path != bundle / executable:
                block('extra-executable', 'iOS distribution cannot include an arbitrary auxiliary executable', path)
            if metadata['file_type'] == 6 and not any(part.endswith('.framework') for part in path.relative_to(bundle).parts):
                # Embedded Swift runtime dylibs are the platform-provided exception.
                if not (path.parent == bundle / 'Frameworks' and path.name.startswith('libswift')):
                    block('standalone-dylib', 'Embed this library as a proper framework and rewrite its load paths', path)
            elif metadata['file_type'] == 6:
                relative = path.relative_to(bundle).parts
                if len(relative) != 3 or relative[0] != 'Frameworks' or relative[1] != relative[2] + '.framework':
                    block('invalid-framework-layout', 'Framework must be flat under the main Frameworks folder', path)
                else:
                    try:
                        framework_info = plistlib.loads((path.parent / 'Info.plist').read_bytes())
                    except (OSError, plistlib.InvalidFileException):
                        framework_info = {}
                    if framework_info.get('CFBundleExecutable') != path.name or framework_info.get('CFBundlePackageType') != 'FMWK':
                        block('invalid-framework-metadata', 'Framework Info.plist must describe its binary', path)
                    if metadata['install_name'] != '@executable_path/' + path.relative_to(bundle).as_posix():
                        block('invalid-framework-install-name', 'Framework install name must match the embedded image', path)
            markers = [marker.decode() for marker in PRIVATE_API_MARKERS if marker in data]
            if markers:
                block('private-api-reference', 'Targeted private API markers: ' + ', '.join(markers), path)
        for dependency in metadata['dependencies']:
            if dependency.startswith('@loader_path/'):
                resolved = path.parent / dependency.removeprefix('@loader_path/')
            elif dependency.startswith('@executable_path/'):
                resolved = bundle / dependency.removeprefix('@executable_path/')
            elif dependency.startswith(('/System/Library/', '/usr/lib/')):
                continue
            elif dependency.startswith('@rpath/'):
                # Dynamic @rpath resolution can inherit main-image paths. Report
                # unresolved paths only after considering these two common roots.
                tail = dependency.removeprefix('@rpath/')
                roots = []
                for rpath in metadata['rpaths'] + [str(bundle / 'Frameworks'), str(bundle)]:
                    roots.append(Path(rpath.replace('@loader_path', str(path.parent)).replace('@executable_path', str(bundle))))
                if any((root / tail).is_file() for root in roots):
                    continue
                block('unresolved-dependency', dependency, path)
                continue
            else:
                block('nonportable-dependency', dependency, path)
                continue
            if not resolved.resolve().is_relative_to(bundle) or not resolved.is_file():
                block('unresolved-dependency', dependency, path)
    if not any(item['path'] == executable and item['file_type'] == 2 for item in images):
        block('invalid-main', 'Main image must be a thin arm64 Mach-O executable')
    return {'format': 1, 'mode': mode, 'ready': not blockers,
            'qualification': 'Static local packaging checks only; excludes runtime, licensing, and Apple server validation',
            'bundle_id': info.get('CFBundleIdentifier'), 'version': info.get('CFBundleShortVersionString'),
            'build': info.get('CFBundleVersion'), 'images': images, 'blockers': blockers}
