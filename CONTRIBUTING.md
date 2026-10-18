# Contributing to AgePad

Thanks for helping make Age of Empires II better on iPad and iPhone.

## Working locally before a pull request

A pull request is not required to experiment. Keep changes on a local branch,
build from your own supported Steam installation, and record what works and
what remains unverified. For this branch, start with
[the phone source-build guide](docs/BUILD-IPHONE.md),
[the iPhone/Duo notes](docs/IPHONE-DUO.md) and
[the control design notes](docs/IPHONE-CONTROLS.md).

Before proposing a contribution, separate source changes from private generated
artifacts, run the checks below, and collect reproducible screenshots and steps.
Preparing that evidence does not require pushing a branch or opening a PR.

## Before opening an issue

- Search this fork's existing issues and the [known limits](README.md#status-and-known-limits) first.
- Include the AgePad version or commit, iPhone/iPad model and memory, OS version, how
  the app is signed (paid or free Apple account), and exact steps.
- For crashes and freezes, run `scripts/agepad-ipad.sh logs` and paste the relevant
  lines. Read them first and remove your Steam account name or ID.
- Never attach or link to game files, saves, `AgePad-mine.ipa`, Steam files or
  sign-in details.

## Making a change

1. Run `python3 scripts/check-repo-safety.py`.
2. Make the change in `port/`, `scripts/` or `docs/`. Everything under
   `generated/` is built from your own game and Steam install and stays private.
3. Run `scripts/run-de-tests.sh`. With the selected Simulator booted it also runs
   the touch and Pencil tests; with the game and a build on your Mac it runs the
   release round trip.
4. Test on the intended physical device when a change touches input, rendering,
   Steam or memory. The existing iPad route is:
   `scripts/agepad-ipad.sh build` installs in place and keeps game files and saves.
   Report Simulator evidence separately; a simulated iPhone does not establish
   a physical iPhone's memory budget or touch ergonomics. Never keep more than
   one Simulator booted at once. Select the approved device explicitly with
   `AGEPAD_SIMULATOR_UDID` before running the tests.
5. Update the docs when behaviour or a known limit changes.

Pull requests should stay focused and say what a player will notice, what was
tested, and on which iPhone/iPad or Simulator. Include known limitations, such
as unsupported poses or an original HUD that still needs touch adaptation.

## Game-data boundary

The game program, game data, Steam client libraries, saves, signing material and
any `.ipa` other than the audited base app must never enter Git history.
`scripts/check-repo-safety.py` and `scripts/audit-agepad-base.py` enforce this.

For the compact phone data pack and the in-app Files importer, see
[game-data installation](docs/GAME-DATA.md). Game assets stay outside the signed
app bundle; private manifests and exports belong under `generated/`.

For private HUD layout experiments, `scripts/de_hud_layout.py --help` documents
the source-hash and game-version guards. It writes fresh files only under
`generated/`; it does not install them. Keep the original widget identities and
record actual rendering and hit targets before treating a layout as usable.
Input-region predictions require Simulator calibration. The current measured
phone profile and its viewport/scale limits are in [the control notes](docs/IPHONE-CONTROLS.md).

## Licensing

AgePad's own code is [MIT](LICENSE). Third-party code keeps its own licence
([THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)). By contributing you agree your
change is released under the same terms.
