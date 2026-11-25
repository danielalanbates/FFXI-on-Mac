# Beta 3.9 build 60 (local only)

Branch `beta-b60`, on top of `beta-b59` (8b000a1). Local beta: no GitHub release, nothing pushed.
Part 1: the main button (never a greyed-out PLAY). Part 2: where things go — Setup asks for a
folder before writing anything and puts everything in one "FFXI on Mac" folder there; Move…
brings an existing install into one folder. Part 3: the game's Wine — Setup downloads athei's
pinned `wine-cx-26.3.0-1` (and installs Rosetta 2 when it is missing), so a fresh user reaches PLAY
with Setup alone. Part 4: Setup uses what is already in the chosen folder — never a second wrapper
or a second 25 GB download — and its button names each step with one figure that only rises.

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
6. "when the folder already contains the previous installation is it going to auto recognize that
   and continue setup based on the files there? or will it duplicate everything and create
   problems"
7. (live, on the b60 preview) "it's been stuck on setting up 0%"

## The main button

The big button under the account fields is always the next thing to do. Its label is one of
**Setup, Update, Repair, Play, Stop** (Play Another where a world allows two clients), or a
running job's progress: "Setting up… 42%", "Updating… 12%", "Repairing…", "Checking…",
"Starting…", "Stopping…", "Moving… 40%", or a wait the user did not start: "Waiting…",
"Running…", "Wine is closing…" (greyed). While Setup's chain runs, the button names its step
instead of "Setting up" — "Downloading Wine…", "Installing game Wine… 9%", "Downloading
HorizonXI… 37%", "Unpacking HorizonXI… 60%", "Updating HorizonXI… 91%" — with the whole chain's
figure (part 4, below); under 1% it shows no figure at all. One short line under it says why when it is not PLAY;
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
| Rosetta 2 missing (`arch -x86_64 /usr/bin/true` fails) | `setup:rosetta` | Setup (macOS's administrator prompt) | Apple's Rosetta isn't installed yet. |
| Wrapper's Wine missing | `setup:wine` | Setup | Wine isn't installed yet. |
| Patched game Wine (wine-coop) missing | `setup:game-wine` | Setup (downloads it, part 3) | The game's Wine isn't installed yet. |
| Game not downloaded | `setup:game` | Setup | HorizonXI isn't installed yet. |
| Ashita or base files missing | `setup:game-files` | Setup | Some of HorizonXI's files are missing. |
| No download route, no folder, or ambiguous folder | `setup:choose-folder` | Setup | Choose where X's game files are. |
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
   SETUP. The chain awaits the sheet through `SheetWaiter`. What is already in the chosen folder
   is used instead of built again (part 4, "What happens if the folder already has an install").
2. **Wine and the Windows drive** — `Bootstrap.run` inside the sheet, into `Bootstrap.target`
   only (there is no default location any more); on success the sheet closes itself and the chain
   rescans (`refreshAsync`).
3. **The game's Wine** — `setupGameWineStep`: athei's pinned wine-coop downloaded, verified and
   unpacked into the same folder (see "Game Wine" below). Rosetta 2 comes before it, in the sheet,
   or on its own (`setupRosettaStep`) when only Rosetta is missing.
4. **The game** — HorizonXI (and the local world, which plays its client):
   `runner.installHorizon` → `update-client.sh install`, progress on the button (base 0–85 %,
   updates the rest). After the steps it needed, the chain also applies HorizonXI's update when
   the install it found or finished is behind (part 4); a stopped or failed update leaves PLAY
   for the session, as the Update button does. Other worlds: their own installer route (`downloadGameData`); a
   `.website` world opens its page on the first press and runs the downloaded installer on the next.
5. **Registry / COM / Wine's links** — `runner.repair` (install.sh with Play's Wine) right after a
   download, or alone when only the rpath check fails.
6. **Local server** — `local.setup` (respects the disk floor and "Set up anyway").
7. **Recheck** — the button becomes the next thing; PLAY when everything is done.

Every press is safe to repeat: each job only adds what is missing (torrents resume, a complete
base is not fetched again, Bootstrap skips finished steps, Repair refuses before writing when the
data is unreachable). Nothing is deleted without a click, with two exceptions, both the launcher's
own downloads: the 9.4 GB base zip once unpacked (below), and the game's Wine tarball once
unpacked or when it does not match its pin.

