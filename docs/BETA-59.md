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
- CFBundleVersion: bumped to 59 later in this beta, through the new `app/VERSION` (see Licence,
  notices, build safety).

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
  source or patch in the repo, so it cannot be rebuilt after the next macOS update (vendor/NOTICE.md
  now has its row, SHA-256 and this gap). Under `swift run` the sidecar dev fallback looks in `app/vendor/`, which does
  not exist (bundled app unaffected).

## Window text, Play-disabled reason, responsiveness

What changed
- **Why PLAY is grey, in one line** (footer, `PlayStatus.footer`): the missing drive by name, else
  "<world> not installed", else the first failing check ("… — see Setup & Diagnostics" only where
  the detail is there); "Updating Wine…" / "Updating HorizonXI…" / "Downloading <world>…" while the
  session is busy (`Runner.busyReason`); "Starting…" until the game window first appears (90 s
  fallback). Nothing when ready or playing: "ready to play", "game running", "setup incomplete"
  and the long starting text are gone.
- **Missing drive** (`Preflight.unavailableDrive`): a failing path that lives on, or passes through
  a symlink into, a `/Volumes/<Name>` that does not resolve gives "The '<Name>' drive isn't
  available — reconnect it or restart the Mac." The mount table is not consulted (today it lists
  `/Volumes/Games` while the path does not exist). The game-data card stays away then (Download
  would be the wrong answer).
- **Log strip**: only "!!" lines (refused login included), only while there are any, dismissible,
  cleared on Play. Everything else is launcher.log only: Setup & Diagnostics › **Open log**.
  Refusals the notice under PLAY already shows go to the file, not the strip.
- **Removed**: dead news banner and renderer banner; notes card ("Vana'diel on Apple Silicon",
  "Measured on this Mac…"; Wine prefix / Client rows moved into Setup & Diagnostics); "every other
  world" signup list; the 45-word "You do not need to do anything…" line on every HorizonXI Play;
  "Addon list saved" / "Graphics written" notices; local-server free-space line once built.
