# Issue #92 — "Can't install game after selecting the .exe" (Eden)

Reported 2026-11-24 on 3.11.1 b127 (MacBook Pro M5 Pro, macOS Tahoe). Fixed on branch
`fix-installer-adopt-92` (3.11.2 b128).

## What the reporter did

Eden XI is not in the world list (it is DarkStar-lineage; the list is LandSandBoat only), so they
added it by hand as `eden` (Add a server). Setup made `…/FFXI on Mac/Games/eden`, they picked Eden's
`Installer.exe`, and the button sat at a disabled **SETTING UP…** with no progress bar. Their check
pane then said polcore.dll, Ashita, the game data and the registry were all missing under
`Games/eden`.

## Root cause (reproduced on this Mac with the launcher's own Wine)

| # | Cause | Evidence |
| --- | --- | --- |
| 1 | Eden's installer (NSIS 3.06.1, `Installer.exe` + `data.pak` 7z, inside Eden534/535.zip) **ignores `/D=C:\Games\eden`** and always installs to `C:\Eden` in the installers' prefix (`prefix-installers`). | Repro A: exit 0 after 145 s, 63,790 files / 14.62 GB in `drive_c/Eden`, 0 files in `Games/eden`. Its `.onInit` sets `$INSTDIR` to `<system drive>\Eden\` after NSIS applies `/D`. |
| 2 | **"Run installer…" never adopted the client.** `findInstalledClient` found `C:\Eden`, but only the built-in download path set `onClientInstalled`; the picker path left `dataPath` at the empty folder. | Every check in the reporter's pane, line for line. |
| 3 | **No progress at all.** The chain ended as soon as the installer started (`setupGameStep` returned false), the job had no progress source, NSIS `/S` shows no window, and every status line went to launcher.log only. | ~50 s of wineboot + ~2.5 min (M1) of silent install under a greyed button. |
| 4 | The installers' prefix was made by an unbounded, unstoppable `wineboot` with undrained pipes and its progress window shown. | Did not hang here (24–48 s), but Stop did nothing during it. |
| 5 | Latent, next in line: Repair (install.sh) assumed `SquareEnix` inside the Ashita folder (Eden keeps it beside it: exit 4); a world added as `Eden` was deleted at the next launch (merge dropped every retired name); Ashita v3 profiles never counted their saved account; an empty `installURL` made Setup say a download page had opened. | Code trace, 2026-11-24. |

Eden facts gathered on the way (2026-11-24, from edenxi.com's own `/api/v1/misc/config`):
edenxi.com/install links **Eden535.zip** (bit.ly/Eden535 → Drive id `1kLPVfruGCzXkkT2XQ-pmiSh4akHMLjo2`,
5,771,573,370 bytes); Eden534 is the 2023 build it replaced. No web signup (their API's
`POST /register` is a 404): accounts are made in the loader console; registration codes "not
currently required" (their news, 2024-10-12); `!getcode` is an in-game command, not a Discord bot.
The login host is `play.edenxi.com` (no TLS on 54231: DarkStar lineage).

## The fix

- **`InstallerClient`** (new): after an installer exits, the client is the world's folder if it now
  holds one, else a real folder under `C:\`, `C:\Games` or Program Files named for the world, else
  the newest one changed since the run (links are never candidates: they are other worlds'
  folders). Only what the run made or changed counts (a snapshot of the candidates is taken just
  before it), named for the world first. It is **moved into the world's folder** by renaming each
  item (same volume: instant, no extra space; another drive: copied after a space check, then the
  originals removed), and the emptied folder (removed with `rmdir`, never recursively) becomes a link
  to it, so the installers' registry (`C:\Eden\…`) and a later run of the same installer land there
  too. Nothing in the world's folder is overwritten: a name already taken leaves the new copy where it
  is with one "!!" line, and the world keeps playing the client it has.
- **A half-written client is never taken for a finished one.** A silent NSIS run that exits non-zero
  is a failure. After a Stop or a failure, whatever the run was writing gets a
  `.ffxi-on-mac-incomplete` marker; a leftover is adopted before an install only when it is named
  for the world, unmarked and has the game's three DLLs.
- **Progress:** the button shows the installer's real percentage. The total comes from the
  payload beside the installer (`bsdtar -tvf data.pak`, about 1 s); what has been written is free
  space that went on the volumes involved (one `statfs` every 2 s, wherever the installer writes).
  Only archives this job unpacked count, or a `data.pak` beside a picked installer (never every
  archive in Downloads). Unknown total: it counts gigabytes ("Running installer… 14 GB"), in Setup's
  chain too. In Setup's chain the step is named "Running installer".
- **Setup waits for the installer** (both the picker and a built-in download), then configures the
  client (Repair) like any other world. A client left behind by 3.11.1 (`C:\Eden`) is adopted
  before asking for an installer, so the reporter does not have to install 14.6 GB again.
- A picked `.zip` is unpacked into the world's own `installer-downloads` (the drive the client goes
  on) after a space check, and that copy is removed once the client is in place.
- Free space is checked before unpacking and before installing (payload + 1 GB); an install is
  refused only when none of the volumes it may write to has room.
- The installers' prefix: bounded (300 s), stoppable, no progress window, output to /dev/null,
  Mono/Gecko still installed from the wrapper's own copies. A `.ffxi-on-mac-booting` marker stays
  until wineboot finished, so a stopped or timed-out one is booted again, never used half-made.
- Stop at any point: no verdict, nothing adopted, no stray "!!" line.
- `linkGamesFolder` only ever replaces a link (it used to delete whatever was at `C:\Games\<world>`).
  No `/D` for a world name with a space (Wine quotes it; NSIS then ignores the whole argument).
- Repair passes the SquareEnix folder to install.sh (identical to its default for HorizonXI).
- A world added by hand is kept at every launch even when named like a world this project retired,
  and blanks are filled from that world's research (`fillFromCatalogue`: host, how accounts work,
  its own download page). It still never appears in the built-in list.
- Eden's catalogue entry: Eden535, edenxi.com/install, accurate account text.
- Ashita v3 (`.xml`) profiles: a saved account counts (`Credentials.bootHasAccount`).
- The installers' prefix is never offered as an install.
- Setup's once-per-press rule treats every `.game` need as one step (an installer that left part of
  the client no longer opens a second picker in the same press), and a world switched while an
  installer ran is not configured in its place.
- "Run installer…" asks for the installer before making any folder, and is not offered for HorizonXI
  (whose empty folder means the wrapper's own client).
- A hand-added world never borrows Phoenix XI's research (it has its own sign-in).

### Review (2026-11-24)

Three independent reviewers (Runner pipeline; Setup chain for every world; data safety), each
finding checked by a skeptic: 20 kept, 0 refuted. All are fixed above. Not changed: a
cross-volume copy that fails or has no room still leaves the client in the installers' prefix
(said in one "!!" line); `InstallMove` still does not carry a world whose folder is inside
`prefix-installers` (only the pre-3.11.2 built-in download path ever stored one).

## Verification

| Check | Result |
| --- | --- |
| `--selftest-installer` (new, fixture folders) | 58/58 |
| 17 existing offline suites, rerun after the review fixes (primary-action 95, setup-progress 27, install-location 107, install-selection 21, ui-text, server-catalog 20, boot-profile 43, multiworld, prefix-scope 14, world-prefix, leftovers 66, carryover 61, graphics 80, perf, dxvk-cache 35, retroachievements 63, runner-gate) | all pass |
| Live 1: real `Installer.exe` through `Runner.runLocalInstaller` (`--selftest-installer-live`), launcher's Wine, fresh test wrapper on x10 | prefix 35 s, button 3 % → 99 % over 130 s, outcome `installed` into the world folder (14.55 GB), `C:\Eden` → link |
| Live 2: the `.zip` picked instead | unpack shown as 0–20 % (13 s, into the world's `installer-downloads`), install 20 → 99 %, `installed` (14.55 GB), the unpacked copy removed |
| Live 3: re-run over a real 14.6 GB `C:\Eden` left by 3.11.1 | `installed`: the leftover moved into the world folder, `C:\Eden` → link. No percentage during this run: rewriting files that are already there uses no new space, so the meter reads 0 (in the app the leftover is adopted before any installer runs, so this needs a deliberate re-run) |
| Live 4 (final code): Stop at 100 s, then the same installer again | Stop: outcome `stopped` at 59 %, nothing adopted, `C:\Eden` marked incomplete. Re-run: starts at 60 % (what was already there counts), climbs to 99 %, `installed` (14.55 GB) into the world folder, mark cleared, `C:\Eden` → link, no Wine left running |

Not tested: the window itself (Setup's chain and the picker are App code; the Runner job under them
was run for real); an M5/Tahoe Mac; a non-APFS volume for the reporter's
`/Volumes/jeremypiret-windows`; logging in to Eden (needs an Eden account; this project is not
approved by Eden, and addons are never tested on hosted servers).

## Pathways for later

- Eden's account is created in the loader console, which Play never shows. If Eden matters, show
  xiloader's console for worlds whose `accountHow` says "loader window", or add a native
  Create account like LoginAccount (Eden's protocol is plain TCP on 54231, see EdenServer/xiloader).
- A per-installer known-folder table (Eden → `C:\Eden`) would let the files land in the world folder
  during the run instead of being moved after; the move is instant on one volume, so not needed yet.
- Installers that hand off to a second process and exit early (a launcher that downloads in a child)
  end the job before their files exist; the job then says "No game files appeared". Watching the
  prefix's wineserver instead of the first process would cover them.
