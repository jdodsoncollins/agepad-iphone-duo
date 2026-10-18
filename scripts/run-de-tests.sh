#!/bin/zsh
# Run AgePad's game-side tests: the Mac-runnable ones run; the iPadOS ones are
# compiled for the Simulator (and the touch tests run if the AgePad Simulator
# is booted). Usage: scripts/run-de-tests.sh
set -u
ROOT=${0:A:h:h}; cd $ROOT
T=$(mktemp -d); FAILED=0
KEEP_T=0; trap '(( KEEP_T )) || rm -rf -- "$T"' EXIT # keep build output only when a test failed
pass() { print -P "  %F{green}✓%f $1"; }
fail() { print -P "  %F{red}✗%f $1"; FAILED=1; KEEP_T=1; }
mac() { # name, extra sources/flags
  local name=$1; shift
  if xcrun clang -fobjc-arc -I port/de "$@" -o $T/$name 2>$T/$name.err && $T/$name >$T/$name.out 2>&1; then pass "$name: $(tail -1 $T/$name.out)"
  else fail "$name (see $T/$name.err, $T/$name.out)"; fi
}
mac hardware-key-mapping tests/de_hardware_key_mapping_test.m -framework Foundation -framework GameController
mac resource-case tests/de_resource_case_test.m -framework Foundation
mac sld-frame-trace tests/de_sld_frame_trace_test.m -framework Foundation
mac bc-decode tests/de_bc_decode_test.c port/de/BCDecode.c
mac touch-command-wheel tests/de_touch_command_wheel_test.c
mac host-metal-metadata tests/de_host_metal_metadata_test.m -framework Foundation
SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
for name in pointer_ownership ordered_delivery touch_control_layout window_presentation; do
  xcrun clang -fobjc-arc -target arm64-apple-ios17.0-simulator -isysroot $SDK -I port/de tests/de_${name}_test.m \
    -framework Foundation -framework UIKit -framework QuartzCore -framework CoreGraphics -o $T/$name 2>$T/$name.err \
    && pass "$name: compiles for iPadOS" || fail "$name (see $T/$name.err)"
done
DEVICE=$(python3 -c 'import sys;sys.path.insert(0,"scripts");import de_device;print(de_device.device_udid() if de_device.require_sole_device()[0] else "")')
for name in touch_control_layout window_presentation; do
  if [[ -n "$DEVICE" && -x "$T/$name" ]]; then
    codesign -s - --force "$T/$name" 2>/dev/null
    xcrun simctl spawn "$DEVICE" "$T/$name" >$T/$name.out 2>&1 \
      && pass "$name: $(tail -1 $T/$name.out)" || fail "$name (see $T/$name.out)"
  fi
