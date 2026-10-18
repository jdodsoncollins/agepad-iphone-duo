"""Synthetic selection evidence; no Steam account, API key, or network access."""
import ast
import contextlib
import copy
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'scripts'))
import steam_library_spike as spike


def response(*games):
    return {'response': {'game_count': len(games), 'games': list(games)}}


def fixture(owned_games, **extra):
    return {'format': 1, 'owned_games': owned_games, **extra}


class LibraryPreflightTests(unittest.TestCase):
    def test_only_de_appid_selected_and_other_library_data_not_returned(self):
        report = spike.inspect_library(response({'appid': 221380, 'name': 'Private other title'},
                                                {'appid': 813780, 'name': 'AoE II DE', 'playtime_forever': 7},
                                                {'appid': 813781, 'name': 'Other depot-like id'}))
        self.assertEqual(report['library']['status'], 'listed')
        self.assertEqual(report['app']['allowlist'], [813780])
        self.assertEqual(report['library']['selected_metadata']['playtime_minutes'], 7)
        self.assertNotIn('Private other title', json.dumps(report))
        self.assertNotIn('813781', json.dumps(report))

    def test_names_do_not_grant_allowlist_membership(self):
        report = spike.inspect_library(response({'appid': 221380, 'name': spike.APP_NAME}))
        self.assertEqual(report['library']['status'], 'not_listed')
        self.assertEqual(report['next_step']['status'], 'blocked')
        self.assertIsNone(report['library']['selected_metadata'])

    def test_private_empty_zero_and_missing_response_data_never_deny_license(self):
        for document in ({'response': {}}, {'response': {'game_count': 0}}, response(),
                         fixture(response(), library_visibility='private'),
                         fixture(response(), library_visibility='visible')):
            with self.subTest(document=document):
                report = spike.inspect_library(document)
                self.assertEqual(report['library']['status'], 'unknown')
                self.assertEqual(report['license']['status'], 'not_verified')
                self.assertNotIn('not_owned', json.dumps(report))

    def test_private_hint_and_nonempty_response_stays_conservative_when_missing(self):
        report = spike.inspect_library(fixture(response({'appid': 42}), library_visibility='private'))
        self.assertEqual(report['library']['status'], 'unknown')

    def test_public_not_listed_is_not_license_denial(self):
        report = spike.inspect_library(fixture(response({'appid': 42}), library_visibility='visible'))
        self.assertEqual(report['library']['status'], 'not_listed')
        self.assertEqual(report['license']['status'], 'not_verified')

    def test_matched_declaration_cannot_authorize_download_stage_or_execution(self):
        report = spike.inspect_library(fixture(response({'appid': 813780}), local_build=copy.deepcopy(spike.SUPPORTED)))
        self.assertEqual(report['compatibility']['status'], 'declared_profile_matches')
        self.assertEqual(report['next_step']['status'], 'eligible_for_owned_file_verification')
        self.assertEqual(report['account_identity'], 'not_verified')
        self.assertEqual(report['downloadable_depots']['status'], 'unknown')
        for key in ('asset_staging', 'native_executable'):
            self.assertEqual(report[key]['status'], 'blocked')

    def test_unknown_and_incomplete_build_require_real_file_verification(self):
        for build, expected in ((None, 'unknown'), ({'bundle_version': '488492.107976'}, 'incomplete_declaration')):
            document = fixture(response({'appid': 813780}))
            if build is not None:
                document['local_build'] = build
            report = spike.inspect_library(document)
            self.assertEqual(report['compatibility']['status'], expected)
            self.assertEqual(report['asset_staging']['status'], 'blocked')

    def test_unsupported_platform_version_profile_or_hash_blocks_next_step(self):
        for key, value in (('platform', 'windows'), ('bundle_version', 'newer'),
                           ('profile', 'mac-unverified'), ('executable_sha256', '0' * 64),
                           ('steam_api_sha256', '0' * 64)):
            report = spike.inspect_library(fixture(response({'appid': 813780}), local_build={key: value}))
            self.assertEqual(report['compatibility']['status'], 'unsupported_declared_build')
            self.assertEqual(report['next_step']['status'], 'blocked')

    def test_duplicate_target_and_non_target_ids_rejected(self):
        for appid in (813780, 42):
            with self.assertRaisesRegex(ValueError, 'Duplicate appid'):
                spike.inspect_library(response({'appid': appid}, {'appid': appid}))

    def test_malformed_shapes_counts_types_and_boolean_ids_rejected(self):
        documents = [[], {}, {'response': []}, {'response': {'games': None}},
                     {'response': {'game_count': True}}, {'response': {'game_count': 1}},
                     response({'appid': True}), response({'appid': '813780'}),
                     response({'appid': 0}), response({'appid': -1}), response({'appid': 1 << 32}),
                     response({}), response({'appid': 813780, 'name': 9}),
                     response({'appid': 813780, 'playtime_forever': -1}),
                     fixture(response(), library_visibility='maybe'),
                     fixture(response(), local_build={'executable_sha256': 'bad'}),
                     fixture(response(), local_build={'unknown': 'value'})]
        for document in documents:
            with self.subTest(document=document), self.assertRaises(ValueError):
                spike.inspect_library(document)

    def test_json_duplicates_non_finite_invalid_encoding_and_size_rejected(self):
        for data in (b'{"response":{},"response":{}}', b'{"response":{"game_count":NaN}}',
                     b'\xff', b'x' * (spike.MAX_INPUT_BYTES + 1)):
            with self.assertRaises(ValueError):
                spike.load_json(data)

    def test_credentials_or_identity_are_not_an_accepted_envelope(self):
        for key in ('steamid', 'token', 'access_token', 'key', 'password'):
            document = response()
            document[key] = 'DO_NOT_ECHO'
            with self.assertRaises(ValueError) as caught:
                spike.inspect_library(document)
            self.assertNotIn('DO_NOT_ECHO', str(caught.exception))

    def test_cli_writes_only_sanitized_report_and_does_not_modify_input(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'fixture.json'
            original = json.dumps(response({'appid': 813780})).encode()
            path.write_bytes(original)
            stdout = io.StringIO()
            with contextlib.redirect_stdout(stdout):
                self.assertEqual(spike.main([str(path)]), 0)
            self.assertEqual(json.loads(stdout.getvalue())['library']['status'], 'listed')
            self.assertEqual(path.read_bytes(), original)
            self.assertEqual(list(Path(directory).iterdir()), [path])

    def test_compatibility_pins_match_existing_preparation_source_without_importing_it(self):
        tree = ast.parse((ROOT / 'scripts/prepare-de-game.py').read_text())
        supported = next(ast.literal_eval(node.value) for node in tree.body
                         if isinstance(node, ast.Assign) and any(isinstance(target, ast.Name) and target.id == 'SUPPORTED'
                                                                for target in node.targets))
        for key in ('bundle_version', 'executable_sha256', 'steam_api_sha256'):
            self.assertEqual(spike.SUPPORTED[key], supported[key])


if __name__ == '__main__':
    unittest.main()
