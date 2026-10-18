#!/usr/bin/env python3
"""Create a private, hash-guarded HUD geometry probe; never install or launch it.

Change one CommandButton, or the known Mac profile's full 5-by-3 action grid,
using numeric geometry only. Names, types, action/state data, materials and
child widgets survive. Generated input regions are predictions until measured.
Proprietary input files and generated probes must stay outside tracked sources.
"""
import argparse
import copy
import hashlib
import json
import math
from pathlib import Path
import plistlib
import re

ROOT = Path(__file__).resolve().parents[1]
GENERATED = ROOT / 'generated'
PROFILE_VERSIONS = {'mac-488492.107976': '488492.107976'}
GRID_INPUT_PROFILE = 'mac-488492.107976-phone-grid-v1'
GEOMETRY_FIELDS = ('xorigin', 'yorigin', 'width', 'height')


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def _unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError('Duplicate JSON object key: ' + key)
        result[key] = value
    return result


def _invalid_constant(value):
    raise ValueError('Non-finite JSON constant: ' + value)


def _finite_number(value):
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return False
    try:
        return math.isfinite(value)
    except OverflowError:
        return False


def _pointer(parts):
    return '/' + '/'.join(str(part).replace('~', '~0').replace('/', '~1') for part in parts)


def find_widget(document, name_path, expected_type='CommandButton'):
    """Resolve exact Name ancestry, rejecting repeated paths in other branches."""
    if not name_path or any(not isinstance(name, str) or not name for name in name_path):
        raise ValueError('A nonempty Name path is required')
    matches = []

    def visit(node, names, pointer):
        if isinstance(node, dict):
            if isinstance(node.get('Name'), str):
                names = names + [node['Name']]
            if names == list(name_path) and node.get('Name') == name_path[-1]:
                matches.append((node, pointer))
            for key, value in node.items():
                visit(value, names, pointer + [key])
        elif isinstance(node, list):
            for index, value in enumerate(node):
                visit(value, names, pointer + [index])

    visit(document, [], [])
    if len(matches) != 1:
        raise ValueError('Name path must resolve to exactly one widget; found ' + str(len(matches)))
    widget, pointer = matches[0]
    if expected_type is not None and widget.get('Type') != expected_type:
        raise ValueError('Target must retain Type ' + expected_type)
    return widget, pointer


def changed_paths(before, after, path=()):
    """Semantic differences, independent of JSON whitespace and key order."""
    if type(before) is not type(after):
        return [path]
    if isinstance(before, dict):
        if before.keys() != after.keys():
            return [path]
        return [p for key in before for p in changed_paths(before[key], after[key], path + (key,))]
    if isinstance(before, list):
        if len(before) != len(after):
            return [path]
        return [p for index, value in enumerate(before)
                for p in changed_paths(value, after[index], path + (index,))]
    return [] if before == after else [path]


def patch_layout(source_bytes, name_path, geometry):
    if not geometry or set(geometry) - set(GEOMETRY_FIELDS):
        raise ValueError('Specify only xorigin, yorigin, width or height')
    before = json.loads(source_bytes.decode('utf-8-sig'), object_pairs_hook=_unique_object,
                        parse_constant=_invalid_constant)
    after = copy.deepcopy(before)
    widget, pointer = find_widget(after, name_path)
    viewport = widget.get('ViewPort')
    if not isinstance(viewport, dict):
        raise ValueError('Target must have a ViewPort object')
    changes = []
    for field, value in geometry.items():
        old = viewport.get(field)
        if not _finite_number(old) or not _finite_number(value):
            raise ValueError('Existing and requested geometry must be finite numbers: ' + field)
        # RapidJSON distinguishes integer and floating-point tokens. Preserve
        # the source representation rather than turning an integer into 160.0.
        if isinstance(old, int):
            if value != int(value):
                raise ValueError('Integer geometry required for original integer field: ' + field)
            value = int(value)
        else:
            value = float(value)
        if field in ('width', 'height') and value <= 0:
            raise ValueError('Button dimensions must be positive: ' + field)
        if old == value:
            continue
        viewport[field] = value
        changes.append({'field': field, 'before': old, 'after': value,
                        'name_path': list(name_path),
                        'json_pointer': _pointer(pointer + ['ViewPort', field])})
    if not changes:
        raise ValueError('Probe must change at least one geometry value')
    expected = {tuple(pointer + ['ViewPort', change['field']]) for change in changes}
    actual = set(changed_paths(before, after))
    if actual != expected:
        raise ValueError('Unexpected semantic change outside selected geometry')
    output = (json.dumps(after, ensure_ascii=False, indent=2, allow_nan=False) + '\n').encode('utf-8')
    return output, {'target_name_path': list(name_path), 'target_type': 'CommandButton',
                    'target_json_pointer': _pointer(pointer), 'changes': changes,
                    'semantic_changes_verified': True}