### Game Wine (part 3)

The last thing a fresh user could not get by pressing Setup. HorizonXI plays only under athei's
patched CrossOver wine, `wine-cx-26.3.0-1` ("wine-coop"); the wrapper's own Wine closes the client
a second after login (docs/WINE-BUILD.md). Part 1 ended Setup with "The game's Wine can't be
installed from here yet." That line, `Primary.gameWineUnavailable`, is gone.

- **Source, pinned in `scripts/game-wine.sh` only**: athei/wine-build release `cx-26.3.0-1`,
  `wine-cx-26.3.0-1-macos-x86_64.tar.xz`, 203,696,924 bytes, SHA-256
  `ec2a9e4d438917a26e381c01367773df79c3b0d6f0504b8183464619cad7e661` (GitHub's asset digest; one
  fresh download matched it). Fetched on the user's Mac, never shipped (LGPL; LICENSING.md, the
  aria2 model).
- **Same as the measured copy?** Every one of its 3,692 files was hashed against Daniel's working
  `/Volumes/x10/Video Games/Mac/FFXI/wine-coop/wine` (read-only): 3,691 identical, including
  `bin/wine` `a84a059a…`, `bin/wineserver` `395e30e7…`, every `x86_64-unix/*.so` and
  `i386-windows/*.dll`, and the 4 symlinks. The one difference is `lib/external/libMoltenVK.dylib`:
  Daniel's is MoltenVK 1.4.2 (`aef00b13…` = `vendor/libMoltenVK-1.4.2.dylib`), with the release's
  original kept beside it as `.bak-pre-1.4.2` (`02adfe96…`, identical to the release). That is the
  launcher's own `Renderer.upgradeCoopMoltenVK`, which Play on the default Metal renderer applies
  to whichever wine-coop it finds. So a fresh download becomes Daniel's tree on its first Play.
