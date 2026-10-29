# What to do next

**Resize continuation (2026-10-28, beta 98):** [BETA-98.md](BETA-98.md) records the newer
source/installed-build distinction, hidden resize verification, and the macOS 27.2 dependency
check. Do not use the older beta 82 installation status below as the current inventory.
Recheck running apps before installation; the playable launcher must stay intact during a game.

**Current priorities (2026-10-27, beta 82)**

1. Read [BETA-82.md](BETA-82.md) for the current checkout, validation record and remaining
   local-only gameplay checks. Preserve the installed playable app while a session is running.
2. Beta-test [VanaGuide Server-Safe](SERVER-SAFE-GUIDE.md) with local LSB dialogue/log titles.
   Test narration and sequential quests locally; never use hosted servers for addon/bot tests.
3. Evaluate the newly released runtime candidates in the isolated lab described in
   [the dependency review](DEPENDENCIES-2026-10-27.md), before proposing a runtime migration.
4. Review the source PRs, then require stable real use and the release checklist before a
   public app release. Source publication does not imply a stable binary release.

The ranked list below predates betas 70–82. Consult the newer beta records before acting on it.

Updated 2026-10-14, ranked. Context, PR table and dead ends: [`HANDOFF.md`](HANDOFF.md). Every b59
change and its live-test recipe: [`BETA-59.md`](BETA-59.md). The August version of this list is
in `archive/docs-2026-08/`.

0. **2026-10-24, b71:** log in to AscensionXI with Daniel's own account (BETA-71 › Needs
   Daniel), then the next LandSandBoat worlds in [`LSB-SERVERS.md`](LSB-SERVERS.md) › Next, one at a
   time, each the way AscensionXI was done: read the world's own launcher, port its update steps,
   one throwaway-account Play to its login server.
1. **Daniel's live test of b59.** Install with `./app/bundle.sh /Applications` (builds, then swaps)
   only when no launcher, client or wine runs (it refuses otherwise). Then the "Needs Daniel's live
   test" lists in `BETA-59.md`: no update text while v3.9 is latest, footer/strip text, #27 window,
   Stop without beach-ball, x87 guard silent.
2. **x87 A/B on macOS 27.0.1**, local LSB, max settings: default (on) vs `FFXI_ON_MAC_X87=0`.
   Make the winner the default and write the numbers into `PERFORMANCE.md`.
3. **Merge #36 into master** once b58/b59 is confirmed playable; then open `beta-b59` as a PR.
4. **Fresh-user wine** (public blocker): rebase #20 as in HANDOFF, or state the limitation in the
   3.10 notes. Test in a scratch macOS user on local LSB.
5. **Outside PRs:** ask rdbell to accept the contributor licence (Daniel's OK to post). Then #23,
   #28; #17 after checking the canonical download page; close #24 (landed), #30, #31, #32; rebase
   #18, #19; #20/#21/#22 per HANDOFF (#21's sidecar must not replace ours).
6. **#35** (password off the command line): fix the flag and path, call `scrubLoginFiles`, test a
   login on local LSB before HorizonXI.
7. **Remaining A/Bs** from HANDOFF › Performance (`WINE_DISABLE_NX_COMPAT` is settled and on by
   default since b66; enforce-nx dll on top of it,
   `maxFrameLatency`, MVK concurrent compilation, Play-to-window time).
8. **b67 carry-over check** (`BETA-67.md` › Manual check): `--carryover-report` first, then a
   Setup into an empty folder; the carry-over line in launcher.log and the macros in game.
9. **Public 3.10** when the gates in `RELEASE-WHEN-STABLE.md` pass, at most weekly:
   `package.sh` → `publish-release.sh` (dry run, then `--yes` with Daniel's OK) → check
   `/releases/latest` → Daniel tests Restart with no game running.

Not worth time: everything in HANDOFF › "Measured dead ends". Measure the mechanism, not only the
fps; three runs each way, minimum.
