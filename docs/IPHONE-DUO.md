# iPhone and iPhone Duo development build

This branch adds universal iPhone/iPad packaging, live scene sizing and compact
touch controls. It now compiles with Xcode 27.1 for the Simulator and device
SDKs. The original game loads a saved skirmish on the iPhone Duo and ordinary
iPhone 17 Simulators. Physical iPhone 17 Pro Max build 14 also starts a game
with Apple's signed Increased Memory Limit grant. It remains a development
candidate: complete phone HUD use, every Duo pose, other phones and sustained
physical-device memory and temperature still require acceptance. See
[the fork status](../README.md#status-and-known-limits) for current evidence and
[the phone control notes](IPHONE-CONTROLS.md) for RTS references and open work.
Existing AgePad releases and their base IPAs do not contain these changes.

## Controls

The overlay chooses its layout from the space available to the game view. A
short or narrow window uses **COMMANDS** and **BACK**; a roomy window retains the
red-and-gold iPad strip with BACK added. Touch targets remain in view points rather than
shrinking with the game framebuffer.

In a compact window during a match:

- Tap to select; move before the hold completes to box-select.
- Hold a map point for 0.45 seconds to open the command wheel. Slide toward
  **ORDER**, **IDLE**, **TOWN**, **ZOOM +**, **ZOOM −** or **MENU**, then lift.
- A held ORDER targets the original map contact, even if the wheel drawing moves
  to avoid an edge or fold. Selection follows displacement from that contact;
  a stationary edge hold never selects a sector.
- Lift without sliding, or move beyond the wheel's outer cancel zone, to cancel.
  A second finger, resize, backgrounding or touch cancellation also cancels.
- Tap COMMANDS for ordinary accessible command buttons without a timed gesture.
  ORDER in this mode arms the next map tap; **CANCEL ORDER** disarms it.
- BACK cancels pending input, disarms ORDER and uses the existing guarded Escape
  action for a possible selection or a menu opened by the adapter. It does not
  reliably detect every original modal or building-placement state.
- Two-finger orders, pinch zoom, map dragging, Pencil and hardware input keep
  their existing routes. Game mouse presses are not sent while choosing a wheel
  command.

The game's match/HUD detection is an existing heuristic. Validate modal dialogs,
custom HUD scale, minimap interactions and menus on a real build before relying
on the hold gesture. The original game's own HUD is not rewritten by this branch.

Ordinary iPhones declare both landscape orientations; iPad keeps all four.
Fixed-size windowed launcher content fits uniformly inside the scene's safe
area through a presentation ancestor. The original logical coordinates remain
intact for input, and gameplay controls are hidden while the launcher is fitted.
Fullscreen gameplay retains scene-sized geometry and full-size touch controls.
The phone's original build/research panel and minimap are still small; this is
not yet a complete phone interface or a physical-device support claim.

## What changed for Duo

Fresh apps declare both iPhone and iPad device families and a single UIKit scene.
The selected scene supplies the window, current logical viewport and display
scale. Open/close, rotation and window resizing update the compatibility display
and notify the original engine of size/backing changes. In-flight input is
cancelled across geometry changes. Pointer events and polled cursor state share
window-local logical coordinates.

Custom controls respect each safe-area edge and query active division and
occlusion regions using SDK 27.1's `reservedRegionsOfKind:options:` API. The
complete wheel or button strip moves into a fitting unobstructed rectangle;
the original map target stays fixed. Region changes cancel in-flight input.
An attached overlay checks for changes every 100 ms and checks again before
committing a wheel action. Small regions fall back to the compact entry, then
a system action sheet when the radial wheel cannot fit. An entry without a
108-by-44-point clear region is hidden. These rules have geometry and actual
gesture-handler coverage; pose-dependent game acceptance is separate.

Display enumeration puts the active scene first. Full-screen frame requests
remain constrained to the actual scene bounds, including requests made by the
engine's own resize callback. This prevents a cached outer-panel mode from
shrinking rendering on the open inner display.

Committed layouts dispatch through the original window subclass's frame setter
and send the AppKit live-resize callback pair. The scene's screen identity also
drives a screen-change callback, independently of size changes. This preserves
Feral's cached frame bookkeeping; actual renderer acceptance across folds is
still required.

Build with **Xcode and iOS SDK 27.1 or later** for Duo's full-display behavior.
The Mach-O adapter now records the selected target SDK instead of hardcoding
26.5; minimum OS support is separate. Older SDKs still build existing iPad
experiments, with a warning that they do not opt into full Duo layout. Release
recipes preserve their built SDK during later injection.

## Build from your own installed game on the Mac

For the compact native-Steam phone app, use the complete
[source-build recipe](BUILD-IPHONE.md). The older setup route below copies the
full data folder over USB and does not enable the compact download profile.

1. Let Steam finish installing the Mac edition of AoE II DE. Select Xcode 27.1
   or newer and check both target SDKs:

   ```sh
   xcrun --sdk iphoneos --show-sdk-version
   xcrun --sdk iphonesimulator --show-sdk-version
   xcrun simctl list devices booted
   ```

2. Follow [the bootstrap guide](DE-BOOTSTRAP-20260919.md) using the existing
   designated AgePad Simulator. Keep only one Simulator booted. A new private
   candidate is necessary because an old base IPA cannot gain new code through
   injection:

   ```sh
   export AGEPAD_SIMULATOR_UDID='<designated AgePad Simulator UDID>'
   python3 scripts/bootstrap-de-simulator.py generated/de-candidate-iphone-duo --skip install --skip manifest
   export AGEPAD_CANDIDATE=generated/de-candidate-iphone-duo
   ```

   Bootstrap surveys the game on the selected Simulator. These skip flags avoid
   replacing the visible game/container. Preserve an unsaved scenario before any
   subsequent install or launch.

3. Explicitly choose the paired physical device, then build, sign, install and
   copy data using the existing setup route:

   ```sh
   xcrun devicectl list devices
   export AGEPAD_UDID='<target iPhone or iPad hardware UDID>'
   scripts/agepad-ipad.sh setup
   ```

   Tooling refuses ambiguous device selection. Existing exact game-version and
   signing/profile checks still apply. The increased-memory entitlement must be
   granted by the profile; declaring iPhone support does not grant memory.

Do not use an upstream 0.1.0 base IPA to test this branch. Its own compiled
controls and device metadata remain those of that release.

## Verification

Portable checks (no game payload or Apple SDK required):

```sh
python3 scripts/check-repo-safety.py
python3 tests/test_agepad_device_config.py
python3 tests/test_prepare_de_load_image.py
python3 tests/test_agepad_kit_diagnostics.py
cc -std=c11 -Wall -Wextra -Werror -pedantic -I port/de tests/de_touch_command_wheel_test.c -lm -o /tmp/agepad-wheel-test
/tmp/agepad-wheel-test
```

On the Mac, run `scripts/run-de-tests.sh`. Its actual-handler gesture probe
compiles for the Simulator and runs on the designated device when booted. A
successful compile with the run skipped is not a passing gesture timeline.

On 15 October 2026, this suite ran on the sole user-approved iPhone Duo
Simulator with SDK 27.1. Touch ordering, finger/Pencil timelines, wheel target
preservation, reserved-region cancellation and full-screen frame enforcement
passed, including actual bridge callback ordering, subclass frame dispatch,
stale-host repair and screen identity changes. The device SDK compiled 27
generated sources and linked 18 boundary
libraries; this does not establish signing or physical execution. Release IPA
round-trip coverage still skips until a device app has been built.

Two launch fixes were necessary on this Mac: the Simulator's non-unified Metal
report required exact-registry-ID native topology evidence, and SDK 27.1's
loader required zero-fill section offsets in two Steam images to be zero.
Neither fix changes vendor instructions. Original file-backed sections remain
verified, and older pinned SDK recipes retain their header representation.

A real skirmish saved and reloaded as `AGEPADDUO20261015`. The open inner display
renders the match. Closing and rotation still stretch the original game image
on the final candidate, despite verified resize and screen callbacks. Reopening
restores the initial aspect ratio and a map tap selects the town center.
The compact wheel opens, its Idle command selects a villager, and pose changes
cancel it. The original renderer's projection/render-target reconfiguration
remains unresolved, so Duo readiness is incomplete.

For visual Duo checks, preserve the existing Simulator session, shut it down
before opening another device, and use Xcode 27.1 Device Hub to inspect open,
closed, partially folded and rotated poses, plus Split View on both sides.
Check all controls against the fold/camera reserved regions, pointer targeting
after every transition, readable HUD, rendering, audio, save/load and relaunch.
Record screenshots alongside classic/HD references as required by AGENTS.md.

On physical devices, measure peak memory and jetsam behavior in representative
matches and a sustained session. Upstream's reported M2 iPad result does not
qualify an iPhone. Lower render scale can reduce render-target allocations but
does not solve the game's full memory requirement.

## Sources and skills

- [Apple: Prepare for iPhone Duo](https://developer.apple.com/iphone-duo/prepare/)
- [Apple: Designing for iPhone Duo](https://developer.apple.com/design/human-interface-guidelines/designing-for-iphone-duo)
- [Apple: Adaptive layouts](https://developer.apple.com/videos/play/tech-talks/111463/)
- [Duo readiness skill](https://github.com/mirzaaghazadeh/iphone-duo-skills/blob/main/skills/iphone-duo-readiness/SKILL.md)
- [Duo games skill](https://github.com/mirzaaghazadeh/iphone-duo-skills/blob/main/skills/iphone-duo-games/SKILL.md)
- [Duo adaptive-layout skill](https://github.com/mirzaaghazadeh/iphone-duo-skills/blob/main/skills/iphone-duo-adaptive-layout/SKILL.md)
- [HD visual reference, Steam screenshot](https://shared.fastly.steamstatic.com/store_item_assets/steam/apps/239550/ss_4dcf8b5301c97af3defc6c8ee91fd5dbd38ec716.1920x1080.jpg) — inspected beside actual Simulator screenshots for serif labels and gold framing.

Xcode's additional App Resizability skill can be exported on the Mac with
`xcrun agent skills export`. Follow its checks and validate the running app;
documentation and static tests do not establish compatibility across poses.
