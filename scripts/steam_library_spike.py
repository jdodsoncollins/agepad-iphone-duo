#!/usr/bin/env python3
"""Offline AoE II library-selection spike; no login, network, download or staging.

Accept a sanitized GetOwnedGames JSON response, e.g.
  {"response":{"game_count":1,"games":[{"appid":813780,"name":"AoE II DE"}]}}
or a sanitized fixture envelope:
  {"format":1,"owned_games":{"response":{}},"library_visibility":"private",
   "local_build":{"platform":"macos","bundle_version":"488492.107976"}}

Fixture visibility/build declarations are unverified hints, never credentials or
license proof. Only app 813780 is selected. GetOwnedGames can be incomplete or
unavailable because of privacy; omission is never reported as "not owned".
Native executable bytes still require the existing host-side personal injection
and signing route. This tool cannot make a downloadable native executable run.

Sources: https://partner.steamgames.com/doc/webapi/IPlayerService#GetOwnedGames
         https://partner.steamgames.com/doc/store/application/depots
Local compatibility pins: scripts/prepare-de-game.py SUPPORTED.
"""
import argparse
import json
from pathlib import Path
import re
import sys

APP_ID = 813780
APP_NAME = 'Age of Empires II: Definitive Edition'
MAX_INPUT_BYTES = 1 << 20
MAX_GAMES = 20000
SUPPORTED = {
    'platform': 'macos',
    'bundle_version': '488492.107976',
    'profile': 'mac-488492.107976',
    'executable_sha256': 'b40e57e9d77877a59c76f73b515635dfc2d9d39db7d1026d185b06da9f6dfa2b',
    'steam_api_sha256': '7d4991c162d283fef829c287217767326649f02fdcb57e4366e441255ea87d91',
}


def _object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError('Duplicate JSON key')
        result[key] = value
    return result


def _invalid_constant(_):
    raise ValueError('Non-finite JSON number')


def load_json(data):
    if len(data) > MAX_INPUT_BYTES:
        raise ValueError('Input exceeds 1 MiB')
    try:
        return json.loads(data, object_pairs_hook=_object, parse_constant=_invalid_constant)
    except (UnicodeError, json.JSONDecodeError, RecursionError) as error:
        raise ValueError('Invalid JSON document') from error


def _uint(value, label, minimum=0):
    if type(value) is not int or not minimum <= value <= 0xffffffff:
        raise ValueError(label + ' must be a uint32')
    return value


def _build_status(build):
    if build is None:
        return 'unknown'
    if not isinstance(build, dict) or set(build) - set(SUPPORTED):
        raise ValueError('local_build contains unsupported fields')
    for key, value in build.items():
        if not isinstance(value, str) or len(value) > 128:
            raise ValueError('Invalid local_build field')
        if key.endswith('_sha256') and not re.fullmatch('[0-9a-f]{64}', value):
            raise ValueError('Invalid local_build SHA-256')
    if any(value != SUPPORTED[key] for key, value in build.items()):
        return 'unsupported_declared_build'
    return 'declared_profile_matches' if set(build) == set(SUPPORTED) else 'incomplete_declaration'


def inspect_library(document):
    """Return selection evidence, never an authentication/authorization decision."""
    if not isinstance(document, dict):
        raise ValueError('Expected a JSON object')
    visibility, build = 'unknown', None
    if 'format' in document:
        if type(document['format']) is not int or document['format'] != 1:
            raise ValueError('Unsupported fixture format')
        if set(document) - {'format', 'owned_games', 'library_visibility', 'local_build'}:
            raise ValueError('Unexpected fixture fields; provide sanitized data only')
        visibility = document.get('library_visibility', 'unknown')
        if visibility not in ('visible', 'private', 'unknown'):
            raise ValueError('Invalid library_visibility')
        build = document.get('local_build')
        document = document.get('owned_games')
    if not isinstance(document, dict) or set(document) != {'response'}:
        raise ValueError('Expected a sanitized GetOwnedGames response envelope')
    response = document['response']
    if not isinstance(response, dict) or set(response) - {'game_count', 'games'}:
        raise ValueError('Unexpected GetOwnedGames response fields')
    count = _uint(response['game_count'], 'game_count') if 'game_count' in response else None
    games = response.get('games', [])
    if not isinstance(games, list) or len(games) > MAX_GAMES:
        raise ValueError('Invalid games list')
    if count is not None and count != len(games):
        raise ValueError('game_count must match the returned games list')
    seen, selected = set(), None
    for game in games:
        if not isinstance(game, dict) or 'appid' not in game:
            raise ValueError('Each game must contain an appid')
        appid = _uint(game['appid'], 'appid', minimum=1)
        if appid in seen:
            raise ValueError('Duplicate appid in library response')
        seen.add(appid)
        if appid == APP_ID:
            selected = {'appid': APP_ID}
            if 'name' in game:
                if not isinstance(game['name'], str) or len(game['name']) > 256:
                    raise ValueError('Invalid selected game name')
                selected['reported_name'] = game['name']
            if 'playtime_forever' in game:
                selected['playtime_minutes'] = _uint(game['playtime_forever'], 'playtime_forever')
    # An empty response / zero-count library is ambiguous, even if a fixture
    # asserts visibility. Absence from a nonempty result is only "not listed".
    library_status = 'listed' if selected else 'not_listed' if games and visibility != 'private' else 'unknown'
    build_status = _build_status(build)
    eligible = library_status == 'listed' and build_status != 'unsupported_declared_build'
    return {
        'format': 1,
        'mode': 'offline_selection_preflight',
        'app': {'appid': APP_ID, 'name': APP_NAME, 'allowlist': [APP_ID]},
        'account_identity': 'not_verified',
        'library': {'status': library_status, 'visibility_hint': visibility,
                    'evidence': 'unverified_sanitized_GetOwnedGames_response',
                    'selected_metadata': selected},
        'license': {'status': 'not_verified',
                    'reason': 'A library response is not a current authenticated Steam client license answer.'},
        'compatibility': {'status': build_status, 'required': dict(SUPPORTED),
                          'verification': 'declarations_only_no_files_hashed'},
        'next_step': {'status': 'eligible_for_owned_file_verification' if eligible else 'blocked',
                      'action': 'Use existing host-side prepare-de-game.py / agepad-kit.py verification.' if eligible else None},
        'downloadable_depots': {'status': 'unknown',
                                'reason': 'No authenticated depot access, branch/manifest IDs, or entitlement checks were performed.'},
        'asset_staging': {'status': 'blocked',
                          'reason': 'Requires authorized matching depots, verified content and explicit asset/code separation.'},
        'native_executable': {'status': 'blocked',
                              'reason': 'The native route requires host-side personal injection and signing; a library listing cannot authorize or enable loading downloaded unsigned native code.'},
    }


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('fixture', type=Path, help='Sanitized offline JSON, never credentials')
    args = parser.parse_args(argv)
    try:
        with args.fixture.open('rb') as stream:
            data = stream.read(MAX_INPUT_BYTES + 1)
        report = inspect_library(load_json(data))
    except (OSError, ValueError) as error:
        # Do not echo input, paths, API error payloads or account identifiers.
        message = str(error) if isinstance(error, ValueError) else 'Cannot read fixture'
        print(json.dumps({'error': message}), file=sys.stderr)
        return 2
    print(json.dumps(report, indent=2, allow_nan=False))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
