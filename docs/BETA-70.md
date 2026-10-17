# Beta 3.10 build 70 (local only)

Branch `beta-b70`, from `beta-b69` (5716690). Local beta: no GitHub release, nothing pushed, not
installed. **Written while Daniel was playing: nothing in it has been compiled or run yet.** The
only check so far is `swiftc -parse` (syntax) on every changed Swift file; the build and the
self-tests below wait until no game runs.

Four launcher changes, all from the freeze on 2026-10-16:

- Wine programs left running by a Wine session that already died are ended
  ([below](#1-programs-of-a-wine-session-that-already-died)).
- The launcher notices when Wine dies under a running game, says so in one line, bounces the
  Dock icon, and the button becomes **Force Stop**
  ([Wine gone under the game](#2-wine-gone-under-the-game)).
- Stop is in the Dock menu and in a new **Game** menu
  ([Stop without the launcher window](#3-stop-without-the-launcher-window)).
- launcher.log gets a line when the Mac sleeps and when it wakes ([Sleep and wake](#4-sleep-and-wake)).

The invisible in-game cursor reported the same day is a separate bug with its own write-up:
[`CURSOR-DXVK.md`](CURSOR-DXVK.md). Nothing below touches it.

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
(`MultiWorld.signalable`: the session's process group), instead of SIGTERM and up to 8 s. The
RUNNING list's Stop says Force Stop for a marked session too. The rest of Stop is unchanged (the
wineserver step only when nothing else is left), and the after-exit cleanup above then ends the
dead session's Wine programs.

**Nothing is ended automatically.** The standing rule is never to close a game Daniel is playing;
a banner, a bouncing icon and one click are enough.

## 3. Stop without the launcher window

- **Dock menu** (`LauncherDelegate.applicationDockMenu`): one item per playing session of this
  launcher, "Stop HorizonXI", or "Force Stop HorizonXI" once marked. No alert, as in the RUNNING
  list.
- **Game menu** (`GameCommands`, `CommandMenu("Game")`): the same items while the launcher is in
  front; a disabled "Stop" when nothing plays. No keyboard shortcut: Stop is never one key away.
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
- **Read-only checks only, during play:** the lock read opens the file read-only, never creates
  it, and `F_GETLK` takes no lock. The region walk reads another process's memory map, nothing
  more.

## Tests (added; not run yet)

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

These add 46 checks to b69's 942 (26 suites): expect 988, to be run once built, with no game
running.

## Not verified

- **Nothing has been compiled.** `swiftc -parse` only. Type errors are possible; the code was
  written against the types as read, not checked by the compiler.
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
- The sleep and wake lines against `pmset -g log` on a real lid close.

## Checks to run (never on the x10, never on HorizonXI, never while Daniel plays)

1. Build in a scratch folder and run all 26 `--selftest-*` suites with no game running.
2. `--leftovers-report` during a healthy session: "would end: []".
3. A scratch DMG with a throwaway prefix: run a trivial wine program from it, then
   `hdiutil detach -force`. Expect the "!!" line within ~10 s, the Dock icon bouncing, Force Stop
   ending the program in one click, and the cleanup ending the rest ("already died" line). This
   also shows whether `didUnmount` fires for a forced detach.
4. On a local LSB world client, `kill -STOP` its loader to fake a freeze: Dock › Stop must end
   only that session's group within 9 s.
5. Lid closed for 2 minutes with the local world running: two lines whose times match
   `pmset -g log`.

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
- The after-exit cleanup looks only in the folders recorded at spawn (no `stat` of a drive that
  may just have gone).
