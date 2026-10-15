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

## Performance and play-time checks

What changed
- **x87 sidecar on by default on every macOS** (`Runner.launch`, `X87Guard` in X87Sidecar.swift).
  #36's macOS 27 gate rested on the 2.98 fps run that X87-SIDECAR.md retracts (wrapped command +
  hand-set `ROSETTA_DISABLE_AOT`). Re-checked here: macOS 27 installed 09-15, 27.0.1 on 09-30
  (`softwareupdate --history`); in-world medians (rows >800 draws) with `ROSETTA_X87_PATH` set:
  09-25 37.9 (fps.csv), 09-26 51.2 (fps-local-server.csv, n=7370), 09-27 46.3 (n=31821), and
  09-26 22.7 on HorizonXI (fps.csv, the LSB-alongside stutter day). Stock Rosetta in-world was
  ~11 fps (August). `Server.x87` still wins per world; `FFXI_ON_MAC_X87=0` forces off, `=1`
  forces on past a recorded failure. The per-launch "macOS 27: x87 sidecar off" line is gone.
- **x87 guard, silent unless it fires.** Armed only when the patched wine launches with
  `ROSETTA_X87_PATH`. Fires on the sidecar's own failure lines in the client output
  (`[rosettax87] bootstrap_register2(`, `cooperative reply failed`, `Failed to attach`,
  `Failed to find Rosetta runtime…`, `Failed to locate translate_insn…`, `M2: failed…`; from
  `rosetta_loader/src/main.cpp`, each followed by the sidecar exiting), or when a minute after the
  loader appears no `x87sidecar…` process is left in the session (a cooperative sidecar lives
  exactly as long as its process). `cooperative handshake receive failed` alone does not fire:
  any i386 wine process that dies before its handshake prints it; the client's own case is caught
  by the missing sidecar. On firing: `x87.brokenFor = <kern.osversion>|<sidecar sha256>` in
  defaults, one line "x87 acceleration didn't attach — next launch uses standard Rosetta.", the
  running client untouched. Later launches skip `ROSETTA_X87_PATH` until the build or the
  sidecar changes. Reset by hand: `defaults delete org.batesai.horizonxi-on-mac x87.brokenFor`.
- **dxvk.conf reaches the client.** Bundled (`bundle.sh`), copied to
  `<prefix>/drive_c/dxvk-cache/dxvk.conf` only when it differs, `DXVK_CONFIG_FILE=C:\dxvk-cache\dxvk.conf`
  set beside `DXVK_STATE_CACHE_PATH`, recorded in last-spawn.txt. Contents = today's effective
  behaviour only (`dxvk.enableStateCache = True`); dead keys and the wrong "clean exit" comment
  removed. No change in what DXVK does until an A/B says so.
- **Play-time checks**, nothing when fine, one line when real, never blocking: Low Power Mode;
  memory with a single client too (same 60% swap / 20% free thresholds; for a lone client the swap
  clause also needs ≥4 GB swapped, because macOS sizes swap to fit: the idle Mac read 2.5 of 3 GB
  = 81% with 53% free today, and the collapses on record were at 4.6–6.7 GB); thermal
  serious/critical; a hosted world started while the local login server answers and no local
  client plays → one line + **Stop local server** (`LocalServer.stop`).
- **Less launcher work during play**: watch-loop `ps` off the main actor every 5 s (was 2 s on
  main; exit still two misses, ≤~7 s); user.reg and window-size write off main; output tail stops
  after the game exits; log strip coalesced to ≤4 updates/s and capped at 200 lines / 16 KB
  (launcher.log keeps everything); clients-elsewhere refresh 15 s (was 5 s), skipped while the
  window is occluded, refreshed when it reappears; timers hoisted out of `body`.
- **Idempotent pre-launch setup** (#25 Play beach-ball): user.reg parsed read-only (never
  rewritten); a `reg add`/`delete` runs only when the value differs; DLLs replaced only when
  different; MoltenVK link left alone when right; `stopWineserver` returns at once when pgrep finds
  no wineserver. `renderer:` lines only when something changed. Launch order unchanged.
