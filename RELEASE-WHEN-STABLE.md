# Standing instruction: ship an official release once the client is definitively stable

**From Daniel, 2026-08-17. This is a standing directive, not a one-off task.**

Whenever the HorizonXI-on-Mac client reaches a state that is *definitively stable*,
roll out an official release. Do not wait to be asked again — the ask has already been
made, permanently, right here.

## What "definitively stable" means
Not "it launched once." All of these, verified, not assumed:

- Client boots to the world reliably across several consecutive cold launches (no
  crash before addons load, no silent exit).
- Mouse works: cursor visible in-window, and addon/ImGui windows can be hovered and
  clicked. See `docs/MOUSE.md` — the click path still has an open rough edge
  (`io.MousePos` reading ImGui's -FLT_MAX sentinel) that must be closed first.
- No Wine window can end up unclosable (the `winedbg --auto` reaper is in the launch
  path; `scripts/quit-wine.sh` works).
- Frame rate holds at the project's max-settings target — never benchmark or ship with
  reduced effects, use `scripts/max.json` / `max4k.json`.
- A normal play session survives without needing manual intervention.

## What rolling out a release means
1. Confirm `/Applications/FFXI-on-Mac.app` is the single current build and is playable.
2. Archive every prior version/build out of the active tree first — keep exactly one
   current version live.
3. Fold the working fixes out of the diagnostic addon into their own proper addon.
   Right now the cursor fix and the shell->game command channel both live inside
   `mousediag`, which is a debug tool, not a shipping component.
4. Tag and cut a GitHub release with real notes covering what changed and what is
   still known-broken. Stability gates the release; a clock only caps it (Daniel,
   2026-08-22): the published .app is NOT re-cut for every fix — at most about once
   a week, and only once the build has been judged stable. Every criterion above
   verified fresh, plus several real play sessions on the current build without a
   single manual intervention. If a week passes and the tree is not stable, no
   release goes out — the cadence is a ceiling, never an obligation.
5. Say plainly in the notes what was verified and what wasn't. No "works" claims that
   were not actually tested.

## The local .app is a different thing from the release
`/Applications/FFXI-on-Mac.app` must stay playable at ALL times — Daniel plays on it
during development. It tracks the working tree: rebuild and reinstall it (`app/bundle.sh`,
then copy into `/Applications`) as soon as a fix lands, so his session is never stuck on a
stale build. Never replace the bundle while the launcher or a client is running; check
with `pgrep -fl "FFXI-on-Mac|horizon-loader|wine"` first and wait for an idle moment.

The GitHub release is the opposite: slow, gated, at most weekly. Fast local .app,
rare public release.

## Answering "where do we stand" in one command

```sh
scripts/release-check.sh
```

It reports and never acts: the installed .app's version and build date, whether any launcher
source is newer than it (so you know the local build is behind the tree), whether a client or
launcher is running (so you know a rebuild would be unsafe *right now*), the latest tag and
how many days and commits ago it was, and the human checklist above in short form. Nothing in
it builds, installs, tags or pushes, because every one of those is a decision.

Its git calls are on a ten-second leash. This repository lives in iCloud Drive, and when
iCloud evicts or re-downloads a pack file, git blocks in `mmap` for minutes — a status report
that hangs forever is worse than one that says "git did not answer".

**As of 2026-08-24 it says:** the installed app is v3.8 build 19 from 2026-08-22 with 22
launcher sources newer than it, a client was running so the bundle must not be touched, and
**there is no tag at all** — nothing has ever been released. So the first release is
outstanding rather than overdue: it is waiting on the checklist above, not on the clock.

## Why this note exists
This project has repeatedly reached a good state mid-session and then lost it to the
next round of experiments. Cutting a release at the stable point is what makes the
good state recoverable.

## Verified 2026-08-28 — window memory (PR #14)

Full drag-resize → exit → relaunch cycle on the local world: window dragged 642×390 → 902×583 pt,
exit via the Ashita close dialog, `lsb.ini` `0001/0002` (and `0037/0038`) rewritten 1280×720 →
1800×1106, next Play opened at exactly 902×583 with the UI rendered natively at that size
(not stretched). Local `/Applications/FFXI-on-Mac.app` now carries this build; prior build 21
archived in `archive/app-builds/`.
