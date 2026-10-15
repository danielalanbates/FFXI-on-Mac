# Beta 3.9 build 60 (local only)

Branch `beta-b60`, on top of `beta-b59` (8b000a1). Local beta: no GitHub release, nothing pushed.
Part 1: the main button (never a greyed-out PLAY). Part 2: where things go — Setup asks for a
folder before writing anything and puts everything in one "FFXI on Mac" folder there; Move…
brings an existing install into one folder.

Daniel's directives for this build, oldest first:

1. "your goal is to get the launcher repair and setup features to run horizonxi. the user should
   be able to do this all themselves. … if you have to make repairs to the code so that the user
   can just click 'update' or 'repair' in place of the 'play' button, that would be best. i don't
   want them to have to dig thru menus to find out what's wrong"
2. "it shouldn't be on the games drive. the user should have the ability to choose where it goes.
   … i want to choose" (setup had created `~/Applications/FFXI on Mac Wine.app` without asking)
3. "the games drive isn't available it says, reconnect it or restart the mac. restarting the mac
   shouldn't be listed."
4. "there should be a setup button in place of the text 'play' when the game is not installed or
   dependencies aren't done."
5. "i'm saying take out the button that says 'play' and replace it with an update or repair text
   field when the game is not playable. the user should never encounter a greyed out play button"

## The main button

The big button under the account fields is always the next thing to do. Its label is one of
**Setup, Update, Repair, Play, Stop** (Play Another where a world allows two clients), or a
running job's progress: "Setting up… 42%", "Updating… 12%", "Repairing…", "Checking…",
"Starting…", "Stopping…", "Moving… 40%", or a wait the user did not start: "Waiting…",
"Running…", "Wine is closing…" (greyed). One short line under it says why when it is not PLAY;
PLAY itself has no line. Nothing anywhere tells the user to restart the Mac.

