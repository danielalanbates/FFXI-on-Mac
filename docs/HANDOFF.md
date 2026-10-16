# Handoff — read this first

Updated 2026-10-14, beta 3.9 build 59. Short on purpose: what is true now, what gates a release,
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
| Installed `/Applications` | 3.10 b68, the notarized release app (installed by hand 2026-10-16, so the b59+ in-app swap has still never run for real) |
| Local beta | 3.10 b69, branch `beta-b69` (from 48719f6): game-window aspect lock (`gamewindow.dylib`), in progress. Queued for b69: window title always "FFXI on Mac", Addons… opens at once with a spinner while it scans. Local betas are SHORT=3.10 with BUILD ≥ 69 from now on |
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
  drops the client a second after login (`docs/WINE-BUILD.md`). Decide #20 (rebased) or say so
  in the release notes.
- Ship with `scripts/package.sh` (Developer ID + notary profile, clean siblings) and
  `scripts/publish-release.sh` (checks only; `--yes` publishes, Daniel's call). Tag `v3.10`,
  asset `FFXI-on-Mac-3.10-b<n>.dmg`, notarized and stapled.
- The updater's Restart swap of `/Applications` has never run for real (needs a release newer
  than the installed build); first line of the 3.10 notes: "Quit the game before pressing
  Restart" (v3.9's Restart does not check).

## Open pull requests (triage 2026-10-14, nothing posted to GitHub)

Outside PRs need the contributor licence (`CONTRIBUTING.md`, added in b59) agreed on the PR
before merging; asking needs Daniel's OK.

| PR | state | action |
| --- | --- | --- |
| #36 quiet-wine-update | installed as b58; merges cleanly into master | merge once Daniel confirms b58/b59 plays |
| #30 multi-world, #31 RetroAchievements | already in master through #33 (90d77ba) | close as merged; the two-client live test (`docs/MULTI_WORLD_LIVE_TEST.md`) never ran |
| #32 quiet-updater-and-vanaguide | superseded by #36; conflicts in 7 files; turns PLAY into UPDATE | close; narrator-on-exit and the asset-host check are already in b59 |
| #35 password-json | passes `--json` where the loader's flag is `--json-file`; wrong Windows path for override folders; temp file only removed by a 180 s task | fix those, call `scrubLoginFiles`, test a login on local LSB first |
| #17 (rdbell) `/play` → `/play-now` | applies cleanly; both URLs answer 200 | merge only after confirming which page is canonical |
| #18, #19 (rdbell) | #18 applies with reduced context; #19 conflicts | rebase |
| #20 (rdbell) patched-wine installer | replaces Daniel's wine candidates and hard-blocks Play without a 1 GB+ runtime | rebase: keep existing candidates first, offer the install only when none is found, free-space check, no hard block |
| #21 (rdbell) DXVK enforce-nx | biggest measured scene-load win (time below 10 fps 24 s → 1 s, M2 Max, macOS 26.5) but replaces `x87sidecar-coop` with upstream 4e9c738 and would undo the macOS 27 change (3c7c2f6) | do not merge as is. b66 sets `WINE_DISABLE_NX_COMPAT=1` on Play (written independently; the same stall, BETA-66.md); only if the patch still wins on top of that, take only the patch and a rebuilt dll |
| #22 (rdbell) | ~29k lines, stacked on #20/#21 | after those |
| #23, #28 (rdbell) docs | apply cleanly | merge after the licence agreement |
| #24 (rdbell) era label | the same change landed in b59 (2e80269) | close with credit |
| #26 (rdbell) cmdpipe | runs commands from world-writable `/tmp`, no hosted gate | dev tool only: per-user `$TMPDIR`, never bundled, local LSB only |
| #9 release-check | stale paragraph; superseded by `publish-release.sh` | rebase or close |
| Daniel's #4, #7, #8, #10, #11, #15, #16 (August) | open | triage separately |

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

- Fresh-user wine: #20 rebased as above, or a pinned athei wine-cx download with an external-drive
  option.
- Passwords: off the loader command line (#35, once fixed) and into the Keychain (`RAKeychain`
  pattern); today they sit in `accounts.json` (0600) and the boot `.ini`.
- `x87sidecar-coop`'s macOS 27 change has no source or patch in the repo: recover it before the
  next Rosetta update breaks it.
- `launch()` off the main actor (#25): order and plan in `BETA-59.md` › Deferred.
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