- **Local world's "Low" preset**: 640×480 window, every quality value at max4K's (4096 textures,
  20 sound channels; was 1024 / 12).

How it was verified
- `swift build -c release` after every commit: clean; warnings down from 4 to the 2 pre-existing
  capture warnings (`import Combine` in App.swift cleared the other two).
- New `--selftest-perf` (33 checks, all pass): guard decision table and override, failure markers
  vs a normal session's output, fingerprint memory (scratch defaults domain), sidecar detection in
  a ps fixture (incl. a path with spaces; a grep/sh mention is not a sidecar), dxvk.conf contents /
  copy-once / replace-on-difference / env, play-time lines and memory thresholds, log-strip tail
  (200 lines, 16 KB, line start, multi-byte safe), lowSpec = max4K at 640×480, hive parsing.
- Read-only against this Mac's prefix10: Metal setup would write **no** registry values, and all
  six DXVK DLLs already match the bundle, so a normal Play now skips 4 `reg add`s and 3
  `wineserver -k`/`-w` pairs (10 osascript + wine starts under Rosetta) and 6 DLL copies.
- All existing `--selftest-*` pass. `--check` runs; HorizonXI/Local server show BAD only because
  `/Volumes/Games` (where `drive_c/HorizonXI/SquareEnix` links) is not mounted right now.

Needs Daniel's live test (local LSB only for any A/B; `/shutdown` between runs; check swap and
Low Power Mode first; `FFXI_ON_MAC_FPSLOG=1`, compare rows with >800 draws, same scene)
- **x87 A/B on 27.0.1** (nobody has measured it in-world since 09-27): quit the launcher with no
  game running, `open --env FFXI_ON_MAC_FPSLOG=1 -a /Applications/FFXI-on-Mac.app`, play the
  local world, `/shutdown`; then again with `--env FFXI_ON_MAC_X87=0`. While in-world,
  `ps -axo pid,command | grep [x]87sidecar-coop` must show a live sidecar in the x87 run. Also
  confirm no "x87 acceleration didn't attach" line appears and `defaults read
  org.batesai.horizonxi-on-mac x87.brokenFor` stays unset.
- **dxvk.conf took effect**: one launch with `--env DXVK_LOG_LEVEL=info`; the client's
  `*_d3d9.log` must show `Found config file: C:\dxvk-cache\dxvk.conf`.
- **`d3d9.maxFrameLatency = 1` A/B** (what every harness 4K measurement used, never on Play): add
  the line to `vendor/dxvk.conf` in a dev build (or hand-edit `drive_c/dxvk-cache/dxvk.conf`, which
  the next Play puts back), 3+ runs each, medians and ranges.
- Play beach-ball (#25) and launch time: cold Play to window, stopwatch, vs b58.
- Play-time lines: turn Low Power Mode on → one line; LSB running + Play HorizonXI → line + Stop
  button stops it; none of them on a normal Play.
- Not added, A/B candidates only: `MVK_CONFIG_SHOULD_MAXIMIZE_CONCURRENT_COMPILATION=1` (pipeline
  compile stalls, via Settings › extra environment), `WINE_DISABLE_NX_COMPAT` (FFXI exes are already
  NX_COMPAT, so low expectation), and whether the Keep-awake toggle (`LSAppNapIsDisabled` env) does
  anything (Activity Monitor App Nap column with the game occluded); it stays as is.
- Known gaps: the sidecar's macOS 27 build (`vendor/x87sidecar-coop`, 3c7c2f6, 09-24) has no
  source or patch in the repo, so it cannot be rebuilt after the next macOS update; vendor/NOTICE.md
  has no row for it. Under `swift run` the sidecar dev fallback looks in `app/vendor/`, which does
  not exist (bundled app unaffected).
