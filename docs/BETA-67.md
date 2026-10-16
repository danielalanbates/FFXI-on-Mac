# Beta 3.9 build 67 (local only)

Branch `beta-b67`, on top of `beta-b66` (87163ba). Local beta: no GitHub release, nothing pushed,
not installed.

One change: a new install gets the macros, equipment sets, keybinds and addon settings of the
install played before it (`CarryOver`).

## Why

Daniel, 2026-10-15: the install Setup made that day (a fresh HorizonXI download into the folder he
chose) started with none of his macros (`mcr*.dat`), equipment sets (`es*.dat`), keybinds or
other per-character client data, and none of his Ashita addon settings or window layout. They
were put back by hand that evening by copying the old install's `USER` and Ashita `config` over
the new one. What that restore replaced is still beside them in the live install:

- `SquareEnix/FINAL FANTASY XI/USER.bak-2026-10-15-before-restore`: the new install's own USER
  after its first login. One character folder (`13459`) with `mcr.dat`, `mcr1.dat`, `mcr9.dat`
  and the rest, written minutes after that login, plus `tig.dat`.
- `config.bak-2026-10-15-before-restore`: the new install's own config. Compared with the
  restored one, the restore changed `addons/` (13 addon folders became 23), `imgui.ini` (85 bytes
  became 1,897), `minimap/minimap.ini` and `nameplate/defaults.ini`. `boot/`, `ashita/`,
  `sandbox/`, `pivot/` and `Shorthand/` are the same in both.

`scripts/` was not restored and has no backup.

## What is carried

From the client's folder (the Ashita folder, `drive_c/HorizonXI` in a wrapper):

| What | Carried | Why |
| --- | --- | --- |
| `SquareEnix/FINAL FANTASY XI/USER/**` | every file | one folder per character (macros, equipment sets, keybinds, filters, menu state) and the files beside them (`tig.dat`, `cmb*.dat`) |
| `config/addons/**` | yes | every addon's settings, per character (`<name>_<id>/`): LuAshitacast's gear sets, HXUI, Timers, Vanaguide's nav grids (31 MB of the live install's 32 MB) |
| `config/imgui.ini` | yes | Ashita v4's ImGui window layout. It lives at the top of `config/` |
| `config/<plugin>/` (minimap, nameplate, Shorthand, …) | yes | each plugin's own settings |
| `config/boot/` | **never** | the boot profiles: the launcher writes them on every Play, and they hold the account and password |
| `config/ashita/` | never | Ashita's memory signatures (`*.datmap.ini`, `*.offsets.ini`, `*.pointers.ini`). They belong to the Ashita build beside them; an older install's would be wrong for a newer client |
| `config/sandbox/`, `config/pivot/` | never | the launcher keeps both right for each install (`Sandbox.swift`'s bypass, `Branding.swift`'s overlays) |
| `scripts/default.txt` | never | it says which addons and plugins load. HorizonXI's own launcher owns two blocks of it and HorizonXI's updates change it, so an older copy can load what the new client lacks or drop what it needs. The Addons… sheet sets it again in a minute. The manual restore left `scripts/` alone too |
| addon code (`addons/<name>/`), `chatlogs/`, `screenshots/` | no | not settings. An addon installed by hand into the old install is not copied; its settings are, and it finds them once it is installed again |

The `config` folders are compared without case (`Boot/` is skipped too). `.DS_Store` is never
copied. A link inside these folders is counted and skipped, never followed. A folder that is a
link (siku.app's `SquareEnix`) is followed. Empty folders are not copied (the old fixture has
one, `USER/5155`).

## When

Once per install, by itself, and only for HorizonXI's client: the worlds whose client Setup
downloads (HorizonXI, and the local world, which plays it; `carriesOver`, `App.swift:1981`).
Another world's characters live on another server, so nothing is ever carried into its folder.

1. **Before the download** (`runSetup`, the `.game` step, line 1960): a `pending` marker with the
   folders Setup knows (`CarryOver.prepare`). A launcher quit in the middle of the 9.4 GB download
   still knows them when Setup is pressed again.
