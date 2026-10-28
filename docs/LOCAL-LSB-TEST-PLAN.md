# Isolated local gameplay test — readiness checked 2026-10-28

This is a preparation plan, **not a record of a completed gameplay test**. The readiness
inspection was read-only. No database, server, Wine process or client was started.

## What is available

| Component | Observed state |
| --- | --- |
| Local server | Existing `~/Games/lsb` resolves to the external FFXI volume. All four arm64 server binaries exist, and their referenced Homebrew libraries exist. |
| Database | MariaDB is installed; its stopped data directory is about 173 MiB and includes the existing `xidb` schema files. Database authentication, table health and character state have not been verified against a running copy. |
| Previous local run | The last map-server log records a successful October 2 startup with 300 zones. This is historical evidence only. |
| Runtime/client | Existing x86_64 Wine, Rosetta, Ashita, Horizon loader and FFXI payload are present. The old local boot profile passes the loopback endpoint check and selects `lsb.txt`. |
| Harness | `cmdpipe` and `autologin` exist in the shared install; its local script names guide, voice and autologin. VanaGuide, VanaVoice and the custom pointer file are currently absent there. A previous pointer source still exists outside the install. |
| Navigation | Local navmeshes include the San d'Oria zones, Selbina and Mhaura. The local `walkto.lua` command exists. |
| Current processes | No native LSB server, MariaDB or Windows `.exe` client was present during the inspection. Recheck immediately before any future launch. |
| Space | Approximately 13 GiB internal and 301 GiB external free. The old complete Wine prefix is about 5.3 GiB, so copying it wholesale into Downloads would breach the project's 8 GiB free-space floor. |

There is no demonstrated missing-binary blocker. A **private, bounded test environment still
needs preparation**. The existing shared game and database must stay unchanged. Missing
addons in the shared install are not permission to install them there for this test.

## Prepare under Downloads

Use one private `~/Downloads/ffxi-local-test-<date>/` directory, ignored by Git. Keep
credentials, registry copies, screenshots, dialogue and character data inside it. Do not
print loader arguments or credential-bearing configuration.

1. Copy the stopped MariaDB data directory into the lab. Start only that copy later, with
   an explicit private data directory, socket, PID file, error log and temporary directory.
   Bind TCP to `127.0.0.1`. Keep the original Homebrew database stopped. Confirm the copy's
   server version matches the installed binary before opening it; do not upgrade the original.
2. Make a private server working directory. Copy `settings/` and any writable modules or
   generated state; read-only source scripts, navmeshes and binaries can be symlinked from
   the existing checkout after checking their write behavior. The settings loader reads
   `./settings/` relative to the working directory. All logs and generated output belong
   in Downloads. Point the copied settings at the private database and bind every listener
   to loopback, including the map and HTTP listeners. Validate paths before launch.
3. Create a private Wine prefix with copied registry files and writable system/profile
   directories. Keep `drive_c/HorizonXI` as the game folder to preserve existing registry
   paths. Omit unrelated launchers, logs, screenshots, caches and backups. Audit copied
   `dosdevices` and user-directory links so Wine cannot write through them into the original
   prefix or the user's home directories. Never symlink a writable Wine directory.
4. Copy the loader, runtime DLLs, plugins and a minimal local boot configuration into that
   game folder. Copy the FFXI executables and writable game directories. Only verified static
   assets such as `ROM*`, `sound*` and movies may point back to the existing payload; keep
   `USER`, `TEMP`, screenshots, caches and logs private. Do not leave a `SquareEnix` symlink
   to the entire shared install, because it also exposes writable game directories.
5. Copy the current VanaGuide and VanaVoice addon sources plus `cmdpipe` and `autologin`
   into the private game. Install the verified custom pointer file only in this private
   config. Author one `lsb.ini`/`lsb.txt` pair carrying exactly one explicit
   `--server 127.0.0.1`; use only local test credentials and load only the required test
   addons. Preserve maximum graphics settings. Do not copy hosted boot scripts into the lab.
6. Measure actual prepared size and free space before proceeding. Aim for a roughly
   2–3 GiB filtered lab, but this estimate is unverified. Stop preparation before internal
   free space drops below 8 GiB. Do not reclaim space by deleting other projects or caches.

The fastest safe path reuses installed binaries and static assets. It does not need a new
server build, runtime migration, full game download or complete 5.3 GiB prefix copy.

## One bounded run

- Recheck that no hosted client, second local client, original database or LSB server runs.
  Check the required loopback ports before starting anything.
- Start the private database and the four server binaries **once**, recording their own PIDs
  and log paths. Avoid `scripts/lsb-server.sh start`: it automatically launches a persistent
  restart watchdog, and writes into the original root unless redirected. Do not create any
  watchdog or relaunch loop for this test.
- The existing map binary contains `--lazy` (development-only zone loading). It can reduce
  the cost of loading all 300 zones for a small local test; its behavior still needs checking
  in the copied environment. It is not evidence about launcher/game performance.
- Verify database authentication, schema health and a dedicated local character before
  launching the game. Do not assume `VG_CHARID=1` identifies the intended fixture. If fixture
  preparation needs GM/quest changes, make them only in the copied database.
- Start one private loopback client using `VG_GAME` pointed at its Downloads game folder.
  Run `tools/local_client_guard.py check <game>` and verify that its PID and working directory
  match. If the guard refuses, stop diagnosis there; do not weaken or bypass it.
- Choose two nearby, prerequisite-satisfied quests. Record `/vg target` and `/vg status`,
  capture the arrow before/after movement, talk to each NPC, record rendered dialogue and
  narration receipt, and confirm acceptance against the local server's quest flags.
  Follow the guide sequentially. Clearly label any teleport or GM-forced completion; neither
  proves that an actual quest route or completion objective was played through.
- A short existing `guided_run.sh` run tests teleport/dialogue/progression; `guided_walk.sh`
  additionally attempts walking but can fall back to teleport. Inspect its report to distinguish
  the two. Both require the verified local loader before commands and captures.
- Finish the client through `/shutdown`, confirm its normal exit, then stop only the test
  server and database processes recorded for this run. Never signal a game client. Leave the
  original shared prefix, boot profiles, addons, branding and database unchanged.

## Evidence required before claiming success

Capture the actual guide step, target, quest-acceptance flags, dialogue text, narrator receipt,
and screenshots for each sequential interaction. Verify audible speech at modest volume as
a separate check: a dialogue-log entry alone proves delivery, not successful sound output.
Keep identifying evidence local and publish only a sanitized result summary. The existing
offline suites are useful regression checks but do not substitute for this run.

Copyright © 2026 Bates LLC. All rights reserved. [batesai.org](https://batesai.org) · help@batesai.org.
