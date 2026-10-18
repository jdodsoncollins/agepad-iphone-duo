"""Synthetic JSON only: identity preservation, unique targeting and private outputs."""
import copy
import json
from pathlib import Path
import plistlib
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
import de_hud_layout as hud


def fixture():
    return {'Collection': {'Name': 'Root', 'Widgets': [
        {'Widget': {'Name': 'Commands', 'Type': 'Anchor', 'ChildWidgets': [
            {'Widget': {'Name': 'ActionA', 'Type': 'CommandButton',
                        'ViewPort': {'xorigin': 10, 'yorigin': -20, 'width': 80,
                                     'height': 80, 'alignment': 'TopLeft'},
                        'Action': {'command': 'train', 'argument': 7},
                        'StateMaterials': {'normal': 'bronze', 'disabled': 'gray'},
                        'ChildWidgets': [{'Name': 'Caption', 'Type': 'Label',
                                          'Text': 'Readability ✓', 'Font': {'PointSize': 12}}]}},
            {'Widget': {'Name': 'ActionB', 'Type': 'CommandButton',
                        'ViewPort': {'xorigin': 90, 'yorigin': -20, 'width': 80, 'height': 80}}}
        ]}},
        {'Widget': {'Name': 'OtherPanel', 'Type': 'Base', 'ChildWidgets': [
            {'Widget': {'Name': 'ActionA', 'Type': 'CommandButton',
                        'ViewPort': {'xorigin': 0, 'yorigin': 0, 'width': 60, 'height': 60}}}
        ]}}
    ]}}


TARGET = ['Root', 'Commands', 'ActionA']


def grid_fixture():
    """Minimal synthetic widget tree, not copied from the private game JSON."""
    slots = []
    for row in range(1, 4):
        for column in range(1, 6):
            slots.append({'Widget': {'Name': 'Button' + str(column) + str(row), 'Type': 'CommandButton',
                          'ViewPort': {'xorigin': column * 12, 'yorigin': row * 13,
                                       'width': 80, 'height': 80, 'alignment': 'TopLeft'},
                          'StateMaterials': {'normal': 'synthetic', 'disabled': 'synthetic-off'},
                          'Action': {'slot': [column, row]}, 'ChildWidgets': []}})
    return {'Collection': {'Name': 'CommandPanel',
            'ViewPort': {'xorigin': 0, 'yorigin': 2159, 'width': 2246, 'height': 413, 'alignment': 'BottomLeft'},
            'xopen': 4200, 'xclosed': 1000, 'xclip': 500,
            'ActionButtonFont': {'PointSize': 34},
            'Widgets': [
                {'Widget': {'Name': 'BackgroundRight', 'Type': 'Base',
                            'ViewPort': {'xorigin': 0, 'yorigin': 0, 'width': 1888, 'height': 413, 'alignment': 'TopRight'},
                            'ChildWidgets': [{'Widget': {'Name': 'Info', 'Type': 'Label', 'Text': 'Synthetic'}}]}},
                {'Widget': {'Name': 'BackgroundLeft', 'Type': 'Base',
                            'ViewPort': {'xorigin': 0, 'yorigin': 0, 'width': 660, 'height': 413, 'alignment': 'TopLeft'},
                            'ChildWidgets': [{'Widget': {'Name': 'Buttons', 'Type': 'Anchor',
                                                         'Anchor': {'xorigin': 45, 'yorigin': 90},
                                                         'ChildWidgets': slots}}]}}
            ]}}


GRID_OPTIONS = dict(cell_units=240, gap_units=44, padding_x_units=64, padding_y_units=120,
                    root_xorigin_units=320, design_scale=402 / 2160,
                    viewport_width=874, viewport_height=402)