2. **Right after Setup downloads the client** (line 1964). That is before the registry/COM
   configure step, so a configure that fails does not lose it.
3. **Before that install's next Play**, if it is still pending (`perform(.play)`, line 1775; a
   handed-over `--play`, line 2497). Setup leaves it pending when:
   - a game was running;
   - another launch held the launch lock;
   - the install in use before Setup could not be read (its drive not connected);
   - the copy failed before anything was changed (for example no room).

   At Play, if a game is still running (or the lock is held), Play shows **one line** instead of
   starting: "Close the other game first: your macros and settings are copied to this install
   before its first Play." (or "Another launch is under way. Press Play again in a moment."). That
   is the only new text. Without it, the first session would log a character in, and nothing
   would ever be carried. A second press plays anyway, so a process that never ends can't hold
   Play up. A `--play` is not carried out then (one `!!` line in launcher.log).

A marker in the client's folder, `.ffxi-on-mac-carryover` (JSON: state, date, source path,
counts), makes it once only. Its states:

- `done`: copied. Never by itself again. `--carryover-apply` also writes `done`.
- `skipped`: a character had already played in this install. Never by itself again.
- `nothing`: no earlier install with characters was found. Never by itself again.
- `pending`: waits for the next Play, with the folders Setup knew.
- `applying`: files were going into place (or some could not be). Finished at the next Play or
  Setup from the same client, adding only what is still missing (`finishing`), even after a
  character has logged in.

A Play on an install with no marker does nothing about carry-over: only Setup starts one. The
marker travels with the install (Move… copies it). It never holds file contents or anything from
a boot profile.

## Only into a fresh install

**The rule:** an install is fresh while no folder in its `USER` holds a file. FFXI creates a
character's folder the first time that character logs in there, and writes its macro files then.
b66's new install had them minutes after its first login. Before that, the install has no
character folders. Files at the top of `USER` (`tig.dat`, written at the title screen) and empty
folders do not count.

Why not the other tests the brief offered:

- **"No `mcr*.dat`"** is the same test, narrower.
- **"All mcr/es files byte-identical to a pristine default"**: a first login writes macro files
  with a header and an MD5. A "pristine" pattern would have to be learnt and trusted, and
  getting it wrong overwrites real macros.
- **"Destination older than source"**: a copy keeps file dates, as the manual restore did, and
  a client unzipped from HorizonXI's archive keeps the archive's dates. Both make dates
  meaningless for this.

**Into a fresh install:**

- What is missing is added.
- What is the same is left.
- What differs (a file the new client shipped, such as a default `imgui.ini`) is replaced. A copy
  of it goes to `<USER|config>.bak-<yyyy-MM-dd>-carryover` beside that folder first, then `-2`,
  `-3`, … if that name is taken.
- Files the source does not have stay.

**Into an install a character has played in:** nothing happens by itself (`skipped`). By hand
(`--carryover-apply`), only what is missing is added: whole character folders it does not have,
and files outside them that it does not have. A character folder it already has is left whole,
compared without case on a case-insensitive drive. Nothing is replaced, so no backup is made.

## From where

**The candidates** (`CarryOver.knownRoots`), in this order:

1. HorizonXI's client in the install in use before Setup, or in `install.last` while its drive is
   gone.
2. That wrapper's own client.
3. Every install the scan found.
4. The install Setup made in each folder chosen before (`install.location`, `.earlier`).
5. A client in the chosen folder the user answered "Download Fresh" to.

They are collected when Setup is pressed, before anything changes, and kept across presses.

**The filtering** (`CarryOver.candidates`):

- A folder that exists but can't be listed (no permission, macOS privacy, a link that loops) is
  an unreadable candidate, not an absent one. Only "no such file" means absent.
- A folder holding more than one client (`~/Games/FFXI`) names none of them.

- Each USER folder counts once, by its real path, however it is reached: a link, a second
  wrapper on the same files, `/var` against `/private/var`.
- The destination's own USER is never a candidate.

**The choice** (`CarryOver.choose`):

