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

The v3.9 download is Developer ID signed but unnotarized: both its app and disk image fail
Gatekeeper with `source=Unnotarized Developer ID`. For the next public release, use
`HXI_SIGN_ID=<certificate SHA-1> ./scripts/package.sh <output-dir>` and require successful
app and disk-image notarization, stapling, and `spctl` acceptance before uploading the image.
`package.sh` must fail without the signing identity and leave an existing release image intact.
An unpublished 3.9 packaging preflight on 2026-10-02 passed Apple's app and disk-image
notarization, stapling, `codesign --verify --strict --deep`, and Gatekeeper checks, including the
app copied back out of the image. It lives only in Downloads under `horizonxi-work/release-audit/`;
the GitHub v3.9 asset remains the earlier unnotarized download. This checks the release pipeline,
not the gameplay stability gates above.

## The local .app is a different thing from the release
`/Applications/FFXI-on-Mac.app` must stay playable at ALL times — Daniel plays on it
during development. It tracks the working tree: rebuild and reinstall it
(`./app/bundle.sh /Applications`, version and build in `app/VERSION`) as soon as a fix lands, so
his session is never stuck on a stale build. Never replace the bundle while the launcher or a
client is running: `bundle.sh` refuses `/Applications` while
`pgrep -f 'FFXI-on-Mac.app/Contents/MacOS|horizon-loader|Ashita-cli|wineserver'` matches, and
moves the replaced bundle to `~/Downloads/FFXI-on-Mac-build/archive-apps/` (one live copy).

The GitHub release is the opposite: slow, gated, at most weekly. Fast local .app,
rare public release.

## Current source and safe handoff

The current GitHub project is `danielalanbates/FFXI-on-Mac`. Its Google Drive checkout is
`My Drive/Code/GitHub/FFXI-on-Mac`; the `HorizonXI-on-Mac` folders are older project history.
Use a worktree in Downloads for local builds, then push reviewed commits to the existing PR and
sync the Drive checkout. Keep beta bundles in Downloads until the running launcher and every game
client have exited. If a character is logged in, enter `/shutdown` in game chat and wait for the
client to exit before replacing `/Applications/FFXI-on-Mac.app`. Never kill a live game process to
make room for an install. Never test addons on hosted servers; use the local LandSandBoat world.

As of 2026-10-03 the Drive checkout's `.git/HEAD` is a File Provider placeholder
(`isDownloaded=0`), and reading it times out. Running Git there can silently
walk up to an unrelated repository in the home folder. Verify `git rev-parse
--show-toplevel` returns the Drive checkout before using it. Until its Git
metadata is available offline, the `quiet-wine-update` worktree in Downloads
and GitHub PR #36 are the authoritative branch state; do not treat a Git command
that reports the home folder as a successful Drive sync. Keep this checkout
pending rather than copying only source files into an unusable Git working tree.
An isolated 2026-10-03 attempt to request just `.git/HEAD` through macOS
`NSFileProviderManager` found the Google Drive item and domain but returned
`NSFileProviderErrorDomain -2001` ("The application cannot be used right now")
for both domain enumeration and the explicit download request. Its one-shot
source is archived in Downloads under `horizonxi-work/archive-local-test/`.
Use Finder's Google Drive **Available offline** action when the provider is
working, then verify `.git/HEAD` can be read before running Git in that folder.

The updater reads GitHub Releases, so branch commits and beta builds do not prompt public users
to restart. Cut a new release only after the stability checks above pass.

## Versioning and publishing (the updater depends on these)

- **The next public version is 3.10.** Every v3.9 client updates with v3.9's own updater, which
  compares the short version only (so a 3.9 build is never offered) and **ditto-merges** the new
  app over the old one. Every file in v3.9's `FFXI-on-Mac.app` must therefore still exist in the
  new app: a dropped file survives the merge outside the new signature's seal. Vanaguide files
  come from the sibling checkout, so a renamed guide file breaks this.
- Tag exactly `v<CFBundleShortVersionString>` (`v3.10`; never `v3.10.0`, `v3.10-rc1`). The asset
  is the one `.dmg` that `scripts/package.sh` names `FFXI-on-Mac-<version>-b<build>.dmg`. The
  updater compares (version, build) and accepts a staged app only if its version equals the tag
  and its CFBundleVersion equals the build in the name, it meets the pinned requirement
  (`anchor apple generic`, bundle id, team MG4YW8XX2Z) and Gatekeeper accepts it (notarized).
  A release that fails is remembered and never downloaded again until a new tag appears.
- Not a draft, not a prerelease: `/releases/latest` skips both.
- Publish only with `scripts/publish-release.sh <dmg> --notes <file> [--legacy-dmg <v3.9 dmg>]`.
  Without `--yes` it only checks and prints the `gh release create` it would run; with `--yes`
  it publishes and confirms `/releases/latest` serves exactly that asset. It checks the name,
  version and build, tag, newer-than-latest, signature, team, stapling and Gatekeeper on the
  image and the app, that the new app's own updater stages the image, and the v3.9 file-list
  superset (it downloads v3.9's image with `gh` when `--legacy-dmg` is not given; otherwise it
  prints a by-hand reminder).
- First line of the 3.10 notes: "Quit the game before pressing Restart." v3.9's Restart button
  does not check for a running game.
- Never create a repo named `HorizonXI-on-Mac`: v3.9 clients still ask that name and reach
  `FFXI-on-Mac` only through GitHub's rename redirect.

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