def patch_action_grid(source_bytes, *, cell_units, gap_units, padding_x_units,
                      padding_y_units, root_xorigin_units=None, root_yorigin_units=None,
                      open_width_units=None, design_scale=None, viewport_width=None, viewport_height=None):
    """Geometry allowlist for the original Mac CommandPanel's fifteen action slots.

    This preserves the existing TopRight stats anchor: widening the root puts
    its left edge after the tray without changing alignment or widget identity.
    An explicit open width can reproduce measured expanded-panel geometry;
    the original xclosed/xclip animation parameters are always kept.
    """
    for name, value in [('cell', cell_units), ('gap', gap_units),
                        ('padding x', padding_x_units), ('padding y', padding_y_units)]:
        if isinstance(value, bool) or not isinstance(value, int) or value < (1 if name == 'cell' else 0):
            raise ValueError('Grid dimensions must be integer design units: ' + name)
    before = json.loads(source_bytes.decode('utf-8-sig'), object_pairs_hook=_unique_object,
                        parse_constant=_invalid_constant)
    after = copy.deepcopy(before)
    root_path = ['CommandPanel']
    left_path = root_path + ['BackgroundLeft']
    right_path = root_path + ['BackgroundRight']
    buttons_path = left_path + ['Buttons']
    root, root_pointer = find_widget(after, root_path, None)
    left, _ = find_widget(after, left_path, 'Base')
    right, _ = find_widget(after, right_path, 'Base')
    buttons, _ = find_widget(after, buttons_path, 'Anchor')
    for widget, alignment in [(root, 'BottomLeft'), (left, 'TopLeft'), (right, 'TopRight')]:
        if not isinstance(widget.get('ViewPort'), dict) or widget['ViewPort'].get('alignment') != alignment:
            raise ValueError('Known grid profile requires original panel alignments')
    if right['ViewPort'].get('xorigin') != 0:
        raise ValueError('Known grid profile requires the original zero-offset TopRight anchor')
    slot_names = {'Button' + str(column) + str(row) for row in range(1, 4) for column in range(1, 6)}
    children = buttons.get('ChildWidgets')
    if not isinstance(children, list):
        raise ValueError('Known grid profile requires ChildWidgets')
    direct_slots = [child.get('Widget', {}) for child in children if isinstance(child, dict)]
    direct_names = [slot.get('Name') for slot in direct_slots if slot.get('Type') == 'CommandButton']
    if len(direct_names) != 15 or set(direct_names) != slot_names:
        raise ValueError('Known grid profile requires exactly the fifteen original action slots')
    changes = []

    def edit(path, container, geometry, expected_type=None):
        widget, pointer = find_widget(after, path, expected_type)
        values = widget.get(container)
        if not isinstance(values, dict):
            raise ValueError('Missing numeric geometry container: ' + container)
        for field, value in geometry.items():
            old = values.get(field)
            if (field not in GEOMETRY_FIELDS or not _finite_number(old) or not _finite_number(value)
                    or isinstance(old, int) and value != int(value)):
                raise ValueError('Invalid original or requested numeric geometry: ' + field)
            value = int(value) if isinstance(old, int) else float(value)
            if field in ('width', 'height') and value <= 0:
                raise ValueError('Geometry dimensions must be positive')
            if old != value:
                values[field] = value
                changes.append({'name_path': path, 'geometry_container': container, 'field': field,
                                'before': old, 'after': value,
                                'json_pointer': _pointer(pointer + [container, field])})

    old_root = copy.deepcopy(root['ViewPort'])
    old_right = copy.deepcopy(right['ViewPort'])
    for field in ('width', 'height', 'xorigin', 'yorigin'):
        if not _finite_number(old_root.get(field)) or not _finite_number(old_right.get(field)):
            raise ValueError('Original panel geometry must be finite')
    tray_width = 5 * cell_units + 4 * gap_units + 2 * padding_x_units
    tray_height = 3 * cell_units + 2 * gap_units + 2 * padding_y_units
    root_height = max(old_root['height'], tray_height)
    root_geometry = {'width': max(old_root['width'], tray_width + old_right['width']), 'height': root_height}
    if root_xorigin_units is not None:
        root_geometry['xorigin'] = root_xorigin_units
    if root_yorigin_units is not None:
        root_geometry['yorigin'] = root_yorigin_units
    edit(root_path, 'ViewPort', root_geometry)
    if open_width_units is not None:
        old = root.get('xopen')
        if (not _finite_number(old) or not _finite_number(open_width_units)
                or open_width_units <= 0
                or isinstance(old, int) and open_width_units != int(open_width_units)):
            raise ValueError('Open width requires existing and requested positive numeric xopen geometry')
        value = int(open_width_units) if isinstance(old, int) else float(open_width_units)
        if old != value:
            root['xopen'] = value
            changes.append({'name_path': root_path, 'geometry_container': 'Collection', 'field': 'xopen',
                            'before': old, 'after': value,
                            'json_pointer': _pointer(root_pointer + ['xopen'])})
    edit(left_path, 'ViewPort', {'width': tray_width, 'height': tray_height}, 'Base')
    edit(right_path, 'ViewPort', {'yorigin': old_right['yorigin'] + root_height - old_root['height']}, 'Base')
    edit(buttons_path, 'Anchor', {'xorigin': padding_x_units, 'yorigin': padding_y_units}, 'Anchor')
    slots = []
    for row in range(3):
        for column in range(5):
            path = buttons_path + ['Button' + str(column + 1) + str(row + 1)]
            widget, _ = find_widget(after, path)
            if widget.get('ViewPort', {}).get('alignment') != 'TopLeft':
                raise ValueError('Known grid profile requires TopLeft action slots')
            x, y = column * (cell_units + gap_units), row * (cell_units + gap_units)
            edit(path, 'ViewPort', {'xorigin': x, 'yorigin': y,
                                    'width': cell_units, 'height': cell_units}, 'CommandButton')
            slots.append({'name_path': path, 'column': column + 1, 'row': row + 1,
                          'design_rect': {'x': padding_x_units + x, 'y': padding_y_units + y,
                                          'width': cell_units, 'height': cell_units}})
    if not changes:
        raise ValueError('Grid probe must change geometry')
    if {_pointer(path) for path in changed_paths(before, after)} != {change['json_pointer'] for change in changes}:
        raise ValueError('Unexpected semantic change outside the known geometry allowlist')
    modified = (json.dumps(after, ensure_ascii=False, indent=2, allow_nan=False) + '\n').encode('utf-8')
    details = {'layout_mode': 'mac-action-grid-5x3', 'target_name_path': buttons_path,
               'changes': changes, 'semantic_changes_verified': True, 'slots': slots,
               'tray_design_size': {'width': tray_width, 'height': tray_height}}
    calibration = (design_scale, viewport_width, viewport_height)
    if any(value is not None for value in calibration):
        if not all(_finite_number(value) and value > 0 for value in calibration):
            raise ValueError('Input predictions require positive scale and viewport dimensions together')
        viewport = root['ViewPort']
        tray_x = (viewport['xorigin'] - old_root['xorigin']) * design_scale
        panel_top = viewport_height + (viewport['yorigin'] - old_root['yorigin']) * design_scale - root_height * design_scale

        def rect(x, y, width, height):
            return {'x': x, 'y': y, 'width': width, 'height': height}

        regions = [{'id': 'action-tray', 'role': 'native-hud-input',
                    **rect(tray_x, panel_top, tray_width * design_scale, tray_height * design_scale)},
                   {'id': 'stats-queue', 'role': 'native-hud-input',
                    **rect(tray_x + (viewport['width'] - old_right['width']) * design_scale,
                           panel_top + right['ViewPort']['yorigin'] * design_scale,
                           old_right['width'] * design_scale, old_right['height'] * design_scale)}]
        rectangles = []
        for slot in slots:
            r = slot['design_rect']
            rectangles.append({'name_path': slot['name_path'],
                               'rect': rect(tray_x + r['x'] * design_scale,
                                            panel_top + r['y'] * design_scale,
                                            r['width'] * design_scale, r['height'] * design_scale)})
        for r in regions + [item['rect'] for item in rectangles]:
            if r['x'] < 0 or r['y'] < 0 or r['x'] + r['width'] > viewport_width + 0.001 or r['y'] + r['height'] > viewport_height + 0.001:
                raise ValueError('Predicted HUD geometry does not fit the specified viewport')
        details['input_prediction'] = {
            'format': 1, 'profile': GRID_INPUT_PROFILE, 'layout_sha256': sha256(modified),
            'coordinate_space': 'UIKit view points; top-left origin',
            'viewport': {'width': viewport_width, 'height': viewport_height},
            'validation': 'predicted; not runtime hit-tested',
            'calibration': {'UIKit_points_per_design_unit': design_scale,
                            'assumptions': ['Original root BottomLeft anchor reaches viewport bottom',
                                            'UI Scale preference is 100; preference is not hash-validated',
                                            'Safe areas/reserved regions require caller padding and runtime verification',
                                            'Engine xopen/xclosed/xclip behavior has not been recalibrated']},
            'regions': regions, 'rectangles': rectangles}
    return modified, details