**Never a greyed-out PLAY** (Daniel, 2026-10-15: "take out the button that says 'play' and
replace it with an update or repair text field when the game is not playable. the user should
never encounter a greyed out play button"). A game that cannot start is an enabled Setup, Update
or Repair whose click starts the fix or opens the exact place it is made, or a wait's progress
label. The one PLAY that does not start the game is the missing account on HorizonXI (its loader
cannot ask): enabled, its click puts the cursor in the account field. `--selftest-primary-action`
asserts, over every state and every action, that a "Play"/"Play Another" label is always enabled
and that every other state is an enabled Setup/Update/Repair or a progress label.

`Primary.decide` (PrimaryAction.swift) is pure: `PrimaryInputs` in, `PrimaryDecision` out. The
window, `--next-action` and `--selftest-primary-action` all use it. First match wins:

| State | Action (`--next-action` id) | Label | Line under it |
| --- | --- | --- | --- |
| Launcher installing its own update | `working:updating` | Updating… | — |
| Setup's chain running | `working:settingUp` | Setting up… N% | — |
| Own job (busy reason) | `working:*` | Setting up… / Updating… / Repairing… / Starting… / Stopping… (+ %) | — |
| Game starting (first 90 s) | `working:starting` | Starting… | — |
| Running here, one client allowed | `stop` | Stop (never on Return; asks first) | — |
| Running from another launcher | `working:runningElsewhere` | Running… | Already running from another launcher. |
| Another world's job in the shared prefix | `working:waiting` | Waiting… | Waiting for another job to finish. |
| No install, still scanning | `working:checking` | Checking… | — |
| No install, remembered wrapper's drive ghost/unplugged | `setup:wrapper-drive` | Setup | The 'x10' drive isn't connected — reconnect it or press Setup. |
| No install, that drive merely unmounted | `repair:mount` | Repair | The 'x10' drive isn't mounted. |
| No install at all | `setup:install` | Setup | HorizonXI isn't installed yet. |
| Checks not yet run for this world | `working:checking` | Checking… | — |
| Game files' drive ghost / unplugged / unknown (incl. another drive answering at its /Volumes name) | `setup:data-drive` (`setup:wrapper-drive` for the wrapper's own drive) | Setup | The 'Games' drive isn't connected — reconnect it or press Setup. |
| That drive merely unmounted | `repair:mount` | Repair | The 'Games' drive isn't mounted. |
| Full Disk Access / Removable Volumes refused | `repair:access` | Repair | Allow FFXI on Mac in Full Disk Access. |
| Wrapper's Wine missing | `setup:wine` | Setup | Wine isn't installed yet. |
| Game not downloaded | `setup:game` | Setup | HorizonXI isn't installed yet. |
| Ashita or base files missing | `setup:game-files` | Setup | Some of HorizonXI's files are missing. |
| No download route, no folder, or ambiguous folder | `setup:choose-folder` | Setup | Choose where X's game files are. |
| Patched game Wine (wine-coop) missing | `setup:game-wine` | Setup | The game's Wine isn't installed yet. |
| Wine's library links (rpath) | `repair:wine` | Repair | Wine needs a quick repair. |
| Any other failing check | `repair:check-<id>` | Repair (install.sh, with the checks shown) | the check's own short line |
| Local world: status loading / not built / below disk floor | `working:checking` / `setup:local-server` | Checking… / Setup (below the floor its click shows the numbers and asks "Set Up Anyway") | The local server isn't set up yet. / Not enough free space for the local server. |
| No login host | `repair:host` | Repair (opens Setup & Diagnostics at the login host) | This world has no login address. |
| Client older than the world requires, updater in the launcher (HorizonXI, CatsEyeXI) | `update` | Update | X needs a client update. |
| … no updater in the launcher | `update` | Update (the world's own installer, client zip or download page; else its home page) | X needs a client update. |
| HorizonXI newer than installed (not deferred this session) | `update` | Update | HorizonXI 2.0.5 is available. |
| Wine still closing after a Stop | `working:closing` | Wine is closing… | — |
| No account, and the loader cannot ask (HorizonXI) | `account` | Play (enabled; the click puts the cursor in the account field) | Type your account name and password above. |
| Ready | `play` / `play-another` | Play / Play Another | none |

Notes on the mapping:
- Registry, layout, COM and Sandbox checks no longer grey PLAY: Play fixes them on the way in
  (`GameRegistry.point`, after `GameRegistry.invalidate` clears its cache when Preflight found
  them missing and no client is live; `Sandbox.repair`).
- A HorizonXI update that fails or is stopped drops back to PLAY for the session (their login
  server accepts one version behind).
- Missing account: HorizonXI's loader console is never shown, so Play without an account would
  sit at a prompt nobody sees; the line points at the fields already on the window. Worlds whose
  loader window creates the account (`accountHow` says so and there is no signup URL) need
  nothing typed. An account typed without its password counts as missing unless the boot
  profile's command line already has `--user`.

What each click does (`ContentView.perform`, decided again at click time, so a double click
cannot start the wrong job): Setup → `runSetup()`; Update → `PrimaryFixer` (HorizonXI's
`update-client.sh horizon`) or CatsEyeXI's own launcher; Repair → `PrimaryFixer` (`install.sh`,
or `diskutil mount <device>`), or the Full Disk Access pane; Play → `play()`; Stop → confirm,
then `runner.stop()`. Every job re-runs the checks when it ends (`onChange` of `runner.busy` and
`local.busy`). The running job's own Stop (HorizonXI download/update, or an installer) is a small
button beside the progress.

Removed as redundant: the "Grant Full Disk Access" and "Set up FFXI on Mac" buttons, the
HorizonXI update banner, the game-data card, the "No login host" line, the footer (PlayStatus.swift,
deleted), "Update HorizonXI…" and "Stop install" in Setup & Diagnostics, the local server card's
"Set up server / Continue setup" (its disk line and "Set up anyway" stay), the selected world's own
row in the running list, Bootstrap's "Install the game…" route. Kept in Setup & Diagnostics as
advanced: Repair (greyed while a drive is gone), Choose folder…, Run installer…, CatsEyeXI
installer…, Install dependencies…, Open log.

