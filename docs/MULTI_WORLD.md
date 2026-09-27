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

1. **Identity.** A running client is identified by its loader's `--server <host>` argument. The local world is `127.0.0.1`; HorizonXI is `play.horizonxi.com`. Add `LiveClients.scan()`, which returns `[host: [pid]]` by reading `pgrep -fl` for every loader name the launcher knows (`horizon-loader.exe`, `xiloader.exe`, `pol.exe`, `ffxi-bootmod`). Every PID check and every stop goes through it, filtered by host.
2. **The duplicate rule.** Add `allowsMultipleClients: Bool = false` to `Server`.
   - It is `true` only for the local world, which is Daniel's own server.
   - Any other server needs cited evidence from its published rules. Without it, the value stays `false`.
   - Launching a world whose host already has a live client is refused when the flag is false. The message says why and names the running PID.
3. **One session per world.** `Runner` becomes a per-world session, and a `Sessions` store keeps `[worldID: Runner]`.
   - The Play button, the log pane and Stop act on the selected world's session.
   - A small "Running" list shows every live world with its own Stop button.
   - `--play` from the command line checks the store *and* `LiveClients.scan()`, so a second launcher process cannot start a duplicate either. The rule is still one launcher process at a time.
4. **Shared-prefix safety.** When `LiveClients.scan()` is not empty:
   - **`RendererSetup.apply`** must not run `wineserver -k`. If the prefix already has the requested renderer, skip the step. If the renderer would change, refuse, with this message: "stop the other world first, the renderer cannot change under a running client".
   - **`stop`** terminates only this session's PIDs. `wineserver` is stopped only when no client is left.
   - **Addon prepare** only removes this world's load line from its own script. It never deletes an addon folder while another client is live. It still deletes the folder when nothing is running, so a strict allowlist world is never started with an excluded addon on disk.
5. **Per-world FPS log.** Default `FFXI_ON_MAC_FPSLOG_PATH` to `fps-<world>.csv`.
6. **Memory warning.** This Mac has 8 GB. Two clients plus LSB pushed HorizonXI to 0.4 fps on 2026-09-25/26. Before a second client starts, if swap is over 60% used or free memory is under 20%, show a warning. It does not block the launch.

## Tests

- **`--selftest-multiworld`** feeds `LiveClients.parse()` canned `pgrep` output. It checks:
  - host extraction;
  - the refusal when a duplicate world has `allowsMultipleClients == false`;
  - that the local world may run twice;
  - that addon prepare keeps folders while another host is live;
  - that the renderer step reports "skip" rather than "kill" when a client is live.
- **Live check on this Mac.** Start the local world, then HorizonXI; neither may die. Stop the local world; HorizonXI must keep running. Then try to start HorizonXI again; it must be refused.
