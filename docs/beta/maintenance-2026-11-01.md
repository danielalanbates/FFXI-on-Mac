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


The sign-in recovery follow-up is assigned local beta build 121 (3.10). This is source/bundle
metadata only until the signed candidate is installed. It is not a published GitHub release.
The installed build 120 retains the verified renderer/resize changes while the hosted game
is active. Updater offline regressions passed on that installed signed beta.


Normal logout limitation found during this pass: the installed `--send-ashita /shutdown
--world "Phoenix XI"` command refused with "no Phoenix XI client is running" while a Phoenix
loader was active. No command was sent. The general resolver does not yet bind the isolated
JSON-auth launch to its world/prefix. Do not bypass this with process termination, another
world's prefix, installing a plugin into a hosted client, or unverified command injection.
Keep the hosted game and current Applications beta running; defer local-client tests and app
replacement until normal shutdown is possible. A future fix needs explicit isolated-session
identity rather than inferring the endpoint from a deleted short-lived credential JSON.


## Phoenix addon-policy correction

The live official approved-addons page was rechecked on 2026-11-01 via its public website
bundle. It contains hundreds of listed tool entries (including Ashita, Windower and standalone
programs). Examples include Affinity, AHColors, allmaps, Ashitacast and Balloon. Phoenix does
not ban all addons. Its conditions cover particular settings, and modified tools need review.

The launcher's currently empty Phoenix allowlist is an unimplemented integration placeholder,
not a representation of an empty official list. Do not tell users that no addons are allowed.
Next policy work should preserve official platform distinctions and item-specific conditions,
and wire approved-addon management into the isolated Phoenix launch path. A generic name-only
import of every entry would lose those distinctions. VanaGuide/VanaVoice are not implied to be
approved by the existence of this list, nor does a screenshot-only app receive an automatic
exemption. No hosted addon test was performed.

Primary source: https://phoenix-xi.com/approved-addons.


A concrete startup defect was also identified: the Mac-specific profile selected an empty
script, suppressing the vendor's baseline Thirdparty/Addons/Screenshot plugin loads. Beta 121
preserves the script specified by the official template instead of writing/selecting that
empty script. The vendor script remains user/vendor-owned; no custom guide or narrator addon
is added. This is separate from importing the optional approved-addon catalog. It needs
normal next-launch acceptance; no hosted addon test was run. An in-progress owned build was
canceled before this source change; rebuild from the now-frozen source before staging.


## Completed beta 121 checkpoint

Immutable launcher source f4bab55 compiled successfully (455 seconds). The Developer ID-signed
candidate passed strict/deep signature verification, all 80 graphics checks, and performance
checks. It was installed transactionally in Applications after normal local-game shutdown;
previous apps were archived in Downloads. The launcher was reopened once in the background.
The bundled guide navigation diagnostic asset additionally matches vanaguide f02ff02, which
preserves fractional grid sizes in status output; it was re-signed and verified after copying.
No public binary release was published. Existing unrelated party-guide drafts remain unmodified.

The hosted Phoenix session exited before the private fixture was started. One isolated client
reached the loopback world with the local-only guide, cmdpipe and voice addons. A private
screenshot confirmed the textured scene, guide UI, direction arrow and ground route line.
Strict movement toward the second authored NPC acceptance step failed at 120 seconds near
the same Port San d'Oria wall. No arrival, new quest acceptance, teleport, server nudge or
forced completion occurred. The actual file header was 0.5-yalm; its 1-yalm UI label was a
rounding bug, now fixed in diagnostic output. The failed file and raw screenshot are archived
privately. Do not claim the center-only navigation experiment succeeded.

One guarded /shutdown ended the local client. Then only the owned fixture holder and generic
20%-volume narrator were stopped; all four server processes and the private database exited 0.
The target NPC was not reached, so new audible narration and sequential quest completion remain
unverified. No hosted addon or bot was tested. Next work remains the collision/first-waypoint
failure, Phoenix isolated-session command identity, optional approved-addon integration, manual
sign-in/resize/vendor startup acceptance, and measured server-by-server playability/performance.


## Beta 122: route-corner steering checkpoint

VanaGuide PR #40 (commit 4d85b3b) fixes two verified steering defects: skipping nearby mesh
corners and turning toward the prior vertex on a long segment. The private route replay now
aims at its first visible corner rather than a shortcut the grid itself marks blocked.
The full guide offline suite passed 2,137/0, and new near-corner/forward-segment plus existing
walking regressions passed. The same walking checks also passed against the signed app's
packaged Lua resources.

The finite strict local retest still failed within 120 seconds, farther along the wall around
(-16.9, -125.3). No new quest was accepted and no teleport/server nudge/forced completion was
used. A bounded alternate AutoFollow-axis probe produced more wall bounce and no Z travel;
that rejected code is archived privately and was not merged. Original axis mapping was
restored. Raw evidence and the result JSON remain outside Git in the private fixture.

The character exited through guarded /shutdown. Only then were the owned holder and narrator
stopped; the four private server processes and database exited 0. No hosted addon/bot test
occurred. Generic narration was running at 20%, but the target NPC was never reached, so no
new audible acceptance is claimed.

The signed local beta 122 bundles guide core/walk.lua and routing/path.lua from 4d85b3b. Its
native executable is unchanged from the verified beta 121 build (f4bab55). Signature checks
and packaged walking tests passed. The Applications app was replaced transactionally while
no game or Wine process was live, the previous playable beta was archived, and the launcher
was reopened once in the background. No public binary release. Full collision, sequential
quest, client-resource alignment, audible narration and server-by-server acceptance remain
open; do not repeat the unchanged failing scenario as an automatic test loop.
