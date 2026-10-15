# Beta 3.9 build 59 (local only)

Branch `beta-b59`, based on PR #36 (`quiet-wine-update`). Local beta: no GitHub release.

## Self-updater

What changed
- Silent until there is something to act on. Idle, checking, downloading, staging, offline and
  failed checks show nothing. One line only when: an update is downloaded, staged and verified
  ("Launcher X ready" + Restart); this copy can't replace itself, i.e. the bundle or its folder is
  not writable ("Launcher X available" + Download link to the release page); a Restart did not go
  through (one short reason, Restart still offered when the staged copy is good). Decided by
  enum cases (`Updater.State`, `RestartFailure`), not by message text. The old per-window
  progress bar and "Preparing update…" text are gone.
- One `Updater.shared` per process (was one per window).
- Cadence: at launch, every 6 h, and on activation only if the last check is >1 h old
  (`updater.lastCheck` in defaults). Skipped while any game client is live or a Runner job is in
  flight; retried 10 min later. Ad-hoc, `swift run` and other-team builds never check.
- Newer = (CFBundleShortVersionString, CFBundleVersion). The asset name carries the build
  (`FFXI-on-Mac-<version>-b<build>.dmg`); a legacy name (v3.9) compares short version only, so no
  3.9 build is ever offered v3.9. Tags must be `v1.2[.3]`; prereleases/drafts ignored.
- Verification (off the main actor): staged Info.plist read directly; version == tag, build ==
  asset build; `codesign --verify --strict --deep -R` with the pinned requirement
  `anchor apple generic and identifier "org.batesai.horizonxi-on-mac" and certificate
  leaf[subject.OU] = "MG4YW8XX2Z"`; `spctl -a -t execute` (notarized). The first download link
  must be https on github.com under the repo; every redirect must stay on GitHub's hosts; the
  dmg must match GitHub's sha256 digest. A release that fails verification is remembered
  (`updater.rejectedTag`) and never downloaded again until a different tag appears.
- No hangs: URLSession request 30 s / resource 15 min; hdiutil (read-only, stdin /dev/null),
  ditto, codesign, spctl all have deadlines; the state machine always returns.
- Restart: refused and disabled while a client is live (here or elsewhere) or Runner work is in
  flight; single in-flight (second press ignored). The helper is started detached
  (`Detach.spawn`), and the launcher quits only after the helper holds the update lock. If the
  quit is cancelled, the helper is called off (no surprise swap later).
- `apply-update.sh`: timestamped log in `~/Library/Application Support/HorizonXI-on-Mac/updates/
  apply-update.log`; mkdir lock with stale-lock takeover; EXIT trap puts the old app back and
  reopens it on ANY failure after the launcher quit, and leaves the reason for the reopened
  launcher ("Last update didn't install", reason in the tooltip); checks the folder is writable;
  same pinned requirement + spctl on the candidate; swap by two renames with rollback (never `mv`
  onto an existing folder); `touch` + `lsregister -f`; opens the new app; keeps exactly one
  previous copy (`updates/previous-<version>-b<build>.app`).
- Launcher-side log of each check's outcome: `updates/updater.log` (capped at 256 KB).
- `scripts/package.sh` names the image `FFXI-on-Mac-<version>-b<build>.dmg` from the built plist.
- New `scripts/publish-release.sh`: checks only, publishes only with `--yes`
  (see RELEASE-WHEN-STABLE.md, "Versioning and publishing").

How it was verified
- `swift build -c release`: clean, no new warnings (same 4 pre-existing ones).
- `--selftest-updater` (40 checks): the version/build table (3.9 b58 vs v3.9 → no; 3.9 b59 vs
  3.10-b60 → yes; 3.10 b65 vs 3.10-b64 → no; 3.10 b59 vs 3.10-b65 → yes, plus edges), asset and
  tag parsing, API-response fixture, rejected-tag memory (scratch defaults domain), URL/redirect
  host checks. All other existing `--selftest-*` still pass.
- `--selftest-updater --dmg <v3.9 dmg>`: real mount/copy/verify. v3.9 passes the pinned
  requirement and is rejected only by Gatekeeper (it is unnotarized), as expected; wrong tag and
  wrong build in the name are rejected; the temp work dir is left empty.
- `--selftest-updater --fetch`: live, read-only against GitHub: API → download through the
  redirect (release-assets.githubusercontent.com allowed by the guard) → digest match → staging
  verdict (v3.9: Gatekeeper rejection). A separate probe confirmed the session redirect delegate
  is consulted by async URLSession calls.
- `scripts/tests/apply-update-test.sh <notarized MG4YW8XX2Z app>` (DockFix.app as stand-in, temp
  folders, stubbed open/lsregister): success swap + one previous copy, wrong signer, live lock
  holder, stale lock, cancelled quit, read-only folder, new app fails to open → rollback.
  All 7 cases pass.
- `scripts/publish-release.sh` dry run on a renamed v3.9 image: fails correctly (not stapled,
  not notarized, not newer than v3.9, no updater self-test), superset check ok, nothing published.

Needs Daniel's live test
- Installed b59 with v3.9 still latest: the launcher must show no update text at all;
  `updates/updater.log` should say "up to date (latest is v3.9 …)".
- The actual Restart swap of `/Applications/FFXI-on-Mac.app` can only be exercised once a
  notarized release newer than the installed build exists (3.10). Unverified on macOS 27:
  whether App Management (TCC) lets the detached helper rename a bundle in /Applications. If it
  does not, the helper logs the error, restores and reopens the old launcher, which then shows
  "Last update didn't install" (reason in the tooltip, details in `apply-update.log`).
- CFBundleVersion is still 58 in `app/bundle.sh`; the b59 bump is not part of this change.
