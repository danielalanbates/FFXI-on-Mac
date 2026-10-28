# Isolated local gameplay test — readiness checked 2026-10-28

The initial readiness inspection was read-only. A private lab was subsequently prepared and
a bounded login attempt, followed by one corrected launch that kept its parent session
alive, was made. **No sequential quest, arrow, live OCR or game-dialogue narration test has
passed.** See the live-test result below before repeating any startup instructions.

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

There is no demonstrated missing-binary blocker. A **private, bounded test environment is
now prepared under Downloads**. The existing shared game and database must stay unchanged. Missing
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
   in Downloads. Point copied settings and advertised addresses at the private loopback database/world.
   Verify actual sockets: this native server build still binds some listeners to wildcard
   addresses despite those settings. Use synthetic private fixtures, a loopback client and
   a bounded run; stop the owned server processes afterward. Do not claim settings alone
   restrict every listener. Validate paths before launch.
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
   2–3 GiB filtered lab (the prepared lab measured about 1.9 GiB). Stop preparation before internal
   free space drops below 8 GiB. Do not reclaim space by deleting other projects or caches.

The fastest safe path reuses installed binaries and static assets. It does not need a new
server build, runtime migration, full game download or complete 5.3 GiB prefix copy.

## One bounded run

- Recheck that no hosted client, second local client, original database or LSB server runs.
  Check the required loopback ports before starting anything.
- Start the private database and required server binaries **once**, recording their own PIDs
  and log paths. Avoid `scripts/lsb-server.sh start`: it automatically launches a persistent
  restart watchdog, and writes into the original root unless redirected. Do not create any
  watchdog or relaunch loop for this test.
- Keep short-lived launchers inside a held managed terminal session. Background children
  can disappear when the tool's parent shell exits; `nohup`/`disown` alone did not keep
  the first database attempt alive here. One client launcher followed by a blocking terminal
  `read` keeps its parent alive without an automatic retry or polling loop. Release that
  terminal only after verifying the actual game client has exited. The quest lab used
  connect/world/map, leaving the unneeded search service stopped.
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

## Live-test result and remaining blocker

The prepared Downloads lab retained about 11.5 GiB internal free space. Its private database
started as MariaDB 12.3.2 with 127 tables. A loopback application grant and one renamed
synthetic fixture were created **only in that copied database**. The game used the existing
patched `wine-coop`, unchanged copied D3D8/D3D9 binaries, the existing MoltenVK, NX compatibility
and cooperative x87 configuration. The custom pointer file was recovered unchanged from
local Git's `origin/ashita-signature-repair`, avoiding a stalled iCloud placeholder read.
No shared game/profile/database files were changed.

The loader authenticated to `127.0.0.1`; the local map server recorded the fixture entering
zone 230. On the corrected held launch the guard verified exactly one loopback loader in
the private game folder. Ashita's log showed Addons 4.20 loaded and the custom outgoing-packet
and key-item signatures resolving successfully. These facts do **not** prove a usable
in-world client.

Current guide/status commands were consumed from the private command file, but its chat
capture remained empty. The map later timed out and removed the fixture session. A read-only
socket/stack inspection found no map UDP socket and idle Cocoa/DXVK activity. A disconnect,
loading or error screen is a plausible explanation, not a visually confirmed diagnosis.
The `Unknowxx_x` client-version warning is nonfatal with the copied `VER_LOCK = 0`, so it is
not by itself a diagnosis. No quest acceptance or game-dialogue narration was demonstrated.

Standard guarded `/shutdown`, followed by the confirmed local GM `!release` and another
`/shutdown`, did not produce a verified normal client exit. After confirming zero fixture
database sessions and the exact private loader identity, a private-prefix `tasklist` identified
its Windows PID. A single `taskkill /PID <id>` request **without `/F` or `/T`** reported that
it sent a normal close message to that process's top-level windows. Full guard inventory then
confirmed zero game clients. This cleanup is separate from a successful in-game logout.

The held launcher was released after that exit. Only the recorded private native servers
were stopped, after checking their executable identity and working directory; the copied
database completed normal shutdown through its private socket. Private-prefix `wineserver -w`
returned normally. No client signal, forced task termination or wineserver kill was used.
The lab remains on disk for diagnosis; its test processes are stopped.

The native UI service was unavailable. No screenshot, focus action, blind key or guessed
packet was used. Future work should inspect the client's visible state and resolve the
missing current addon/chat response before attempting any quest run. Keep exact fixture
identifiers and private evidence in Downloads, outside Git.

## Evidence required before claiming success

Capture the actual guide step, target, quest-acceptance flags, dialogue text, narrator receipt,
and screenshots for each sequential interaction. Verify audible speech at modest volume as
a separate check: a dialogue-log entry alone proves delivery, not successful sound output.
Keep identifying evidence local and publish only a sanitized result summary. The existing
offline suites are useful regression checks but do not substitute for this run.

Copyright © 2026 Bates LLC. All rights reserved. [batesai.org](https://batesai.org) · help@batesai.org.

## Second live run — 2026-10-28 08:05, PASSED for located steps

Root cause of the first attempt's stall: the FFXI client binds fixed UDP port 54090, so the
second launch matched the first (dead) launch's map session and its old key; the server
then dropped it exactly 300 s (`MAX_TIME_LASTUPDATE`) after launch #1's session began.
Restarting the services and launching **once** produced a fresh session and a normal zone-in.

Using vanaguide `tools/guided_run.sh` against this lab: five located San d'Oria steps
traveled across zones 230/232, talked to the right NPC, wrote every dialogue line to the
narrator sink, and three quests reached **ACCEPTED** on the server (the other two are correctly
not flagged by talking). The arrow rendered. Details: vanaguide `docs/VERIFY-2026-10-28.md`.
Two harness bugs were fixed (same-instant sends; cmdpipe read/truncate race, PR #26).
`/shutdown` logged out normally once a stuck event was cleared with `!release`.