- **The step** (chain step 3, `setupGameWineStep` → `Runner.installGameWine` →
  `game-wine.sh install "<chosen>/FFXI on Mac"`), after Wine and before the 9.4 GB game: free space
  checked first (download + 1.13 GB unpacked, plus 8 GB on the Mac's own disk), nothing written on a
  refusal; `/usr/bin/curl -fL -C -` with five attempts (a stall under 1 KB/s for a minute ends an
  attempt, the next resumes; a Stop leaves the partial file for the next press); size and SHA-256
  checked **before** extracting; `/usr/bin/tar` into `.wine-coop-unpack.XXXXXX` beside it, one
  rename to `wine-coop`; the tarball deleted after. A mismatch deletes the download and changes
  nothing else; a `wine-coop` without a Wine in it is set aside as `wine-coop.incomplete-<time>`,
  never deleted. Progress on the button ("Setting up… N%", download 0–90 %, unpack 90 %), the
  small Stop beside it. The launcher clears the script's test-only `HXI_GAME_WINE_*` overrides.
- **Where**: the remembered "FFXI on Mac" folder (where Setup built Wine). An install made before
  b60 has none (or its drive is gone, or it lacks room): the chooser asks once, "Where should the
  game's Wine go?", and that folder is remembered.
- **Found by** `X87Sidecar.patchedWine()`: the remembered folder's `wine-coop` first, then the
  old fixed places (`/Volumes/Games/FFXI/wine-coop`, Application Support's `ffxi-runtime`, two x10
  paths). Daniel's Mac still resolves to the x10 copy, so his Setup never downloads it again.
  `OwnWine` follows the same list.
- **Move…** copies a `wine-coop` that sits beside the wrapper (Setup's layout, and Daniel's x10
  one) with the rest, verifies it, and lists the old one in the Trash question.
- **Rosetta 2**: the build (and Sikarugir's, and aria2) is x86_64. `Bootstrap.rosettaMissing()`
  runs `arch -x86_64 /usr/bin/true` (a yes is cached for the session); missing → Setup, "Apple's
  Rosetta isn't installed yet.", ahead of everything but a missing drive and Full Disk Access.
  The click runs `softwareupdate --install-rosetta --agree-to-license` through macOS's own
  administrator prompt (`Bootstrap.ensureRosetta`, the same code the setup sheet runs), never
  Terminal. `FFXI_ON_MAC_ROSETTA=missing|present` injects the answer for tests; `ensureRosetta`
  still asks the Mac, so the flag can never run softwareupdate.
- **Space**: a fresh install now needs about 28 GB (36 GB on the Mac's own disk).

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
        wine-coop/wine/bin/wine                the game's Wine (part 3, scripts/game-wine.sh)
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
here · about 28 GB needed", or why it can't be used. A folder that can't be used is refused in the
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
| Not enough space | Not enough space here: 19.2 GB free, about 36 GB needed. |

Space needed for a fresh HorizonXI install, from the measurements in this build's analysis: Wine
and its Windows drive about 1.4 GB, the game's Wine 1.33 GB (its 204 MB tarball and 1.13 GB
unpacked, part 3), the base zip 9,426,920,806 bytes, unpacked about 15.5 GB beside it until
update-client.sh deletes the zip: about 28 GB at the peak. On the Mac's own disk 8 GB more must
stay free (36 GB). Another world's folder: about 25 GB (no Wine). A Move: exactly
what it copies.

**Move…** (`InstallMove`, `Runner.moveInstall`): in Setup & Diagnostics, and as a small "Move…"
beside the main button's Setup line when the game's files are on (or link to) another drive than
Wine (`Primary.Probe.dataElsewhere`). Neither is shown while a drive the Move would read is gone
(`InstallMove.offered`, part 4): Daniel's screen showed "Move…" beside "The 'Games' drive isn't
connected", where it could only refuse.
1. Refused in one line while a game (here, in another launcher, or seen by the process scan), a
   job, the local server (its login port answers) or any wineserver runs.
2. Measured, read-only: the wrapper with only the selected prefix (other prefixes and the
   installer prefix stay behind), and the selected world's own folder when it is outside the
   wrapper, and the game's Wine when it sits beside the wrapper (`wine-coop`, part 3; copied as
   its own part and listed with the old copy). A source behind a drive that is gone: "The 'Games' drive isn't connected, so the game
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

## What happens if the folder already has an install (part 4)

Daniel, 2026-10-15: "when the folder already contains the previous installation is it going to
auto recognize that and continue setup based on the files there? or will it duplicate everything
and create problems". Before part 4: only the layout Setup builds ("FFXI on Mac/") was carried on
from, and the chooser still demanded the full ~28 GB. A previous-style install — a wrapper such as
`siku.app`, the old `~/Applications/FFXI on Mac Wine.app`, a bare HorizonXI client or SquareEnix
folder — was not seen at all: Setup built a second wrapper and downloaded 25 GB again.

**Looking** (`ExistingInstall.find`, read-only): the chosen folder itself and up to three folders
below it, at most 3,000 folders, never into an app's own files (a wrapper is looked at, not
walked), Library, system, backup or media folders, the game's ROM trees, or through a link (a link
is looked at once). It runs off the main thread while the user browses the chooser; inside
Desktop, Documents and Downloads only once a folder there is chosen (macOS asks before those are
read). A client is HorizonXI's when it has HorizonXI's `version.json`, or Ashita and SquareEnix in
a folder named for HorizonXI; a folder named for any other world the launcher knows (CatsEyeXI,
Eden, Gaia XI, …) is never taken.

**What it finds, best first:** a wrapper whose Windows drive holds HorizonXI (a complete client
first, then the new layout); a HorizonXI or SquareEnix folder on its own; a wrapper with Wine and
no game yet; the game's Wine alone. Anything whose files are behind a drive that is gone counts
only when nothing usable is there.

