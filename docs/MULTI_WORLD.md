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
   - Command lines are split quote-aware: wine quotes a program path with spaces, so `"Z:\Volumes\x10\Video Games\Eden\Ashita\injector.exe" eden.xml` is an injector with boot profile `eden.xml`. An unquoted Windows path with spaces (`Z:\…\Video Games\…\Ashita-cli.exe`) is rejoined. A Mac command that only mentions an .exe (a shell, `grep`, `echo`) is not a client.
   - **Any Windows program is live**, not only the named ones: `Credentials.fixBootLoader` can boot any .exe in `bootloader/`. A program that is neither a known loader or injector nor one of wine's own is a client with `other` set. wine's own are the ones read with `ps` under the live wineserver on 2026-09-26 (`services.exe`, `winedevice.exe` ×2, `plugplay.exe`, `svchost.exe`, `rpcss.exe`, `explorer.exe`, each `C:\windows\system32\…` and each its own group leader) plus the ones wine starts on demand and leaves running (`tabtip`, `conhost`, `start`, `winemenubuilder`). They are matched only under `C:\windows\` or with no folder, so a game's own `explorer.exe` still counts.
   - An `other` program counts for every "is anything live in the prefix" decision: `wineserver -k` at launch and at the last Stop, the renderer step, the sync mode, Repair/Update. Its world is known only if it was given `--server`, so without one it is not a duplicate, not in the Running list, and does not tell a session its loader has arrived. `ps` cannot tell which prefix a Windows program runs in (wine rewrites its command line and `ps -E` shows it no environment; measured), so an installer running in the installer prefix counts too. The cost is that a renderer change waits for it.
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
   - Every refusal runs before any shared client file (`pivot.ini`, the boot profile) is rewritten. `launchClient` runs the gate once for an early answer, but `Branding.apply` (pivot.ini) and `Credentials.apply` (the boot profile's account line) are handed to `Runner.launch` as `beforeLaunch` and run only after it holds `LaunchLock` and its gate has passed again. A launch refused there, because another launcher got in first, rewrites nothing.
4. **Shared-prefix safety.** When `LiveClients.scan()` is not empty:
   - **`RendererSetup.apply`** must not run `wineserver -k`. If the prefix already has the requested renderer, skip the step. If the renderer would change, refuse, with this message: "stop the other world first, the renderer cannot change under a running client".
   - **`stop`** terminates only this session's process group. Nothing is signalled unless it is provably still this session's (`MultiWorld.signalable`): a process running wine, the sidecar or a Windows program, in this session's group, or (no group) a loader of this session's host in no other session's group. `Runner.gamePID` is the injector's pid, which exits seconds after launch; it is cleared when the injector is gone and goes through the same check until then, so a pid the system has since handed to another program is never signalled. Before the SIGKILL eight seconds later, each pid is checked again to be the same wine process in the same group. `wineserver` is stopped only when no client or injector is left, no other session of this launcher is playing, and no launch holds the lock. That decision is made on the main actor, after the kill.
   - **Addon prepare** only removes this world's load line from its own script. It never deletes an addon folder while another client is live. It still deletes the folder when nothing is running, so a strict allowlist world is never started with an excluded addon on disk.
5. **One launcher.** Daniel's standing rule: never more than one copy of the launcher. `SingleInstance.enforce()` runs in `App.init`, right after `Headless.runIfAsked` and before any window, scan, log rotation or file of the game's.
   - The launcher is the process holding an flock on `Application Support/HorizonXI-on-Mac/instance/instance.lock` (close-on-exec, its pid written inside). flock is atomic, so of two launches started together exactly one gets it, and the kernel releases it when its holder exits or crashes.
   - A launch that cannot get it writes its request (`--world <name>`, `--play`; nothing else on the command line is forwarded) to `instance/requests/<uuid>.json`, mode 0600, through a temporary name and a rename. It posts the distributed notification `org.batesai.horizonxi-on-mac.request`, which carries nothing: the file is the request, and the holder reads only files in this user's own Application Support, owned by this user and private to them. It then waits up to 5 s for the holder to take (delete) the file, activates the holder and exits 0. If nobody takes it, it withdraws the request; it becomes the launcher if the holder has since quit, and otherwise exits 1 having done nothing.
   - The holder registers for the notification, polls the folder once a second in case one is lost, and drains it once at start-up, so a request written between the flock and the registration is not lost. A request older than 30 s is thrown away unread: a `--play` from a launch that gave up must not start a game minutes later. A taken request is queued. The window's start-up task first handles its own `--world`/`--play`, then the queue; later ones run as they arrive, one at a time. All go through `ContentView.handleCommand`, the same path as a launch's own `--play`: Sessions, the duplicate rule and every gate. With no window open, the queue waits until one opens.
   - A launcher from before this existed holds no lock. One is recognised by bundle id (`org.batesai.horizonxi-on-mac`) or executable path, if it started more than 5 s before this launch; a launch of this build that started at the same moment is left to the lock. Since it cannot take a request, this launch activates it and exits: 0 for a plain open, 1 when a `--play`/`--world` could not be handed over.
   - `--selftest-*` and `--check` are exempt. They open no window, touch nothing and exit in `Headless.runIfAsked`, and they must work while a launcher is open. An unknown `--selftest-` flag exits 2 there instead of falling through to a window.
   - With a single launcher process, the two-launcher scenarios from the reviews are closed: another launcher's injector-phase launch, a second `wineserver -k`, a Stop racing another launcher's launch. The cross-process guards (the scan, injectors' boot profiles, `LaunchLock`, the lock-then-scan order at the last Stop) stay as defence in depth. They still cover a client started by hand, an older launcher, and a request that arrives while a launch is under way.
6. **One sync mode per wineserver.** `WINEMSYNC`/`WINEESYNC` belong to the wineserver, and a client that disagrees with the running one exits at start-up. When a client is live, the launch reads the running wineserver's mode from its environment (`ps -E`, same user) and uses it. A world that must run with msync off (Gaia XI) is refused while the running wineserver has msync on.
7. **Per-world FPS log.** Default `FFXI_ON_MAC_FPSLOG_PATH` to `fps-<world>.csv`.
8. **Memory warning.** This Mac has 8 GB. Two clients plus LSB pushed HorizonXI to 0.4 fps on 2026-09-25/26. Before a second client starts, if swap is over 60% used or free memory is under 20%, show a warning. It does not block the launch.

## Tests

- **`--selftest-multiworld`** feeds `LiveClients.parse()` canned `ps` output. It checks:
  - host extraction, and that injectors count as live and carry their boot profile;
  - quote-aware parsing: quoted injector and loader paths with spaces (with a quoted `--server` and a quoted boot profile), an unquoted Windows path with spaces, and a Mac command that only mentions a quoted .exe;
  - that a loader under an unknown name is live for the wineserver, renderer and sync decisions but, without `--server`, is not a duplicate or in the Running list; that one given `--server` is that world's loader; that wine's own programs, as read from the live `ps`, are not clients; and that a game program sharing a wine program's name outside `C:\windows` still counts;
  - that Stop signals only this session's wine processes (never a reused pid, a non-wine process or another session's), with and without a group, and that the SIGKILL re-check refuses a pid that has changed;
  - that another launcher's injector for a capped world (a scan showing only it) refuses a duplicate, through `Runner.duplicateRefusal` reading a fixture boot profile, and that an unreadable one holds a capped world off;
  - the sync-mode read and decision, and that Repair/Update wait for clients, starting sessions and a held lock;
  - that a loader which left its spawn group is still found by host;
  - the refusal when a world is at its `maxClients`, including CatsEyeXI's cap of two;
  - that the local world may run twice;
  - that each of two local sessions sees only its own process group;
  - that the last Stop leaves the wineserver up while anything else holds the prefix;
  - that addon prepare keeps folders while another host is live;
  - that the renderer step reports "skip" rather than "kill" when a client is live.
- **`--selftest-single-instance`** runs in a temporary folder with a notification name of its own. The probes it starts are this binary with `--selftest-single-instance-probe`, so it never detects, talks to or disturbs a launcher that is open. It checks:
  - what is forwarded and what is exempt;
  - that the lock has one holder, which records its pid;
  - that a request is private, taken once and deleted, and that a stale or world-readable one is thrown away unread;
  - that a second launch forwards `--world`/`--play` to a running holder and exits 0;
  - that unanswered, it withdraws its request and exits 1 without taking over;
  - that of two launches started at once, exactly one becomes the launcher and takes the other's request.
  - Not covered by a self-test: recognising a pre-lock launcher by bundle id, since that would detect the real one. Neither is the window acting on a queued request, which needs the UI.
- **Live check on this Mac.** Start the local world, then HorizonXI; neither may die. Stop the local world; HorizonXI must keep running. Then try to start HorizonXI again; it must be refused.