- The one whose USER has the newest file wins. FFXI rewrites some of those files every session,
  so this is the install played last. On equal dates, the first in the list wins.
- A candidate with no character is never chosen.
- A candidate that cannot be read (no permission, a drive not connected, a link that loops) is
  never chosen.
- **The install in use before Setup can't be read:** Setup waits for it rather than take an older
  one. On Daniel's Mac that is x10 not mounted. At the first Play, the last chance before a
  character logs in, the carry-over takes the best one it can read.
- Nothing usable, but something unreadable: it waits.
- Nothing at all: `nothing`.

Only HorizonXI's client is carried by itself. Other worlds keep their characters on other servers
(different character ids, different `tig.dat`/`cmb*.dat`), and the launcher does not track an
earlier client for them. `--carryover-apply` works for any two clients with the retail layout.

## How (`CarryOver.apply`)

**Before anything:** the launch lock is held, so no launch, Repair or Stop of any launcher process
starts underneath. No game client, injector or x87 sidecar of any world may be running
(`LiveClients.snapshot`). Then the destination is read again.

1. **Room.** On each drive written to: the copies plus the backups, plus the 8 GB floor on the
   Mac's own disk. Short, and nothing is written.
2. **Staging.** Every file is copied into a hidden folder beside its destination
   (`.USER.carryover-<uuid>`, `.config.carryover-<uuid>`). The copy is `copyfile(3)` with
   `COPYFILE_ALL`: data, mode, dates, extended attributes, ACL. It never goes through a link and
   never writes over anything. Each copy is compared byte for byte with its source. One failure:
   the staging folder is removed, and **nothing in the install has changed**.
3. **Backups.** Each file that will be replaced must still be as the plan saw it (size and date).
   If it was written since, it is newer than anything carried and stays. If it is unchanged, it
   is copied to the backup folder and compared. One failure: staging and backups are removed,
   and nothing has changed.
