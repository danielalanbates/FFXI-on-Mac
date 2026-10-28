# Beta 3.10 build 82

Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
[batesai.org](https://batesai.org) · help@batesai.org

This source branch extends beta 81. Public releases remain separate from local beta builds;
do not publish a new release merely because this branch has been pushed. The user is beta
testing the app. Keep the Applications launcher playable and never replace it while it or its
game/Wine processes are running. If a character must leave the world, use `/shutdown` and
verify the exit; never kill the client.

## Changes

| Area | Behavior |
| --- | --- |
| Separate guide | **VanaGuide Server-Safe** opens from the launcher's setup controls. It also builds as its own `.app`. It does not install or enable a game addon. |
| Local OCR | Explicit Start/Stop, selected FFXI game window and chat crop, capture every 10 seconds. Apple Vision runs locally; images and text are not saved or sent to an AI service. Two matching samples select a guide section. Progress stays manual. |
| Guide coverage | The standalone app now reads the bundled quest/mission catalogue as reference sections as well as authored routes. A reference target is not a complete quest walkthrough. |
| Achievements | All 12 populated HorizonXI RetroAchievements sets known on October 27 are included. Failed or incomplete refreshes retain the last good snapshot; HTTP 429 establishes a refresh cooldown. |
| Update offer | Accept only published stable releases and uploaded disk images matching the release version. Restart rechecks asset identity/digest; a withdrawn release clears the offer. |
| Packaging | The launcher contains the matching standalone guide as a nested helper app, so its normal GitHub update carries both. A standalone build uses `app/bundle-server-safe.sh <output-dir>`. No script starts screen capture or opens the app. |

The name “Server-Safe” describes the separate GUI architecture, not approval by a server.
The existing addon policy still restricts VanaGuide and VanaVoice installation to permitted
local worlds. Screenshot-only mode does not infer player coordinates, draw a live heading arrow,
read game memory, inspect packets, award RetroAchievements or automate gameplay.

## Workspace and related projects

Google Drive `Code/HorizonXI-on-Mac` remains the base project folder. Its files and Git metadata
were online-only placeholders at startup; reads stalled while Drive hydrated them. Work for
this branch uses an independent Downloads clone, rather than overwriting that historical
checkout or assuming its old working tree is clean. The previous beta-81 checkout is also
preserved. See the local workspace pointer in the Drive project's `docs` folder.

| Project | Repository | This work |
| --- | --- | --- |
| Launcher and standalone GUI | `danielalanbates/FFXI-on-Mac` | Beta 82, based on `beta-b81` at `87a5a02`. |
| Guide addon / local test harness | `danielalanbates/vanaguide` | Guard local test commands using positive process/folder/loopback evidence; no hosted addon tests. |
| Narrator | `danielalanbates/vanavoice` (private) | Retain one generic narrator by default, modest new-config volume, safer standalone packaging. |

The existing **CompletionRoute** WoW project was reviewed in Drive, particularly
`docs/GUIDE_FORMAT.md` and `docs/PARITY_CHECKLIST.md`. Its useful interaction model is an
ordered step list, explicit accept/objective/turn-in state, route recommendations and a heading
arrow. Preserve that distinction here: the local addon can use permitted client state, while
the screenshot GUI has only recognized text and manual progress. Do not pretend screenshot
matching supplies the same movement or quest-completion evidence.

## Dependency and performance pathway

[Dependency review](DEPENDENCIES-2026-10-27.md) was completed before implementation. New
Mach9 ARM64/FEX, x87sidecar and Metal-renderer releases merit a separate local compatibility
lab. This beta preserves the current Wine, sidecar, DXVK and MoltenVK versions. Do not replace
the playable prefix or promise a performance maximum from release notes alone.

The next performance experiment needs the owner's local LSB server, one test client, maximum
visual settings, repeated samples of the same scene and frame-time/memory observations. Keep
the active hosted game untouched. Do not run a local server alongside the user's game on the
8 GB machine just to collect a benchmark; prior notes show severe memory-pressure collapses.

## Verification and remaining work

The final build/test/install record is appended below once validation finishes. Offline tests
are not evidence of live cutscene audio, successful quest gameplay, mouse/arrow appearance or
an updater swap on the actual Applications app.

Required local-only beta checks remain:

- Actual game-window selection, chat crop and OCR-triggered section selection, including Stop
  during capture and closing/minimizing the target window.
- A character accepting, completing and turning in sequential authored quests while VanaVoice
  speaks and VanaGuide routes. Record real objectives separately from GM-forced completions.
- New runtime A/B tests, including correct cutscenes/fonts/effects, cold launch, zoning and
  `/shutdown`. Preserve the current runtime until a candidate passes.
- A real public-update installation when a newer stable version exists. Offline metadata tests
  must never manufacture an update prompt in the user's installed launcher.
- Server coverage still depends on client availability, server permission and server-specific
  login flows. See [LSB-SERVERS.md](LSB-SERVERS.md); protected authentication and operator approval
  are not bypassed to satisfy a claim that every LSB world works.

No automatic release schedule, login bot, app-opening loop, repeated focus control or update
watcher is installed. Publish a stable public release at most about weekly, after the relevant
gates in [RELEASE-WHEN-STABLE.md](../RELEASE-WHEN-STABLE.md) are met.

## Continuation fixes — 2026-10-28

- Reference lists now permit OCR selection of an earlier, unrelated quest. Authored routes
  still preserve a player's later manual checkpoint.
- Achievement refresh requires the complete published achievement map and count, rejects
  invalid/duplicate IDs and empty populated built-ins, and keeps the last good file on failure.
  Both current `Type` and legacy `type` metadata are accepted. The endpoint's unknown-game `[]`
  response follows the existing built-in failure / extra-set skip policy.
- The updater's detached launch script is removed by the child after opening, instead of
  racing its interpreter when the parent returns. It is owner-only from creation, handles
  quoted paths at both interpreter layers, and stops on a failed working-directory change.
  The existing updater probe now uses spaces, apostrophe, double quote and backslash in its
  path. The retired implementation is identified in `archive/2026-10-28/README.md`.
- Both source installers refuse replacing the launcher while its embedded guide is running,
  matching the new updater refusal. Nothing terminates a running guide or client.

Source PRs for the related projects:
[VanaGuide #21](https://github.com/danielalanbates/vanaguide/pull/21) (`5015f9a`) and
[VanaVoice #10](https://github.com/danielalanbates/vanavoice/pull/10) (`5d3fffa`).

## Offline validation — 2026-10-28

Release-mode build completed with one compiler job and existing non-fatal Swift warnings.
All 35 launcher self-test suites pass. This includes 92 multiworld checks, 106 updater checks
(including the detached helper probe with quoted paths) and 63 RetroAchievements checks.
The companion parser/achievement/OCR suite passes 63 checks with the explicit current
VanaGuide source. The synthetic updater companion-swap suite passes all 8 checks. Shell
syntax and `git diff --check` pass. The nested-helper candidate bundle passes strict deep
signature verification.

The first unbundled addon-install fixture timed out because development-source discovery
reached online-only cloud folders. Running that fixture from the packaged candidate uses
its complete bundled snapshots and passes all 6 assertions. No source-discovery shortcut
was added to the installed app.

The native computer-use service returned `Trusted RPC service is not configured: sky`.
No visual, screen-capture, audible speech or live character test is claimed from these
checks. The private local-LSB preparation path is in [LOCAL-LSB-TEST-PLAN.md](LOCAL-LSB-TEST-PLAN.md).
No hosted server was used for addon, bot or capture testing. No public binary release was made.
