# Beta 3.10 build 70 (local only)

Branch `beta-b70`, from `beta-b69` (5716690). Local beta: no GitHub release, nothing pushed, not
installed. Written while Daniel was playing; **built and self-tested 2026-10-17** with no game
running (release build, all 26 `--selftest-*` suites: 1014 checks, 0 failures). Nothing in it has
run in a game yet.

Launcher changes from the freeze on 2026-10-16 at 14:15 (§1-§4), and renderer and launcher changes
from the second freeze that evening (§5-§7):

- Wine programs left running by a Wine session that already died are ended
  ([below](#1-programs-of-a-wine-session-that-already-died)).
- The launcher notices when Wine dies under a running game, says so in one line, bounces the
  Dock icon, and the button becomes **Force Stop**
  ([Wine gone under the game](#2-wine-gone-under-the-game)).
- Stop is in the Dock menu and in a new **Game** menu
  ([Stop without the launcher window](#3-stop-without-the-launcher-window)).
- launcher.log gets a line when the Mac sleeps and when it wakes, and when the displays go off and
  on with the Mac awake ([Sleep and wake](#4-sleep-and-wake)).
- A GPU reset no longer freezes the game: MoltenVK keeps the device, and DXVK no longer deadlocks
  when the device is lost ([Graphics survive a GPU reset](#5-graphics-survive-a-gpu-reset)).
- Stop says **Stopping…** until the client is gone, which takes at most about 3 s, and asks
  nothing when the launcher knows the game is frozen
  ([Stop on a frozen game](#6-stop-on-a-frozen-game)).
- When the game's GPU device is lost, the button is **Stop** with one line under it, and the Dock
  icon bounces once ([Graphics gone under the game](#7-graphics-gone-under-the-game)).

The invisible in-game cursor reported the same day is a separate bug with its own write-up:
[`CURSOR-DXVK.md`](CURSOR-DXVK.md). Only the rebuilt DXVK DLL in §5 touches it: it carries the fix.

## What happened on 2026-10-16

Daniel: *"I closed my laptop and wine froze and crashed, and I couldn't close it."* Read back
from the Mac's own logs, read-only:

- **The lid did not cause it (verified).** At 14:15:40 the Crucial X10 Pro holding both
  `wine-coop` and `prefix10` dropped off USB, and it remounted at 14:15:42 (pmset `ExternalMedia`
  Released/Created; icdd `[Removed] [USB][CT4000X10PROSSD9]`). The lid closed at 15:41:57, 86
  minutes later.
- **The wineserver died at that moment (verified).** `wineserver-2026-10-16-141542.ips`:
  SIGBUS, `KERN_MEMORY_ERROR` inside its own mapped code, which had been paged out under 8 GB
  memory pressure and could not be read back from the vanished volume. `/Volumes/x10` is
  st_dev 0x1000016, the prefix's server folder is `server-1000016-d7c73b`.
- **The game froze then, at character select (verified before the lid; ~14:15:31 likely).**
  The 16:13 hang report: the game's main thread "last ran 6055 s ago", blocked behind more than
  ten threads in `_sigtramp`. xiloader's last line was "Receiving character list" at 14:15:30.
- **Its window could not be closed** (main thread blocked), and **the launcher said nothing**:
  its watch loop only checked that the loader pid existed, `didUnmount` only rechecked Play, and
  Stop was only in the launcher window, behind the game. Stop itself would have worked: it finds
  the session by process group, which needs no executable path.
- **Every other Wine program of that session kept spinning (verified).** Wine ends a client
  thread only when that thread touches the dead server socket; these sat in CFRunLoop and
  pthread waits. Their executables were on the revoked mount, so `proc_pidpath` failed and the
  existing cleanup (`Leftovers.serverless`) never counted them as this launcher's. It also gave up
  whenever any of this launcher's wineservers ran, never ran after a natural exit, and only ran
  while the launcher window was visible. At 16:37 Daniel's new session started right beside five
  of them (services, plugplay, explorer at ~95% CPU, svchost, rpcss).
- The drive has dropped like this four times this week (pmset Released/Created pairs on 10/11
  twice, 10/15, 10/16). No software can save a game whose Wine is on a drive that disconnects;
  what b70 changes is that the launcher now says so, offers one click out, and cleans up.

## 1. Programs of a Wine session that already died

`Leftovers.stale` / `staleInstance` / `endStale` (Leftovers.swift).

**The rule** (pure: `staleInstance`). One of wine's own programs (`LiveClients.wineSystemPrograms`,
recorded in `Snapshot.systemPrograms` when it is this launcher's wine's or its executable cannot
be read; another Wine install's is left out) is left from a dead session when all of these hold:

- it is this user's, and its parent is launchd (pid 1);
- no wineserver holds the prefix's server folder lock, or the one that does started more than
  60 s after it (`staleMargin`) on the wall clock *and* on the monotonic clock
  (`ri_proc_start_abstime`), so a clock stepped back cannot make a live session's programs look
  older than their server;
- it maps a file in that server folder (`/tmp/.wine-<uid>/server-<dev>-<ino>`; the kernel
  reports `/private/tmp/...`, both spellings match, by whole path components).

The lock is read the way wine itself asks (`kill_lock_owner`, server/request.c): `open(lock,
O_RDONLY|O_CLOEXEC)`, never `O_CREAT`, then `fcntl(F_GETLK)` for a write lock on byte 0, which only
reports and takes nothing (`lockOwner`; on the live session it returned WRLCK, pid 44464). The
lock counts as free only when F_GETLK says nobody holds it, or when the lock file and the socket
are both gone. Anything else is unreadable and decides nothing (`serverLock`): wine writes the
lock file once, at start, and macOS's `tmp_cleaner` (daily at 00:00) deletes files in /tmp
untouched for 3 days, so a session played for 4 days has its socket and no lock file; an `open`
can also fail for a moment (EMFILE, EINTR). Each folder's lock is read again after the walks, and
a program counts only where it has not changed.

The region walk (`PROC_PIDREGIONPATHINFO`, 778-3784 regions for a Wine program) is the last test
and only runs for a program that passed the others, always off the main actor. It runs at most
once for each process's life (`mapsFileOnce`, kept by pid and identity once the process is a
minute old), whatever the folders.

**Where it runs:**

- **Before Play** (`Runner.launch`, before `cleanStaleWineSockets`): `flagStale` with
  `lockHeld: true`, since the launch already holds the launch lock and a second `acquire` in the
  same process fails. The scan stops at 2 s (`staleEndLimit`) and is dropped unless it finished
  by then; the client starts either way. The signals and their 1.5 s grace go from a task of
  their own, so Play never waits for them.
- **After the game exits** (by itself or by Stop): 10 s after `==> game exited`, in its own task,
  only when no client is left on the Mac, no other session of this launcher plays, no job runs,
  and the session was not started again (`Runner.endStaleAfterExit`).
- **On each refresh** (`Sessions.refreshElsewhere`), now also while a game plays and its
  wineserver runs: the start-time test is what keeps a live session's programs out. With a game
  playing, a refresh costs a lock read per folder and an identity read per program (`procID`,
  two proc calls). A folder whose lock is free (one recorded from an earlier session, say) lets
  every program pass the cheap tests, but a program's regions are walked at most once for its
  life. The prefix is only `stat`ed when some program could be a dead session's at all. The old
  `serverless` path, `workInFlight` and `otherLauncherAlive` checks stay.
- **At spawn**, each session records its prefix's server folder (`Runner.serverDirs`) from the
  prefix's `stat`. If the drive comes back under another device number, the prefix gets a new
  folder; the old one is still looked in. If neither matches, nothing is ended (safe failure).

**Ending them** (`flagStale` → `signalStale`; `endStale` does both): the rule is run again under
the launch lock (taken unless Play already holds it; another holder means "not now"), and the
signals go after the lock is let go. Every pid is re-read right before every signal and must
have the same start time, owner and parent. One whose executable path can no longer be read gets
SIGKILL at once (it cannot run shutdown code; one winedevice ignored SIGTERM that day); the rest
get SIGTERM, then SIGKILL 1.5 s later. Every SIGKILL is remembered (`Leftovers.killed`): one stuck
in the kernel that outlives it is not flagged, signalled or logged again on every refresh. One
line in launcher.log: `i  ended N wine program(s) of a Wine session that had already died (pid
…)`. Nothing on screen.

`--leftovers-report` (read-only, safe during play) now also prints the server folder, who holds its
lock, every wine program and what the rule would end. A healthy session shows nothing to end.

## 2. Wine gone under the game

**In the watch loop** (`Runner.watchServer`, every 5 s tick): from 30 s after the loader appeared,
the holder of the session's server folder lock is read (`Leftovers.lockHolder`: one open, one
fcntl, one identity read) until one is found. That wineserver is kept on the Runner (the loop
restarts itself every 10 minutes, the state does not) and from then on it is asked as a process,
never the lock file again (`Leftovers.state`: one identity read). If no process has its pid any
more, or the one that has started at another time, while the loader is alive
(`MultiWorld.serverLost`), the session is marked once (`Runner.markServerLost`). A read that
fails while the pid is alive says nothing: a lock file deleted by `tmp_cleaner`, or an `open`
that failed for a moment, would otherwise have offered Force Stop on a healthy game.

- launcher.log: what was seen and when;
- the strip: `!! Wine stopped under the game at HH:MM:SS — the game drive may have disconnected.
  The game can't recover; press Force Stop.`;
- `NSApp.requestUserAttention(.criticalRequest)`: the Dock icon bounces while the frozen game is
  in front.

**On unmount** (`didUnmountNotification`, observed by the app delegate so it is seen with the
window closed → `Sessions.volumeGone`): each playing session keeps the realpaths of its prefix,
the wrapper's wine and the wine it plays with, read at spawn while they still resolve
(`Runner.spawnFacts`; an adopted session reads them in its watch loop). A volume
that is a path-component prefix of one of them (`MultiWorld.sessionsOnVolume`: `/Volumes/x1` is not
`/Volumes/x10`; `/Volumes/Games/FFXI/wine-coop` resolves into the x10) marks that session the same
way, naming the drive: `!! The 'x10' drive disconnected under the game at HH:MM:SS. The game
can't recover; press Force Stop.`

**Force Stop.** `PrimaryInputs.serverLost` turns the button into Force Stop (still destructive,
never on Return, ahead of "Starting…" and of Play Another). It skips the "Stop HorizonXI?" alert,
and `Runner.stop(force: true)` sends SIGKILL at once to exactly the processes Stop would signal
(`MultiWorld.signalable`: the session's process group), instead of SIGTERM and what follows it
(§6). The RUNNING list's Stop says Force Stop for a marked session too. The rest of Stop is
unchanged (the wineserver flush only when nothing else is left), and the after-exit cleanup above
then ends the dead session's Wine programs.

**Nothing is ended automatically.** The standing rule is never to close a game Daniel is playing;
a banner, a bouncing icon and one click are enough.

## 3. Stop without the launcher window

- **Dock menu** (`LauncherDelegate.applicationDockMenu`): one item per playing session of this
  launcher, "Stop HorizonXI", or "Force Stop HorizonXI" once marked. No alert, as in the RUNNING
  list.
- **Game menu** (`GameCommands`, `CommandMenu("Game")`): the same items while the launcher is in
  front; a disabled "Stop" when nothing plays. No keyboard shortcut: Stop is never one key away.
- In both, a session whose Stop is under way is a disabled "Stopping HorizonXI…" (§6).
- **Sessions live for the whole process** (`Sessions.shared`, like `Updater.shared`; the window,
  both menus and the delegate use it). Before, they were the window's `@StateObject`: closing the
  window (the app keeps running) released them with their Stop and their watch loops, exactly
  when the Dock menu's Stop is needed.
- The RUNNING list hides the session the main button acts on (`runner.session`), not the world's
  first session: Force Stop can be the button of a second client ("Local server #2").
- Nothing for a client another launcher started (`MultiWorld.stopItems` takes only this
  launcher's playing sessions).

## 4. Sleep and wake

`NSWorkspace` `willSleep` / `didWake`, registered in `applicationDidFinishLaunching`:

    i  sleep at 15:41:57 with HorizonXI
    i  wake at 16:07:02 after 25 min

(`Runner.sleepLine` / `wakeLine`; 24-hour time to the second, as `pmset -g log` prints it.) On wake
each playing session's server check runs straight away (`Runner.checkServerNow`) instead of
waiting for the next tick. Logging only: sleep is never held up or delayed, `IOAllowPowerChange` is not
involved, and no game is stopped for it.

**Displays off and on with the Mac awake** (`NSWorkspace` `screensDidSleep` / `screensDidWake`,
same place):

    i  display off at HH:MM:SS with HorizonXI
    i  display on at HH:MM:SS with HorizonXI

(`Runner.displayLine`.) The 21:31 freeze came with the lid closed on AC: a display sleep from
20:13 to 22:10 with the Mac awake, so `willSleep` never fired and launcher.log had nothing for it.
Lines only: nothing is checked, ended or bounced when the displays come back.

## 5. Graphics survive a GPU reset

**The second freeze, 2026-10-16 21:31 (verified from source, the game log and a `sample`).** The
lid was closed and the Mac awake on AC. A Metal GPU recovery failed one of the game's command
buffers ("Discarded (victim of GPU error/recovery)"). Then:

- **MoltenVK 1.4.2 marked the VkDevice lost for good.** The error lands in the default branch of
  `MVKQueue.mm:220-258`, where `markDeviceLoss = !resumeLostDevice`, and the default is 0.
  After that every submit, fence wait, acquire and swap-chain creation fails, and nothing clears
  the state.
- **DXVK 1.10.3 then deadlocked itself.**
  - The submit thread logged "Command submission failed" and called `waitForIdle()` while
    holding the queue's `m_mutex`.
  - `waitForIdle` → `lockSubmission` → `synchronize` locks the same non-recursive lock and waits
    for the entry being handled to leave the queue.
- **Every D3D9 path blocked behind it.** dxvk-submit, dxvk-queue, dxvk-cs and the first Windows
  thread sat in `futex_wait` for 311 of 311 samples.
  - The game stopped pumping window messages, so neither closing the window nor Quit did anything.
  - The game log's last line is "Command submission failed". The submit thread's own
    `waitForIdle` never logged, which is what the deadlock predicts.
  - The busy `NtDelayExecution` thread in the sample is the pivot's sound lookups, not DXVK.
- **What caused the GPU reset is unknown.** The unified log from 21:30:30 to 21:32 has no GPU,
  AGX or IOGPU entries.

**Fix 1, MoltenVK (the main one): `MVK_CONFIG_RESUME_LOST_DEVICE=1`** in every client's
environment (`PerfSettings.environment`). It is in `Runner.spawnDiagnosticKeys`, so
`last-spawn.txt` shows it.

- **The name is right for 1.4.2.** Checked in its source (tag v1.4.2 = db66022):
  - `MVKConfigMembers.def:80` has `RESUME_LOST_DEVICE`;
  - `MVKEnvironment.cpp:110-111` reads `MVK_CONFIG_RESUME_LOST_DEVICE` as a number;
  - `MVKEnvironment.h:293-294` defaults it to 0;
  - the vendored `libMoltenVK-1.4.2.dylib` contains the name.
- **With it set:**
  - An error that leaves the physical GPU usable is logged and the device stays usable. The
    failed buffer's fence is still signalled (`finish()` runs from the completion handler
    whatever the status), so DXVK never sees the failure. One frame of GPU work is lost.
  - A GPU that is removed, blacklisted or no longer permitted is still fatal.
- MoltenVK's "Resumed VkDevice…" warning needs `MVK_CONFIG_LOG_LEVEL=2`. The launcher runs 1, so
  a resumed reset leaves no line in the game log.
- `MVK_CONFIG_RESUME_LOST_DEVICE=` (or `=0`) in Extra environment turns it off, like any other
  default.

**Fix 2, DXVK: a lost device no longer freezes the game.** This is for a real loss, which
MoltenVK still reports. It is in the fencewait patch, which builds the shipped DLL. The hunks are
described in `patches/README.md`, "One upstream bug, fixed our own way":

- the submit thread no longer waits for idle;
- every command list, refused ones too, is retired exactly once;
- one `waitForIdle` runs from the retirement thread, which holds no lock;
- after the loss, `Present` returns `D3D_OK` within ~16 ms.

The picture freezes; the game keeps running, so its window, Quit and Stop work normally. The game
log gets one line through `Logger::err`, which the launcher's `DXVK_LOG_LEVEL=error` keeps:
`horizonxi: GPU device lost; drawing stopped, the game keeps running so it can be closed`.

**How the hunks were reviewed** (against v1.10.3 with the patch applied, and MoltenVK 1.4.2's
source):

- **No self-deadlock is left.**
  - No thread calls `waitForIdle` while holding `m_mutex`.
  - The retirement thread's one wait needs the submit queue to drain. After a loss the submit
    thread only refuses entries, and the CS thread's `submit()` stops at the queue bound, so the
    queue does drain.
- **Each command list is retired exactly once.** Every list goes through the finish queue once:
  submitted ones as before, refused ones now too. Each gets `notifyObjects`, `m_pending -= 1`,
  the `m_finishCond` notify, `reset` and recycle.
  - `DxvkSubmitEntry` is value-initialised, so `submitResult` is `VK_SUCCESS` unless a submit
    failed.
  - Before this, a refused list never fired its frame-latency signal and never released its
    resources. Locks and presents waited for it forever, and `m_pending` never fell, which also
    stopped the implicit flushes.
- **Nothing still on the GPU is freed.**
  - Whatever the retirement thread sees first as a loss gets the one `waitForIdle`. That can be
    its own fence wait, `m_lastError` set by the submit thread, or a refused entry, and it comes
    before any lost list is reset.
  - MoltenVK's `vkDeviceWaitIdle` commits an empty command buffer on the same queue and waits for
    it (`MVKQueue.mm` `waitIdle`). Metal runs a queue's buffers in order, so everything submitted
    before has finished.
  - After the loss MoltenVK refuses every submit (`MVKQueue::submit` returns the device's result
    first), and DXVK stops submitting, so nothing reaches the GPU after that wait.
- **A failed submit that is not a loss** waits at most 2 s on its fence. MoltenVK 1.4.2 still
  submits such a batch, "to ensure submission semaphores and fences are signalled". If the wait
  times out, the failure takes the old log-and-`waitForIdle` path, from the retirement thread.
- **`Present` after the loss** takes the device lock only inside `Flush()`. The CS thread cannot
  stall it for long, because the finish queue now drains. The readback fence wait on a lost
  device returns at once from `vkWaitForFences` and falls back to the normal wait, which returns
  once the lists are retired.
- **One caveat, harmless with MoltenVK.** `PresentImage` bumps `m_frameId` before the acquire
  loop. The new early return there skips that frame's latency signal.
  - If acquire later succeeded, the next `SyncFrameLatency` would wait for a signal that never
    comes.
  - MoltenVK's acquire returns `VK_ERROR_DEVICE_LOST` only for a lost device
    (`MVKSwapchain.mm:83`), and a lost device stays lost, so that frame never comes. Revisit if
    the MoltenVK version changes.
- Upstream v2.3 (5d119673, checked in an upstream clone) also stopped calling `waitForIdle` on
  `DEVICE_LOST` in the submit thread.

**The rebuilt DLL** (`patches/README.md` has the commands and the SHA table):

- **The recipe reproduces b69's DLL.** b69's patch (5716690) on a fresh v1.10.3 clone, with
  `SOURCE_DATE_EPOCH=1787269764`, gives b69's 3,403,776 bytes. Only the export directory's time
  stamp and the PE checksum differ.
- **The b70 DLL** is `70ba5664…`, from the full patch:
  - b69's patches, the cursor fix and the device-lost fix;
  - same size, same imports, same export count;
  - `strings` finds the cursor fix's and the device-lost fix's log strings in it, and in
    neither b69's DLL nor the baseline.
- **Shipped as** `vendor/dxvk-1.10.3-x32-d3d9-horizonxi.dll`. `vendor/NOTICE.md` is updated.
  `RendererSetup` replaces any `d3d9.dll` whose bytes differ on the next Play, so existing
  installs pick it up.

**Tests:** `--selftest-perf` +1. Every client gets `MVK_CONFIG_RESUME_LOST_DEVICE=1`, under the
game's Wine and the wrapper's, and `last-spawn.txt` records it.

**Not verified:**

- **No GPU reset was reproduced.** There is no safe way to force a Metal GPU recovery. Neither
  fix has run in a game.
- **That FFXI keeps drawing correctly after a resumed reset.** A texture upload in the dropped
  buffer could leave a wrong texture until the client rewrites it.
- **The DXVK hunks' runtime behaviour after a loss.** There is no device-loss injection harness.
  They are checked by reading and by compiling only.
- **That `vkDeviceWaitIdle` returns on a GPU that is really gone.** If Metal never completes the
  empty buffer, the retirement thread waits, and the CS thread and `Present` block once the queue
  bound is reached.
- **The cursor probe and the A/B in `CURSOR-DXVK.md`.** `cursorprobe.c` compiles (no warnings)
  but needs Wine.
- The launcher now watches the game's output for both lines: §7.

## 6. Stop on a frozen game

At 21:31 every Stop path would have ended the client: SIGTERM kills it outright, since CrossOver's
ntdll installs no SIGTERM handler and neither does the x87 sidecar with its sampler off (read in
the Wine source and the sidecar's). The gaps were around it: the main Stop asked first, the button
said Stop for up to 7 s after the client was gone (a 5 s tick plus a 2 s second look), and a client
that ignored SIGTERM waited 8 s for SIGKILL.

**Stopping…** (`Runner.stoppingGame`) from the click until the session ends:

- on the main button (disabled; ahead of Force Stop, the graphics line, "Starting…" and Play
  Another), on the RUNNING row (disabled), and in the Dock and Game menus ("Stopping HorizonXI…",
  disabled);
- the watch loop looks every 0.5 s instead of every 5 s, and takes its second look 0.5 s on
  instead of 2 s, so Play is back about a second after the client ends;
- App Nap is held off (`beginActivity(.userInitiatedAllowingIdleSystemSleep)`): the launcher sits
  behind the game, where macOS stretches its timers;
- 10 s on (`stopGiveUp`) with the client still there: one launcher.log line, Stop is offered
  again, and it asks nothing (`stopOutlived`).

**The signals** (`Runner.escalateStop`; signals, liveness, scans and sleeps all injectable):

1. SIGTERM to each pid Stop may signal (`MultiWorld.signalable`: the session's process group).
   Up to 1.5 s for all of them to go.
2. If any is left, SIGINT then SIGCONT to the session's wineserver: what `wineserver -k` sends. The
   server then ends every client of the prefix in order and SIGKILLs what is left about 0.5 s later
   (server/request.c, signal.c, process.c). Up to 1.5 s more. Only when
   `MultiWorld.mayInterruptServer` allows it, because that server serves every world in the prefix:
   - every client on the Mac is one of this session's pids;
   - no other session of this launcher plays;
   - the launch lock is free (taken here and held until the signals are done, so no Play starts
     against the dying server);
   - the process holding the session's server folder lock is a wineserver in the scan, and the
     one first seen holding it, if one was.

   On this Wine it adds no killing power over SIGKILL; it takes the prefix down in order.
3. If any is left, SIGKILL to each pid that is still the same wine process in the same group
   (`stillSignalable`, read again).

That is at most 3 s of waiting, and usually none. Force Stop sends SIGKILL to each and nothing
else. Every signal after the SIGTERMs goes to launcher.log, for example
`i  HorizonXI: SIGTERM was not enough: INT 44464, CONT 44464`. The rest of Stop is unchanged: 1 s
on, the wineserver flush under the launch lock if nothing is left.

**No question** when the launcher knows there is nothing to save:

- Wine gone under the game (Force Stop, §2);
- the graphics gone (§7);
- a client that outlived a Stop the player already confirmed.

A game the launcher believes is healthy still asks "Stop HorizonXI?": that guards against a stray
click. A hang the launcher cannot see therefore costs one extra click. The Dock menu, the Game menu
and the RUNNING row never asked.

## 7. Graphics gone under the game

MoltenVK never un-loses a VkDevice (§5) and the b70 DXVK latches the loss, so a client whose device
is lost can never draw again. There is no recovery line to wait for. With §5's MoltenVK setting, a
GPU reset that MoltenVK rides out prints nothing at the launcher's log level; what still prints is
a real loss.

**The lines** (`LoaderOutput.renderEvents`), read from whole lines of the game's output (after
`RepeatCap`, where a line's first time always passes) and matched by how the line starts:

- `[mvk-error] … Lost VkDevice after MTLCommandBuffer …` (MoltenVK);
- an `err:` line naming `VK_ERROR_DEVICE_LOST` (DXVK's "Failed to sync fence" and "Command
  submission failed");
- `err:   horizonxi: GPU device lost; …` (the b70 DXVK, printed once).

On 2026-10-16 at 21:31, three of the four lines matched; "waitForIdle: Operation failed" alone
does not. MoltenVK's `[mvk-warn] … Resumed VkDevice …` (log level 2 only) and a chat line that
names the error match nothing.

**What happens** (`Runner.noteRender`). The first loss of a session goes to launcher.log at once:
`i  HorizonXI: the game's GPU device was lost at 21:31:07; it can't draw again`. 2 s later
(`renderGrace`, so a burst of lines settles into one; App Nap is held off for those 2 s):

- the main button is **Stop**, enabled and destructive (never on Return), ahead of "Starting…" and
  Play Another, with one line under it: `The game's graphics stopped at 21:31:07 — press Stop.`
  (53 characters);
- the Dock icon bounces once (`.informationalRequest`);
- Stop asks nothing (§6).

With Wine also gone, Force Stop comes first and the strip's "!!" line says it. Nothing is ended
automatically, nothing says "restart", and Play is never greyed out.

**Not for an adopted session.** A client an earlier launcher run started is adopted without its
output file, so its loss is not seen. Its Stop works as always.

## Kill safety

What b70 can end, and why nothing else:

- **Automatically, only wine's own programs** (services, explorer, winedevice, plugplay, svchost,
  rpcss and the on-demand ones in `wineSystemPrograms`). Never a loader, an injector, the x87
  sidecar or any other Windows program: they are not in `Snapshot.systemPrograms`. Never by name
  and never with `pkill`/`killall`; never `wineserver -k` from any cleanup path.
- **Only of a session whose wineserver is gone.** A Wine client connects to its wineserver once,
  at start, and never reconnects; a wineserver kills its programs when it exits. So a program
  that started more than a minute before the server now holding its prefix, or whose prefix no
  server holds, belongs to a server that no longer exists and can serve nothing. A live session's
  programs started after their server and fail the test.
- **Only of this prefix.** The program must map a file in this prefix's server folder. Another
  prefix maps another folder. Another Wine install's programs (CrossOver, Whisky, XIV on Mac) are
  left out of the scan while their executable reads, and map another folder in any case. Another
  user's processes fail the uid test; anything with a live parent fails the ppid test.
- **Never a reused pid.** Identity (start time to the microsecond, uid, ppid) is re-read right
  before every signal, SIGTERM and SIGKILL alike.
- **Decided under the launch lock.** No launch or Stop's wineserver flush is under way while the
  rule is decided; another holder means the cleanup waits for its next turn. The signals, each
  pinned to the identity read then, may land after the lock is released (Play's go from a task
  of their own).
- **Never on a guess about the lock.** A lock that could not be read, or a missing lock file
  beside a socket, decides nothing; only F_GETLK saying "unlocked", or no lock file and no
  socket, counts as free.
- **A loader is ended only by the player's Stop or Force Stop**, and Force Stop signals exactly
  the set Stop always did (the session's process group). Other worlds' clients are never touched.
- **Stop's wineserver step (§6) is Stop's, never a cleanup's**, and only when every client on the
  Mac is the session's own, no other session plays, no launch is under way (the launch lock is
  held for it) and the server is the one the session started with. A pid gets SIGKILL only while
  it is still the same wine process in the same group.
- **Read-only checks only, during play:** the lock read opens the file read-only, never creates
  it, and `F_GETLK` takes no lock. The region walk reads another process's memory map, nothing
  more.

## Tests

**Run 2026-10-17** (release build, no game running, one suite at a time): all 26 suites exit 0,
989 checks, 0 failures (leftovers 55, multiworld 88, primary-action 80, ui-text 42, perf 64 with
§5's check). launcher.log was untouched (same inode, mtime and size before and after).

**Run again 2026-10-17 with §6, §7 and the display lines**, the same way: all 26 suites exit 0,
1014 checks, 0 failures (leftovers 64, multiworld 89, primary-action 87, ui-text 49, perf 65).
launcher.log untouched. One full run before it had 2 `--selftest-updater` checks fail ("probe ran
with the helper's five arguments", "its PATH is the fixed one": the probe's output not seen within
its 15 s). Nothing in b70 touches that suite; it passed in three runs on its own and in the full run
after.

All pure or injected; no process is scanned for real except where noted, nothing is signalled.
The one process started is the lock probe, which ends when its stdin is closed.

`--selftest-leftovers` (+26; the 29 existing checks are unchanged):

- wine's own programs are all listed, readable path or not; only the live session's are this wine's
- another Wine install's programs (path readable, not this wine) are not listed at all
- 2026-10-16 16:39: exactly the dead session's five programs (started 1792175493-97) are flagged
  beside the live session (wineserver 44464 started 1792193859, programs 1792193860 on)
- 16:25, no wineserver, the lock free: the same five, which the old rule never saw; never the frozen loader
- one that maps no file of this prefix's server folder is never flagged
- nor another user's, nor one with a live parent, nor one started within a minute of the wineserver
- started a minute before the wineserver by both clocks, or not flagged (a clock stepped back)
- nothing decided when the lock's holder or the process cannot be read
- a live session's program fails before its regions are walked
- nothing flagged when the folder's lock changed during the scan, nor past Play's deadline
- a pid that is another process by the time of the signal is never signalled
- SIGTERM, then SIGKILL for one still the same process after the grace
- no SIGKILL for one whose pid went to another process during the grace
- SIGKILL at once, no SIGTERM, for one whose executable's drive went away (each SIGKILL remembered)
- a program already sent SIGKILL is not flagged again; the others still are
- the launcher.log line
- inside a folder by whole path components, `/tmp` and `/private/tmp` alike
- `mapsFile`, on a file this process maps under a scratch folder in `/tmp`: found, spelled `/tmp`
  or `/private/tmp`; not under a sibling folder, nor under `/tmp/x` beside `/tmp/x2`
- `mapsFileOnce`: walked once and kept for a process a minute old; a younger one is walked again
- `lockOwner`: no lock file and no socket is free (the file is never created), and so is a lock
  nobody holds
- a missing lock file beside a socket is unreadable, never free
- a lock another process holds (this binary as a stand-in wineserver, `--selftest-lock-probe`,
  F_SETLK on byte 0 until its stdin closes) names that pid, reads as held with its identity, and
  under it only a program started before it is flagged
- once that holder has exited (as a crashed wineserver), the same lock is free
- a prefix's server folder is named from its `stat`; none for a prefix that is not there
- `procID` of the test process itself: its owner, its parent, a start time in the past on both
  clocks

`--selftest-multiworld` (+14): a session playing beside a dead session's programs (only those
flagged, never a loader or the sidecar); the drive back under another device number (found through
the recorded folder, nothing without it); `endStale` with the launch lock held by another holder
(scans and signals nothing), Play's `flagStale` holding it (goes ahead), `endStale` once it is free
(goes ahead), with no folder (nothing); `serverLost` with `Leftovers.state` (gone with the loader
alive; another process under its pid counts as gone; a read that fails while the pid lives says
nothing; not while the same one runs, not once the loader is gone, not when none was ever seen);
`sessionsOnVolume` (x10 holds the session; `/Volumes/x1` and `/Volumes/x10 2` do not; the Games
volume's `wine-coop` link resolves into the x10, on a temporary folder); the Dock and Game menu
items (Stop / Force Stop per playing session, nothing when idle, none for an idle session; a
client elsewhere gets none by construction, since the items come from `live` alone).

`--selftest-primary-action` (+3): Force Stop is enabled, destructive (never on Return) and has no
reason line; it comes ahead of "Starting…" and of Play Another; a lost server with nothing running
here leaves Play. "Force Stop" joins `Primary.verbs`.

`--selftest-ui-text` (+3): both Force Stop lines word for word, one line each, no "restart", and
they reach the strip as errors; the sleep and wake lines (time to the second, sessions, minutes).

These add 46 checks to b69's 942 (26 suites), and §5 adds 1: 989, as run.

§6, §7 and the display lines add 25 (1014):

- `--selftest-leftovers` (+9): `escalateStop` on 2026-10-16's pids (loader 44487 and sidecar 44489
  in group 44470, wineserver 44464), with every signal and sleep injected:
  - a client SIGTERM ends: SIGTERM only, nothing waited;
  - one that outlives it: SIGINT + SIGCONT to the wineserver after 1.5 s, which ends it;
  - one that outlives both: SIGKILL to each, 3.0 s in all;
  - the wineserver step not allowed: SIGTERM, then SIGKILL after 1.5 s;
  - Force Stop: SIGKILL only, nothing waited;
  - no SIGKILL for a pid now in another group, nor for one no longer a wine process;
  - `mayInterruptServer`: allowed with only this session's clients live, with the server first seen
    or none seen yet; never with another world's client, another session playing, a launch under
    way, a server started at another time, or no server read.
- `--selftest-multiworld` (+1): a session whose Stop is under way is a disabled "Stopping …" in the
  menus, even once its Wine is gone.
- `--selftest-primary-action` (+7): Stopping… (disabled, no line), ahead of Force Stop, the graphics
  line, Starting… and Play Another; the graphics gone: Stop (not Force Stop), enabled, destructive,
  with its line, ahead of Starting… and Play Another; with Wine gone too, Force Stop with no line;
  either flag with nothing running here leaves Play. The existing checks (72 characters, no jargon,
  no "restart", the label set, only Stop off Return) cover the new states.
- `--selftest-ui-text` (+7): the display lines; the 2026-10-16 lines give three losses; each line
  shape alone gives one, the b70 DXVK's own too; MoltenVK's "Resumed", a chat line naming the
  error, `info:` and `warn:` lines give nothing; a line split across two reads counts once, on the
  read that ends it; the line under Stop word for word, at most 72 characters, no "restart"; said
  at 2 s and not at 1.9 s, never without a loss.
- `--selftest-perf` (+1): `last-spawn.txt` records `FFXI_GAMEWINDOW_HANG` (gamewindow.dylib's
  hung-game question; the dylib side is a later part).

## Not verified

- **Nothing has run outside the self-tests.** The release build compiles (two warnings, both in
  older code: LocalServer.swift:251, Runner.swift:2198) and every suite passes; no part of it has
  been seen in the app or in a game.
- That `--leftovers-report` lists nothing to end during a healthy session (read-only, safe to run
  during play).
- That the Dock menu reaches the launcher's delegate through SwiftUI's
  `NSApplicationDelegateAdaptor` (it does for `applicationShouldHandleReopen` today), and that it
  and the Game menu still work with the window closed.
- That `ri_proc_start_abstime` matches `pbi_start_tvsec` in order on a live process, and that
  `MemoryLayout<proc_regionwithpathinfo>.size` is what the kernel expects (only the in-process
  `mapsFile` checks would catch that).
- Whether `didUnmountNotification` fires for a drive that is pulled rather than ejected.
- That the server check catches the next real drop within ~10 s. On 2026-10-16 the wineserver
  died because its pages had been paged out; one that survives a drop is only caught by the
  unmount path.
- That a normal Play followed by an exit or a Stop logs no "already died" line (Wine's own
  shutdown takes ~3 s; the after-exit cleanup waits 10 s and needs the launch lock, which a
  Stop's wineserver flush holds).
- The sleep and wake lines against `pmset -g log` on a real lid close, and that
  `screensDidSleepNotification` fires for a lid closed on AC.
- **§6 has not run.** That SIGTERM ends a hung client in practice, the escalation's timings, and
  that the wineserver step does what wine's source says: only the injected self-test covers them.
  Nor whether App Nap really stretched the launcher's timers behind the game, or that the activity
  stops it.
- "Stopping…", the disabled menu items and the line under Stop have not been seen in the app.
- **§7 has not run.** The MoltenVK line and the two stock DXVK lines are the ones 2026-10-16 left
  in launcher.log. The b70 DXVK's line is known only from its source; it goes through
  `Logger::err`, assumed to print the same `err:   ` start as the stock lines.
- The line under Stop shows only while that session's world is the one selected in the window.
  The Dock bounce does not depend on it.

## Checks to run (never on the x10, never on HorizonXI, never while Daniel plays)

1. ~~Build in a scratch folder and run all 26 `--selftest-*` suites with no game running.~~ Done
   2026-10-17: 989 checks, 0 failures.
2. `--leftovers-report` during a healthy session: "would end: []".
3. A scratch DMG with a throwaway prefix: run a trivial wine program from it, then
   `hdiutil detach -force`. Expect the "!!" line within ~10 s, the Dock icon bouncing, Force Stop
   ending the program in one click, and the cleanup ending the rest ("already died" line). This
   also shows whether `didUnmount` fires for a forced detach.
4. On a local LSB world client, with no HorizonXI client running (§6's wineserver step ends
   every client of the prefix), `kill -STOP` its loader to fake a freeze. Dock › Stop must:
   - end only that session's group within about 3.5 s;
   - show "Stopping…" on the button and in the Dock menu meanwhile;
   - leave a "SIGTERM was not enough" line in launcher.log, since a stopped process holds its
     SIGTERM.
5. Lid closed for 2 minutes with the local world running: two lines whose times match
   `pmset -g log`. On AC with the Mac kept awake, the display off and on lines instead.
6. §7 without a GPU reset, on a local LSB world client: append
   `err:   horizonxi: GPU device lost; test` to that session's output file
   (`$TMPDIR/ffxi-on-mac-game-<launcher pid>-Local-server.log`, the file the launcher tails).
   Within about 2.5 s expect launcher.log's loss line, Stop with "The game's graphics stopped at
   …" under it, one Dock bounce (with the launcher behind), and a Stop that asks nothing.

## Deviations from the plan

- `dockItems(live:)` is `MultiWorld.stopItems(_:)`, used by both menus through
  `Sessions.stopItems`.
- The plan's weak `Sessions.shared` is a strong, process-lifetime one that the window uses too
  (review: a weak one died with the window).
- The sleep and wake lines carry the time (`sleep at HH:MM:SS with …`), since launcher.log lines
  have no timestamps of their own and the plan's check compares them with `pmset`.
- `serverLost` watches the wineserver first seen holding the lock, as a process, while the
  session's *loader* is alive (the watch loop already stops once none of the session's pids is
  left). The plan read the lock every tick; a lock read that fails is not "gone".
- Force Stop also comes ahead of "Starting…" and of Play Another, so a second client is never
  started beside a frozen one.
- The before-Play scan runs on a worker thread that Play waits on for at most 2 s (as the DXVK
  cache warm does); the scan stops there too, and its signals go from a detached task.
- `endStale` sends its signals after letting go of the launch lock (the rule is decided under it,
  every signal is pinned to the identity read then), so a Play pressed during its 1.5 s grace is
  not refused as "Busy".
- Recorded folders (`Runner.serverDirs`) are never dropped: with each process walked once, a
  kept folder costs one lock read per refresh, and dropping one could forget the folder of a
  session that is still starting.
- The unmount check moved from the window to the app delegate, beside sleep and wake.
- §7 has no recovery line and no "HXI: device recovered" contract (understand-1's proposal):
  MoltenVK never un-loses a device. The grace is 2 s, from a task of its own, not 10 s on the
  watch loop's tick. The Dock bounce is the one-time kind (`.informationalRequest`), where the
  proposal had `.criticalRequest`.
- §6: the Dock and Game menus show a disabled "Stopping …" for a session whose Stop is under way,
  where the proposal dropped it from the menus. Force Stop returns straight after its SIGKILLs
  (the proposal waited 1.5 s and could send a second SIGKILL). The wineserver step also requires
  the lock holder to be a wineserver in the scan. A client that outlived a confirmed Stop is not
  asked about again (`stopOutlived`, not in the proposal).
- The after-exit cleanup looks only in the folders recorded at spawn (no `stat` of a drive that
  may just have gone).