4. **Into place.** The marker first says `applying`. Then one rename per file, within the same
   drive:
   - The folder it goes into must really be inside the destination. This is checked before any
     folder is made and again after, so nothing is written, and no folder made, through a link
     out of it.
   - An added file goes in with `renamex_np(RENAME_EXCL)`, which never replaces anything that
     appeared meanwhile.
   - A replaced file goes in with `RENAME_SWAP`. The file that comes out must equal its backup;
     if it doesn't, it is swapped back.
   - On a file system without these flags, the same checks are made just before a plain
     `rename(2)`. **x10 is one:** it is HFS+, and its `getattrlist` volume capabilities offer
     `RENAME_EXCL` but not `RENAME_SWAP` (read-only probe, 2026-10-15; `/`, ~/Downloads and the
     Games drive are APFS and offer both). Any failure of either flag (other than "already
     there") takes this path; `renamex_np` changes nothing when it fails.

   A file that fails here is listed, the rest go in, and the marker stays `applying`.
5. The staging folders are removed. A staging folder left by a launcher that quit mid-copy is
   removed the next time (it holds only copies).

Copying never runs on the main thread: Setup and Play run it in `Task.detached`.

**launcher.log, one line, never on screen.** For example (from the fixture below):

```
==> carried over macros and settings from …/siku.app/Contents/SharedSupport/prefix10/drive_c/HorizonXI: 20 characters, 829 files (3.0 MB); 1 replaced, the originals kept in config.bak-2026-10-15-carryover
i  carry-over of macros and settings waits (a game is running); it runs before this install's first Play
i  carry-over of macros and settings: not done, a character has already played in this install
```

**On screen: nothing**, except the one Play line above. The copy takes about a second for Daniel's
3 MB USER folder; his config is 32 MB, almost all Vanaguide's nav grids. Setup's button shows the
step it was already on.

## By hand

```
FFXI-on-Mac --carryover-report [--world <name>] [--to <folder>] [--from <folder>]...
FFXI-on-Mac --carryover-apply --from <folder> --to <folder>
```

A folder is a wrapper `.app`, an "FFXI on Mac" folder (or the one it is in), a client folder, or
(`--from` only, USER alone) a SquareEnix folder.

**`--carryover-report`** is read-only. It shows the destination (the install in use, resolved for
the world, HorizonXI by default, or `--to`):

- its USER and config: counts and sizes;
- whether it is fresh;
- its marker;
- whether a game runs now;
- the candidates, each with its newest date, and the one that would be used;
- what would be copied: added, replaced and the same, per folder, and characters added or kept;
- whether it will run by itself.

It never shows a file's contents and never reads `config/boot`. It does compare the bytes of
same-size files to count "the same".

**`--carryover-apply`** follows the same rules:

- It refuses while a game runs or a launch is under way.
- Into a played install, only what is missing goes in.
- It makes backups, and never copies a boot profile.
- It prints the plan and the result, then writes the marker as `done`.
- Exit codes: 0 copied (or nothing to copy); 1 refused (a game is running, the lock is taken, it
  can't be read, the two are the same client); 2 no client found; 64 usage; 70 failed, nothing
  changed (or some files not put in place).

Both are headless and exempt from SingleInstance (`isExempt`), like `--send-ashita`. They print to
stdout/stderr only. launcher.log is not touched.

## Tests

**Builds.** Release build (`swift build -c release`, `nice -n 19`, scratch path
`~/Downloads/FFXI-on-Mac-build/swift-build`). Each build started only after checking that no game
process was running. Only the two old warnings (LocalServer.swift:251, Runner.swift:1971).

**`--selftest-carryover`, 62 checks, all pass.** They run on installs made up under `$TMPDIR`
(removed afterwards), with a launch lock file of their own:

- Reading:
  - characters are the folders with a file;
  - links (one to another folder, one back to USER itself) are counted and not followed;
  - boot/ashita/sandbox/pivot are skipped in any case;
  - `.DS_Store`;
  - a missing folder;
  - an empty character folder.
- Fresh destination:
  - every USER file arrives, byte for byte and with its date;
  - addon settings, gear sets and `imgui.ini` arrive;
  - the boot profile is never copied, and the source's password appears in no destination file
    and not in the log line;
  - ashita/sandbox/pivot are not copied;
  - the replaced `imgui.ini` is kept, as it was, in `config.bak-<date>-carryover`, and only it;
  - a shipped file the source lacks stays;
  - no hidden folder is left.
- Once: a second Setup or a Play does nothing, even with the source still there. A Play never
  starts one Setup did not leave pending.
- Played destination: nothing by itself (`skipped`). By hand, only what is missing: `99f` whole,
  `cmb0.dat` and the settings. `1410b` is kept whole although the destination has it as `1410B`.
  Nothing is replaced and there is no backup.
- Choosing:
  - a SquareEnix behind a link is followed;
  - one USER reached three ways is one candidate;
  - never the destination's own files, even through a link;
  - the newest wins in any order;
  - equal dates go to the first in the list;
  - a client with no character is never chosen;
  - `.app`, "FFXI on Mac" and SquareEnix folders are accepted by hand.
- Missing and unreadable:
  - no source at all gives `nothing`, said once, never again;
  - an unreadable USER (mode 000) is never chosen, and a readable one is;
  - only an unreadable one: it waits, then is done at Play once readable;
  - the install in use before Setup unreadable: Setup waits, and the first Play falls back to the
    readable one;
  - a client folder with no game is not waited for;
  - a client behind a drive that isn't connected says so.
- A game running, the lock held elsewhere, no room: each waits, changes nothing, and is then done
  with nothing running and room. "No room" is logged as a failure.
- A source file that can't be read: nothing changed, no backup, no hidden folder.
- A client inside a folder that can't be read (mode 000) is an unreadable candidate, not a
  missing one. When it is the install in use before Setup, Setup waits.
- A folder holding two clients names neither.
- A copy cut short (marker `applying`) is finished at the next Play: only what is missing goes
  in, a differing file is kept, and there is no backup.
- `prepare`:
  - writes a pending marker with the known folders, and adds to it on a second call;
  - never touches a `done` marker;
  - never makes a folder on a drive that isn't there.

  A download finished after a relaunch uses the folders kept with the install.
- The Play outcome: a game running gives `waits == .game`; the lock held gives `.launch`.
- Files changed or appearing between the plan and the copy are left as they are.
- Nothing is written, and no folder made, through a link out of the destination (a deeper
  source folder included).
- With the rename flags off (the HFS+ path): added, replaced with a backup, and a file that
  appeared meanwhile is kept.
- A second backup the same day gets `-2`.
- Case:
  - two names that differ only in case, onto a case-insensitive drive: the newer is copied;
  - onto a case-sensitive drive: both;
  - a replaced file keeps the destination's spelling;
  - case is decided for each folder by its own drive.
- The marker round-trips. The new flags are exempt from SingleInstance.
- Daniel's old USER folder (`fixture/old-USER/USER`, 826 files, 20 characters, 3.0 MB), copied
  into a test install, then carried into a fresh one: every file byte for byte, dates to the
  microsecond, in 0.6-0.9 s.

**The CLI on a fixture** (`~/Downloads/FFXI-on-Mac-build/fixture/carryover/`, 5.3 MB). An old
`siku.app` whose `SquareEnix` links to `old-games/FFXI/SquareEnix`, which holds a copy of the old
USER. A fresh "FFXI on Mac" install. Fake boot profiles.

- `--carryover-report --to … --from …`: 20 characters, 826 + 2 added, 1 replaced; "only after
  Setup downloads a client here".
- `--carryover-apply`: done, exit 0.
  - `diff -r` shows the USER folders identical except the empty `5155`.
  - Dates are equal.
  - The new boot profile is untouched, and the old one's fake password is in no new file.
  - `config.bak-2026-10-15-carryover/imgui.ini` holds the replaced default.
  - The marker reads `done`.
- Applying again: played mode, nothing to copy, exit 0.
- Usage (64), no client (2) and the same client (1) are refused.

**The report on Daniel's Mac, read-only, no game running (3.4 s, the build before the review
fixes):**

- The destination is the live x10 install: played, no marker.
- The candidate is `siku.app` (USER: 20 characters, newest 2026-10-03; config 420 files).
- "Only what is missing": 1 config file.
- "by itself: no".
- `config` is 31.6 MB, almost all Vanaguide's nav grids.

Nothing was written there.

**All 26 suites pass:**

- carryover: 62, new;
- addons-live: 51;
- primary-action: 77/77;
- install-location: 107/107;
- install-selection: 21/21;
- setup-progress: 27/27;
- graphics 64, boot-profile 43, dxvk-cache 39, leftovers 26, news 36, retroachievements 47;
- all checks passed in: addon-install, addon-installer, addon-policy, addon-profile,
  addon-scrub, addon-source, cursor-fix, guide-disabled, multiworld, narration-disabled, perf,
  single-instance, ui-text, updater.

launcher.log was identical (inode, mtime, size) before and after the suites, the CLI runs and the
report.

In the last full run, `--selftest-updater` failed 2 checks: "probe ran with the helper's five
arguments" and "its PATH is the fixed one". Its spawned probe has 15 s to write a file, and the
Mac's load average was about 10. It passed alone twice right after, and in both earlier full
runs. Nothing in b67 touches the updater.

## Not verified

- **The window's path has never run.** No Setup downloaded a client under b67, and no Play found
  a pending marker. The Setup hook and the Play hook are a few lines each over the function the
  tests drive (`CarryOver.automatic`), but they have not been seen working in the app.
- **macOS privacy in the app.** If a candidate is on a drive the app has no access to, the read
  fails and that install is treated as unreadable. Whether macOS asks first (a Removable Volumes
  prompt) was not tested.
- **The Play line** ("Close the other game first…") has not been seen in the window.
- **HFS+ itself.** The tests ran on APFS. The HFS+ path (no `RENAME_SWAP`) is exercised by
  turning the flags off in the self-test, not on an HFS+ volume. Nothing was written to x10.
- **Real Wine/FFXI after a carry-over.** Daniel's manual restore showed that a copied USER and
  config work. This copies the same files the same way, but no session has run on a
  launcher-made copy.

## Risks

- **An install played before any carry-over** (every install before b67, including today's
  restored one) is `skipped` the first time Setup touches it. That is by design.
- **Pending, and a game running at the first Play.** Play says so once. A second press plays
  without the carry-over, and after that session the install has a character, so the carry-over
  is skipped. `--carryover-apply` then adds only what is missing.
- **Newest-file choice.** If the newest data is on a drive that can't be read at the first Play,
  an older readable install is used. Two installs with different accounts: the one played last
  wins.
- **Play waits** a second or two, with no text, the one time a pending carry-over runs before a
  Play. A second click meanwhile is ignored.
- **Config is replaced in a fresh install whatever its dates.** A file something wrote there after
  the download (Vanaguide's RetroAchievements snapshot, an `imgui.ini` from a session that never
  reached a character) is replaced by the earlier install's. Each one is in the backup folder.
  This was kept on purpose: the layout is what was lost.
- **Shared path caches** (`Install.resolveAshitaDir`, `resolveSquareEnix`) are written from the
  background task, as Preflight's background probe already does. This race is older than b67.

## Manual check (Daniel)

This needs b67 installed (`./app/bundle.sh /Applications`, with nothing running). It is not
installed.

1. Read-only first. With no game running:
   `/Applications/FFXI-on-Mac.app/Contents/MacOS/FFXI-on-Mac --carryover-report`. Today it
   should say the x10 install has played, no marker, siku.app is the candidate, "by itself: no".
2. To see it work without touching your install: in Setup, choose a new, empty folder on a drive
   with about 27 GB free. Let it download. Then, before pressing Play:
   - launcher.log has one `==> carried over macros and settings from …` line;
   - the new install's `SquareEnix/FINAL FANTASY XI/USER` has your character folders;
   - its `config/addons` and `config/imgui.ini` are your current ones;
   - its `config/boot/horizonxi.ini` is the new one, not a copy.
   - Log in: your macros and equipment sets are there.
   - The folder button (or Move…) takes you back to the x10 install.
3. Optional: start the download while a game is running. launcher.log then says the carry-over
   waits. Press Play on the new install with that game still running: it shows "Close the other
   game first…". Close the game and press Play: the `==> carried over` line appears, then the
   game starts.

## Review (adversarial, 2026-10-15)

A separate reviewer read `beta-b66..HEAD` for data-loss paths. It found none that overwrites or
deletes destination data without a backup. Fixed (commit "CarryOver review"):

1. **An unreadable folder was read as absent.** Any `lstat` error gave an empty tree, and a client
   folder that couldn't be listed was dropped, so an older install could win. Now only
   ENOENT/ENOTDIR means absent; anything else is unreadable, and Setup waits for the install in
   use before it.
2. **A pending carry-over was silently lost** when Play went ahead with a game running. Now Play
   says so once (above), and `--play` is not carried out.
3. **A copy cut short became permanent.** It was then skipped as "played". Now the marker is
   `applying` from the first rename, and the next run finishes it.
4. **Check-then-rename window.** Now `RENAME_EXCL` and `RENAME_SWAP`.
5. **`copyFile` unlinked its target on any failure**, EEXIST included. Not reachable before, now
   impossible.
6. **A relaunch mid-download lost the source list.** Now kept in the `pending` marker before the
   download.
7. **Case was decided once, from USER's drive.** Now per folder.
8. **Folders were made before the link check.** Now checked before and after.
9. **`--carryover-apply` with a folder holding several clients** took the first. Now refused.
10. **Room was checked on the first drive only.** Now every drive written to.
11. **Not in the review, found while fixing it.** A pending marker in another world's folder would
    have carried HorizonXI's characters into it. Now nothing is carried for a world whose client
    Setup does not download (`carriesOver`).

Not changed:

- **"At first Play, an older install wins while the newest is unreachable."** Setup waits for the
  install in use before it. Taking the best readable one at the first Play is the last chance
  before a character logs in.
- **"Fresh is judged on USER only; config replaced regardless of dates."** See Risks.
- **"Shared caches written from the background task."** See Risks.