Drives (`Preflight.driveState`, `unavailableDrive`): **ghost** = the mount table lists
`/Volumes/<name>` but the path does not exist (Daniel's 'Games', 2026-10-14); **unmounted** =
`diskutil list` knows the volume, no mount point (Repair mounts it, no admin); **absent** =
neither. New this build: `/Volumes` is case-insensitive, and on 2026-10-15 an exFAT stick named
`GAMES` answered at `/Volumes/Games` while the APFS 'Games' was still ghosted, so the data read as
deleted. A `/Volumes/<name>` served by another volume's mount point (`statfs`, exact case) now
counts as that drive missing, in Preflight, install.sh and update-client.sh alike.

## Setup's chain

`ContentView.runSetup()` runs every step still missing, re-reading the state before each one, at
most once per step per press (a step that did not fix its need prints its own "!!" line; the next
press tries again):

1. **Location** — `setupLocationStep(_:)`, the only place a location is decided, before anything
   is written (see "Where things go" below):
   - `.install`, `.wrapperDrive`, `.wine` with no wrapper to fix in place, and `.dataDrive` for
     HorizonXI and the local world: the folder chooser (`LocationPanel`), then `SetupSheet`
     builds Wine and its Windows drive in `<chosen>/FFXI on Mac/`, and that install becomes the
     one in use (remembered; the game downloads into it next). The old install is not touched.
   - `.wine` when the selected wrapper is there and only its Wine is missing: Wine is replaced in
     place (G11), no chooser.
   - `.dataDrive` for another world with a download route: the chooser; its files go in
     `<chosen>/FFXI on Mac/Games/<world>`. With no route, and for `.chooseFolder`: the folder
     that already holds its files (`chooseGameData`).
   Cancel on the chooser or the sheet stops the chain with nothing written; the button stays
   SETUP. The chain awaits the sheet through `SheetWaiter`.
2. **Wine and the Windows drive** — `Bootstrap.run` inside the sheet, into `Bootstrap.target`
   only (there is no default location any more); on success the sheet closes itself and the chain
   rescans (`refreshAsync`).
3. **Patched game Wine** — see "Game Wine" below; noted, and said at the end.
4. **The game** — HorizonXI (and the local world, which plays its client):
   `runner.installHorizon` → `update-client.sh install`, progress on the button (base 0–85 %,
   updates the rest). Other worlds: their own installer route (`downloadGameData`); a
   `.website` world opens its page on the first press and runs the downloaded installer on the next.
5. **Registry / COM / Wine's links** — `runner.repair` (install.sh with Play's Wine) right after a
   download, or alone when only the rpath check fails.
6. **Local server** — `local.setup` (respects the disk floor and "Set up anyway").
7. **Recheck** — the button becomes the next thing; PLAY when everything is done.

Every press is safe to repeat: each job only adds what is missing (torrents resume, a complete
base is not fetched again, Bootstrap skips finished steps, Repair refuses before writing when the
data is unreachable). Nothing is deleted without a click, with one exception noted below.

### Game Wine

