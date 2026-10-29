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
- **Sets.** All twelve currently populated HorizonXI sets are included; see the dated table below. You can add future legacy game ids in the "extra set ids" field (UserDefaults `ra.extraSetIDs`). Built-ins and extras are requested once each; invalid or duplicate extra ids are dropped.
- **Endpoint.** Each set is one request to `API_GetGameInfoAndUserProgress.php?y=&u=&g=`. Requests go one at a time, through an ephemeral URLSession with no URL cache (the URL carries the key).
- **When it refreshes:**
  - Automatic (window open, a 2-minute timer): at most every 10 minutes, counting failed attempts and the snapshot already on disk.
  - Play: always, but not twice within 60 s.
  - The "Refresh achievements" button: immediate unless an HTTP 429 cooldown is active.
  - After HTTP 429, **all** triggers respect `Retry-After` (seconds or HTTP date), or ten minutes if absent/invalid. The cooldown is held for this launcher session. There is no sleeping retry task or automatic retry loop.
- **Failures.** A 401, 429, other HTTP error, being offline, an undecodable answer or a mismatched game id fails the whole fetch. The last good snapshot is left byte for byte, and the reason goes to the log pane and the settings section. An unknown extra set (HTTP 404, or `ID` null) is skipped with a note. An unknown built-in fails the refresh, preserving the previous full snapshot instead of replacing it with partial coverage.

## Set coverage and primary sources (checked 2026-10-27)

The official [HorizonXI sets hub](https://retroachievements.org/hub/25633) lists 26 sets: twelve populated sets with **537 achievements**, and fourteen empty sets. Counts are a research checkpoint, not a fixed limit; each refresh imports every achievement returned by the API for every configured set.

| Set | Legacy API game id | Achievements at check |
| --- | ---: | ---: |
| [Final Fantasy XI](https://retroachievements.org/game/28275) | 28275 | 109 |
| [Hero of Nations](https://retroachievements.org/game/28303) | 28303 | 28 |
| [Rise of the Zilart](https://retroachievements.org/game/28317) | 28317 | 75 |
| [Chains of Promathia](https://retroachievements.org/game/28359) | 28359 | 94 |
| [Hardcore Hero](https://retroachievements.org/game/28547) | 28547 | 8 |
| [Treasures of Aht Urhgan](https://retroachievements.org/game/41186) | 41186 | 41 |
| [Paragon of Black Mage Excellence](https://retroachievements.org/game/28409) | 28409 | 33 |
| [Paragon of Monk Excellence](https://retroachievements.org/game/28414) | 28414 | 28 |
| [Paragon of Red Mage Excellence](https://retroachievements.org/game/28321) | 28321 | 33 |
| [Paragon of Thief Excellence](https://retroachievements.org/game/28420) | 28420 | 26 |
| [Paragon of Warrior Excellence](https://retroachievements.org/game/28421) | 28421 | 23 |
| [Paragon of White Mage Excellence](https://retroachievements.org/game/28422) | 28422 | 39 |

Subset website links may redirect to `/game/28275?set=<id>`. That `set` id is not the legacy game id accepted by these API endpoints. Do not replace the ids above with redirect query values.

- [Official FFXI support announcement](https://retroachievements.org/forums/topic/25391): the integration is a partnership with HorizonXI. No evidence here establishes RA awarding on other LSB servers. Local completion goals on those worlds must be labelled separately from confirmed RA unlocks.
- [User Game Progress API](https://api-docs.retroachievements.org/v1/get-game-info-and-user-progress.html): `g` is the game id, `u` is the username or stable ULID, `y` is the web API key. A ULID may be entered in the username field to survive account renames. The response supplies per-achievement earned dates and descriptions.
- [Game list API](https://api-docs.retroachievements.org/v1/get-game-list.html): Standalone uses system id 102; `i=102&f=1` can support future discovery. This beta uses a reviewed built-in table plus extras rather than silently importing other Standalone games.
- [API usage guidance](https://api-docs.retroachievements.org/): cache static data and avoid excessive requests. The launcher keeps its existing ten-minute progress cadence and fetches sequentially. This is polling, not instant push; newer unlocks become visible after a successful refresh.
- [Current endpoint source](https://github.com/RetroAchievements/RAWeb/blob/master/public/API/API_GetGameInfoAndUserProgress.php): confirms the legacy `game_id` lookup and returned earned dates. No achievement-awarding endpoint is called.

Importing all descriptions makes them available as a to-do list. It does not create quest routes for each achievement; guide mappings remain a separate authored and locally validated data task. No third-party walkthrough text or achievement catalogue is copied into source by this change; descriptions arrive in the user's private snapshot.

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
  - It covers failures: 401/offline/429, a 500 part-way through, missing built-ins and mismatched response ids preserve the file; unknown extras are skipped.
  - It checks all twelve set ids, request coverage, duplicate extras, cache timing, Retry-After parsing/cooldown, redaction and adoption of the environment key.
  - It exercises the Keychain wrapper on a per-run service name, which it deletes.
- `VanaguideCompanion --selftest-parser` adds the Lua reader, `achievements.lua` in nested and flat shapes, snapshot reading, staleness and registry choice, the merge rules, and guide links.

Not verified by this beta: a live request with a real key, private-server addon approval, or routes for every imported achievement. Tests use fake transports and synthetic progress; they do not contact RA or a hosted FFXI server. Keychain tests use their own disposable service, never the player's stored key.

## Runtime checkpoint — October29,2026

The running launcher’s fresh registered snapshot carried12 unique populated sets and537 records, matching each public hub count. Every record had a title, description and both earned-state fields. The previously stated637 was an arithmetic error; individual table counts were correct. No key, username, earned history or private snapshot is committed. The public hub was rechecked directly.

This is catalogue/progress-file evidence, not proof of a walkthrough for every achievement or of UI rendering. Guide links are best-effort target/description matches; unmatched achievements remain list items without authored routes. The API count is dynamic, not a hardcoded ceiling.
