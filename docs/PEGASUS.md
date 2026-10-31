# PegasusXI

Added in beta 74 (2026-10-24), the fourth world of [`LSB-SERVERS.md`](LSB-SERVERS.md)'s list.

**PegasusXI** (<https://pegasusxi.com>, Discord `discord.gg/M3NFvpm75E`) is a retail-like level-99
world, "playable through Chains of Promathia; later expansions are still in development". Accounts:
website signup (`/new_accounts/index.html`, 18+, password 8–32 characters: "The game client
(xiloader) cannot use longer passwords"). Characters are made in game. Population:
`pegasusxi.com/api/status` `playerCount` (it said 0 while their Discord showed 16 online; whether the
counter works is unknown).

LandSandBoat: port 54231 answers LSB's JSON ("Your xiloader is too old … '2.1.x'"), and their client
ships stock LandSandBoat xiloader 2.1.1.0 (`Game/bootloader/xiloader.exe`, built by LSB's own CI).

## What their launcher does (read, not guessed)

Their launcher is Electron 1.1.8 (`app.asar` read as data; `lib/pegasusxi-zip-pack-sync.js`,
`main.js`). Research copies: `~/Downloads/lsb-survey/specs/pegasusxi/`.

1. **Index**: `https://cdn.pegasusxi.com/launcher/pegasusxi-pack.json` →
   `{"version":"1.2.4","zipUrl":"https://cdn.pegasusxi.com/launcher/PegasusXI_1.2.4.zip"}` (their
   site's copy at pegasusxi.com/launcher/ is stale: only the CDN is used).
2. **The pack**: one ZIP64, 13.9 GB, 107,720 entries (105,427 files, 27.9 GB unpacked), one
   `PegasusXI_<version>/` folder: `Game/` (Ashita 4.3.0.2, the loader, `config/boot/PegasusXI.ini`,
   `scripts/default.txt`, XIPivot with seven DAT overlays (12.3 GB, AshenbubsHD-Basic 10.8 of it),
   88 approved addons, plugins, the retail client in `Game/SquareEnix/`), plus Windows prereqs.
   No hashes published; each member's CRC-32 is in the zip directory.
3. **Install/update**: download the whole zip, unpack every member over the install with the
   wrapper dropped (only `LauncherLogs/` and the state file protected; nothing ever deleted), write
   `pegasusxi-pack-state.json` `{appliedVersion, zipUrl, updatedAt}`. In 1.1.8 this throws before it
   starts (`const pegasusXiDir` reassigned), so their players re-download zips by hand.
4. **Play**: copy `PegasusXI.ini` to `__runtime_pega.ini`, add `--user/--pass`, boot it with
   `Ashita-cli.exe`, cwd `Game`.

## What this launcher does (`PegasusSync.swift`)

| theirs | here | why |
| --- | --- | --- |
| the whole zip, every time | the zip's directory by two Range requests (end record, then 15.6 MB), then only the members missing or changed since the release last applied, by Range, raw-inflated, CRC-32 and size checked; three ranges at a time, three tries each | 1.2.3 → 1.2.4 was 20 MB this way; no 14 GB zip kept on disk |
| prereqs, their launcher exe, its shortcut, `LauncherLogs/`, `pegasus-config.json` (developer E:\ paths), `__runtime_pega.ini` | not installed | Windows-only, or theirs; GameRegistry already does the registry and COM part of their prereq tool |
| every file overwritten by each update | the player's files (`Game/config/` except `config/ashita/`, `Game/scripts/`, the game's `USER/`, PlayOnline's `usr/`) written when missing or when a release changes them, never by Repair | Repair must not reset settings, macros or the account line |
| nothing ever deleted | a file the new release no longer has is removed, if it is still the file this launcher wrote and not the player's | a removed DAT left in an overlay folder keeps overriding the game |
| `__runtime_pega.ini` | `PegasusXI.ini` itself (the account line written at Play, as for every world) | the same settings; their template is in every release |
| — | an addon entry file with LuaJITGuard's lines in front counts as intact | this launcher's guard is not damage |

Layout: `<folder>/Game/` (Ashita, `SquareEnix/`), `<folder>/README.txt`, their
`pegasusxi-pack-state.json`; this launcher's own state in `<folder>/.ffxi-on-mac/`
(`pegasus.json`, `pegasus-listing.json` = path → CRC-32/size of the release applied, `crc32.json`).

XIPivot is booted with `pivot = pegasus` ([ashita.polplugins.args]); its strings ("Using config file:
'%s'", "pivot", ".ini") say the argument names the config file, so `config/pivot/pegasus.ini` is the
overlay list in use: chocobo-saddle-eyes, PegasusXI-Enhancements, xiview, horizonmusic, remapster,
AshenbubsHD-Basic. Left as they ship it, HD pack included.

Addons: their approved list (`addons.js` `ASHITA_APPROVED`, 88 names): "Unlisted addons should be
considered prohibited, and using them is punishable." This launcher's own addons are hidden here.
One client at a time: the live site's rules say nothing on boxing, but the operator's own repo
(aremais/PegasusXI `public/rules.html`, read 2026-10-25) calls PegasusXI a "single box" server with
one account per adventurer (docs/MULTI_WORLD.md, "Clients per world").

## Verified (2026-10-24)

- `--selftest-pegasus`: 26 checks against a fake CDN on 127.0.0.1 with zips made by Info-ZIP (one
  forced to ZIP64).
- The real install: see BETA-74.

## Not verified

- Logging in (needs Daniel's account).
- In game: the HD pack's cost on an 8 GB Mac, zoning, addons.
- Whether their server refuses a newer retail client (no `VER_LOCK` published). This launcher only
  installs their own files, so it does not matter unless a donor were used (none is).

## Pathways if it breaks

- **A new release**: nothing to do; the index names it and the next Play fetches the difference.
- **"does not answer Range requests"**: their CDN changed; fall back to the whole zip
  (`Runner.installClientZip`, 42 GB peak: zip + unpacked).
- **Text overlays wrong / HD too heavy**: edit `Game/config/pivot/pegasus.ini` (the player's file:
  updates leave it alone unless their release changes it).