No pinned, verified source for the patched wine exists in this repo: the playable
`wine-cx-26.3.0-1` has no recorded hash, and `docs/MACOS-27-PERFORMANCE.md` records a SHA-256 for
`wine-cx-26.3.0-7` but says it is not shown to play HorizonXI and must not replace the playable
tree. So Setup does not download one. When it is missing the button is Setup ("The game's Wine
isn't installed yet."); the chain still does every other step and ends with one line: "The game's
Wine can't be installed from here yet." On Daniel's Mac it resolves to the x10 copy. This is a
hard block for a fresh user, as the mapping asked; HANDOFF's #20 note recommended no hard block —
Daniel's call (see pathways).

### aria2 (the fresh-user download blocker)

`update-client.sh` uses Homebrew's `aria2c` when present. Otherwise `ensure_aria2` fetches aria2's
own last macOS build, `aria2-1.35.0-osx-darwin.tar.bz2` from aria2's GitHub release (1,953,763
bytes, SHA-256 `f6d9ab4212a97b4a52cf0ff03aeb24da673b11599e6b9c1a5d6a5f6c94fd39da`, both
pinned), once, into `~/Library/Application Support/HorizonXI-on-Mac/tools/aria2c` with its
`COPYING` beside it. It is x86_64 (runs under Rosetta, which Setup installs anyway), links only
system libraries (`otool -L`: Security, CoreFoundation, libc++, libSystem), has BitTorrent, and is
never shipped in our image (LICENSING.md). It is from 2019; Homebrew's newer build wins when present.
`update-client.sh tools <dir>` prefetches it. JSON is now read with JavaScript for Automation
(`osascript -l JavaScript`), so `python3` (a stub that pops the Command Line Tools installer on a
stock Mac) is no longer needed.

## Scripts

