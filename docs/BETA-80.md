# Beta 3.10 build 80 (local only)

Copyright (c) 2026 Bates LLC. All rights reserved.

Branch `beta-b80`, from `beta-b79`. Local beta: no GitHub release.

Daniel, 2026-10-25: *"is it possible to change this so it can run unlimited simultaneous clients
(when not against TOS)?"*

The launcher could already run any number of clients of one world (sessions per process group,
docs/MULTI_WORLD.md). The limit was the policy: a world got one client unless its rules were found
to allow more. Now it is the other way round. A world gets as many clients as its rules allow, with
no cap when they say nothing against boxing.

| world | before | b80 | why (quotes and links in MULTI_WORLD.md, "Clients per world") |
| --- | --- | --- | --- |
| Moghouse XI | 1 | no cap | no rules published; their listing says "Dual-boxing: Yes" |
| Olympus XI | 1 | no cap | their seven rules say nothing on boxing or accounts |
| Supernova | 1 | 6 | "Playing more than 6 characters at once" is prohibited |
| Gaia XI | 1 | 2 | "Maximum 2 Accounts Per Player", "Dual-Boxing Allowed" |
| OmicronXI | 1 | 2 | "Currently we allow 2 active characters on at a time." |
| HorizonXI | 1 | 1 | "Horizon is a single box server" (now cited) |
| DriftwoodXI | 1 | 1 | "One account per player."; "Why multi-boxing is against the rules" |
| PegasusXI | 1 | 1 | the operator's repo rules: "single box" server, one account per adventurer |

Unchanged: Local server, Vanadreams and Legendary Relaunch (no cap); CatsEyeXI, MistXI, LevelDown 99
and Scythe (2); AscensionXI (1, "Multiboxing ... is not permitted"). A world added by hand stays at 1,
since nobody has read its rules. A saved servers.json picks the new caps up at the next start
(`maxClients` is refreshed from the built-ins).

**How the rules were read.** A two-step research pass (`docs/research/multibox-rules-2026-10-25.json`):
one agent read each world's own rules, FAQ, wiki and listings. A second agent was told to refute any
verdict more permissive than the truth, and it re-read every cited page. Where the sources disagreed
(PegasusXI's live site against its operator's repo, OmicronXI's 2021 blog), the stricter reading was used.

**Technically.** Current LandSandBoat xiloader (`src/network.cpp`, read 2026-10-25) binds no fixed
local port, so extra copies of one world do not collide. Older forks (Driftwood's xiloader) bind
their POL listen port, and those worlds are capped at 1 anyway. Each client still costs about
1–1.5 GB on an 8 GB Mac. The memory warning (non-blocking) still appears before a client starts
when swap or free memory is low.

## Tests

- `--selftest-multiworld`: a world without a cap takes a twelfth client beside eleven running, this
  window's own starting session and another launcher's injector whose world cannot be told. Each
  built-in's cap is checked against the table above.
- `--selftest-retail-world`: Moghouse XI and Olympus XI have no cap.
- Not yet done: three or more live clients of one world on this Mac.

## Next

- Live run: two or three clients of an uncapped world, the local server first (never test on a hosted
  server without Daniel).
- Re-read a world's rules when it changes them. OmicronXI's rules are on a 2023 wiki page; their site
  was down on 2026-10-25.
