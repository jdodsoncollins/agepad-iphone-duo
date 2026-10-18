# Game-data installation on iPhone

The signed app contains the compatible runtime and a version-pinned asset
manifest. Game assets are installed separately in
`Documents/AgeOfEmpires2Data`. Steam sign-in verifies access to the owned game.
After lookup, the native library shows the official game thumbnail and an
explicit **Download** action (or **Play** for a verified existing installation).
Ownership verification and Files import never automatically launch the game.
**Import game files from Files** remains available as an alternative.

## Download from Steam

The native downloader authenticates a separate Steam content connection using
the saved Keychain sign-in, asks Steam for each pinned depot's decryption key,
manifest request code and CDN authorization, and selects only the signed
compact profile's asset paths. It downloads directly from Steam over HTTPS.
It never downloads or installs executable code. Depot denials do not become
invented entitlements; if an old manifest or required DLC is unavailable, the
UI offers a retry or the matching Files import.

Downloads use one persistent background URLSession, including delegate
reconnection on background app launch. The card shows percentage, bytes and
phase, with Pause, Resume and Cancel. Wi-Fi is required for this large pack.
iOS schedules background work; it may delay transfers. Force-quitting the app
stops its background tasks; reopening restores the journal and reschedules
unfinished chunks. Authentication/manifest preparation and final whole-file
verification require AgePad in the foreground. Queued HTTPS transfers can run
while AgePad is suspended. No unrelated background mode is declared.

Each chunk is decrypted, decompressed and checked against its size, Adler32
and SHA-1. The assembled files then pass the bundled SHA-256 inventory before
installation. Completion records append four bytes after the data is synced;
the multi-megabyte plan is not rewritten for every chunk. Interrupted chunks
can be fetched again without discarding verified progress. Data stages under
`Library/Application Support/AgePadDownloads/813780`, excluded from iCloud
backup. Depot keys use a separate device-only Keychain item, accessible after
the first unlock for background completion. Account tokens stay in their
existing Keychain item and are absent from download URLs/journals/logs.

Successful installation renames the verified download into place, avoiding a
second complete asset copy. Cancel/finish removes only the download staging,
journal and depot keys; an existing game installation, saves and Steam sign-in
are preserved. A whole-file hash failure invalidates only that file's completed
chunks so Resume can repair it.

## Compact pack

For the currently pinned Steam build **25464371**, the full Mac data folder is
25,713 files / 22,812,460,118 bytes. The English core profile retains 17,199
files / **14,604,683,208 bytes**, saving **8,207,776,910 bytes** (36%).
It excludes the additional game mode, bonus soundtrack/manuals, other text
languages, campaign presentation images and videos. Core game sprites and
textures retain their original bytes. Most large art files are already
compressed; blanket recompression cannot be assumed to work with the engine.

This is a core-match candidate. Campaigns and extra modes are not qualified
with the compact profile. A complete play session must be validated before
claiming the profile supports gameplay without missing resources.

Create a private folder for Files transfer without changing the Steam install:

```sh
python3 scripts/phone_asset_profile.py \
  "$HOME/Library/Application Support/Steam/steamapps/common/AoE2DE/AgeOfEmpires2Data" \
  --build-id 25464371 \
  --output generated/phone-assets-private/GameDataProfile.json \
  --export generated/phone-assets-private/AgeOfEmpires2Data
```

Use fresh output paths. Exports use independent APFS clones where available,
otherwise ordinary copies. Transfer the exported folder to Files/iCloud Drive,
then choose it with the in-app import button. A complete matching source folder
also works: the importer copies only the signed profile's required files.
Archives must first be extracted in Files. Allow at least the compact pack's
size in free space for a new import; replacing an install keeps the previous
copy until the new copy is verified.

## Verification and cleanup

The importer streams SHA-256 checks against the bundled manifest. Missing,
changed or incomplete files fail before replacing the old install. Existing
full installs migrate in place, avoiding a second 14.6 GB copy. Only known
excluded asset paths of the expected size are removed, after every retained
asset has passed verification.

Successful installation clears AgePad's temporary files and caches, obsolete
transfer markers, and owned interrupted-import staging/backup folders. An
active diagnostic capture is retained. Saves, unknown user files, Keychain
sign-in and Steam's license/offline state are preserved. Unknown files in a
replaced data tree move to `Documents/PreservedGameData/`. Files/iCloud source
folders and their provider-managed caches remain under the user's control.

`Library/Application Support/AgePad/InstallReceipt.json` records the verified
profile, retained size, removed asset bytes and cleared cache bytes. Later
launches check that receipt and required file sizes; they do not hash 14.6 GB
on every launch. A fresh import always performs full content verification.

Run `tests/test_phone_asset_profile.py` and `tests/test_game_asset_store.py` for
synthetic content-boundary, integrity, replacement, recovery and cleanup checks.
