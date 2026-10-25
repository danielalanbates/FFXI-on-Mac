# Beta 3.10 build 81 (local beta)

Copyright (c) 2026 Bates LLC. All rights reserved.

Branch `beta-b81`, from `beta-b80`. A local beta bundle is staged in Downloads. No public
GitHub release is part of this work. Licensing remains the
repository's [LICENSE](../LICENSE) and commercial-use rider; [batesai.org](https://batesai.org),
help@batesai.org.

## What changes

Beta 80 could refuse a second world because both clients shared one Windows registry, renderer
configuration and Wine synchronization mode. Its Sandbox exception also depended on launch order.
Beta 81 adds an optional Windows environment per world so different client installations can
start in either order, with each world's own settings.

| Choice or action | Behavior |
| --- | --- |
| **Enable multi-server play**, under the world title | Saved separately for each world; off by default, including older saved server lists. Selecting it creates nothing. |
| **Setup**, after selecting it | Creates the world's Windows environment beside the existing prefix on the same Wine-wrapper drive. About 1 GB per enabled world, plus 2 GB free headroom required there. |
| Existing client and Wine | Reused. Enabling this feature does not download or duplicate a game client. A world without game files still needs its ordinary client Setup. |
| More copies of one world | Share that world's environment. Its curated server-rule cap still counts clients across every prefix and launcher. |
| Uncheck the option | Returns future launches to the shared environment; keeps the separate environment for reuse. Changes wait for that world's client and setup work to finish. |

For order-independent play, enable and finish Setup for each world that needs its own Windows
configuration. This changes isolation, not server permissions or the Mac's memory capacity.
The same physical client folder still requires a matching renderer when several clients use it.

## Safety and remaining limits

- Registry, renderer and synchronization decisions use the target prefix. A process group is
  assigned only by agreeing positive evidence: the launcher's recorded group, readable
  `WINEPREFIX`, or a mapped wineserver socket folder. Missing, changing or conflicting evidence
  stays conservative; a matching login host alone never proves a prefix.
- The global launch lock still serializes launch decisions. Stop targets a session's group;
  a prefix's wineserver is stopped only after checking that prefix's remaining clients.
- Per-play file updates are skipped while the same game files are already in use, so another
  copy does not rewrite a playing client's files. Update normally after those clients exit.
- Renderer DLLs beside a shared client still have to match. Shared Wine runtime DLLs are not
  changed underneath running clients, even when those clients use other prefixes.
- Setup uses a hidden staging prefix and publishes a completion marker only after Wine exits
  successfully. Failed or cancelled preparation removes its own staging data. A process crash
  can leave a hidden `.prefix-multiserver-*.preparing-*` folder: verify that no wineserver uses
  that exact prefix before manually reclaiming it. Never remove the ordinary game prefix.
- **Move** excludes sibling Windows environments. After a move, use each enabled world's
  **Setup** to rebuild its environment beside the new wrapper. Existing game data is reused.

## Handoff and validation

The inherited checkout's Git links led into unavailable Google Drive placeholder metadata.
`~/Downloads/hxi-work/b81-wt` is an independent clone and the authoritative checkout for this
branch. Leave the old checkout as historical material. Build scratch is on the x10 external
drive because internal free space must be reserved for the user's download (requested target:
26 GB free); check free space before builds or installs and avoid duplicate build trees.

Validation, 2026-10-25:

- Optimized release build completed. With the installed Xcode toolchain, use
  `swift build --build-system native -c release -j 1 -Xswiftc -parse-as-library`
  and an external `--scratch-path`. The default Swift Build engine preallocated a 37 GB cache;
  that abandoned cache was removed. Native's library flag is needed for the existing companion's
  `@main` in `main.swift`.
- All **35 self-test suites passed**, including 13 transactional-prefix checks, 14 process-scope
  checks, 9 real launch-gate fixture checks and the existing world-cap tests. The first pass caught
  an overly long setup message; it was shortened and the final full pass passed.
- Packaged `~/Downloads/FFXI-on-Mac-build/b81-out/FFXI-on-Mac.app` (3.10 build 81);
  `codesign --verify --strict --deep` passed. Build/test logs remain on x10 under
  `FFXI/Launcher Development/b81`.
- The playable `/Applications` copy remains build 80 because HorizonXI is still running.
  Replace it with the staged bundle only after the game and launcher have exited. No automatic
  quit, reopen loop or installation watcher was created.
- No hosted-server addon testing, live simultaneous-client validation or fresh real-Wine prefix
  boot was performed. The prefix transaction tests inject a tiny boot fixture. Keep this as beta.

During development, two abandoned Google Drive partials totaling 19.17 GB were removed only
after stable size/mtime and closed-file checks. Browser, package and compiler caches were cleared;
older build bundles and launcher research were archived to x10 with their Downloads paths retained
as symlinks. The active Drive transfer was preserved. Its 25.0 GB file still consumes local space
as it hydrates; cache cleanup does not make its remaining allocation disappear.

The user is the beta tester. Next useful checks are:

1. Confirm the checkbox's saved state, explicit Setup, error recovery and off/on reuse.
2. On a permitted local setup, start two clients in both orders, stop one and confirm the
   other continues; repeat with distinct renderer/sync requirements and separate game folders.
3. Check an allowed same-world pair and a capped world's refusal, without bypassing its rules.
4. Have the user try their real world combinations and report the launcher log if a launch
   remains refused. Do not automate hosted logins or addon tests.

A public release still needs review, the completed validation record, stable real-use feedback
and the project's normal signing/notarization and release checks. Keep the local Applications
beta usable; update it only after the intended checks and when no affected client is running.
