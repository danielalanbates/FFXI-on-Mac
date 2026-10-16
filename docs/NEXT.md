# What to do next

Updated 2026-10-14, ranked. Context, PR table and dead ends: [`HANDOFF.md`](HANDOFF.md). Every b59
change and its live-test recipe: [`BETA-59.md`](BETA-59.md). The August version of this list is
in `archive/docs-2026-08/`.

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
