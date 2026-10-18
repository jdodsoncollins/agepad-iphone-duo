# Build the phone fork from source

This is a developer workflow, not an installable release. It builds a personal
app from your own supported Mac Steam game and Steam client. All generated
outputs remain private. Use fresh output directories to preserve prior builds.

## Prerequisites

- Apple Silicon Mac, Python 3 and Xcode with both iOS SDKs. The current Duo
  implementation is built with Xcode/iOS SDK 27.1; older SDKs do not establish
  full Duo compatibility.
- AoE II: DE installed and fully updated to a supported Mac build in Steam.
  The demonstrated compact profile uses Steam build **25464371**. Game and
  Steam adapters check their actual inputs; an arbitrary newer build is not
  automatically supported.
- One selected Simulator for bootstrap surveys, and a paired, trusted physical
  iPhone/iPad with Developer Mode enabled for installation.
- Your own App ID, signing identity and development profile for that device.
  The demonstrated physical phone route needs a profile that actually grants
  `com.apple.developer.kernel.increased-memory-limit`. The packager refuses to
  substitute a handwritten entitlement for a missing Apple grant.

## Bootstrap the compatible runtime

Check `xcrun simctl list devices booted` before Simulator work. Reuse your
designated device and keep only one booted. Bootstrap runs a survey probe on
that device even when the final candidate install is skipped.

```sh
export AGEPAD_SIMULATOR_UDID='<your designated Simulator UDID>'
export AGEPAD_GAME="$HOME/Library/Application Support/Steam/steamapps/common/AoE2DE"
export AGEPAD_CANDIDATE=generated/phone-candidate

python3 scripts/bootstrap-de-simulator.py "$AGEPAD_CANDIDATE" \
  --game "$AGEPAD_GAME" --public-api --skip install --skip manifest
```

The output contains your game/client files, generated compatibility sources
and verification reports. It must stay under ignored `generated/`. See the
[bootstrap explanation](DE-BOOTSTRAP-20260919.md) for individual stages.
`--public-api` removes the development desktop web host; it is not an App Store
certification for the vendor binaries.

## Prepare data and device boundaries

The asset manifest must match the installed Steam app manifest. Replace the
build number below only when the source build is supported and verified. Read
the `buildid` in your own `steamapps/appmanifest_813780.acf`; do not publish that
file, which can also contain personal account fields.

```sh
python3 scripts/phone_asset_profile.py "$AGEPAD_GAME/AgeOfEmpires2Data" \
  --build-id 25464371 --output generated/phone-assets/GameDataProfile.json

python3 scripts/build-de-device-runtime.py generated/phone-device-runtime \
  --package "$AGEPAD_CANDIDATE/package" --public-api

python3 scripts/build-de-device-ipc-probe.py \
  --source "$AGEPAD_CANDIDATE/package/ipc-helper-relay/ipcserver.arm64" \
  --output generated/phone-device-ipc
```

Create normal-use launch settings from the checked-in configuration. This
selects the native Steam route and removes temporary startup diagnostics:

```sh
python3 - <<'PY'
import json
from pathlib import Path
settings = json.loads(Path('scripts/ipad-launch-env.json').read_text())['play']
omit = {
    'AGEPAD_STEAM_TUNNEL_HOST', 'AGEPAD_HOST_PATH_RELAY_TCP_HOST',
    'AGEPAD_STEAM_TUNNEL_PORT', 'AGEPAD_HOST_PATH_RELAY_TCP_PORT',
    'AGEPAD_STEAM_LOOPBACK_PORT', 'AGEPAD_DEVICE_LOG_FILE',
    'AGEPAD_DEVICE_MAIN_WATCHDOG', 'AGEPAD_DEVICE_STARTUP_MEMORY',
    'AGEPAD_DEVICE_FRAME_RATE', 'AGEPAD_GAME_GPU_BUDGET_MB',
}
Path('generated/phone-launch.env').write_text(
    ''.join(f'{key}={value}\n' for key, value in settings.items() if key not in omit))
PY
```

## Package, sign and install

Replace the signing placeholders with your own values. Keep the same bundle
identifier and signing/keychain identity when updating an existing install.

```sh
python3 scripts/prepare-de-device-probe.py \
  --candidate-root "$AGEPAD_CANDIDATE" \
  --boundary generated/phone-device-runtime \
  --ipc-load-probe generated/phone-device-ipc \
  --original-steam-module "$AGEPAD_GAME/Age Of Empires II.app/Contents/Frameworks/libsteam_api.dylib" \
  --steam-app-manifest "$HOME/Library/Application Support/Steam/steamapps/appmanifest_813780.acf" \
  --asset-profile generated/phone-assets/GameDataProfile.json \
  --launch-env generated/phone-launch.env --framework-layout \
  --profile '<your development.mobileprovision>' \
  --identity '<your Apple Development identity>' --increased-memory-limit \
  --bundle-id '<your.bundle.identifier>' --version 0.2.0 --build-number 1 \
  --output generated/phone-signed/AgePad.app

codesign --verify --deep --strict generated/phone-signed/AgePad.app
xcrun devicectl list devices
xcrun devicectl device install app --device '<your physical device UDID>' \
  generated/phone-signed/AgePad.app
```

Optional: add `--game-artwork generated/private-artwork/header.jpg` when
packaging your personal app. No game artwork is shipped in the source tree;
without it the game card uses a system controller icon. Personal artwork does
not become covered by AgePad's MIT license.

Installing in place restarts the app and an unsaved scenario. Do not uninstall
to update: uninstalling removes the game-data container. This packaging step
does not copy the multi-gigabyte data folder into the app bundle.

Open AgePad, sign in privately, and let it verify ownership. Use Download for
the matching core assets or import the folder through Files. Follow
[game-data installation](GAME-DATA.md) to export a private Files-transfer pack.
Play remains an explicit action after verification. Background HTTPS transfers
can continue while suspended; preparation and final verification need AgePad
open. No Mac helper is required for this native Steam route.

The older `scripts/agepad-ipad.sh setup` route still copies the full game data
over USB; it is not the compact download/Files recipe above. Upstream base IPAs
also do not contain this fork's new compiled code.

## Verify changes

Run `python3 scripts/check-repo-safety.py` and `scripts/run-de-tests.sh`.
Report skipped Simulator or owned-game checks as skipped. Actual background
recovery, Steam Guard screen lifecycle, sustained memory/temperature and Duo
renderer transitions need physical/runtime evidence in addition to fixtures.
See [current status](../README.md#status-and-known-limits).