- **install.sh (Repair)**: refuses before writing anything when the game data is unreachable —
  a drive that is gone ("The 'Games' drive isn't connected — reconnect it or press Setup. Nothing
  was changed.", exit 4) vs files that are gone ("Game files missing (FFXiMain.dll) — press Setup
  to get them again.", exit 4). Takes the world's game folder, SquareEnix Windows path and
  SquareEnix folder (args 3–5) and `HXI_WINE` (Play's wine) from `Runner.repair`. Every COM DLL is
  tried; failures are named with regsvr32's code (exit 3). polcore.dll missing is a warning, as in
  Preflight. Writes GameRegistry's marker on success. `reg add` failures say so. "Play
  HorizonXI.command" is skipped, not fatal, on a read-only folder. No ANSI codes.
  `WINEDLLOVERRIDES=mscoree,mshtml=` and `WINEBOOT_HIDE_DIALOG=1` keep Mono/Gecko prompts away.
- **Runner.repair** refuses up front with the drive line when the data is unreachable (Daniel's
  "repair exited 3"), and the S&D Repair is greyed then.
- **update-client.sh**: `install` re-fetches the base when version.json exists but Ashita or the
  base files do not (G10), flattens `HorizonXI/` over an earlier client (also through a symlinked
  SquareEnix), writes the base version so updates re-apply, **deletes the 9.4 GB base zip once it
  is unpacked and complete** (the one deletion without a click: our own download cache), checks
  free space (zip still to come + 16 GB) and the data drive first. A Stop's `.aria2` control file
  now resumes instead of unzipping half a file. Offline and stalled torrents say so in one line.
  version.json is read by pattern, so the old literal-`\n` files still read.
- **fix-wine-rpath.sh**: relative links (a moved wrapper keeps working), dangling links replaced,
  verified with `wineserver --version` instead of `wine cmd.exe` (which made `~/.wine` on first
  setup and re-stamped the game prefix with the wrapper's wine on every Repair).
- **Bootstrap**: never deletes a wrapper (swaps only its wine — from the checkpoint), checks
  `system.reg` rather than `drive_c` for a finished prefix, hides Mono/Gecko prompts, and the
  dead "Install the game…" route is gone. The scan keeps a selected install that holds the game
  over a fresh empty wrapper (G11). With nothing found at launch the checks still run, so a
  remembered install on an unplugged drive is named instead of "isn't installed"; mounting a
  drive rescans when nothing is selected.

## Where things go (part 2)

Daniel, 2026-10-15: "it shouldn't be on the games drive. the user should have the ability to
choose where it goes. … i want to choose" — the old setup built `~/Applications/FFXI on Mac
Wine.app` without asking (he had it deleted), and HorizonXI's `SquareEnix` was a link onto a third
drive ('Games') that later went missing.

**One folder** (`InstallLocation`):

    <chosen>/FFXI on Mac/
        FFXI on Mac Wine.app/                  Wine + its Windows drive (prefix10)
            Contents/SharedSupport/prefix10/drive_c/HorizonXI/    HorizonXI, SquareEnix included
        Games/<world>/                         any other world's client

Bootstrap's downloads and unpacking sit beside the wrapper (`.ffxi-on-mac-setup`, same drive) and
are removed once Wine is built. The choice is remembered (`install.location` in the launcher's
defaults, plus `install.last` for the install); discovery looks in the remembered folder first,
and `Install.remembered()` now needs the prefix, not the game, so a just-built install stays
selected while the game downloads. Existing wrappers in `~/Applications`, `~/Games`, `/Volumes/*`
are still found as before. Other worlds with no folder get `Games/<world>` in the chosen folder
(asked for only when no folder was chosen yet); "Choose folder…" no longer creates
`~/Games/FFXI/<world>` before the user picks.

**The chooser** (`LocationPanel`): an open panel for folders ("New Folder" allowed), opening on
the last choice, else the drive with the most room that would be accepted (home, or `~/Games` when
it exists, if that is the Mac's own disk). One line under it follows the selection: "120.4 GB free
here · about 27 GB needed", or why it can't be used. A folder that can't be used is refused in the
panel (it stays open); Cancel returns nothing and nothing is written. Refusals, one plain line each:

| Folder | Line |
| --- | --- |
| exFAT / FAT / NTFS / anything not APFS or Mac OS Extended | This drive is exFAT. Choose one formatted APFS or Mac OS Extended. |
| Network volume (not local, or smbfs/afpfs/nfs/webdav) | This is a network drive. Choose a drive connected to this Mac. |
| Read-only volume | This drive is read-only. Choose another. |
| Folder not writable | This folder can't be written to. Choose another. |
| iCloud Drive / CloudStorage / ubiquitous | This folder syncs to iCloud or another cloud. Choose one that doesn't. |
| Inside an .app | Choose a folder outside an app. |
| Drive gone (ghost, impostor) | The 'X' drive isn't connected. Choose another place. |
| Not enough space | Not enough space here: 19.2 GB free, about 35 GB needed. |

Space needed for a fresh HorizonXI install, from the measurements in this build's analysis: Wine
and its Windows drive about 1.4 GB, the base zip 9,426,920,806 bytes, unpacked about 15.5 GB
beside it until update-client.sh deletes the zip: about 27 GB at the peak. On the Mac's own disk
8 GB more must stay free (35 GB). Another world's folder: about 25 GB (no Wine). A Move: exactly
what it copies.

**Move…** (`InstallMove`, `Runner.moveInstall`): in Setup & Diagnostics, and as a small "Move…"
beside the main button's Setup line when the game's files are on (or link to) another drive than
Wine (`Primary.Probe.dataElsewhere`).
1. Refused in one line while a game (here, in another launcher, or seen by the process scan), a
   job, the local server (its login port answers) or any wineserver runs.
2. Measured, read-only: the wrapper with only the selected prefix (other prefixes and the
   installer prefix stay behind), and the selected world's own folder when it is outside the
   wrapper. A source behind a drive that is gone: "The 'Games' drive isn't connected, so the game
   can't be moved." and nothing else happens.
3. The chooser, with the same refusals, the need being exactly what is copied, and never inside
   the install or the data its links reach.
4. Copy with `ditto` into hidden names (discovery never sees a half copy). Links under the game's
   folder (`drive_c/HorizonXI`, the folder itself included) that leave the install are copied as
   real files, also when they chain onto a third place; links that loop back to a folder holding
   them, dangling links and links to a whole drive or home stay links. Wine's own links stay as
   Wine made them: `dosdevices` (`z:` is the whole Mac), `drive_c/users/*`, and the per-world
   `C:\Games\<world>` links. Absolute links inside the install are re-pointed at the copy.
5. Verify: files, folders, links and bytes of the copy equal the source as copied; Wine,
   `system.reg`, Ashita and the three FFXI DLLs present. Only then renamed into place. Any
   failure: the partial copy goes to the Trash (never `rm`), the old install is as it was.
6. Switch: the remembered install and folder, world folders that pointed inside the old wrapper
   (and the moved world's own folder) re-pointed; the checks run again.
7. Ask once: "The game now plays from …. The old copy is still here: … Move it to the Trash?"
   — Keep It (default) / Move to Trash. The old copy is the wrapper (or only the moved prefix when
   the wrapper holds other installs), the data its links reached, and the world folder.
8. The button shows "Moving… N%" (free-space change on the destination; a same-drive copy that
   macOS clones may jump from 0 to 100).

**How to test without the window** (never on the real install):

    B=~/Downloads/FFXI-on-Mac-build/swift-build/release/HorizonXILauncher
    $B --selftest-install-location ~/Downloads/FFXI-on-Mac-build/fixture   # builds fixture/install-location

## Tests run (2026-10-15, M1 8 GB, macOS 27.0)

- `swift build -c release --scratch-path ~/Downloads/FFXI-on-Mac-build/swift-build`: clean (only
  the two pre-existing `ImplicitStrongCapture` warnings, LocalServer.swift and Runner.swift).
- `--selftest-primary-action`: 69/69. Every state in the table above; ghost 'Games' → Setup with
  the reconnect line; label ⊆ {Setup, Update, Repair, Play, Stop, Play Another} or a greyed
  progress label; **a "Play"/"Play Another" label is always enabled, and every other state is an
  enabled Setup/Update/Repair or a progress label** (over every state and every action); no
  "restart" in any label, reason, drive line or Setup's last line; reasons ≤ 72 characters, one
  line, no jargon; only Stop off Return; Play/Play Another without a line; "Moving… 40%"; Repair's
  refusal on a fixture behind a missing drive and with missing DLLs; `--fix` limited to jobs that
  need no person.
- `--selftest-install-location ~/Downloads/FFXI-on-Mac-build/fixture`: 62/62 (also 62/62 with no
  folder given, in a temporary folder it removes). The chooser's refusals from injected facts and
  the facts of a real folder; the one-folder layout; the remembered choice in a throwaway defaults
  suite; a real Move of a ~10 KB fixture whose SquareEnix links outside the tree and on to a third
  place (real files in the copy, Wine's links kept, absolute link re-pointed, other prefixes left,
  counts equal, source snapshot unchanged, moved install passes the file checks), a linked
  HorizonXI folder, a copy whose source changed under it (refused, discarded inside the fixture),
  a second Move into the same place, a source behind a missing drive (one line, nothing written),
  and Move's blockers.
- `--selftest-ui-text`: 24 checks, including the drive line wording and the impostor rule.
- All other suites pass unchanged: addon-policy, addon-source, addon-installer, addon-profile,
  addon-scrub, addon-install, cursor-fix, guide-disabled, narration-disabled, multiworld,
  retroachievements (47), updater, perf, single-instance.
- `scripts/tests/setup-scripts-test.sh <aria2 archive>` with `HXI_LAUNCHER_BIN` set: 64 checks,
  all pass, on a 4 MB fixture in `~/Downloads/FFXI-on-Mac-build/fixture/setup-scripts` with stub
  wine/wineserver/curl/aria2c/python3: install.sh refusals (drive gone, DLLs gone, no data, no
  game), named regsvr32 failures with every DLL tried, success path (registry, four DLLs, marker,
  relative links, wineserver verify, Play's wine via HXI_WINE), polcore warning, read-only folder,
  Z:\ world folder; fix-wine-rpath dangling/moved wrapper; update-client fresh install
  (flatten, updates in order, deleteFiles, version.json, zip removed, 1.1.1 not re-applied,
  progress lines, python3 never run), G10 re-fetch, already-current, literal-`\n` version.json,
  resume after Stop, offline, stalled torrent, drive gone (install and horizon), free-space
  refusal, the pinned aria2 fetch from a local copy (installed, runs under Rosetta, COPYING kept,
  second run no fetch, tampered archive refused), and the launcher's own `--next-action` /
  `--fix` on the fixture (Repair → then Play with no line; files missing → Setup; drive gone →
  Setup, `--fix` refuses and runs nothing).
- Real Mac, read-only: `--next-action HorizonXI` (and Local server, CatsEyeXI) →
  `setup:data-drive | Setup | The 'Games' drive isn't connected — reconnect it or press Setup.`
  (exit 10), both before and after the exFAT 'GAMES' stick appeared, and again after part 2.
  `--check` names the same line (exit 1).
- `grep` of Sources and Resources: no string tells the user to restart the Mac. Remaining
  "Restart" text is the launcher's own self-update button (restarts the launcher, not the Mac)
  and log-only lines about it; one code comment quotes Daniel.

## Not tested (rules for this build: no GUI, no game, no wine on the real install)

- The window itself: SwiftUI layout of the button, its line, the small Stop and the "Move…" link;
  the chain end to end (chooser → sheet → rescan → download → Repair → PLAY); `SheetWaiter` with
  Cancel / closing the sheet; `LocationPanel` itself (its line under the panel, the refusal sheet,
  the default folder); the Move… flow in the window (the chooser, "Moving… N%", the Trash
  question and `trashItem`); the account PLAY putting the cursor in the field and Repair opening
  the login host; the local server's "Set Up Anyway" alert; the Full Disk Access pane and macOS's
  "Quit & Reopen"; the local server's Setup from the button; the `.website` second-press installer.
- Move on a real install (only the fixture; never Daniel's): copy speed and the progress figure
  on a 25 GB tree, `ditto` across drives and onto the Time Machine drive, a real wrapper and
  prefix after the move (Wine's own checks, the registry marker, a launch).
- Real wine: install.sh with real regsvr32/reg, `wineserver --version` on a real Sikarugir
  wrapper, Bootstrap's build and wineboot.
- A real torrent (9.4 GB) or a real HorizonXI update; aria2c 1.35.0 against HorizonXI's swarm
  (only `--version` ran). The fetch itself was tested through `file://` with the archive that was
  downloaded from aria2's GitHub release once to pin it.
- `diskutil mount` (no unmounted volume to try); the ghost case from the GUI.

## Possible next pathways

- **Game Wine download** (Daniel's decision, HANDOFF #20): pin `wine-cx-26.3.0-1` (needs its
  SHA-256 from a fresh, verified download) or adopt 26.3.0-7 (hash already recorded) after a
  local-world launch test; install under Application Support, append to
  `X87Sidecar.patchedWineCandidates`, add a chain step before the game download, free-space check.
  Or, if Daniel prefers, drop the hard block and let Play fall back with a warning as in b59.
- **Space estimate per world**: the chooser uses HorizonXI's 27 GB for everyone (25 GB for
  another world's folder); CatsEyeXI and the retail-client worlds differ.
- **Local server**: lsb-server.sh still builds where it always did, outside the chosen folder.
- A SquareEnix symlink that dangles on a drive that *is* there (target folder deleted) reads as
  "files missing", and Setup's download then refuses ("links to …, which isn't there") — the
  chain could offer the location step there too.
- `GameRegistry.point` still ignores regsvr32 results and writes its marker anyway (analysis
  P0-6); a failed registration is cached as done.
- Login refusals (`Runner.loginFailure`) could become the button's line (version mismatch →
  Update, wrong password → the account fields).
- Bootstrap's 250 MB download: no progress or resume, template not hash-checked.
- Offline and disk-space checks before Bootstrap (the download scripts have them now).
- `LocalServer.script()` and `X87Sidecar`'s dev fallbacks still look in `app/` instead of the repo
  root (only matters for unbundled runs; Runner's two are fixed).
- The launcher self-update's "Restart" wording could become "Relaunch" if Daniel wants the word
  gone entirely.