def observed_input_regions(source_bytes, prediction, layout_sha256):
    """Validate operator-supplied measurements; never accept its layout identity."""
    observed = json.loads(source_bytes.decode('utf-8-sig'), object_pairs_hook=_unique_object,
                          parse_constant=_invalid_constant)
    if not isinstance(observed, dict):
        raise ValueError('Observed input calibration must be a JSON object')
    if observed.get('profile', GRID_INPUT_PROFILE) != GRID_INPUT_PROFILE:
        raise ValueError('Observed input calibration profile must be ' + GRID_INPUT_PROFILE)
    viewport = observed.get('viewport')
    expected = prediction['viewport']
    if (not isinstance(viewport, dict)
            or any(not _finite_number(viewport.get(key)) or viewport[key] != expected[key]
                   for key in ('width', 'height'))):
        raise ValueError('Observed input calibration viewport must match requested viewport')
    regions = observed.get('regions')
    if not isinstance(regions, list) or not 1 <= len(regions) <= 64:
        raise ValueError('Observed input calibration requires 1..64 flat regions')
    for region in regions:
        if (not isinstance(region, dict) or 'rect' in region
                or any(not _finite_number(region.get(key)) for key in ('x', 'y', 'width', 'height'))):
            raise ValueError('Observed regions require finite flat x/y/width/height numbers')
        if (region['x'] < 0 or region['y'] < 0 or region['width'] <= 0 or region['height'] <= 0
                or region['x'] + region['width'] > expected['width']
                or region['y'] + region['height'] > expected['height']):
            raise ValueError('Observed regions must be contained in the requested viewport')
    screenshot = observed.get('calibration_screenshot')
    if screenshot is not None and (not isinstance(screenshot, str) or not screenshot):
        raise ValueError('Calibration screenshot reference must be a nonempty string')
    result = copy.deepcopy(prediction)
    result.update(profile=GRID_INPUT_PROFILE, layout_sha256=layout_sha256, regions=regions,
                  validation='operator-observed regions; generator has not inspected screenshot',
                  rectangles_validation='predicted slot rectangles; not replaced by observed regions')
    result['observed_calibration'] = {'source_sha256': sha256(source_bytes)}
    if screenshot is not None:
        result['observed_calibration']['calibration_screenshot'] = screenshot
    return result