class GridGeometryTests(unittest.TestCase):
    def test_explicit_open_width_changes_only_known_animation_geometry(self):
        original = grid_fixture()
        baseline, _ = hud.patch_action_grid(json.dumps(original).encode(), **GRID_OPTIONS)
        output, report = hud.patch_action_grid(json.dumps(original).encode(),
                                               **GRID_OPTIONS, open_width_units=3392)
        modified = json.loads(output)
        self.assertEqual(hud.changed_paths(json.loads(baseline), modified), [('Collection', 'xopen')])
        self.assertEqual(modified['Collection']['xopen'], 3392)
        self.assertIs(type(modified['Collection']['xopen']), int)
        for field in ('xclosed', 'xclip'):
            self.assertEqual(modified['Collection'][field], original['Collection'][field])
        change = next(item for item in report['changes'] if item['field'] == 'xopen')
        self.assertEqual(change['json_pointer'], '/Collection/xopen')
        for value in (0, -1, True, float('inf'), 3392.5):
            with self.subTest(value=value), self.assertRaises(ValueError):
                hud.patch_action_grid(json.dumps(original).encode(), **GRID_OPTIONS, open_width_units=value)
        del original['Collection']['xopen']
        with self.assertRaises(ValueError):
            hud.patch_action_grid(json.dumps(original).encode(), **GRID_OPTIONS, open_width_units=3392)

    def test_fifteen_action_slots_and_parent_geometry_preserve_semantics(self):
        original = grid_fixture()
        output, report = hud.patch_action_grid(json.dumps(original).encode(), **GRID_OPTIONS)
        modified = json.loads(output)
        self.assertEqual(len(report['slots']), 15)
        self.assertEqual(report['tray_design_size'], {'width': 1504, 'height': 1048})
        root = modified['Collection']
        self.assertEqual(root['ViewPort']['width'], 3392)
        self.assertEqual(root['ViewPort']['height'], 1048)
        self.assertEqual(root['ViewPort']['xorigin'], 320)
        self.assertEqual(root['ViewPort']['alignment'], 'BottomLeft')
        for field in ('xopen', 'xclosed', 'xclip', 'ActionButtonFont'):
            self.assertEqual(root[field], original['Collection'][field])
        right, _ = hud.find_widget(modified, ['CommandPanel', 'BackgroundRight'], 'Base')
        self.assertEqual(right['ViewPort']['xorigin'], 0)
        self.assertEqual(right['ViewPort']['yorigin'], 635)
        self.assertEqual(right['ViewPort']['alignment'], 'TopRight')
        for slot in report['slots']:
            old, _ = hud.find_widget(original, slot['name_path'])
            new, _ = hud.find_widget(modified, slot['name_path'])
            self.assertEqual({k: v for k, v in old.items() if k != 'ViewPort'},
                             {k: v for k, v in new.items() if k != 'ViewPort'})
            viewport = new['ViewPort']
            self.assertEqual(viewport['xorigin'], (slot['column'] - 1) * 284)
            self.assertEqual(viewport['yorigin'], (slot['row'] - 1) * 284)
            self.assertEqual((viewport['width'], viewport['height']), (240, 240))
            self.assertIs(type(viewport['width']), int)
        # In particular, the far column and bottom row must fit in their tray.
        last = report['slots'][-1]
        self.assertEqual(last['name_path'][-1], 'Button53')
        self.assertEqual(last['design_rect'], {'x': 1200, 'y': 688, 'width': 240, 'height': 240})
        self.assertEqual(1504 - last['design_rect']['x'] - 240, 64)
        self.assertEqual(1048 - last['design_rect']['y'] - 240, 120)
        self.assertEqual({hud._pointer(p) for p in hud.changed_paths(original, modified)},
                         {change['json_pointer'] for change in report['changes']})

    def test_native_input_schema_and_calibrated_full_hud_regions(self):
        output, report = hud.patch_action_grid(json.dumps(grid_fixture()).encode(), **GRID_OPTIONS)
        prediction = report['input_prediction']
        self.assertEqual(prediction['profile'], 'mac-488492.107976-phone-grid-v1')
        self.assertEqual(prediction['layout_sha256'], hud.sha256(output))
        self.assertEqual(prediction['viewport'], {'width': 874, 'height': 402})
        self.assertIn('predicted', prediction['validation'])
        self.assertIn('not hash-validated', ' '.join(prediction['calibration']['assumptions']))
        self.assertEqual(len(prediction['rectangles']), 15)
        tray, stats = prediction['regions']
        for region in prediction['regions']:
            self.assertTrue({'x', 'y', 'width', 'height'}.issubset(region))
            self.assertNotIn('rect', region)
        self.assertAlmostEqual(tray['x'] + tray['width'], stats['x'])
        self.assertAlmostEqual(stats['y'] + stats['height'], 402)
        self.assertLess(stats['x'] + stats['width'], 874)
        scale = 402 / 2160
        for slot in prediction['rectangles']:
            rect = slot['rect']
            self.assertGreaterEqual(rect['width'], 44)
            self.assertAlmostEqual(rect['width'], 240 * scale)
            self.assertGreaterEqual(rect['x'], 60)  # Explicit camera-side padding.
            self.assertLessEqual(rect['y'] + rect['height'], 381)  # Explicit 21-point bottom inset.
            self.assertGreaterEqual(rect['y'], tray['y'])
            self.assertLessEqual(rect['x'] + rect['width'], tray['x'] + tray['width'])
        last = prediction['rectangles'][-1]['rect']
        self.assertAlmostEqual(last['y'] + last['height'], 402 - 120 * scale)

    def test_profile_structure_and_calibration_guards(self):
        for mutation in ('missing', 'duplicate', 'alignment', 'right-offset'):
            document = grid_fixture()
            left = document['Collection']['Widgets'][1]['Widget']
            slots = left['ChildWidgets'][0]['Widget']['ChildWidgets']
            if mutation == 'missing':
                slots.pop()
            elif mutation == 'duplicate':
                slots[-1] = copy.deepcopy(slots[0])
            elif mutation == 'alignment':
                left['ViewPort']['alignment'] = 'BottomRight'
            else:
                document['Collection']['Widgets'][0]['Widget']['ViewPort']['xorigin'] = 100
            with self.subTest(mutation=mutation), self.assertRaises(ValueError):
                hud.patch_action_grid(json.dumps(document).encode(), **GRID_OPTIONS)
        for values in ({'cell_units': 0}, {'gap_units': -1}, {'cell_units': 240.5},
                       {'design_scale': float('nan')}, {'viewport_width': None},
                       {'viewport_width': 200}):
            with self.subTest(values=values), self.assertRaises(ValueError):
                hud.patch_action_grid(json.dumps(grid_fixture()).encode(), **{**GRID_OPTIONS, **values})


