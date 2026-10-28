# VanaGuide Server-Safe — live local-server test, 2026-10-28

Private LandSandBoat lab (`~/Downloads/ffxi-local-lab-20261028`), one game client, loopback only,
no hosted server. The character was driven through the in-game command pipe; Server-Safe ran
unattended with its test hooks (`--auto-read Labguide --crop 0,44,42,56 --trace …`) and was judged
from its event trace and window screenshots. The character logged out with `/shutdown`.

## Result: 9/9 quest givers

| # | NPC | Zone | Server-Safe zone | Heard | Opened |
|---|---|---|---|---|---|
| 1 | Portaure | Port San d'Oria | Port San d'Oria | Portaure | A Job for the Consortium |
| 2 | Gulemont | Port San d'Oria | (same) | Gulemont | The Dismayed Customer |
| 3 | Raimbroy | Southern San d'Oria | Southern San d'Oria | Raimbroy | The Sweetest Things |
| 4 | Balasiel | Southern San d'Oria | (same) | Balasiel | A Squire's Test (Balasiel offers 3) |
| 5 | Dauperiat | Northern San d'Oria | Northern San d'Oria | Dauperiat | Blackmail |
| 6 | Belgidiveau | Northern San d'Oria | (same) | Belgidiveau | Trouble at the Sluice |
| 7 | Kuu Mohzolhi | Northern San d'Oria | Northern San d'Oria | Kuu Mohzolhi | Growing Flowers |
| 8 | Nogelle | Port San d'Oria | Port San d'Oria | Nogelle | Lufets Lake Salt |
| 9 | Hanaa Punaa | Southern San d'Oria | Southern San d'Oria | Hanaa Punaa | The Seamstress (Hanaa Punaa offers 3) |

Also verified live: World filled from the launcher's `session.json`; character **Labguide** read
twice from the status box ("Labguide 507") within 4 s; directions ("You're in Port San d'Oria.
1. Walk to Southern San d'Oria 2. Find Balasiel…"); Developer Mode recorded **Glenne** in Southern
San d'Oria for *A Sentry's Peril* and exported `[0] = { name = 'A Sentry\'s Peril', zone = 230,
npc = 'Glenne' }`, matching the server's script. After the data fix below, a clean Server-Safe
opened *A Sentry's Peril* from Glenne's line with no recordings.

## Second run: Bastok, Windurst, Jeuno (b91)

| NPC | Zone (detected) | Opened |
|---|---|---|
| Wahid | Bastok Mines | The Siren's Tear |
| Corann | Port Bastok | The Quadav's Curse |
| Hungry Wolf | Metalworks | Shady Business |
| Hakkuru-Rinkuru | Port Windurst | Making Amends |
| Fuepepe | Windurst Waters | Making the Grade |
| Ojha Rhawash | Windurst Walls | Flower Child |
| Collet | Upper Jeuno | A Clock Most Delicate |
| Derrick | Lower Jeuno | Save the Clock Tower |
| Karl | Port Jeuno | Child's Play (after the b91 fix) |
| Radeivepart | Ru'Lude Gardens | Northward |

All 13 zones visited today were detected. Horatius (Bastok Markets) never spoke: the in-game
`/vg talk` driver failed, not Server-Safe. A first attempt was invalid because the in-game
VanaGuide panel was covering the chat; the harness must hide it (`/vg` toggles it).

b91 fixes, found by replaying the recorded run (`--replay <trace>`):
- A stray old line at start-up opened *Child's Play* once, and the once-per-session limit then
  ignored Karl's real line. Speaker matches need no such limit (a line is new only once).
- The sample that shows a zone change is baseline for speaker matching (old lines re-show then).
Replays of the earlier San d'Oria runs give exactly their quests (no regressions).

## Bugs found live and fixed (b90)

| Symptom | Cause | Fix |
|---|---|---|
| No text for minutes; Neural Engine errors | Recognizer's first request in a process loads its model (~65 s; then 0.1 s). macOS also compiled it for the ANE for ~20 min once | Warm-up on Find Game Window / at launch after first use; 8 s timeout, no stacking; status says "Preparing" |
| NPC never matched | Vision returns "Gulemont" and "It's been…" as two boxes, colon lost | Rejoin boxes into rows by position; restore " : " only across a wide gap |
| "Deleted San d'Oria" as a speaker | Separator restored across ordinary word spacing | Gap must be ≥ 0.8 line height |
| Own character recorded as a speaker | Typed commands echo as "Labguide : …" | Exclude the current character |
| Old chat opened an old quest at start-up / credited NPCs to the wrong zone | Lines already on screen treated as new | Lines on screen at start or a zone change are the baseline |
| Repeated NPC line missed / jumping log re-showed old lines | Log scrolls and jumps during conversations | New = unseen since zone began **or** unmatched against the last reading (LCS); top (cut) row ignored |
| "Vanaguidel release" as a speaker | Misread addon line | Every word of a name must be capitalized |
| Zone unknown after restart | Area line scrolled away | Last zone per character remembered for 2 h |
| Stop button clipped | Header too wide | Hammer icon + status dot |
| "Talk to qm1" | ??? spots in data | "Examine the ??? marker" |

## Data (VanaGuide PR #21, commit 768b3ae)

`tools/gen_quests.py` only read `-- Name : !pos …`; LandSandBoat also writes `Name - Zone, !pos`,
`Zone, Name, !pos`, `Name !pos` and comma coordinates. Quest start locations **346 → 422** of 506
(+3 missions) via `tools/merge_locations.py`, which only fills blanks. Fixed sandoria 60 (an
upstream header calls it "A Sentry's Peril"; it is *The General's Secret*). Offline tests 1415/0.

## Not verified

- **Getting Started** (reading the in-game Quests/Missions log): opening the menu needs a key
  press; posting keys to the game requires Accessibility permission, which the test shell lacks.
- Character switching (one fixture character), and the Developer Mode name *buttons* themselves
  (the same code path ran through `--dev-autotest`; clicking needs Accessibility permission).
- Ambient NPCs (e.g. Lusiane, Raminel in Southern San d'Oria) appear in Developer Mode's heard
  list; the developer picks the right name.

Trace files: `results/serversafe-trace-run*.jsonl`; step tables: `results/serversafe-steps*.md`
(lab, Git-ignored).

Copyright © 2026 Bates LLC. All rights reserved. [batesai.org](https://batesai.org) · help@batesai.org
