# Running several worlds at once

Copyright (c) 2026 Bates LLC. All rights reserved.

Daniel asked for this on 2026-09-26. Several *different* worlds can run side by side, for example HorizonXI plus the local LandSandBoat world. Two copies of the *same* world are allowed only when that server says duplicate accounts or multiboxing are allowed.

## Why the launcher cannot do it today

Every client shares one wine prefix (`prefix10`) and one game folder. The launcher was written for a single game, and six things break:

| Where | What it does now | What goes wrong with a second world |
|---|---|---|
| `Runner.running` / `busy` | One flag for the whole app. Play is disabled while any game runs. | You cannot start a second world. |
| `Runner.gamePIDs()` / `gameIsRunning()` | `pgrep -f horizon-loader.exe` | HorizonXI and the local world both run `horizon-loader.exe`, so they cannot be told apart. |
| `RendererSetup.apply` | Runs `wineserver -k` before writing renderer DLLs and registry. | Kills the client that is already running. |
| `Runner.stop` | Sends SIGTERM to the game, then `RendererSetup.stopWineserver`. | Stopping one world kills every world. |
| `Guide/Narration/CursorFix.prepare` | Deletes `addons/<name>` before a world whose allowlist excludes it. | Pulls Vanaguide, VanaVoice or winecursor out from under a client that has them loaded. On 2026-09-26 it also deleted the navigation grids. |
| FPS log | One `fps.csv` in the game folder. | Two clients write the same file. |

## Design

1. **Identity.** A running client's *world* is identified by its loader's `--server <host>` argument. The local world is `127.0.0.1`; HorizonXI is `play.horizonxi.com`. `LiveClients.snapshot()` reads `ps -axww -o pid=,pgid=,command=` and returns every loader the launcher knows (`horizon-loader.exe`, `xiloader.exe`, `pol.exe`, `ffxi-bootmod`) by host, plus Ashita's injectors (`Ashita-cli.exe`, `injector.exe`) under the unknown host, so a launch still injecting counts as live.
   - A running client's *session* is its process group. Everything one launch starts (injector, loader, x87 sidecar) keeps the group of the shell `Detach.spawn` ran it from; wine's own services each lead a group of their own. Measured 2026-09-26: loader and sidecar in group 57810, spawned pid 57812. Stop, the exit watcher and window memory act on that group only, whatever the loader is called. When the group could not be read, a session falls back to its host, minus other sessions' groups.
   - That the loader keeps its spawn group is measured, not guaranteed: wine could `setsid()` a detached child. So until a session's group has been seen holding a loader, the session also takes its host's new clients (not there at launch, not in another session's group). Once the group has held the loader, an empty group means the client exited.
2. **The duplicate rule.** `Server.maxClients` (default 1) caps how many clients of one world may run. `allowsMultipleClients` is `maxClients > 1`.
   - The local world, Daniel's own server, has no cap.
   - Any other server needs cited evidence from its published rules. CatsEyeXI's account rules allow two active characters per person, so its cap is 2.
   - A launch is refused when the world already has `maxClients` clients (counted by process group, so a sidecar is not a second client). Both the Host field and the `--server` the boot profile really carries are checked, and this launcher's own sessions count even while injecting. The message says why and names the running PID.
   - Another launcher process's launch is visible only to the scan, and for its first seconds only as an injector. An injector's command line names its boot profile (`Ashita-cli.exe horizonxi.ini`), and that profile's `--server` is the world it is starting, so injectors count toward the cap too. An injector whose world cannot be read that way, in no group of this launcher's and in no group that already shows a loader, holds off a capped world for those few seconds ("press Play again in a few seconds").
   - The PLAY/RUNNING button uses the same two keys (Host field and boot profile `--server`) for clients outside this window, so it agrees with the refusal.
3. **One session per world.** `Runner` becomes a per-world session, and a `Sessions` store keeps `[worldID: Runner]`.
   - The Play button, the log pane and Stop act on the selected world's session.
   - A small "Running" list shows every live world with its own Stop button.
   - `--play` from the command line checks the store *and* the process scan, so a second launcher process cannot start a duplicate either. The Running list also shows clients started outside this window, without a Stop button.
   - `LaunchLock` (an flock in Application Support, close-on-exec) is held from a launch's first check until a scan can see the spawned injector (at most 10 s), and while the last Stop decides to stop the wineserver. Until the injector exists no scan can see a launch, so without the lock a second launcher process could pass every check and run `wineserver -k` on it. Stop takes the lock *before* it scans, so a launch cannot finish and let go in between.
   - Repair and Update HorizonXI refuse while any client or injector is live, while any session of this window is playing, or while the lock is held; they then hold the lock until they finish, so no launch from any launcher starts under them.
   - Every refusal runs before any shared client file (`pivot.ini`, the boot profile) is rewritten.
4. **Shared-prefix safety.** When `LiveClients.scan()` is not empty:
   - **`RendererSetup.apply`** must not run `wineserver -k`. If the prefix already has the requested renderer, skip the step. If the renderer would change, refuse, with this message: "stop the other world first, the renderer cannot change under a running client".
   - **`stop`** terminates only this session's process group. `wineserver` is stopped only when no client or injector is left, no other session of this launcher is playing, and no launch holds the lock. That decision is made on the main actor, after the kill.
   - **Addon prepare** only removes this world's load line from its own script. It never deletes an addon folder while another client is live. It still deletes the folder when nothing is running, so a strict allowlist world is never started with an excluded addon on disk.
5. **One sync mode per wineserver.** `WINEMSYNC`/`WINEESYNC` belong to the wineserver, and a client that disagrees with the running one exits at start-up. When a client is live, the launch reads the running wineserver's mode from its environment (`ps -E`, same user) and uses it. A world that must run with msync off (Gaia XI) is refused while the running wineserver has msync on.
6. **Per-world FPS log.** Default `FFXI_ON_MAC_FPSLOG_PATH` to `fps-<world>.csv`.
7. **Memory warning.** This Mac has 8 GB. Two clients plus LSB pushed HorizonXI to 0.4 fps on 2026-09-25/26. Before a second client starts, if swap is over 60% used or free memory is under 20%, show a warning. It does not block the launch.

## Tests

- **`--selftest-multiworld`** feeds `LiveClients.parse()` canned `ps` output. It checks:
  - host extraction, and that injectors count as live and carry their boot profile;
  - that another launcher's injector for a capped world (a scan showing only it) refuses a duplicate, through `Runner.duplicateRefusal` reading a fixture boot profile, and that an unreadable one holds a capped world off;
  - the sync-mode read and decision, and that Repair/Update wait for clients, starting sessions and a held lock;
  - that a loader which left its spawn group is still found by host;
  - the refusal when a world is at its `maxClients`, including CatsEyeXI's cap of two;
  - that the local world may run twice;
  - that each of two local sessions sees only its own process group;
  - that the last Stop leaves the wineserver up while anything else holds the prefix;
  - that addon prepare keeps folders while another host is live;
  - that the renderer step reports "skip" rather than "kill" when a client is live.
- **Live check on this Mac.** Start the local world, then HorizonXI; neither may die. Stop the local world; HorizonXI must keep running. Then try to start HorizonXI again; it must be refused.
