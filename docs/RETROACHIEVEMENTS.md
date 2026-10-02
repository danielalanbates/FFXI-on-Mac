# RetroAchievements

Copyright (c) 2026 Bates LLC. All rights reserved.

HorizonXI links RetroAchievements (RA) accounts server-side, so only HorizonXI earns RA achievements. The launcher fetches a player's progress and writes it to a file. Vanaguide (in the game, on worlds that allow it) and VanaguideCompanion (outside the game, on HorizonXI and other allowlist worlds) only read that file.

## Nothing in the game goes online

RetroAch, the approved HorizonXI addon, makes synchronous HTTP requests inside Ashita and freezes the client for seconds. Here the launcher does the fetching instead, with `URLSession` async, off the main actor. The game process and the addon never do network I/O.

## Launcher

Settings live under Setup & Diagnostics › RETROACHIEVEMENTS.

- **Username.** Stored in UserDefaults as `ra.username`.
- **Web API key.** Stored in the login Keychain as a generic password with service `org.batesai.horizonxi-on-mac.retroachievements` and account `web-api-key`. UserDefaults holds only the flag `ra.keySaved`.
  - The key is never logged and never written to a file.
  - The key is read only when a fetch runs. An ad-hoc-signed rebuild changes the signature the Keychain ACL trusts, so the first read after a rebuild asks for the login password (see Credentials.swift).
  - `RETROACHIEVEMENTS_API_KEY` in the launcher's own environment is also accepted, for scripted runs. `App.init` takes it into memory and removes it with `unsetenv`, and both game spawn paths strip it again. It never reaches wine, the game or `last-spawn.txt`.
- **Sets.** The built-in table is 28275 Final Fantasy XI, 28303 Hero of Nations, 28317 Rise of the Zilart, 28359 Chains of Promathia and 28547 Hardcore Hero. You can add extra ids in the "extra set ids" field (UserDefaults `ra.extraSetIDs`).
- **Endpoint.** Each set is one request to `API_GetGameInfoAndUserProgress.php?y=&u=&g=`. Requests go one at a time, through an ephemeral URLSession with no URL cache (the URL carries the key).
- **When it refreshes:**
  - Automatic (window open, a 2-minute timer): at most every 10 minutes, counting failed attempts and the snapshot already on disk.
  - Play: always, but not twice within 60 s.
  - The "Refresh achievements" button: always.
- **Failures.** A 401, 429, other HTTP error, being offline, or an undecodable answer fails the whole fetch. The last good snapshot is left byte for byte, and the reason goes to the log pane and the settings section. A set RA does not know (HTTP 404, or `ID` null) is skipped with a note.

## Snapshot file (the shared contract)

Path: `<Ashita install>/config/addons/Vanaguide/retroachievements.json`, for the selected world's install. It is written atomically: a temporary file in the same folder, then a rename.

```json
{
  "source": "RetroAchievements",
  "user": "Name",
  "fetched_at": 1790000000,
  "games": [
    { "game_id": 28275, "title": "Final Fantasy XI", "earned": 1, "total": 2,
      "achievements": {
        "282751": { "earned_at": "2026-09-20T03:04:05Z", "earned_hardcore_at": null,
                    "title": "...", "description": "...", "points": 5, "type": "progression" },
        "282752": { "earned_at": null, "earned_hardcore_at": null,
                    "title": "...", "description": "...", "points": 10 }
      } }
  ]
}
```

- Every achievement in the set is listed, earned or not.
- `earned_at` and `earned_hardcore_at` are always present. Each is either an ISO 8601 UTC date or `null`. RA's `YYYY-MM-DD hh:mm:ss` is UTC.
- `title`, `description`, `points` and `type` are optional extras, so a reader without `data/achievements.lua` can still name what is left. Readers may ignore them.
- `earned` counts achievements with either date set. `total` is the larger of RA's `NumAchievements` and the number of achievements listed.
- A reader must treat a missing or stale file as "no progress data", never as "not earned".

**Registry.** `~/Library/Application Support/HorizonXI-on-Mac/retroachievements-snapshots.json` is a JSON array of the snapshot paths written, newest first, at most ten. It tells the companion where the snapshots are.

## VanaguideCompanion

The Achievements tab shows each set with its earned/total count, a to-do list (description, points, missable flag, guide target) and the earned list with dates.

- **Snapshot.** The companion reads the newest `fetched_at` among the registry paths, a file picked with "Choose progress file…", or `VANAGUIDE_RA_SNAPSHOT`. It re-reads the file every 30 s, from disk only.
- **Staleness.** A snapshot older than 24 h keeps earned achievements shown as earned, and shows the rest as "progress unknown". Sets the snapshot does not cover are also "unknown".
- **Achievement lists.** They come from `Vanaguide/data/achievements.lua` in the first Vanaguide root that has one: `VANAGUIDE_ROOT`, the bundled copy, the Drive checkout, then `~/Downloads/vanaguide/Vanaguide`.
  - The reader is a Lua data-literal parser (`LuaData.swift`) and runs no Lua.
  - A record is any table with a numeric `id` (or a numeric key) and a `title`, and no `achievements` child. A table with an `achievements` child is a set, and its `game_id`/`id` is inherited.
  - The mapping is read from `target`/`targets`/`mapping`/`map`/`guide`, or from `quest`/`mission`/`key_item`/`item`/`zone`/`nm`/`npc` sub-tables on the record. `confidence` is read from the record or its target.
  - "Open in guide" jumps to the first step whose tags reach a target: `Q`/`QA` or `M` `area,id`, `KI` id, `IT` id, or a zone.
- **Isolation.** Nothing is injected into or read from the game.

## Tests

- `FFXI-on-Mac --selftest-retroachievements`. It needs no network, because every request goes to a fake transport.
  - It decodes the verbatim documented example and FFXI-shaped fixtures (string numbers, missing dates, PHP `[]`).
  - It checks the snapshot's contract shape, atomic writing and the registry.
  - It covers failures: a 401 or offline keeps the file, a 500 part-way fails the fetch, and an unknown set is skipped.
  - It checks cache timing, set ids, redaction and adoption of the environment key.
  - It exercises the Keychain wrapper on a per-run service name, which it deletes.
- `VanaguideCompanion --selftest-parser` adds the Lua reader, `achievements.lua` in nested and flat shapes, snapshot reading, staleness and registry choice, the merge rules, and guide links.

Not verified: a live request with a real key, since no key existed on this Mac on 2026-09-26.
