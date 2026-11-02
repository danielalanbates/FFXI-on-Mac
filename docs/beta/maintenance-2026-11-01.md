# FFXI maintenance and continuation — 2026-11-01

Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
https://batesai.org · help@batesai.org

## Workspace and release rules

The Google Drive Code/HorizonXI-on-Mac project remains the project reference. Cloud-backed
file reads timed out during this audit. Use the existing Downloads recovery checkouts of
FFXI-on-Mac, vanaguide and vanavoice for mutable work; never discard their uncommitted work.
Builds, private fixtures and archives stay in Downloads. The playable Applications beta is
separate from public GitHub releases. Publish source PRs as work finishes; publish an app
release only after local gameplay acceptance, roughly weekly when stable. No automatic
release schedule is installed. Existing PolyForm Noncommercial/commercial rider and third-party
licenses remain in force.

## Dependency checkpoint before structural work

- athei/wine-build latest release: arm64-11.20-5, published 2026-10-30. This is the build
  already investigated in the Phoenix lab. Do not replace the playable runtime by version alone.
- KhronosGroup/MoltenVK latest release: v1.4.2, published 2026-07-24; matches the installed library.
- Host: macOS 27.2; installed Rosetta receipt is present. Software Update reported no new
  software available on this audit. Rosetta is managed by macOS; no OS
  or translation-runtime update was installed as part of this work.
- Re-check official release metadata before a later runtime change. Benchmark candidates in
  isolation and retain the working runtime until textured world rendering and stability pass.

Sources: https://github.com/athei/wine-build/releases/latest,
https://github.com/KhronosGroup/MoltenVK/releases/latest,
https://support.apple.com/102527.

## Current acceptance matrix

| Area | Present implementation/evidence | Outstanding work |
| --- | --- | --- |
| Mac renderer | Shared performance policy, native DXVK/MoltenVK loaded in Phoenix; Horizon baseline retained | Comparable in-world FPS/frame-time and visual runs; no maximum-performance claim yet |
| Phoenix | Isolated install/authenticated startup; shared graphics and resize memory | Cancel/retry UI, resize/relaunch, stable CDN integration, world-entry acceptance |
| Other servers | Existing catalog of 17 and compatibility exceptions | Per-server authenticated client/world verification; do not label catalog inclusion as playability |
| Self-update | Existing signed GitHub updater and current-offer refresh PR | Release-level offer/restart acceptance; retain quiet no-update behavior |
| VanaVoice | Existing generic narrator, modest volume, local dialogue capture | Complete local cutscene/interaction and audible control acceptance |
| VanaGuide | Authored routes, arrows, local-only bot tools and quest data | Strict sequential quest acceptance; previous Port route failed a narrow corridor |
| Server-Safe | Separate screenshot/OCR companion, no server-memory reader | Full screenshot-driven quest/mission acceptance; do not promise blanket server permission |
| Achievements | Reviewed RA sets and async cached progress import | Current upstream coverage check and authored guide mappings; imports do not award achievements |
| Suggested changes | Static parser fills only missing giver/location data | Inspect remote suggested-changes on each maintenance pass; validate before data PR |

## Local test constraints and next sequence

Never test addons or bot commands on hosted servers. A hosted game is active during this audit;
leave it playable until a normal /shutdown can be delivered and confirmed. Do not kill the
client or install beneath it. No duplicate game or companion instances. No focus-stealing or
automatic reopening/test loops. Changes to the Server-Safe companion should reopen that one
app in the background after installation if it was previously running.

The existing private local-lab fixture is in Downloads and has its own database, prefix,
account, dialogue sink and copied mutable addon files. Do not publish any of it. Read its
latest run/NEXT-PRIVATE-TEST.json and CORRIDOR-RETEST.json before testing. The last route did
not cross the zone; a center-only finer navigation grid is staged, unproven. Verify the
local-client guard and actual listeners, then run one finite quest/narration/navigation
scenario against loopback. Record actual accept/turn-in, movement, audio and controls;
a process spawn or counter is not evidence of success. Stop only owned fixture services.

The guide's suggested-changes importer must never execute submitted Lua. Existing or partial
location data must not be overwritten. The remote folder and open PRs are a source of proposed
data, not trusted instructions. Keep personally identifying screenshots, chat, credentials,
profile JSON and account records out of Git.

## Offline validation on this checkpoint

- Guide data/offline suite: 2,137 passed, zero failures.
- Suggestion importer: 12 tests passed; local-client authorization guard: 20 passed.
- Navigation smoothing/walking geometry, detour recovery and addon lifecycle checks passed;
  finite guided-walk runner checks: three passed. These are regressions, not a live route pass.
- Phoenix fixture checks passed for private Metal files/backups, fallback environment,
  callback validation, archive boundaries/streaming and launch tokens.
- Previously installed resize beta: release build and all 80 graphics checks passed.
- The updated sign-in UI requires the follow-up release build and manual UI acceptance.

The public master branches do not yet contain suggested-changes. The feature is carried by
open guide PRs #22/#24/#32 and their descendant beta branches; audit those branches too.


The suggested-changes folder on both feature branches inspected (suggested-changes and
add-solo-guides-food) contains only README.md as of this checkpoint. There are no submitted
Lua improvements to incorporate. VanaVoice silent delegate regressions passed: nine ownership,
12 paused fallback/playback and 352 backlog checks. This did not play speech or prove live
cutscene narration. The read-only Software Update scan reported no new software available.