| Found in the chosen folder | Chooser line | What Setup does | Space it asks for |
| --- | --- | --- | --- |
| "FFXI on Mac" with HorizonXI 2.0.4 | Found HorizonXI 2.0.4 here — Setup will use it. | Uses that wrapper; builds nothing; only what is missing | nothing at the latest version ("nothing more to download"); ~1 GB if behind |
| `siku.app` (any wrapper) with HorizonXI | Found HorizonXI 2.0.4 in “siku.app” — Setup will use it. | That wrapper becomes the install in use (remembered, selected); no new wrapper; the game's Wine goes beside it (Daniel's layout) if it is not found anywhere | as above, plus the game's Wine (1.3 GB) when not found |
| A wrapper with part of HorizonXI | Found part of HorizonXI in “siku.app” — Setup will finish it. | Used; update-client.sh fetches the base again (it holds Ashita) and unpacks it over | the base download and unzip |
| `FFXI on Mac Wine.app` with no game (old ~/Applications default) | Found Wine in “FFXI on Mac Wine.app” — Setup will use it. | Its Wine and Windows drive used; the game downloads into it; a part-downloaded base resumes | the game's Wine if missing, the base less what is downloaded |
| A HorizonXI folder on its own, same drive | Found HorizonXI 2.0.3 here — Setup will move it into FFXI on Mac. | "Use the HorizonXI files already here? They'll be moved into FFXI on Mac, not copied" [Use Them] [Download Fresh]; Use Them: Wine and its drive built (or a no-game wrapper found there used), then **one rename** into `drive_c/HorizonXI` and a link left where it was | Wine, the game's Wine, ~1 GB update |
| The same on another drive | Found HorizonXI 2.0.4 on another drive — Setup will copy it. | The question says it is copied and the original stays; a verified copy (`InstallMove.copyTree`: hidden name, counted against the source, renamed into place), the original never touched | as above, plus the client (~15.5 GB) |
| A SquareEnix folder on its own | Found FINAL FANTASY XI's files here — Setup will move them into FFXI on Mac. | Moved into `drive_c/HorizonXI/SquareEnix` (no duplicate); HorizonXI's base still downloads (Ashita ships only inside it) and unpacks over it | the base download and unzip |
| Files behind a drive that is gone | HorizonXI here is on the 'Games' drive, which isn't connected. | "Setup can download a fresh copy into … Nothing on the 'Games' drive is changed." [Download Fresh] [Cancel]; the link and its target are never touched | a fresh install |
| … and that install is the chosen folder's own "FFXI on Mac" | the folder is refused: This install's files are on the 'Games' drive, which isn't connected. | nothing (there is nowhere to download fresh without touching it) | — |
| Nothing | (no line) | a fresh install in `<chosen>/FFXI on Mac` | ~28 GB (36 GB on the Mac's own disk) |

Choosing the client folder itself puts "FFXI on Mac" beside it. The space check is asked of where
Setup writes (the found wrapper's folder, or the chosen one), with the Mac's own disk keeping 8 GB
free only when something is to be written. After "Download Fresh" the full need is checked again
before anything is written.

**Moving in** (`ExistingInstall.moveIn`): `rename(2)` only, after checking both ends are on one
drive (otherwise it refuses with nothing changed and the copy path is used). What was at the
destination — an empty folder, or the launcher's own unfinished download — goes to the Trash first,
never `rm`. A link is left at the old place pointing at the new one, so another wrapper's
SquareEnix link or a world's folder setting still reaches the same files; a world's folder setting
that named the client is re-pointed (HorizonXI's and the local world's back to the install's own),
and HorizonXI's / the local world's setting is cleared when it names files that are gone.

**One entry per install** (`Install.dedupe`): the picker lists one entry per set of game files
(the real path of `SquareEnix/FINAL FANTASY XI`, or the prefix when there is no game). The same
wrapper reached through a link, a second prefix whose HorizonXI links to the first's, an older
wrapper that linked to the client Setup just moved: one entry, the one in use kept. Only the list
changes, never anything on disk. Entries with different files all stay (a copy from another drive
leaves the original's install in the list).

**The game's Wine is never fetched twice**: the folders chosen before the last one (three at most,
`install.location.earlier`) are looked in too, so choosing a new place or using an older install
finds the wine-coop already on the Mac.

## Progress that never looks stuck (part 4)

Daniel, live on the b60 preview: "it's been stuck on setting up 0%". Measured: aria2c was fetching
at ~5 MB/s while the button sat at "Setting up… 0%" for minutes. update-client.sh ran it with
`--summary-interval=60` (its "(N%)" readout is the only figure the button read), the 9.4 GB unzip
printed nothing, and the steps before the torrent (Wine, the Windows drive) reported nothing.

- **update-client.sh**: aria2c `--summary-interval=2` (base and updates; its readout lines still
  stay out of launcher.log). Unzips report "==> unpacking N%" every 2 s: bytes unpacked
  (`du -skA` of the extraction folder) against the zip's own uncompressed size (`zipinfo -t`;
  1.65× the zip when unreadable), capped at 99 % until ditto ends.
- **No second 15 GB copy**: the base zip is rooted at `HorizonXI/`, and the old code flattened it
  with `ditto HorizonXI/ .` — a second full copy (peak ~40 GB against a 25 GB space check). It
  now unpacks into `updates/.base-extract` (same drive) and `merge_into` renames everything into
  place (zsh's builtin `mv`; across a link onto another drive it copies, as before). Updates unpack
  beside the game too, not in `$TMPDIR` on the Mac's own disk. A half-unpacked folder is removed on
  exit.
- **ScriptProgress** reads the scripts' output (lines split across reads, `\r` readouts), never
  going back: a fresh install's base is 0–85 % of the job (download 70 % of that, unzip 30 %),
  updates the rest; game-wine.sh's download 90 %, its unpack the rest. It names the stage.
- **SetupMeter** weighs the whole chain (Wine 8, moving/copying files 12, the game's Wine 5,
  the game 70, finishing 2, the local server 30, Rosetta 2), planned from the state Setup starts
  in and re-planned by what the chooser found. The figure only rises: a job that ends does not
  drop it, a step found unnecessary makes it jump, an unplanned one leaves it until the next.
  It says 100 % only by ending.
- **The button**: "Installing Rosetta…", "Downloading Wine…", "Building Wine…" (the setup sheet's
  steps, reported to the window), "Moving game files…" / "Copying game files… 40%", "Installing
  game Wine… 9%", "Downloading HorizonXI… 37%", "Unpacking HorizonXI… 60%", "Updating HorizonXI…
  91%", "Finishing…", "Building the server…"; "Setting up…" while the chooser is open; no figure
  under 1 %. Every label fits the button (≤ 26 characters).

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

**Part 3 (the game's Wine), same day, same Mac:**

- Release build clean (the same two pre-existing warnings).
- `--selftest-primary-action`: 77/77. New: Rosetta missing → Setup with its line; Rosetta, Wine
  and the game's Wine all missing → Rosetta first; a missing drive outranks Rosetta; nothing
  installed + no Rosetta → plain Setup (the sheet installs it); game Wine missing → an enabled
  Setup; game Wine and the game both missing → the game's Wine first; Wine and game Wine both
  missing → Wine first; `--fix` never runs the Rosetta or game-Wine steps; the injected
  `FFXI_ON_MAC_ROSETTA` flag read (missing, by the probe, present); this Mac's own answer
  (x86_64 runs) agrees with `rosettaMissing()`.
- `--selftest-install-location ~/Downloads/FFXI-on-Mac-build/fixture`: 67/67. New: 28 GB / 36 GB;
  the game's Wine alone about 2 GB; `patchedWineCandidates` = the chosen folder's wine-coop, then
  the fixed list; a fake wine-coop in the chosen folder is the one `patchedWine()` returns and
  `OwnWine` owns; a Move carries the wine-coop beside the wrapper (its relative link a link,
  counted, a key file, in the old-copy list) and the moved one is what `patchedWine()` returns.
- Every other suite passes: addon-policy, addon-source, addon-installer, addon-profile,
  addon-scrub, addon-install, cursor-fix, guide-disabled, narration-disabled, multiworld,
  retroachievements (47), updater, perf, ui-text, single-instance.
- `scripts/tests/setup-scripts-test.sh <aria2 archive>` with `HXI_LAUNCHER_BIN` and
  `HXI_GAME_WINE_TARBALL` set: 94 checks, all pass. New game-wine.sh cases on a ~20 KB fake
  tarball served through `file://` with its own pin: fresh install (in place, link kept, 755,
  tarball and temp folders gone, verify before extract, progress line); already installed
  (nothing fetched, nothing changed); bad SHA-256, size one byte over and one under (exit 1, the
  checksum line, nothing extracted or set aside, the folder byte-for-byte as it was, an existing
  incomplete `wine-coop` untouched); a good download over that incomplete folder (set aside, its
  file kept, the wrapper untouched); a partial download resumed (`-C -`) and a stale unpack folder
  cleared; offline (one line after five tries); a missing drive and no room (refused before
  anything is written). The real release through `file://` against the script's own pin: 3,692
  files, x86_64, `wineserver --version` runs under Rosetta. The launcher on the fixture:
  `setup:game-wine | Setup | The game's Wine isn't installed yet.` (and `--fix` refuses it, runs
  nothing), `setup:rosetta | Setup | Apple's Rosetta isn't installed yet.` with the flag, PLAY
  with `present`. (game-wine.sh calls `/usr/bin/curl` by path, so the fixture serves its fake
  tarball through `file://` to the real curl rather than through the PATH stub.)
- The pin itself: one download from GitHub with curl, 203,696,924 bytes, SHA-256 `ec2a9e4d…e661`,
  equal to the asset digest; the equivalence check against Daniel's x10 copy (above, "Game Wine").
  The tarball and the extraction were deleted afterwards.
- Real Mac, read-only, after part 3: `--next-action` for HorizonXI, Local server and CatsEyeXI →
  `setup:data-drive | Setup | The 'Games' drive isn't connected — reconnect it or press Setup.`
  (exit 10); `--check` the same line (exit 1). The game's Wine resolves to the x10 copy, so it is
  not offered for download there.

**Part 4 (what is already there; progress), same day, same Mac:**

- Release build clean (the same two pre-existing warnings).
- `--selftest-install-location ~/Downloads/FFXI-on-Mac-build/fixture`: 106/106. New, each on its
  own fixture tree: the new layout chosen again (and its "FFXI on Mac" folder chosen directly):
  reused, no second wrapper, nothing to download at the latest version, ~1 GB a version behind,
  accepted with 5 GB free where a fresh install is refused, looking leaves the tree unchanged;
  `siku.app` three folders down with a `prefix-old` and a wrapper without HorizonXI beside it:
  adopted with its prefix10, home its folder, the game's Wine found there, no wrapper created,
  need 0, read-only; the old `FFXI on Mac Wine.app` with no game (its Wine used, the game still
  needed, a part-downloaded base subtracted); a bare HorizonXI 2.0.3 on the same drive: its line,
  need = Wine + the game's Wine + an update, moved by rename (same inode, one 0.DAT in the whole
  folder, a link left, one wrapper), an older wrapper linking to it collapsed in the picker
  (`keep` honoured, files untouched), different files kept apart, a second Setup reusing it, world
  folder settings re-pointed; a bare client into a wrapper with an unfinished download (that
  download to the injected Trash); a bare SquareEnix (moved into `HorizonXI/SquareEnix`, same
  inode, the base still needed); Eden / CatsEyeXI / Gaia XI clients and SquareEnix folders left
  alone; another drive (injected `sameVolume`): the copy line and need, a move refused with
  nothing changed, then `copyTree` verified with the original byte-for-byte as it was and no hidden
  leftovers; a SquareEnix linked to a missing drive (one line naming it, no "restart", Download
  Fresh in the chosen folder with the full need, the link unchanged); that install being the
  chosen folder's own "FFXI on Mac" (refused); a SquareEnix link onto a gone drive; a usable
  client beside a ghost one wins; the chosen folder being the client itself; bounds (depth 4,
  Library, inside an app: nothing); an empty folder; the TCC-gated folders; the game's Wine in an
  earlier folder still found; Move… not offered for the ghost install.
- `--selftest-setup-progress` (new): 27/27. update-client.sh's install output as printed (aria2
  summary blocks, a readout that drops from 50 % to 40 %, the unzip's figures, two updates):
  never goes back, stages Downloading → Unpacking → Updating, 25 % of the torrent = 14 % on the
  button, 40 % unpacked = 69 %, the base in place = 85 %, the end = 100 %; the same output a byte at
  a time; a `\r` readout; what launcher.log keeps; an install over a complete client; an update
  alone; game-wine.sh; SetupMeter plans and a whole chain with jobs ending at 0 (only rises, under
  100 %), a step dropped (jumps) and added (never drops), an unplanned step; the button's labels,
  no figure under 1 %, every label ≤ 26 characters, plain words.
- `--selftest-primary-action`: 77/77; the label rule now also accepts Setup's step names (each
  checked as a greyed progress label).
- Every other suite passes: addon-policy, addon-source, addon-installer, addon-profile,
  addon-scrub, addon-install, cursor-fix, guide-disabled, narration-disabled, multiworld,
  retroachievements (47), updater, perf, ui-text, single-instance.
- `scripts/tests/setup-scripts-test.sh <aria2 archive>` with `HXI_LAUNCHER_BIN`: 101 checks, all
  pass (the real game-Wine tarball case skipped: it is 204 MB and this part's rule was no download
  over 50 MB). The stub aria2c now prints aria2's summary block once per `--summary-interval`; new
  checks: every aria2c call asks for 2 s, its readout reaches the output, "==> unpacking 100%"
  between "extracting" and the updates, no `.base-extract`/`.update-extract` left; a slow unzip
  (stub ditto writing half first) shows "unpacking 50%", the base unzip's figures only rise; a
  SquareEnix linked to another folder is unpacked through the link with the link kept; and the
  launcher's own `--progress-trace` of the real output: rising figures, Downloading → Unpacking →
  Updating, the torrent's 25 % at 14 %, ending at "100 Updating HorizonXI".
- Real Mac, read-only, after part 4: `--next-action` for HorizonXI, Local server and CatsEyeXI →
  `setup:data-drive | Setup | The 'Games' drive isn't connected — reconnect it or press Setup.`
  (exit 10); `--check` the same line (exit 1). `ExistingInstall.find` was never pointed at the
  x10 install or any real folder.

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
- Part 3: the game's Wine downloaded by the launcher itself from GitHub (the script ran only on
  `file://`; the one real download was a plain curl to pin it), Stop during that download from
  the window, its chooser for an install made before b60, the button's "Setting up… N%" for it,
  and `softwareupdate --install-rosetta` (Rosetta is installed here; only the detection ran, with
  the injected flag). A launch on a freshly downloaded wine-coop (it is byte-identical to the
  measured one apart from the MoltenVK swap Play makes itself, but no game ran on it).

- Part 4: the chooser's found line and its live update while browsing, the two questions (Use
  Them / Download Fresh, the unreachable one), the button's step names behind the setup sheet, a
  real 15 GB move or copy of a client, the copy's figure, Setup adopting a real `siku.app`
  (Daniel's is behind the ghost 'Games' drive and was never looked at), aria2c 1.35.0's real
  readout at `--summary-interval=2` when its output is a pipe (the stub prints the documented
  summary block), and the unzip's figure on a real 9.4 GB zip (only fixture zips).

## Possible next pathways

- **Space estimate per world**: the chooser uses HorizonXI's 28 GB for everyone (25 GB for
  another world's folder); CatsEyeXI and the retail-client worlds differ.
- **Local server**: lsb-server.sh still builds where it always did, outside the chosen folder.
- **A lone SquareEnix still costs the 9.4 GB base**: HorizonXI ships Ashita and its config only
  inside the base zip, so update-client.sh fetches all of it and unpacks over the moved files. An
  unzip of only the non-SquareEnix part (`unzip -x 'HorizonXI/SquareEnix/*'`) would save the 15 GB
  unpack, not the download.
- **Existing-install detection is HorizonXI's**: another world's client found in the folder is
  left alone, never offered to that world.
- **A link left where a client was moved from** keeps other references working; Daniel may prefer
  none (it shows as an alias in Finder).
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

## Review fixes (2026-10-15, adversarial review of `beta-b59..beta-b60`)

Each fixed in its own commit on `beta-b60`; the full self-test set, `setup-scripts-test.sh` and
the read-only `--check` / `--next-action` on Daniel's Mac were rerun afterwards (results below).

- **`--check`, `--next-action` and `--fix` looked at a different install from the window**
  (`776418e`). A `swift build` binary has no bundle identifier, so its `UserDefaults.standard`
  was its own domain (`HorizonXILauncher`) holding an old `install.last` (siku.app), while the
  window read `org.batesai.horizonxi-on-mac` (`…/FFXI on Mac/FFXI on Mac Wine.app#prefix10`).
  `AppDefaults.store` is the app's domain whichever binary runs (self-tests keep their own). On
  Daniel's Mac they now report the window's install: HorizonXI and Local server `play` (only COM
  registration missing, which Play does on the way in), CatsEyeXI `setup:data-drive` ('Games').
  The stale `install.prefix` key in the app's defaults is read by nothing in any branch or in the
  history, so it was left alone.
- **game-wine.sh had 19 stray lines above its `#!/bin/zsh`** (`cc4e129`), pasted in by `9e5c437`:
  three "command not found" lines and a `mkdir ''` in every Setup log, and no interpreter line.
- **Stop never ran the scripts' cleanup** (`2953967`). zsh runs an EXIT trap on a signal only when
  that signal has a trap of its own, so a Stop mid-unzip left up to 15.5 GB in
  `updates/.base-extract` (and game-wine.sh its unpack folder). Both trap TERM/INT/HUP now.
  install.sh had no trap at all: a Stop or Quit mid-Repair left its Wine session (the hung
  regsvr32) running; it now ends the prefix's session. Fixture test 31 covers both.
- **No Stop for most jobs, and Quit left every job running** (`ed0a59f`, `79c917d`). Repair
  (Setup's last step), Setup's copy, Move, Wine's prefix update and the client downloads had no
  Stop; "Quit anyway" killed nothing (scripts, aria2c, ditto, tar and their Wine sessions ran on
  as orphans). `JobKill` (Jobs.swift) tracks every job process with its Wine prefix: Stop (now
  beside every job's progress) and Quit end what it started, then it, then `wineserver -k` for
  that prefix. Wine's prefix update is bounded (5 minutes). An installer's Stop is honoured
  between its steps (no "download failed" page on a Stop).
- **Setup's Wine step** (`9a6c711`): a second Setup started while a cancelled one still built in
  the background ran two builds into one folder; one at a time now. The first `wineboot` was
  unbounded and its output pipe was read to the end, which waits on every program the session
  started (a crash-looping explorer never closes it): output goes to a file, wineboot is bounded
  at 5 minutes, and `wineserver -w` (1 minute) before system.reg is checked.
- **Move could copy a system folder as game data** (`842616d`): a link under the game's folder to
  `/Users`, `/Applications` or `/System` would have been copied in its place. Those stay links.
- **A Move or copy cut short by Quit left its hidden copy for good** (`797f562`); the next one
  sends its own earlier hidden copies to the Trash first (exact name only).
- **The first client of a multi-client world had no Stop** (`31e2f19`): the RUNNING list dropped
  the selected world's session assuming the main button was its Stop, but there it is Play
  Another (and "Starting…" while a launch starts). It is left out only while the button is Stop.
- **diskutil on the main thread** (`1b93c24`): Repair, Update and the downloads asked
  `Preflight.driveState` (which runs `diskutil list`) on the main actor for their refusal's
  wording; they say the plain drive line now.

Checked and left as they are: the main button can never be a greyed Play (resolver and self-test
agree, every `.disabled` on it is the resolver's); no user-facing "restart the Mac" anywhere;
Gemini 2.5 Flash's three findings (Move's Trash filter, game-wine.sh's tar, install.sh's launcher
line) did not hold up: the filter excludes only the new copy and what contains it, the tarball's
SHA-256 is checked before tar runs, and the launcher line is a log line whose status is chmod's.

Still not bounded or not stoppable: the local server's build (LocalServer, its own card), Rosetta
once macOS's password prompt is accepted (Apple's `softwareupdate`, root), the main-thread
`GameRegistry.point` at Play (headless now, but no time limit), and `diskutil mount` behind
Repair on an unmounted drive.

Rerun after the fixes (release build, the two old warnings only): all 18 self-test suites pass
(`--selftest-primary-action` 77/77, `--selftest-install-location` 107/107,
`--selftest-setup-progress` 27/27, the other 15 "all checks passed"); `setup-scripts-test.sh`
105/105 (test 29, the real game-Wine tarball, skipped: 204 MB is over this run's download
limit). On Daniel's Mac, read-only: `--check` names `…/FFXI on Mac/FFXI on Mac Wine.app
[prefix10]` and exits 1; `--next-action` gives `play` for HorizonXI and Local server (exit 0)
and `setup:data-drive | Setup | The 'Games' drive isn't connected — reconnect it or press Setup.`
for CatsEyeXI (exit 10).
