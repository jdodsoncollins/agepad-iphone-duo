# Controls for ordinary iPhones

AgePad needs a playable landscape phone layout as well as Duo support. The
original desktop HUD contains small build, research and minimap targets; adding
large shortcut buttons does not make those targets usable. This work starts
with safe presentation, clear selection and order states, and reachable ways to
cancel. See [the Duo development guide](IPHONE-DUO.md) for the shared bridge and
[the fork status](../README.md#status-and-known-limits) for current runtime evidence.

## Lessons from shipped games

These are observed behaviors from official sources. The last column describes
what AgePad can reasonably adopt through its existing input adapter.

| Reference | Observed behavior | Application to AgePad |
| --- | --- | --- |
| [Company of Heroes mobile controls](https://www.feralinteractive.com/en/faqs/companyofheroes/1.0.2/ios/) | Players choose a traditional command panel or a hold, drag and release command wheel. Returning to the center cancels. Holding the intended target supports targeted abilities. | Keep both the hold wheel and ordinary tappable COMMANDS entry. Moving the wheel away from an edge must preserve the original target. Its contents remain global adapter commands until reliable selection state is available. |
| [Company of Heroes iPhone Button Select Overlay](https://www.feralinteractive.com/en/news/feature-highlight-button-overlay-in-company-of-heroes-for-iphone-and-android/) | Tap Assist enlarges a cluster of small buttons before the player confirms a choice. A separate hold mode enlarges the button beneath the finger. | A future Tap Assist overlay could make the original build and research HUD usable without shrinking custom touch targets. It needs exact visual and input mapping plus explicit confirmation. |
| [ROME Total War touch design](https://www.feralinteractive.com/en/news/building-rome-the-touch-controls-of-rome-total-war-on-ipad/?platform=mac) | Camera gestures use familiar pinch, spread, rotation and pan. Players can draw unit paths. Holds expose information. | Retain pan and pinch zoom with distinct selection and order gestures. Freehand paths need verified waypoint support; a stream of independent orders would change their meaning. |
| [Age of Empires II Xbox controls](https://www.ageofempires.com/learn-to-play/controlling-your-empire-gathering-resources-xbox/) | Quick selection exposes idle villagers, town centers and military units. Commands depend on the selection. The minimap can expand for navigation. | Keep IDLE and TOWN easy to reach. Show whether the next map tap selects or orders. An enlarged minimap is a useful later feature, once its mapping is verified. |
| [Age of Empires II Xbox advanced controls](https://www.ageofempires.com/learn-to-play/match-goals-advanced-controls-xbox/) | Control groups support recall and camera focus. Common commands get shortcuts. Site-based commands can automatically assign suitable units. | Existing hotkeys can support shortcuts and future group controls. Automatic assignment and context-dependent abilities require engine capabilities; the adapter does not currently provide them. |

## Phone interaction decisions

Use available viewport dimensions to select compact controls. The seven-button
roomy layout, including BACK, is 356 points tall and would occupy too much of a
landscape phone's map even where it fits. Keep custom targets at least 44
points, with the game's serif labels and
red-and-gold framing. Do not scale those targets with the game framebuffer.

Tap selects and a deliberate drag box-selects. ORDER visibly arms the next map
tap for the existing move, gather or attack action; cancelling disarms it.
Two-finger map orders remain an alternative. Pan and pinch navigate the map,
and zoom buttons remain accessible through COMMANDS. These routes must not
leave a mouse press held or issue an order while choosing a wheel command.

BACK is the compact companion to COMMANDS. It cancels pending synthetic input
and disarms ORDER, then sends Escape only when the adapter believes something
may be selected or its game-menu flag is set. This guard prevents an extra
Escape from opening the game menu after deselection. BACK deselected a unit in
the phone run; arbitrary dialog closing and building-placement cancellation
remain unverified. The guard can miss engine state that the adapter has not
tracked. A delayed tap must never select or place something after cancellation.

The current implementation work also gives ordinary iPhones landscape
orientation support and uniformly fits fixed-size windowed launcher content
through a presentation ancestor. This keeps the launcher's own coordinate
system intact while fitting the visible scene. It does not establish that the
match renderer rebuilds its projection after a fold or rotation; that remains
the separate limit documented in the Duo guide.

## Contextual HUD prototype

### Runtime result, 17 October 2026

The original command widgets can be enlarged without replacing their game
bindings. On the existing iPhone 18 Pro Simulator (iOS 27.0, 874 by 402 points),
the engine opened the loose HUD files. Enlarging `Button11` from 80 to 320
design units enlarged both its drawing and hit area: a tap outside the old
bounds spent 50 food and started training a villager.

The follow-up private layout enlarges all fifteen action slots, retaining the
original five-column, three-row arrangement. Cells are 240 design units
(approximately 44.7 points), with 44-unit gaps. Original widget identities,
materials, costs, availability, categories and queues remain engine-owned.
The native adapter does not infer a semantic command model. The layout is
generated from the user's own supported `488492.107976` assets; those assets
and the generated layouts stay outside Git.

Live acceptance covered Town Center training, the bottom-right Town Bell,
villager economic and military menus, unavailable construction, house
placement and completion, selection-panel collapse/expand, and queue removal.
Three training taps spent 150 food; removing one queued villager refunded 50
and the game continued. An armed ORDER was disarmed by a build-category tap,
which opened the category with a primary click. Holding an empty HUD slot for
750 ms did not open a map wheel or discard the selection.
An ordinary gather order sent a villager to mine gold. Once resources were
available, the enlarged Loom control spent 50 gold and displayed research
progress. On completion, its action disappeared and a villager showed 40/40 HP,
up from 25/25 before the upgrade.

The engine overrides some parent geometry. Expanding the root viewport alone
left the selection panel behind the grid. Changing the collection's `xopen`
from 2404 to 3392 moved that panel beside the grid. The original `xclosed=1178`
and `xclip=560` still passed collapse/expand and were retained. The observed
panel positions also differed from the initial geometry predictions, so input
regions were calibrated from native Simulator screenshots.

`AGEPAD_HUD_INPUT_REGIONS` opts into touch ownership for that measured layout.
Its manifest must match the exact viewport and the SHA-256 of the staged
`widgetui/commandpanel.json`. HUD contacts commit one tracked primary click on
release; movement, a second contact, cancellation or a changed layout cancels
the sequence. They cannot become map orders, camera gestures or a hold wheel.
The existing selection remains available. A bounded cache covers temporary
window sizes without repeatedly hashing the same layout.

This is an opt-in prototype at **874 by 402 points and the fixed 100% HUD
scale**, not a general layout preset. A rejected input manifest does not
restore the installed JSON; restore the baseline before using another viewport
or HUD scale. The original details text, queue icons, group portraits, minimap
and collapse arrow remain small. Mixed-unit controls, other viewports, both
hands and physical-phone play remain open.
Coordinated layout/input fallback is required before enabling this by default.

Private evidence includes `generated/hud-grid3-economic.png`,
`generated/hud-grid3-town.png`, `generated/hud-grid3-queue-refund.png` and
`generated/hud-grid3-loom-complete.png`, alongside
`generated/research/hud-probe1-result.json`. The first preserves the game's
ornamented framing and original icons, compared with the original runtime HUD
and the [official HD reference](https://shared.fastly.steamstatic.com/store_item_assets/steam/apps/239550/ss_4dcf8b5301c97af3defc6c8ee91fd5dbd38ec716.1920x1080.jpg).
See the handoff for current launch commands and validation logs.

### Overlay and original-layout research, 16 October 2026

A native overlay can use the existing UIKit hosting and mouse/key bridge.
Recreating the game rules is not a prerequisite for drawing larger controls.
However, the current DE adapter exposes no reliable selected-object or available-
command model: its maybe-selected flag and match detection are only heuristics.
A native tray must not invent costs, prerequisites, disabled states or queues.

Read-only inspection of the owned supported Mac build `488492.107976` found a
promising alternative to a full semantic replacement: loose
`widgetui/commandpanel.json`, `resourcepanel.json` and `mappanel.json` files.
Their staged copies match the owned originals. They contain named, typed
widgets, viewport geometry, state materials, command-button definitions, a
queue anchor and the original game’s map widget. Matching widget-system type strings exist
in the executable. At the time of this read-only research, their runtime use
was unproven. The 17 October probes above subsequently confirmed actual file
opens, visual enlargement and working hit areas.

[Feral documents Mac mod support](https://www.feralinteractive.com/en/support/mac/ageofempires2/#faqs/mods_steam),
and [World's Edge documents widget UI, button and hotkey mod features](https://support.ageofempires.com/hc/en-us/articles/15607286588948-Return-of-Rome-Mod-Updates).
Some features require data mods and should not be assumed cosmetic. A
[UI mod author's implementation notes](https://github.com/Ch4nKyy/age2de-ui#how-to-reload-assets)
also report hit-area and queue-click problems on Windows; verify Mac behavior.

The first private probe preserved widget names/types and enlarged one existing
command button, then verified the actual file read, visual geometry and hit
target before expanding the grid. This preserves the engine's original
selection/availability/queue behavior without exporting that model to UIKit.
Never overwrite the owned Steam installation for these probes.

The supplied Siege Up image and its
[developer's iPhone screenshots](https://apps.apple.com/us/app/rts-siege-up/id1496107124)
support a contextual bottom deck with visible costs, categories and cancellation.
Still images do not establish badge semantics or the right-side T icon's role.
[Rusted Warfare's developer changelog](https://corrodinggames.com/rusted_warfare_changelog)
adds useful precedents for selection previews, building blueprints, cancellation
and minimap command feedback. Borrow the hierarchy while retaining AoE styling.

HUD/tooltip scaling should also be checked: the
[official accessibility guide](https://www.ageofempires.com/age-ii-de-accessibility/)
documents HUD scaling up to 125%. `LoaderProbe.m` seeds 125 once in the imported-
device start path, preserving later preferences. The saved ordinary-iPhone
preference inspected in this research reads 100; the Simulator result is not
evidence that the device seeding path applied.

If layout reflow is insufficient, a live Tap Assist panel remains a candidate.
It requires a real Metal region-copy path, not an assumed UIKit screenshot.
[Apple's sample](https://developer.apple.com/documentation/metal/reading-pixel-data-from-a-drawable-texture)
explains copying before presentation and waiting for GPU completion before
consuming pixels. The DE adapter has no production HUD capture implementation.
Confirmed taps must reverse the crop/fit transform and use actual texture and
host dimensions. They also need a tracked synthetic point-click entry point;
the current delayed helper expects a real game touch, while `nativeMouse:` does
not share its cancellation tracking. Closing an assistance tray must not send
BACK/Escape and discard the selection the player wanted to act on.

The 16 October research itself changed no game code, assets, settings or
Simulator state. The subsequent layout prototype is described above. Live
Metal enlargement and a semantic native HUD remain proposals.

The original build and research panels, minimap, tooltips and modal dialogs
still need phone-specific acceptance. Tiny desktop targets must not be counted
as solved because a match loads or the custom wheel works. Tap Assist should
enlarge a chosen HUD region, show what will be activated, allow cancellation,
and commit to the exact original target. A magnifier needs separate checks for
HUD scaling, orientation and letterboxing before it can safely issue clicks.

Left- and right-handed use need testing in both landscape orientations. If
COMMANDS or BACK is difficult to reach with either hand, adjust placement or
provide an edge preference. No handedness preference is claimed by this work.

## Runtime evidence and remaining acceptance

On 15 October 2026, the iPhone 17 Simulator running iOS 27.0 displayed an
874-by-402-point landscape scene. The fixed 930-by-640-point launcher fitted
uniformly, and taps on its lower PLAY button worked. The saved match
`AGEPADDUO20261015` loaded. The compact wheel's IDLE action selected a villager,
ORDER followed by a map tap moved that villager, and BACK deselected it.

Both landscape directions and an attempted portrait rotation retained
landscape game geometry. Custom controls retained 44-point targets and stayed
clear of the notch. This establishes basic presentation and command behavior;
left- and right-handed comfort, the complete gesture sequence and original HUD
tasks still needed acceptance in that run. The 17 October prototype above
supersedes the action-grid limitation at its measured viewport. There is no
physical-iPhone runtime result in that Simulator run. Subsequently a game
started on a physical iPhone 17 Pro Max with the signed memory grant; see
[current status and limits](../README.md#status-and-known-limits).

- [x] Keep only one Simulator booted and preserve the saved validation match
  before changing the visible candidate.
- [x] Launch and load a saved match on an ordinary iPhone in landscape. Verify
  the launcher is uniformly fitted and every visible target maps to its click.
- [x] Check both landscape directions, including asymmetric notch and home
  indicator insets. No custom control may be hidden or clipped.
- [ ] Check left- and right-handed reachability of COMMANDS, BACK and ORDER;
  retain 44-point targets and unobstructed map space.
- [ ] Select one unit, box-select several, issue a move and a gather order, pan,
  pinch, and use the wheel without accidental selection or lingering presses.
- [ ] Check BACK during building placement and modal dialogs, including states
  missed by its selection/menu guard. Deselection passed; cancelling ORDER
  without issuing an order still needs explicit acceptance.
- [ ] Cancel input while rotating, backgrounding, opening a menu and adding a
  second finger. A delayed click must never survive cancellation.
- [ ] Train a unit, construct a building, research a technology and navigate
  using the minimap. Record small or inaccessible original HUD targets as open
  issues until Tap Assist or an equivalent verified route exists.
- [x] Compare actual screenshots with classic or HD references for framing,
  readable labels and game-appropriate custom controls.
- [ ] On a physical iPhone, check a sustained match, peak memory, jetsam,
  thermal behavior, audio, save and reload before describing it as supported.

Development can stay local. [CONTRIBUTING.md](../CONTRIBUTING.md) describes the
test and game-data boundaries; a pull request is not required to iterate or
collect private runtime evidence. Keep game files, saves and private generated
artifacts out of Git.