class GeometryTests(unittest.TestCase):
    def test_only_requested_geometry_changes_preserving_command_semantics(self):
        original = json.dumps(fixture(), indent=4).encode()
        snapshot = bytes(original)
        output, report = hud.patch_layout(original, TARGET, {'width': 160, 'height': 144, 'yorigin': -84})
        before, after = json.loads(original), json.loads(output)
        old, pointer = hud.find_widget(before, TARGET)
        new, _ = hud.find_widget(after, TARGET)
        expected = copy.deepcopy(old)
        expected['ViewPort'].update(width=160, height=144, yorigin=-84)
        self.assertEqual(new, expected)
        self.assertEqual(set(hud.changed_paths(before, after)),
                         {tuple(pointer + ['ViewPort', field]) for field in ('width', 'height', 'yorigin')})
        self.assertEqual(original, snapshot)
        self.assertEqual(report['target_name_path'], TARGET)
        self.assertEqual(report['target_type'], 'CommandButton')
        self.assertTrue(report['semantic_changes_verified'])
        self.assertEqual(len(report['changes']), 3)
        self.assertTrue(all(change['json_pointer'].startswith(report['target_json_pointer'] + '/ViewPort/')
                            for change in report['changes']))

    def test_repeated_leaf_name_uses_exact_full_ancestry(self):
        output, _ = hud.patch_layout(json.dumps(fixture()).encode(), TARGET, {'xorigin': -42})
        untouched, _ = hud.find_widget(json.loads(output), ['Root', 'OtherPanel', 'ActionA'])
        self.assertEqual(untouched['ViewPort']['xorigin'], 0)
        with self.assertRaisesRegex(ValueError, 'exactly one'):
            hud.patch_layout(json.dumps(fixture()).encode(), ['ActionA'], {'width': 120})

    def test_numeric_token_kind_is_preserved_for_rapidjson_consumers(self):
        output, _ = hud.patch_layout(json.dumps(fixture()).encode(), TARGET, {'width': 160.0})
        widget, _ = hud.find_widget(json.loads(output), TARGET)
        self.assertIs(type(widget['ViewPort']['width']), int)
        with self.assertRaisesRegex(ValueError, 'Integer geometry'):
            hud.patch_layout(json.dumps(fixture()).encode(), TARGET, {'width': 160.5})
        document = fixture()
        widget, _ = hud.find_widget(document, TARGET)
        widget['ViewPort']['width'] = 80.0
        output, _ = hud.patch_layout(json.dumps(document).encode(), TARGET, {'width': 160})
        widget, _ = hud.find_widget(json.loads(output), TARGET)
        self.assertIs(type(widget['ViewPort']['width']), float)

    def test_duplicate_full_name_path_is_rejected(self):
        document = fixture()
        children = document['Collection']['Widgets'][0]['Widget']['ChildWidgets']
        children.append(copy.deepcopy(children[0]))
        with self.assertRaisesRegex(ValueError, 'found 2'):
            hud.patch_layout(json.dumps(document).encode(), TARGET, {'width': 120})

    def test_wrong_widget_type_and_missing_numeric_field_are_rejected(self):
        document = fixture()
        widget, _ = hud.find_widget(document, TARGET)
        widget['Type'] = 'Label'
        with self.assertRaisesRegex(ValueError, 'CommandButton'):
            hud.patch_layout(json.dumps(document).encode(), TARGET, {'width': 120})
        document = fixture()
        widget, _ = hud.find_widget(document, TARGET)
        del widget['ViewPort']['width']
        with self.assertRaisesRegex(ValueError, 'finite numbers'):
            hud.patch_layout(json.dumps(document).encode(), TARGET, {'width': 120})

    def test_invalid_geometry_and_no_op_are_rejected(self):
        original = json.dumps(fixture()).encode()
        cases = [{}, {'Name': 'different'}, {'width': 0}, {'height': -5},
                 {'xorigin': float('inf')}, {'width': float('nan')}, {'height': True}, {'width': 80},
                 {'width': 10 ** 1000}]
        for geometry in cases:
            with self.subTest(geometry=geometry), self.assertRaises(ValueError):
                hud.patch_layout(original, TARGET, geometry)

    def test_duplicate_json_keys_and_nonfinite_source_are_rejected(self):
        for source in (b'{"Name":"one","Name":"two"}', b'{"value": NaN}'):
            with self.subTest(source=source), self.assertRaises(ValueError):
                hud.patch_layout(source, TARGET, {'width': 120})


class ArtifactTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.generated = self.directory / 'generated'
        self.source = self.directory / 'owned.json'
        self.raw = json.dumps(fixture(), indent=4, ensure_ascii=True).encode()
        self.source.write_bytes(self.raw)
        self.info = self.directory / 'Info.plist'
        self.info.write_bytes(plistlib.dumps({'CFBundleVersion': '488492.107976'}))
        self.output = self.generated / 'probe/widgetui/panel.json'
        self.manifest = self.generated / 'probe/manifest.json'

    def create(self, **overrides):
        options = dict(profile='mac-488492.107976', game_info=self.info,
                       source_sha256=hud.sha256(self.raw), name_path=TARGET,
                       geometry={'width': 160, 'height': 160}, generated_root=self.generated)
        options.update(overrides)
        return hud.create_probe(self.source, self.output, self.manifest, **options)

    def test_manifest_describes_actual_output_and_preserves_raw_source(self):
        info_bytes = self.info.read_bytes()
        report = self.create()
        self.assertEqual(json.loads(self.manifest.read_bytes()), report)
        self.assertEqual(report['source_sha256'], hud.sha256(self.raw))
        self.assertEqual(report['output_sha256'], hud.sha256(self.output.read_bytes()))
        self.assertEqual(report['bundle_version'], '488492.107976')
        self.assertEqual(report['profile'], 'mac-488492.107976')
        self.assertEqual(self.source.read_bytes(), self.raw)
        self.assertEqual(self.info.read_bytes(), info_bytes)

    def test_hash_profile_and_bundle_version_fail_before_writing(self):
        for overrides in ({'source_sha256': '0' * 64}, {'source_sha256': 'bad'}, {'profile': 'unknown'}):
            with self.subTest(overrides=overrides), self.assertRaises(ValueError):
                self.create(**overrides)
            self.assertFalse(self.output.exists())
        self.info.write_bytes(plistlib.dumps({'CFBundleVersion': 'different'}))
        with self.assertRaisesRegex(ValueError, 'bundle version'):
            self.create()
        self.assertFalse(self.manifest.exists())

    def test_outputs_outside_generated_and_source_overwrites_are_rejected(self):
        for attribute, path in [('output', self.directory / 'elsewhere.json'),
                                ('manifest', self.directory / 'elsewhere.json'),
                                ('output', self.source), ('manifest', self.info)]:
            previous = getattr(self, attribute)
            setattr(self, attribute, path)
            with self.subTest(attribute=attribute, path=path), self.assertRaises(ValueError):
                self.create()
            setattr(self, attribute, previous)
        self.assertEqual(self.source.read_bytes(), self.raw)
        self.assertFalse(self.output.exists())

    def test_existing_output_or_manifest_is_never_overwritten(self):
        for attribute in ('output', 'manifest'):
            path = getattr(self, attribute)
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b'preserve me')
            with self.subTest(attribute=attribute), self.assertRaises(ValueError):
                self.create()
            self.assertEqual(path.read_bytes(), b'preserve me')
            path.unlink()
        self.assertFalse(self.output.exists())

    def test_symlink_escape_and_shared_destination_are_rejected(self):
        self.generated.mkdir()
        outside = self.directory / 'outside'
        outside.mkdir()
        (self.generated / 'escape').symlink_to(outside, target_is_directory=True)
        self.output = self.generated / 'escape/panel.json'
        with self.assertRaisesRegex(ValueError, 'private generated'):
            self.create()
        self.output = self.manifest
        with self.assertRaisesRegex(ValueError, 'different files'):
            self.create()
        self.assertFalse((outside / 'panel.json').exists())

    def test_full_grid_writes_matching_native_input_manifest_and_layout_sha(self):
        self.raw = json.dumps(grid_fixture()).encode()
        self.source.write_bytes(self.raw)
        input_manifest = self.generated / 'probe/input.json'
        report = self.create(name_path=None, geometry=None, action_grid=GRID_OPTIONS,
                             input_manifest=input_manifest)
        input_report = json.loads(input_manifest.read_bytes())
        self.assertEqual(input_report['profile'], hud.GRID_INPUT_PROFILE)
        self.assertEqual(input_report['layout_sha256'], hud.sha256(self.output.read_bytes()))
        self.assertEqual(report['output_sha256'], input_report['layout_sha256'])
        self.assertEqual(report['profile'], 'mac-488492.107976')
        self.assertEqual(len(input_report['regions']), 2)
        self.assertEqual(self.source.read_bytes(), self.raw)

    def test_full_grid_input_manifest_has_same_path_and_calibration_guards(self):
        self.raw = json.dumps(grid_fixture()).encode()
        self.source.write_bytes(self.raw)
        for path in (self.directory / 'escape.json', self.output):
            with self.subTest(path=path), self.assertRaises(ValueError):
                self.create(name_path=None, geometry=None, action_grid=GRID_OPTIONS, input_manifest=path)
        uncalibrated = {k: v for k, v in GRID_OPTIONS.items()
                        if k not in ('design_scale', 'viewport_width', 'viewport_height')}
        with self.assertRaisesRegex(ValueError, 'requires scale'):
            self.create(name_path=None, geometry=None, action_grid=uncalibrated,
                        input_manifest=self.generated / 'probe/input.json')
        self.assertFalse(self.output.exists())

    def test_observed_regions_stamp_actual_output_identity_and_preserve_inputs(self):
        self.raw = json.dumps(grid_fixture()).encode()
        self.source.write_bytes(self.raw)
        calibration = self.directory / 'calibration.json'
        observed = {'viewport': {'width': 874, 'height': 402},
                    'profile': hud.GRID_INPUT_PROFILE, 'layout_sha256': 'stale-untrusted-digest',
                    'regions': [{'x': 60, 'y': 215, 'width': 294, 'height': 187},
                                {'x': 340, 'y': 215, 'width': 351, 'height': 100}],
                    'calibration_screenshot': 'generated/synthetic-evidence.png'}
        raw_calibration = json.dumps(observed).encode()
        calibration.write_bytes(raw_calibration)
        input_manifest = self.generated / 'probe/input.json'
        report = self.create(name_path=None, geometry=None,
                             action_grid={**GRID_OPTIONS, 'open_width_units': 3392},
                             input_manifest=input_manifest, input_regions_json=calibration)
        result = json.loads(input_manifest.read_bytes())
        self.assertEqual(result['regions'], observed['regions'])
        self.assertEqual(result['profile'], hud.GRID_INPUT_PROFILE)
        self.assertEqual(result['layout_sha256'], hud.sha256(self.output.read_bytes()))
        self.assertEqual(result['layout_sha256'], report['output_sha256'])
        self.assertIn('operator-observed', result['validation'])
        self.assertIn('predicted', result['rectangles_validation'])
        self.assertEqual(result['observed_calibration']['source_sha256'], hud.sha256(raw_calibration))
        self.assertEqual(result['observed_calibration']['calibration_screenshot'], observed['calibration_screenshot'])
        self.assertEqual(calibration.read_bytes(), raw_calibration)
        self.assertEqual(self.source.read_bytes(), self.raw)

    def test_observed_regions_reject_invalid_calibration_before_creating_artifacts(self):
        self.raw = json.dumps(grid_fixture()).encode()
        self.source.write_bytes(self.raw)
        calibration = self.directory / 'calibration.json'
        base = {'viewport': {'width': 874, 'height': 402},
                'regions': [{'x': 60, 'y': 215, 'width': 294, 'height': 187}]}
        cases = [[], {**base, 'profile': 'mac-488492.107976'},
                 {**base, 'viewport': {'width': 873, 'height': 402}},
                 {**base, 'viewport': {'width': True, 'height': 402}},
                 {**base, 'regions': []}, {**base, 'regions': base['regions'] * 65},
                 {**base, 'calibration_screenshot': 1}]
        for field, value in [('x', -1), ('y', float('nan')), ('width', 0), ('height', True),
                             ('width', 900), ('y', 300)]:
            cases.append({**base, 'regions': [{**base['regions'][0], field: value}]})
        cases.append({**base, 'regions': [{'rect': base['regions'][0]}]})
        for case in cases:
            calibration.write_text(json.dumps(case))
            with self.subTest(case=case), self.assertRaises(ValueError):
                self.create(name_path=None, geometry=None, action_grid=GRID_OPTIONS,
                            input_manifest=self.generated / 'probe/input.json', input_regions_json=calibration)
            self.assertFalse(self.output.exists())
            self.assertFalse(self.manifest.exists())
        calibration.write_text(json.dumps(base))
        with self.assertRaisesRegex(ValueError, 'require an input manifest'):
            self.create(name_path=None, geometry=None, action_grid=GRID_OPTIONS,
                        input_regions_json=calibration)
        with self.assertRaisesRegex(ValueError, 'only for the full action-grid'):
            self.create(input_regions_json=calibration)


if __name__ == '__main__':
    unittest.main()