def create_probe(source, output, manifest, *, profile, game_info, source_sha256,
                 name_path=None, geometry=None, action_grid=None, input_manifest=None,
                 input_regions_json=None, generated_root=GENERATED):
    """Write fresh artifacts only. generated_root is injectable for synthetic tests."""
    if profile not in PROFILE_VERSIONS:
        raise ValueError('Unsupported HUD profile: ' + profile)
    if not re.fullmatch(r'[0-9a-fA-F]{64}', source_sha256):
        raise ValueError('An exact expected source SHA-256 is required')
    source, game_info = Path(source).resolve(strict=True), Path(game_info).resolve(strict=True)
    root = Path(generated_root).resolve()
    output, manifest = Path(output).resolve(), Path(manifest).resolve()
    destinations = [output, manifest]
    if input_manifest is not None:
        input_manifest = Path(input_manifest).resolve()
        destinations.append(input_manifest)
    for destination in destinations:
        if destination == root or not destination.is_relative_to(root):
            raise ValueError('Probe output must be inside the private generated directory')
        if destination in (source, game_info) or destination.exists():
            raise ValueError('Refusing to overwrite source, metadata or an existing artifact')
    if len(set(destinations)) != len(destinations):
        raise ValueError('Output and manifest must be different files')
    version = plistlib.loads(game_info.read_bytes()).get('CFBundleVersion')
    if version != PROFILE_VERSIONS[profile]:
        raise ValueError('Game bundle version does not match HUD profile')
    original = source.read_bytes()
    if sha256(original) != source_sha256.lower():
        raise ValueError('Source SHA-256 does not match the measured baseline')
    if action_grid is not None:
        if name_path is not None or geometry:
            raise ValueError('Choose either one widget or the full action grid')
        modified, details = patch_action_grid(original, **action_grid)
    else:
        if input_manifest is not None or input_regions_json is not None:
            raise ValueError('Input manifest is available only for the full action-grid profile')
        modified, details = patch_layout(original, name_path, geometry)
    if input_manifest is not None and 'input_prediction' not in details:
        raise ValueError('Input manifest requires scale and viewport calibration')
    if input_regions_json is not None:
        if input_manifest is None:
            raise ValueError('Observed input regions require an input manifest destination')
        calibration_source = Path(input_regions_json).resolve(strict=True)
        details['input_prediction'] = observed_input_regions(
            calibration_source.read_bytes(), details['input_prediction'], sha256(modified))
        details['input_prediction']['observed_calibration']['source'] = str(calibration_source)
    report = {'format': 1, 'scope': 'private geometry probe only; not installed or runtime validated',
              'profile': profile, 'bundle_version': version, 'game_info': str(game_info),
              'source': str(source), 'source_sha256': sha256(original),
              'output': str(output), 'output_sha256': sha256(modified), **details}
    artifacts = {output: modified}
    if input_manifest is not None:
        report['input_manifest'] = str(input_manifest)
        input_report = {'bundle_version': version, **details['input_prediction']}
        artifacts[input_manifest] = (json.dumps(input_report, indent=2, allow_nan=False) + '\n').encode('utf-8')
    artifacts[manifest] = (json.dumps(report, indent=2, allow_nan=False) + '\n').encode('utf-8')
    created = []
    try:
        for path, data in artifacts.items():
            path.parent.mkdir(parents=True, exist_ok=True)
            with path.open('xb') as handle:
                created.append(path)
                handle.write(data)
    except OSError:
        for path in reversed(created):
            path.unlink()  # Only fresh artifacts this invocation created.
        raise
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--manifest', type=Path, required=True)
    parser.add_argument('--profile', required=True, choices=PROFILE_VERSIONS)
    parser.add_argument('--game-info', type=Path, required=True, help='Owned app Contents/Info.plist')
    parser.add_argument('--source-sha256', required=True, help='Expected SHA-256 of measured source JSON')
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument('--name-path', help='Exact slash-separated Name ancestry')
    mode.add_argument('--action-grid', action='store_true', help='Known Mac 5-by-3 production/action grid')
    for field in GEOMETRY_FIELDS:
        parser.add_argument('--' + field, type=float)
    for option in ('cell-units', 'gap-units', 'padding-x-units', 'padding-y-units',
                   'root-xorigin-units', 'root-yorigin-units', 'open-width-units'):
        parser.add_argument('--' + option, type=int)
    parser.add_argument('--design-scale', type=float, help='Measured UIKit points per source design unit')
    parser.add_argument('--viewport-width', type=float)
    parser.add_argument('--viewport-height', type=float)
    parser.add_argument('--input-manifest', type=Path, help='Optional fresh predicted input-region artifact')
    parser.add_argument('--input-regions-json', type=Path, help='Observed flat input regions and matching viewport')
    args = parser.parse_args()
    # Do not let a replacement/symlinked generated root redirect CLI output.
    if GENERATED.resolve() != GENERATED:
        parser.error('The repository generated directory must not be a symlink')
    geometry = {field: getattr(args, field) for field in GEOMETRY_FIELDS if getattr(args, field) is not None}
    grid = None
    if args.action_grid:
        if geometry:
            parser.error('Single-widget geometry flags cannot be combined with --action-grid')
        required = ('cell_units', 'gap_units', 'padding_x_units', 'padding_y_units')
        if any(getattr(args, name) is None for name in required):
            parser.error('--action-grid requires cell, gap and both padding values in design units')
        grid = {name: getattr(args, name) for name in required + ('root_xorigin_units', 'root_yorigin_units',
                                                               'open_width_units', 'design_scale', 'viewport_width', 'viewport_height')}
    elif any(getattr(args, name) is not None for name in ('cell_units', 'gap_units', 'padding_x_units',
              'padding_y_units', 'root_xorigin_units', 'root_yorigin_units', 'open_width_units',
              'design_scale', 'viewport_width', 'viewport_height')):
        parser.error('Grid/calibration flags require --action-grid')
    try:
        report = create_probe(args.source, args.output, args.manifest, profile=args.profile,
                              game_info=args.game_info, source_sha256=args.source_sha256,
                              name_path=args.name_path.split('/') if args.name_path else None,
                              geometry=geometry, action_grid=grid, input_manifest=args.input_manifest,
                              input_regions_json=args.input_regions_json)
    except (OSError, ValueError, TypeError, plistlib.InvalidFileException) as error:
        parser.error(str(error))
    print('Prepared private HUD geometry probe: ' + report['output'])
    print('Manifest: ' + str(args.manifest))


if __name__ == '__main__':
    main()
