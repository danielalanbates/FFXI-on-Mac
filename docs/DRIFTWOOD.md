# DriftwoodXI

Added in beta 73 (2026-10-24), the third world of [`LSB-SERVERS.md`](LSB-SERVERS.md)'s list.

**DriftwoodXI** (<https://xi.driftwoodgaming.com>, Discord `discord.gg/DriftwoodGaming`) is a level-99
world with the limit-break quests removed and many custom systems (an arena of 240 notorious
monsters, merits past the stock caps, politics, a player market). Home page, 2026-10-24: *"Sixteen
character slots, one account, one game window."* 44 online that day (`/api/players`). Accounts:
website signup at `/register`.

LandSandBoat: port 54231 answers LSB's JSON ("Your xiloader is too old. Please update to version
'2.1.x'"). Their loader `bootloader/xiloader.exe` (in their Ashita bundle) is LSB xiloader 2.1.2,
byte-identical to AscensionXI's (sha256 `f716a45d…`).

## What their launcher does (read, not guessed)

Sources: their launcher (Electron, 0.36.15, read from the AppImage's `app.asar`), their Linux page
(`/download/linux`, a by-hand version of the launcher's steps) and their public content repo
<https://github.com/DriftwoodGaming/DriftwoodXI-Content>. Research copies in
`~/Downloads/lsb-survey/specs/driftwood/`.

1. **No game files from them.** "No game files come from us, on any platform." The player brings
   retail FFXI updated by PlayOnline. Their server takes retail build `30260904_1`; `/api/manifest`
   lists all 65,053 files of that client with sizes and SHA-256.
2. **Ashita bundle**: `ashita.json` names a 44 MB zip (`bundles/DriftwoodXI-Ashita-<date>-<sha12>.zip`,
   sha256 published) with Ashita v4, their loader, the sandbox and DAT-overlay POL plugins, winefix
   and their addons. Then a **core** zip (Ashita 4.3.2.1, 14 files each with its own sha256), applied
   whenever one of those files differs: root binaries, `config/ashita/*.ini`, `plugins/*.dll`,
   `polplugins/*.dll`.
3. **Addons**: `content.json` lists 33 packages (`kind: ashita-addon`), each a zip holding one
   `<id>/` folder, with the zip's sha256 and a `treeHash` of the unpacked folder. `dwgmpanel` (staff
   tooling) is not in it, and is refused here should it ever appear.
4. **Profile** `config/boot/driftwood.ini` from Ashita's `example-privateserver.ini` (name DriftwoodXI,
   `file = .\\bootloader\\xiloader.exe`, `command = --server xi.driftwoodgaming.com`,
   `script = driftwood.txt`, `sandbox = 0`), and **script** `scripts/driftwood.txt` loading
   `thirdparty`, `addons`, `screenshot`, `winefix` and the 33 dw* addons.
5. **DAT text overlay** (`driftwood-core`): built on the player's machine from the client's item DATs
   by a parser inside their launcher. Cosmetic: without it job capes show donor names, augment
   strings are blank, DWPolitics titles are missing (their Linux page says so).

**treeHash**, worked out from the launcher and checked against `dwah` (`853d00a9…`, matches):
sha256 over, for every file of the folder sorted by lower-cased relative path,
`<lower-cased path> NUL <size> NUL <sha256 hex> LF`.

Their zips name entries with backslashes (`dwah\dwah.lua`, made on Windows): `bsdtar` turns them into
folders, `ditto` keeps them as literal file names.

## What this launcher does (`DriftwoodSync.swift`)

At **Setup** and (only what changed) **before every Play**:

| theirs | here | why |
| --- | --- | --- |
| the player's own retail client | assembled from other worlds' clients on this Mac: every file of their list taken only when its SHA-256 matches (AscensionXI's client is the same build, all but `patch2.cfg`) | no Square Enix installer under Wine (hours), no download at all |
| `patch2.cfg` | taken from the donor as it is | a PlayOnline patch-history file, never sent to the server; it differs between every client checked |
| their bundle + core | the same, sha256 checked, unpacked with bsdtar into `Ashita/` | |
| addons by treeHash | the same; an entry file with LuaJITGuard's lines in front counts as current | this launcher's own LuaJIT guard would otherwise look like a change at every Play |
| `default.txt` (bigmode, fps, multisend) | not used: `driftwood.txt` is written as their Linux page says | bigmode throws on their Ashita |
| core files | only the paths their `ASHITA_CORE_PATH` allows (`Ashita.dll`, `Ashita-cli.exe`, `config/ashita/*.ini`, `plugins/*.dll`, `polplugins/*.dll`) | |
| the bundle | unpacked at Setup and Repair only; later changes come as core and packages | their launcher does the same (`installAshita` runs only from its install button) |
| the bundle's `pivot.ini` (a developer's `E:\…catseyexi` overlay) | replaced by an empty one | names folders that do not exist |
| VC++ 2022 runtime via winetricks | not run | this Wine's `msvcp140.dll` has `_Throw_Cpp_error` (checked), the missing piece their page names |
| the DAT text overlay | **not ported** | cosmetic; their parser exists only inside their launcher |

Layout: `<folder>/Ashita/` (Ashita, loader, addons, profile) and `<folder>/Game/FINAL FANTASY XI`
+ `Game/PlayOnlineViewer` (the registry is pointed at `Game/` the way it is for every world).
State in `<folder>/.ffxi-on-mac/` (`driftwood.json`, `hashes.json`, the cached client list).

Addons: their published allowlist (`/addons`, 158 names: "On this page means allowed … Not on this
page means not allowed.") is the world's addon policy, so this launcher's own addons are hidden here.
Less two their launcher refuses to load (`BLOCKED_LOAD_REASONS`): **bigmode** ("throws on load
against the Ashita build this server ships") and **chatfix** ("eats the first letter of every line
the server says and misaddresses your tells").
One client at a time (`maxClients 1`).

A package new in their list is switched on once (added after the script's last addon line); one the
player removed stays off.

## Verified (2026-10-24)

- `--selftest-driftwood`: 32 checks against a fake site on 127.0.0.1 with fake donor clients.
- `--driftwood-treehash` on their real `dwah` package: `853d00a9…`, the published value.
- The real install: see BETA-73.

## Not verified

- Logging in (needs Daniel's account from `/register`).
- In game: addons loading, zoning, fps.

## Pathways if it breaks

- **"Your xiloader is too old"**: their bundle's loader moved; a new bundle in `ashita.json` brings it
  (Repair re-unpacks the bundle).
- **A client file not on this Mac**: their server moved to a newer retail build. Their `/api/manifest`
  names it; a donor client on that build is needed (AscensionXI and Vanadreams follow retail), or
  the Square Enix installer route (`installRetail`) and PlayOnline's own update.
- **"Failed to locate profileServerPortAddress2!" / POL-0033**: their page says the PlayOnline build
  does not match the loader's signature; compare `Game/PlayOnlineViewer/viewer/com/polcore.dll` with
  AscensionXI's.
- **Item names wrong (capes, augments)**: the DAT text overlay; porting it means reading
  `driftwood-core` out of their `app.asar`.
