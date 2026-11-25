# Handoff — read this first

**2026-11-24: public release is 3.11.2 build 128 (tag `v3.11.2` = `7c7824e`, also installed in
Applications). It fixes issue #92** (a world installed from its own Windows
installer, e.g. Eden added by hand, never found its client: Eden's installer always writes
`C:\Eden`). Root cause, the fix, its review and the live runs: [ISSUE-92.md](ISSUE-92.md). New
self-test `--selftest-installer`; `--selftest-installer-live <exe|zip> <world> <folder> <wrapper>
[--stop-after s]` runs the real job on a spare wrapper. Eden's catalogue entry now points at
Eden535 (what edenxi.com/install links). Eden is still not listed (DarkStar lineage).

**2026-11-20: public release is 3.11.1 build 127 (also installed in Applications).** It fixes
issue #89: athei deleted the `cx-26.3.0-1` Wine release, so Setup now downloads a repack from this
repo's `wine-cx-26.3.0-1` release (never mark that release latest; the updater reads
`/releases/latest`). How it was packed and how to re-pin: [WINE-BUILD.md](WINE-BUILD.md). Open:

| Item | State |
| --- | --- |
| Full first-time Setup in the launcher window on a clean Mac | not tried (script-level install from the live mirror passed) |
| In-app update 3.11 → 3.11.1 | 3.11's `--selftest-updater` accepts the image; not clicked through in the window |
| LGPL source for the mirror | points at CodeWeavers' source and athei/mach9 tag `cx-26.3.0-1`; host a copy if either disappears |
| athei's successor (Mach9, arm64 wine `v0.4.0`) | not evaluated as a replacement for the x86_64 build |
| Google Drive checkout of this repo | stale at 3.10; work happens in `~/Downloads/ffxi-release-3.11/launcher` (no remote; push by URL) |

**2026-10-29: launcher and VanaGuide Server-Safe beta 103 are installed in Applications;
VanaVoice is 1.5.5. Read [CURRENT-2026-10-29.md](CURRENT-2026-10-29.md),
[BETA-103.md](BETA-103.md) and the October 29 continuation in
[DEPENDENCIES-2026-10-27.md](DEPENDENCIES-2026-10-27.md) first.** The installed launcher bundles
the corrected generated route graph from VanaGuide `56c4701`. Public binary release remains
3.10 build 68. The older state and next-step lists below are historical and must not be used
to downgrade the local beta or repeat already-landed work.

Updated 2026-10-24, beta 3.10 build 71 (state table); the rest as of 2026-10-14, beta 3.9 build 59. Short on purpose: what is true now, what gates a release,
what is open. Every b59 change and the live tests it needs: [`BETA-59.md`](BETA-59.md). Ranked
next steps: [`NEXT.md`](NEXT.md). The August handoffs (read-back diagnosis, probes, early dead
ends) are in `archive/docs-2026-08/`.

## Daniel's rules (non-negotiable)

- `/Applications/FFXI-on-Mac.app` is the copy Daniel plays on and must stay playable. Build
  elsewhere (`./app/bundle.sh ~/Downloads/FFXI-build`); install with `./app/bundle.sh /Applications`
  only when nothing runs (it refuses otherwise and archives the old bundle).
- A logged-in character leaves only by `/shutdown` in game chat. Never kill a client, never close
  a game Daniel is playing.
- Addons are tested on the local LandSandBoat world only, never on a hosted server.
- Max graphics settings only. Never trade effects or resolution for fps.
- GitHub release at most weekly and only when stable ([`RELEASE-WHEN-STABLE.md`](../RELEASE-WHEN-STABLE.md)).
  The launcher prompts to update only when there is an update.
- Window text only when it is an error or an action, one short line.
- 8 GB RAM, swap usually high: one `swift build` at a time; keep ≥8 GB disk free. Use
  `/usr/bin/git` (Homebrew git hangs on HTTPS).

## State