- **Moved / shortened**: account card only while no account is saved for the world (never local);
  Renderer picker + blurb into Setup & Diagnostics, Metal titled "Metal (DXVK)"; "N online"; era
  is a tooltip on the world row; status list in Setup & Diagnostics shows only non-OK checks
  ("All checks passed" otherwise); notices shortened per the review, non-error ones clear after
  5 s; long help texts shortened or made tooltips (Update HorizonXI… → "Downloads and applies the
  HorizonXI patch.", VanaVoice, Vanaguide, sound output, addons sheet, RetroAchievements, local
  server setup, choose wrapper, other launchers' pids).
- **HorizonXI update banner**: "HorizonXI <latest> available" + Update, only when the installed
  version (version.json) is known and older; unknown → nothing. Installed version read off the
  main actor in `recheckAsync`, not in `body`; the window's duplicate API fetch is gone
  (`ServerFeeds.horizonLatest`). Running-update line with Stop unchanged.
- **Era**: HorizonXI is "Treasures of Aht Urhgan · 75 cap" (was Chains of Promathia). Evidence,
  2026-10-14: horizonxi.com's bundle (`/assets/index-DnbLEafN.js`) has "Treasures of Aht Urhgan is
  live on HorizonXI", badge "Now Live", "Three new jobs, Assault, and the Near East are open",
  launch `2026-08-07T09:00:00-05:00`; 35 "Treasures of Aht Urhgan" vs 15 "Chains of Promathia"
  mentions. Contributor PR #24 said the same.
- **Responsiveness (#25)**: Stop's whole-Mac `ps` at the press runs detached (pids still decided on
  main); `wineserver -k`/`-w` runs detached while the launch lock is held, released when done, so a
  Play meanwhile gets "Busy — try Play again in a few seconds" instead of a beach-ball. Installer
  zip unpack (ditto) off main. `launch()` itself is unchanged and synchronous.
- **#27**: `applicationDidFinishLaunching`: policy `.regular`; 1 s after launch with no visible
  window, activate and send ourselves the reopen event a second `open -a` sends (bundle only);
  windows framed on no connected display are centred.
- **Quit alert** names the work: "Quit while updating Wine?" etc.; resume hint only for downloads.
- **Narrator** (from PR #32, narrowed): `Narration.terminateNarrator()` when the last client is gone,
  on Stop or natural exit, only if a launch this run started it. Never at launcher start.
- Tagline "FINAL FANTASY XI ON APPLE SILICON" kept: with the cards gone the hero column is title +
  "N online" over the backdrop; without the tagline it would be a lone title (not judged on
  screen, so kept as branding).

How it was verified
- `swift build -c release` before each of the 6 commits: clean, same 2 pre-existing capture
  warnings.
- New `--selftest-ui-text` (21 checks, all pass): drive detection (symlink, relative chain, plain
  `/Volumes` path, existing folder, missing file, loop), Preflight on a fake wrapper whose
  SquareEnix links to a missing drive, footer order/texts, error-only strip filter, quit question.
  Read-only on this Mac: HorizonXI's `…/SquareEnix/FINAL FANTASY XI` → "The 'Games' drive isn't
  available — reconnect it or restart the Mac."
- `--check` on this Mac: HorizonXI and Local server report the Games drive line; CatsEyeXI
  (`/Volumes/Games/FFXI/CatsEyeXI`) too; Gaia XI ok. All 15 `--selftest-*` pass.
- Nothing was launched: the window itself (layout, footer, strip, #27) is unverified on screen.

Needs Daniel's live test
- Open the launcher with the Games drive ghost-mounted: footer must read the Games-drive line;
  after reconnecting (or restart) and ↻, nothing in the footer and PLAY enabled.
- Window look: hero column with the cards gone (tagline kept?), Setup & Diagnostics with the
  renderer picker, Wine prefix/Client rows and Open log; account card absent for HorizonXI.
- #27 (local world only, no `--play` against a hosted world): quit the launcher, then
  `open -a /Applications/FFXI-on-Mac.app --args --world 'Local server'`; a window must appear within
  ~1 s. Then check `launcher.log` rotated.
- Stop on the local world: no beach-ball; Play pressed within a few seconds of Stop shows "Busy —
  try Play again in a few seconds", then works. VanaVoice (if narration was on) quits with the
  game, and does not quit while another client still plays.
- A refused login (wrong password, local world) appears once, in the strip, not twice.

Deferred, and why
- `launch()` async (#25 Play beach-ball): needs the in-game run to verify; the ordering inside
  launch is load-bearing. Pathway: on main keep `LaunchLock.acquire`, `running = true`, the
  `Runner.playing` entry and `loginFailure`/`current*`; then `await Task.detached { … }` for
  relinkStrayDylibs → RendererSetup.apply/GameRegistry.point → cleanStaleWineSockets → ini/Sandbox/
  Narration/Guide/CursorFix/AddonSuite/LuaJITGuard → stopWineserver → Detach.spawn +
  writePrivateDiagnostic, in the same order, collecting log lines; pass the lock fd through and
  keep it held; back on main set sessionGroup, the tail timer, gamePID and
  `LaunchLock.release(_:whenVisible:)`. Make `gate`/snapshot nonisolated; callers become
  `Task { if let why = await r.launch(…) { notice = why } }`. The previous commit's idempotent
  setup already removes most of that work on a normal Play.
- Auto-continue Play after the start-up Wine update (instead of "Updating Wine first — press Play
  again when it finishes"): touches the Play path; the footer now says "Updating Wine…" and PLAY
  re-enables when done.
- `ServerFeeds.bannerItems`/`items` are now unused (kept, no warning); delete when convenient.

## Licence, notices, build safety, privacy, docs

What changed
- **Licence, one story:** PolyForm Noncommercial 1.0.0 + 10% commercial rider everywhere
  (README said GPL-3.0, LICENSING.md said MIT). LICENSE line 1 is "FFXI on Mac (formerly
  HorizonXI-on-Mac)". LICENSING.md: history (GPL-3.0 08-08, Apache-2.0 and MIT 08-11, PolyForm
  from 08-22; earlier copies keep theirs), third-party table by what actually ships, in-repo not
  bundled: `addons/FFXIFriendList` GPL-3.0, `addons/gmtools` MIT, the LSB patch GPL-3.0. Wine
  corrected: CodeWeavers' wine source is LGPL, athei's wine-cx is built from it, we ship no wine.
  README footer carries the copyright line. Swift headers: 9 of ~50 files had one, so no mass
  edit; the one new Swift file carries it like its target's siblings.
- **Contributor licence** (CONTRIBUTING): contributors grant Bates LLC a perpetual, irrevocable,
  sublicensable licence, commercial licensing included. Needed before any rdbell PR merges.
- **Third-party notices:** `vendor/licenses/` = canonical upstream texts (d3d8to9 v1.15.1 BSD-3,
  DXVK v1.10.3 zlib, MoltenVK v1.4.2 Apache-2.0 (upstream has no NOTICE), cereal a56bad8 BSD-3
  (statically linked in MoltenVK), x87sidecar MIT moved from `vendor/x87sidecar-LICENSE`) + a
  README.txt index marking the modified binaries. `bundle.sh` copies them to
  `Contents/Resources/ThirdPartyNotices/` and LICENSE to `Contents/Resources/LICENSE`; `package.sh`
  adds `LICENSE.txt` and a combined `Third-Party Notices.txt` to the DMG. `vendor/NOTICE.md`
  rewritten to the tree: real dll name and patch (fencewait), coop row (3c7c2f6, 09-24), SHA-256 of
  every binary, entitlements (`cs.debugger` only), bundle.sh's real signing order; nofog gone.
- **bundle.sh safety:** output folder required (usage, exit 2). `/Applications` refused while
  `pgrep -f 'FFXI-on-Mac.app/Contents/MacOS|horizon-loader|Ashita-cli|wineserver'` matches,
  checked before the build and again before the swap. The replaced bundle is moved to
  `~/Downloads/FFXI-on-Mac-build/archive-apps/FFXI-on-Mac-<ver>-b<build>-<timestamp>.app`, not
  deleted (`HXI_ARCHIVE_DIR` overrides). Version from `app/VERSION` (`SHORT=3.9`, `BUILD=59`).
  Info.plist `HXIAddonRevisions` = Vanaguide/VanaVoice commits (`-dirty` if uncommitted).
- **package.sh:** refuses non-git or dirty vanaguide/vanavoice checkouts and a built plist without
  clean revisions; prints both for the release notes.
- **Install FFXI on Mac.command** called `bundle.sh` with no argument, then deleted the app it had
  just installed; now builds into `app/build`, refuses while the game runs, no Keychain claim.
- **Privacy:** VanaguideCompanion uses `CodeFolders` (no `GoogleDrive-<email>` path); login name
  out of Credentials.swift and two docs; `archive/catseye-account-2026-08-19` removed from the
  repo (identical copy in `~/Downloads/hxi-work/_private-archive/`); `addons/lsb2.ini` →
  `lsb2.ini.example` with `--pass CHANGE_ME` (nothing reads the repo copy: twoclient.py passes
  `lsb2.ini` to Ashita-cli, which reads the game's `config/boot/`); `.gitignore` adds `.env*`,
  `*api-key*`, `AuthKey_*.p8`, `*.p8`, `*.p12`, `*.pem`, `*.keychain-db`, `**/config/boot/*.ini|xml`,
  `addons/*.ini`, `last-spawn*.txt`, `**/cmdpipe/cmd.txt|chat.txt`, `imgui.ini`.
- **CONTRIBUTING** no longer claims the Keychain: passwords are in `accounts.json` (0600) and the
  boot `.ini`; Keychain migration listed as a pathway.
- **Docs:** `docs/HANDOFF.md` and `docs/NEXT.md` rewritten as a short current handoff (state,
  rules, release gates, PR triage, A/B list, dead ends, pathways); the August ones moved to
  `archive/docs-2026-08/`. README: 8.6 MB download, tested-on stack (macOS 27.0.1, athei wine-cx,
  DXVK 1.10.3 + MoltenVK 1.4.2), build commands; RELEASE-WHEN-STABLE install paragraph.

How it was verified
- `zsh -n` and `bash -n` on bundle.sh, package.sh and the Install .command.
- `bundle.sh` with no argument: usage, exit 2. The guard run on its own: target `/Applications`
  refused and listed the running launcher (pid 11511); a scratch target proceeds.
- Full `bundle.sh` twice into a scratch folder (`HXI_BINARY` = the release binary, `HXI_ADHOC=1`,
  scratch `HXI_ARCHIVE_DIR`): Info.plist 3.9 / 59, `plutil -lint` OK, `HXIAddonRevisions`
  e2c1609… / 29a8ec9…, ThirdPartyNotices (6 files) + LICENSE present, `codesign --verify --deep
  --strict` OK; the second run archived the first as `FFXI-on-Mac-3.9-b59-<timestamp>.app`. Both
  scratch bundles unregistered from Launch Services and deleted.
- package.sh's addon check on its own: clean siblings pass; untracked file → refused; non-git
  folder → refused. Revision check: 40-hex passes, `-dirty` refused. Notices concatenation on
  scratch copies: index + 5 texts. `package.sh` as a whole not run (signing + notarization).
- Upstream texts: d3d8to9 main == v1.15.1, cereal master == a56bad8, x87sidecar master == our
  copy; MoltenVK v1.4.2 NOTICE is 404; `nm` shows cereal, SPIRV-Cross and SPIRV-Tools symbols in
  the dylib.
- `git check-ignore` on a sample path per new pattern; `lsb2.ini.example` not ignored.
- `swift build -c release`: clean, same 2 pre-existing capture warnings.
- `VanaguideCompanion --selftest-parser`: finds the Drive vanaguide checkout through CodeFolders
  (the same folder the old hard-coded path named); 1 failure, "every real guide step has a zone,
  level, or tag": that checkout's guide content, same check and path as before. Not investigated.

Needs Daniel
- Nothing here touches Play. First real install: `./app/bundle.sh /Applications` with the launcher,
  game and wine quit; expect "archived the previous app to …/archive-apps/FFXI-on-Mac-3.9-b58-…"
  and exactly one app in /Applications.
- Decisions: character name "Murn" (README, ANNOUNCEMENT, FINDINGS, PATHWAYS, `docs/img/murn-*.png`);
  `/Users/daniel` paths in 37 tracked files; volume names in `X87Sidecar.swift`/`Install.swift`
  (live wine candidate paths, left alone); the login name inside the archived 2.7 app binary; the
  removed CatsEye scripts and earlier mentions still in git history. Rewriting history is
  `git filter-repo` + force push: irreversible, his call.
- Posting the contributor-licence request on rdbell's PRs (a GitHub write).

Deferred
- Game passwords into the Keychain (pathway in CONTRIBUTING/HANDOFF).
- Local `origin` still uses the old repo name (works through the redirect); not changed here.
- `archive/` keeps ~50 MB of old binaries.
- `CodeFolders` is duplicated in VanaguideCompanion; a shared library target would remove the
  copy but changes Package.swift for 12 lines.

## Review fixes: Play path, x87 guard, Stop, preflight refresh, window text

- **Stop ends the x87 check** (`Runner.stop`): a Stop near the one-minute mark killed the sidecar
  before the loader and recorded a false "didn't attach" for the macOS build + sidecar.
- **x87 guard, timing vs fingerprint**: the sidecar's own failure lines still record at once; "no
  sidecar a minute in" (timing, e.g. heavy swap) records only in two sessions in a row with the
  same fingerprint (`x87.suspectFor`, cleared when a session sees its sidecar alive). Reset by
  hand: also `defaults delete org.batesai.horizonxi-on-mac x87.suspectFor`.
- **Stop's wineserver wait** bounded at 30 s (`Runner.finishes`); the launch lock is always
  released. On timeout: "Wine didn't shut down — if the game won't start, restart the Mac."
- **Boot profile** read-modify-writes serialized (`Credentials.profileLock`): the off-main window
  size write could restore the previous account under a second client's launch.
- **Failed jobs say so**: Repair, HorizonXI update/download, retail install, installer, CatsEyeXI
  launcher add one "… failed — Open log in Setup & Diagnostics" line on a non-zero exit, unless
  stopped by the user or the job already printed its own "!!" reason.
- **Preflight reruns** on volume mount/unmount and on activation (≤ once per 5 s, never while a
  game is starting); a generation counter drops a slower, older result.
- **Play-time lines** are their own list, set only for a launch that started; cleared on game exit,
  world change, next Play, and when Low Power Mode / heat ends. World change clears `notice`; the
  forwarded-Play busy line clears after 5 s. The local-server line clears on game exit or when the
  local server is seen stopped.
- **RetroAchievements**: automatic and Play-time refresh failures go to launcher.log only.
- **--selftest-ui-text** removes its temp folder (the `defer` never ran before `exit`).

How it was verified: `swift build -c release` clean (same 2 capture warnings); all 15
`--selftest-*` pass (`--selftest-perf` 38 checks, 5 new: x87 suspect ×3, bounded wait,
`PlayCheck.stillTrue`); `--selftest-ui-text` leaves no `ffxi-uitext-*` folder; `--check` runs
(BAD only for the missing Games drive, as before). Nothing launched.

Needs Daniel's live test: unplug/replug a game drive with the launcher open (footer clears, PLAY
enables without ↻); Low Power Mode on → Play → line → turn it off → line goes; Stop the local
world, then Play within a few seconds (Busy, then works).