done
OUT=$(python3 tests/test_de_touch_ordering.py 2>&1) && pass "touch-ordering: $(print -r -- $OUT | tail -1)" || fail "touch-ordering: $(print -r -- $OUT | tail -3)"
OUT=$(python3 tests/test_de_two_finger.py 2>&1) && pass "two-finger: $(print -r -- $OUT | tail -1)" || fail "two-finger: $(print -r -- $OUT | tail -3)"
OUT=$(python3 tests/test_agepad_kit_diagnostics.py 2>&1) && pass "kit diagnostics: $(print -r -- $OUT | tail -1)" || fail "kit diagnostics: $(print -r -- $OUT | tail -3)"
OUT=$(python3 tests/test_agepad_device_config.py 2>&1) && pass "device configuration" || fail "device configuration: $(print -r -- $OUT | tail -3)"
OUT=$(python3 tests/test_de_hud_layout.py 2>&1) && pass "HUD geometry probe: $(print -r -- $OUT | tail -1)" || fail "HUD geometry probe: $(print -r -- $OUT | tail -3)"
OUT=$(python3 tests/test_bundle_image_paths.py 2>&1) && pass "bundle image paths: $(print -r -- $OUT | tail -1)" || fail "bundle image paths: $(print -r -- $OUT | tail -3)"
OUT=$(python3 tests/test_agepad_distribution.py 2>&1) && pass "distribution packaging: $(print -r -- $OUT | tail -1)" || fail "distribution packaging: $(print -r -- $OUT | tail -3)"
OUT=$(python3 tests/test_agepad_app_icons.py 2>&1) && pass "App Store icon catalog: $(print -r -- $OUT | tail -1)" || fail "App Store icon catalog: $(print -r -- $OUT | tail -3)"
OUT=$(python3 tests/test_de_public_launcher.py 2>&1) && pass "public launcher: $(print -r -- $OUT | tail -1)" || fail "public launcher: $(print -r -- $OUT | tail -3)"
OUT=$(python3 tests/test_de_loader_probe.py 2>&1) && pass "standalone loader build: $(print -r -- $OUT | tail -1)" || fail "standalone loader build: $(print -r -- $OUT | tail -3)"
OUT=$(python3 tests/test_steam_module_digest.py 2>&1) && pass "native module section digest: $(print -r -- $OUT | tail -1)" || fail "native module section digest: $(print -r -- $OUT | tail -3)"
OUT=$(python3 tests/test_native_view_lookup.py 2>&1) && pass "native view method inspection" || fail "native view method inspection: $(print -r -- $OUT | tail -3)"
OUT=$(python3 tests/test_steam_auth_protocol.py 2>&1) && pass "Steam auth protocol: $(print -r -- $OUT | tail -1)" || fail "Steam auth protocol: $(print -r -- $OUT | tail -3)"
OUT=$(python3 tests/test_steam_engine_start.py 2>&1) && pass "Steam engine startup: $(print -r -- $OUT | tail -1)" || fail "Steam engine startup: $(print -r -- $OUT | tail -3)"
OUT=$(python3 tests/test_ipc_helper_entry.py 2>&1) && pass "IPC helper entry: $(print -r -- $OUT | tail -1)" || fail "IPC helper entry: $(print -r -- $OUT | tail -3)"
OUT=$(python3 tests/test_agepad_ipc_entry.py 2>&1) && pass "IPC entry packaging: $(print -r -- $OUT | tail -1)" || fail "IPC entry packaging: $(print -r -- $OUT | tail -3)"
OUT=$(python3 tests/test_game_asset_store.py 2>&1) && pass "asset import and cleanup: $(print -r -- $OUT | tail -1)" || fail "asset import and cleanup: $(print -r -- $OUT | tail -3)"
OUT=$(python3 tests/test_game_canvas.py 2>&1) && pass "phone game canvas: $(print -r -- $OUT | tail -1)" || fail "phone game canvas: $(print -r -- $OUT | tail -3)"
OUT=$(python3 tests/test_game_artwork.py 2>&1) && pass "game artwork: $(print -r -- $OUT | tail -1)" || fail "game artwork: $(print -r -- $OUT | tail -3)"
OUT=$(python3 tests/test_steam_content.py 2>&1) && pass "Steam content and download recovery: $(print -r -- $OUT | tail -1)" || fail "Steam content and download recovery: $(print -r -- $OUT | tail -3)"
OUT=$(python3 tests/test_steam_asset_download.py 2>&1) && pass "Steam downloader callbacks and bookkeeping: $(print -r -- $OUT | tail -1)" || fail "Steam downloader callbacks and bookkeeping: $(print -r -- $OUT | tail -3)"
OUT=$(python3 tests/test_phone_asset_profile.py 2>&1) && pass "compact asset profile" || fail "compact asset profile: $(print -r -- $OUT | tail -3)"
OUT=$(python3 tests/test_prepare_de_load_image.py 2>&1) && pass "target SDK and release replay" || fail "target SDK and release replay: $(print -r -- $OUT | tail -3)"
OUT=$(python3 tests/test_agepad_kit_roundtrip.py 2>&1) && pass "release round trip: $(print -r -- $OUT | tail -1)" || fail "release round trip: $(print -r -- $OUT | tail -3)"
OUT=$(python3 tests/test-startup-trace-parser.py 2>&1) && pass "startup-trace-parser" || fail "startup-trace-parser"
(( FAILED )) && { print 'Some tests failed.'; exit 1; }
print 'All game-side tests passed.'