| what | now |
| --- | --- |
| Public release | **3.10 build 68** (tag `v3.10` at 5f3759d, published 2026-10-16), Developer ID signed, **notarized and stapled**; `/releases/latest` serves `FFXI-on-Mac-3.10-b68.dmg` (sha256 a7c9429a…067d) under both repo names. Master = 5f3759d; PRs #36–#45 merged. Release notes: `docs/RELEASE-3.10.md` |
| Installed `/Applications` | **3.10 b71** (local beta, installed 2026-10-24; b70 archived in `~/Downloads/FFXI-on-Mac-build/archive-apps`). Before that b70 (2026-10-17), b69, and the notarized 3.10 b68 release app (installed by hand 2026-10-16, so the b59+ in-app swap has still never run for real) |
| Local beta b71 | 3.10 b71, branch `beta-b71` (from `beta-b70` c721e2a): **AscensionXI** as a world, its client, DATs, addons and loader from their own update channel, natively ([`ASCENSION.md`](ASCENSION.md)); a new world no longer inherits HorizonXI's saved login; `Server.loaderOptions`; LuaJIT guard vs. the sync; the Addons… sheet on their script block ([`BETA-71.md`](BETA-71.md)). 27 suites pass; one Play reached their login server with a throwaway account. Survey of every other LSB world: [`LSB-SERVERS.md`](LSB-SERVERS.md) |
| Local beta | 3.10 b69, branch `beta-b69` (from 48719f6, `release-3.10` e441246 merged in, so the Play-time fit is 3.10's `WindowMemory.playSettings`): the game window keeps its shape when resized (`gamewindow.dylib`, `HXI_GAME_ASPECT` from the profile after the fit), and inserted dylibs are carried through the hardened x87 sidecar; the game window's title is always "FFXI on Mac" (same dylib, `HXI_WINDOW_TITLE`); Addons… opens at once with a spinner while it scans off the main actor ([`BETA-69.md`](BETA-69.md)). Not installed, not pushed, not played. Local betas are SHORT=3.10 with BUILD ≥ 69 from now on |
| Local beta b70 | 3.10 b70, branch `beta-b70` (from `beta-b69` 5716690), after the 2026-10-16 freeze (the X10 dropped off USB at 14:15:40, the wineserver died, the game froze at character select and could not be closed): programs of a Wine session that already died are ended (Play, game exit, refresh), Wine dying under a running game is shown with one line and Force Stop, Stop is in the Dock menu and a Game menu, sleep and wake lines in launcher.log; after the 21:31 GPU reset froze the game, `MVK_CONFIG_RESUME_LOST_DEVICE=1` and a rebuilt DXVK DLL (cursor fix + device-lost fix, sha256 70ba5664…); Stop says "Stopping…" and escalates SIGTERM → the session's wineserver (gated) → SIGKILL; a lost GPU device turns the button into Stop with one line under it; `gamewindow.dylib` asks "The game isn't responding." when a frozen game ignores its close button or Quit ([`BETA-70.md`](BETA-70.md), §9 = the review). Built and self-tested 2026-10-17 (26 suites, 1016 checks; window harness 342 PASS); not run in a game, not installed, not pushed |
| Version source | `app/VERSION` (`SHORT`, `BUILD`) |
| GitHub | `danielalanbates/FFXI-on-Mac`. v3.9 clients still ask for `HorizonXI-on-Mac` and arrive by GitHub's rename redirect: never create a repo with the old name. The local `origin` URL still uses the old name. |
| Working copy | `~/Downloads/hxi-work/HorizonXI-on-Mac`; siblings `vanaguide` (e2c1609) and `vanavoice` (29a8ec9) are bundled as they sit on disk (revisions recorded in Info.plist `HXIAddonRevisions`) |
| Test Mac | M1 MacBook Pro 8 GB, macOS 27.0.1 |
| Play stack | athei `wine-cx-26.3.0-1` (`wine-coop`, fetched by Setup via `scripts/game-wine.sh` (pinned) or found on the Mac, not shipped) + WINEMSYNC; d3d8to9 → patched DXVK 1.10.3 → MoltenVK 1.4.2; `x87sidecar-coop` on by default (b59); Ashita v4 |

## Release gates (3.10 shipped 2026-10-16 with these still open; they apply to the next release)

- The stability list in `RELEASE-WHEN-STABLE.md`, verified fresh, plus several real sessions on
  the current beta with no manual intervention.
- macOS 27.0.1 in-world fps, x87 on vs off (nobody has measured it since 09-27).
- **Fresh users:** Play needs athei's wine-cx; *Install wine…* gives Sikarugir 10.0, whose wine
  drops the client a second after login (`docs/WINE-BUILD.md`). #20 was closed on 2026-11-25:
  Setup has fetched the pinned wine-cx itself since v3.10 (`scripts/game-wine.sh`).
- Ship with `scripts/package.sh` (Developer ID + notary profile, clean siblings) and
  `scripts/publish-release.sh` (checks only; `--yes` publishes, Daniel's call). Tag `v3.10`,
  asset `FFXI-on-Mac-3.10-b<n>.dmg`, notarized and stapled.
- The updater's Restart swap of `/Applications` has never run for real (needs a release newer
  than the installed build); first line of the 3.10 notes: "Quit the game before pressing
  Restart" (v3.9's Restart does not check).

## Pull requests (updated 2026-11-25: none open)

Outside PRs need the contributor licence (`CONTRIBUTING.md`, added in b59) agreed on the PR
before merging. On 2026-11-25 that was asked on #18 and #23, which were closed until rdbell replies.

| PR | outcome (2026-11-25) | still open |
| --- | --- | --- |
| #26 cmdpipe | merged (609c748) without the world-writable `/tmp` pipe; in-game-folder pipe only, not bundled | none |
| #11 ashita-signature-repair | closed; `docs/SIGNATURES.md`, `patches/ashita/custom.pointers.ini` and `addons/sigscan` salvaged through #95 (fa3fc0a) | the winecursor ImGui click feed and the audiofollow restart watchdog (d0b1944) stay on branch `ashita-signature-repair`; both need an in-game check |
| #17 (rdbell) `/play` → `/play-now` | merged (f47d255): horizonxi.com's route table has `/play-now` and no `/play` (the SPA answers 200 for any path) | ships with the next release |
| #18 (rdbell) aria2 metadata retry | closed pending the licence; ported onto master as `fetch_torrent` (setup-scripts-test 94/94) on branch `port/rdbell-18-aria2-metadata` | reopen and merge when rdbell agrees on #18 |
| #23 (rdbell) docs | closed pending the licence; PR plus two fixes (MoltenVK 1.4.2, MAX4K note points at #22) on branch `port/rdbell-23-docs` | reopen and merge when rdbell agrees on #23 |
| #19 (rdbell) | closed as addressed (cc5ee53, cb9a9f4, 42edcfa) | `Install.remembered()`/`lastChosen()` still accept an `install.last` naming `prefix-installers` (only from builds before 3.11.2) |
| #20 (rdbell) | closed as superseded: Setup fetches the pinned wine-cx through `scripts/game-wine.sh` since v3.10, a verified repack since 3.11.1 (#90); the PR's athei URL now returns 404 | `ServerStore.merge` does not refresh the built-in per-world `x87`/`msync` flags |
| #21 (rdbell) DXVK enforce-nx | closed as superseded: `WINE_DISABLE_NX_COMPAT=1` (fffe128) and explicit `DXVK_CONFIG_FILE` (cd83afd); its vendored DXVK DLL and `x87sidecar-coop` would regress master | enforce-nx on top of NX_COMPAT stays an A/B (Performance item 3) |
| #22 (rdbell) harness | closed: stacked on #20/#21, 16 conflicts, symbol maps for DLLs that no longer ship | none |
| #4, #7, #8, #9, #10, #15, #28 (Daniel) | closed as superseded; branches kept | only on their branches: the ImGui click feed (#8, #10, #11), #10's `docs/MOUSE.md` reading of Ashita.dll (WH_MOUSE hook), the `--addons` command line (#15), Locate… (#4) |
| #35 password-json | closed in favour of branch `fix-login-file-35` (834839f, WIP, no PR) | Wine loaders reject the `Z:\var\folders` path: move the file under `/private/var` or the prefix's `drive_c`, then a local-world login test |
| #85 party-camp draft | closed: wiki-sourced, unverified, moved the Solo Guide out of the top section | branch `draft/horizon-party-camps` |
| #16, #24, #30, #31, #32, #36 | closed earlier (#36 merged 2026-10-16) | none |
| issue #25 beach-balls | closed as not planned: shutdown fixed (a13d09a); `launch()` is still synchronous on the main actor | `BETA-59.md` › Deferred; a `Runner.swift`-only PR is welcome |
| issue #27 window | closed: fcd3adb, shipped since v3.10 | the on-screen check in `BETA-59.md` is not recorded as run |

## Performance

A/B list (local LSB only, max settings, same scene, `/shutdown` between runs, ≥3 runs each,
medians and ranges; check swap and Low Power Mode first; `FFXI_ON_MAC_FPSLOG=1`, rows with >800
draws). Recipes: `BETA-59.md` › Performance.

1. x87 sidecar on (default) vs `FFXI_ON_MAC_X87=0`, macOS 27.0.1.
2. ~~`WINE_DISABLE_NX_COMPAT=1`~~ settled, and the default since b66 (`BETA-66.md`). The
   "FFXI's exes are already NX_COMPAT" doubt written here was wrong: the exes are, but
   FFXiMain.dll, FFXi.dll, polhook.dll, app.dll and polcore.dll are not, and this Wine turns
   no-execute off for the whole process when any module lacks the flag. Measured live
   2026-10-15: ~85-94k page faults/s without it, ~3k with it. Reported upstream as
   athei/wine-build#3 (rdbell, same ratios); the cx-26.3.0-6 release notes carry the fix.
3. #21's enforce-nx DXVK patch alone, in a rebuilt dll, keeping our `x87sidecar-coop`. Now only
   worth measuring against b66 (variable on): #21 addressed the same stall from inside DXVK.
4. `d3d9.maxFrameLatency = 1` in `vendor/dxvk.conf` (every harness 4K number used it; Play never did).
5. `MVK_CONFIG_SHOULD_MAXIMIZE_CONCURRENT_COMPILATION=1` (pipeline-compile stalls).
6. Cold Play-to-window time and beach-balls vs b58 (#25).

The worst collapses on record (0.4–5 fps) were swap (local LSB alongside on 8 GB) and background
indexing / Apple Intelligence asset installs (`docs/CHECKPOINT-2026-09-26.md`), not the renderer.
Whether Low Power Mode was on then is unknown (logs rotated); b59 warns about it at Play.

**Measured dead ends, do not re-propose:** read-back NOWAIT / shadow / EARLY / EARLY_FENCE /
PERIODIC_FLUSH / UNBIND_FLUSH / dedup; a second queue (MoltenVK has one); fence spin; MVK prefill;
`MVK_CONFIG_SYNCHRONOUS_QUEUE_SUBMITS=0`; `DXVK_EARLY_BUFFER_COPY`; `DXVK_KEEP_DEPTH`; removing
render-pass spills; vsync off / presentInterval 0; 3 back buffers; timer resolution; batching /
instancing; lower quality or resolution; msync off; `X87_FAST_ROUND=2`; the x87 control word;
attach-by-pid on 26.5.2+; wrapping wine in the sidecar or hand-set `ROSETTA_DISABLE_AOT`;
wine32on64; WineHQ 11; Whisky; Sikarugir wine for Play; DXVK 2.x/3.x (no geometry shaders on
Metal); D3DMetal; dgVoodoo2; wined3d Vulkan/OpenGL; removing Ashita; d3d8to9 state filtering;
the upstream sidecar (not faster offline); the
old CrossOver MoltenVK on macOS 27. Numbers: `MAX4K.md`, `PERFORMANCE.md`, `X87-SIDECAR.md`,
`MACOS-27-PERFORMANCE.md`.

## Pathways (open, not started)

- Fresh-user wine: done since v3.10 (Setup's pinned `scripts/game-wine.sh` download into the
  chosen folder; #20 closed as superseded).
- Passwords: off the loader command line (branch `fix-login-file-35`, WIP; #35 closed) and into
  the Keychain (`RAKeychain` pattern); today they sit in `accounts.json` (0600) and the boot `.ini`.
- `x87sidecar-coop`'s macOS 27 change has no source or patch in the repo: recover it before the
  next Rosetta update breaks it.
- `launch()` off the main actor (#25, closed until a PR lands): order and plan in `BETA-59.md` ›
  Deferred.
- Personal data still in the tree or history: character name "Murn" and `docs/img/murn-*.png`,
  `/Users/daniel` paths (harness profiles, results JSON, scripts), volume names in
  `X87Sidecar.swift`/`Install.swift`, the login name inside the archived 2.7 app binary, and the
  removed CatsEye scripts in history. Keeping or rewriting history (`git filter-repo` + force
  push, irreversible) is Daniel's call.
- `archive/` holds ~50 MB of old apps, DMGs and DLLs: move to a release asset or external archive.

## Working practices that cost time to learn

- **Never rewrite `user.reg`/`system.reg` by parsing and re-emitting them.** `DllOverrides`
  stopped being readable, wine fell back to its builtin d3d8, DXVK never loaded, and the game
  still rendered, so every measurement came back empty. The launcher only reads hives and changes
  them through `wine reg`. Check with `WINEDEBUG=+module`; snapshot both hives first.
- `--play` must be started through `open`, not by running the binary (`docs/WINE-BUILD.md`).
- Run-to-run spread is ~7 fps: single runs prove nothing. Confirm the code path actually ran
  before believing a null result.
- `/shutdown` sometimes needs a second try; check the character really left.
- Never send blind Return presses in-world (it once reached an auction-house fee confirmation).
  Driving the game needs real window focus; `CGEventPostToPid` does not work.
- A crashed client can leave `winedbg --auto` behind and the next launch never renders.
