# Live test: several worlds at once

Copyright (c) 2026 Bates LLC. All rights reserved.

The round-3 reviewer wrote this plan (2026-09-26) for one supervised run on the Mac. Run it before the multi-world launcher ships in a public release.

This is one supervised run with Daniel present. A player may be in game now: HorizonXI pids 57992 and 57994, and the old launcher is pid 57268.

0. Preparation (Daniel)
- In HorizonXI, type /shutdown and wait until `pgrep -fl horizon-loader` is empty. Never pkill a live client.
- Quit the old launcher with Cmd-Q, confirming no download is in flight.
- Check `pgrep -fl FFXI-on-Mac` is empty and `pgrep -x wineserver` is empty (allow about 5 s).

1. Install
- With Daniel's explicit OK, run app/bundle.sh from the multi-world branch.
- Archive the previous FFXI-on-Mac.app per the archive rule, so exactly one copy exists.
- `defaults read /Applications/FFXI-on-Mac.app/Contents/Info CFBundleIdentifier` should print org.batesai.horizonxi-on-mac.

2. Open one launcher
- Run `open -a /Applications/FFXI-on-Mac.app`.
- Check `cat ~/Library/Application\ Support/HorizonXI-on-Mac/instance/instance.lock` prints the launcher's pid (compare with `pgrep FFXI-on-Mac`).
- Check `lsof ~/Library/Application\ Support/HorizonXI-on-Mac/instance/instance.lock` shows only that pid.

3. Start the local world
- Select Local server and press Play.
- Log: "started detached, pid N, process group G".
- `ps -axo pid,pgid,command | grep -E '\.exe|sidecar|wineserver' | cut -c1-160`: the loader and sidecar are in group G with `--server 127.0.0.1`, and wine's services.exe and friends each lead their own group.
- Record the local pids and the wineserver pid.

4. Start HorizonXI alongside
- Record `stat -f %m` of pivot.ini and config/boot/horizonxi.ini.
- Select HorizonXI and press Play.
- The log should say "also running: 127.0.0.1 …" and "renderer: … already set up; left alone", with NO "wrapper wineserver stopped" line.
- The local client's pids and the wineserver pid are unchanged, and the local character still responds in game.
- HorizonXI appears in a new group G2 with --server play.horizonxi.com.
- The Running list shows exactly two worlds, each with a Stop button, and no services.exe or explorer.exe entries. A memory warning may appear; it must not block.

5. Duplicate from the UI
- Record the mtimes of pivot.ini and horizonxi.ini.
- With HorizonXI selected, press Play. It must be refused ("already running … another copy is refused").
- ps shows no new Ashita-cli.exe or injector, and both mtimes are unchanged (this checks fix 5).

6. Second launcher copy
- a. In Terminal: `/Applications/FFXI-on-Mac.app/Contents/MacOS/FFXI-on-Mac --world HorizonXI --play; echo rc=$?`. Expect about 1 s, stderr "already running (pid P); handed it the request (--world HorizonXI --play)", rc=0.
  - `pgrep -fl FFXI-on-Mac` still shows one process, and there is one Dock icon.
  - The holder's HorizonXI log shows "--play (handed over by another launch)" followed by a refusal, and no new injector appears.
  - Note whether the window came to the front (last finding).
- b. `open -n /Applications/FFXI-on-Mac.app`: the second process exits, leaving one Dock icon and no second window.
- c. Two at once: `for i in 1 2; do /Applications/FFXI-on-Mac.app/Contents/MacOS/FFXI-on-Mac --world HorizonXI --play & done; wait`. Both exit 0, there is still one launcher, and both requests are refused in the log.
- d. `ls ~/Library/Application\ Support/HorizonXI-on-Mac/instance/requests` is empty afterwards.

7. Self-tests beside the open launcher
- Run `/Applications/FFXI-on-Mac.app/Contents/MacOS/FFXI-on-Mac --selftest-multiworld` and `--selftest-single-instance`. Both print "all checks passed" with exit 0.
- No second window or Dock icon appears, and the pid in instance.lock is unchanged.
- The multiworld live line lists 127.0.0.1 and play.horizonxi.com only.

8. Stop one world
- Press Stop on Local server in the Running list.
- The log line "stopping Local server (pid …)" lists only pids from group G (compare with step 3).
- Within about 10 s the group-G pids are gone, while the HorizonXI pids are unchanged and the character still moves.
- The log says "wineserver left up: still running play.horizonxi.com …", and `pgrep -x wineserver` still shows the same pid.

9. Duplicate after the stop
- Press Play on HorizonXI again: refused.
- Terminal `--world HorizonXI --play`: exit 0 and refused in the log.
- Optional: Play Local again. It starts, and HorizonXI is undisturbed, with no "wrapper wineserver stopped" line.

10. Queued request with no window (demonstrates the first finding safely)
- Close the launcher window with the red button (the app stays running and the game keeps playing).
- Run `… --world HorizonXI --play` from Terminal: exit 0, nothing visible.
- Click the Dock icon. Watch whether the new window replays or acts on the queued --play. It must be refused because HorizonXI is running, and this confirms the finding.

11. Stale lock
- Cmd-Q the launcher, or with Daniel's OK `kill -9` the launcher pid only (never wine or loader pids). HorizonXI keeps running because it is detached.
- Reopen: the new pid is in instance.lock. HorizonXI is listed as started elsewhere, with no Stop button.
- `--world HorizonXI --play` from Terminal is forwarded and refused by the scan.

12. Finish
- In HorizonXI, /shutdown, then Stop any remaining session.
- After the last Stop, the log shows the wineserver being stopped, and within a few seconds `pgrep -x wineserver` and `ps | grep -E '\.exe'` are empty (wine's own services go with it).
- Exactly one launcher remains or none; no stray wine processes.
