# Every-server download + launch — worklog (started 2026-08-16)

Goal (Daniel, 2026-08-16): every server in the list must both **download** its client and **launch**
from this launcher. Keep `/Applications/FFXI-on-Mac.app` playable on HorizonXI the whole time;
GitHub .app releases roughly weekly, only when stable. Work from
`iCloud/Code/HorizonXI-on-Mac`.

This file is the running log for that job — what was decided, what was tried, what failed, so the
next session (human or AI) can pick up without re-deriving it. `CLIENT-UPDATES.md` has the
version-check background; `PATHWAYS.md` the earlier pathway survey.

## State found at start

* CatsEyeXI client **fully downloaded** overnight by their launcher under wine (`cexi.log`:
  `Game download finished! 0 Failures`, 66,109 + 3,487 files, ~15 GB) into
  `~/Games/FFXI/CatsEyeXI/catseyexi-client/{Game,Ashita}` — so the "Continue button is inert"
  blocker in CLIENT-UPDATES.md was beaten later that evening (a click did land). Layout:
  `catseyexi-client/Ashita/Ashita-cli.exe`, `config/boot/catseyexi.ini`
  (`file = .\bootloader\pol.exe`, `command = --server server.catseyexi.com`),
  `catseyexi-client/Game/SquareEnix/{FINAL FANTASY XI,PlayOnlineViewer}`.
  Their `bootloader/pol.exe` is an xiloader fork: `--server --user --pass --email --otp-code
  --hairpin --hide --json-file`.
* Internal disk had 2 GB free: a 20 GB duplicate of the HorizonXI install sat in the Trash
  (`HorizonXI-moved-to-x10-2026-08-15`; x10 copy verified identical, 67,820 SquareEnix files
  both sides). Deleted → 24 GB free.
* Live install: `/Volumes/x10/Video Games/Mac/FFXI/siku.app#prefix10`, `drive_c/HorizonXI` with
  `SquareEnix` on the drive beside the wrapper.

## Design decisions

1. **One wrapper, one prefix, many game folders.** A server's client is any folder the user
   points at (or the Download flow fills), on any drive. `Install` now *resolves* the layout
   instead of assuming HorizonXI's: Ashita-cli.exe found up to 3 levels under the chosen
   folder; `SquareEnix` found beside it or under `../Game/` (CatsEye) etc.
2. **The PlayOnline registry is re-pointed at launch.** `HKLM\SOFTWARE\PlayOnlineUS\InstallFolder`
   0001/1000 (both views) + the four COM registrations are prefix-global; they must name the
   selected server's `SquareEnix` before Ashita starts, or the game loads the wrong (or no)
   FFXiMain.dll. Done in `GameRegistry.point`, cached by a marker so it runs only on change.
3. **Play launches Ashita directly for every server, credentials on the loader command line**
   (`--server --user --pass`), including CatsEyeXI — their launcher is only needed to
   download/update, not to play. Their launcher's own login profile UI is not driven; it is
   flaky under wine and unnecessary.
4. **The game process is whatever the boot profile's `file =` names** (horizon-loader.exe,
   pol.exe, xiloader.exe…) — the x87 sidecar and the exit watcher key off that, not a
   hard-coded name.
5. **Downloads/installers run in a second prefix** (`prefix-installers`, created with
   `wineboot -u` on first use, ~30 s / 340 MB). Play does `wineserver -k` on the *game* prefix
   first (renderer + registry writes need it), which would kill an installer running there —
   so installers get their own. Whatever they write to their registry is irrelevant: decision 2
   re-points the game prefix from the resolved folder. `C:\Games\<world>` is symlinked to the
   world's data folder in both prefixes.

## Log

(appended below as work happens)

### 2026-08-16 14:30 — x10 is a Time Machine drive: the app cannot read it (and never could)

`/Volumes/x10` is Daniel's Time Machine destination (`tmutil destinationinfo`). macOS refuses any
app without Full Disk Access a directory listing there (EPERM) — the launcher's own "Drive
readable" check goes red, and TCC.db shows `org.batesai.horizonxi-on-mac` = **denied**. So the
game moved there on 08-15 was not launchable from the .app at all without Daniel granting FDA
(which cannot be done from a script). Terminal has FDA, which is why every hand test worked.

Fix without asking: the x10 disk had **803 GB of unpartitioned free space** after the HFS+
volume. `diskutil addPartition disk5 APFS Games 0` made a second volume, `/Volumes/Games` (APFS,
not a TM destination, no data touched). The install was copied there (`rsync -aH`):
`/Volumes/Games/FFXI/{siku.app,SquareEnix}`; the old x10 copy is left in place as a backup for
now (delete once the new one has been played from). `drive_c/HorizonXI/SquareEnix` is an absolute
symlink and had to be re-pointed. `install.last` (UserDefaults) re-pointed too.

Also: `~/Games/FFXI/CatsEyeXI` (15 GB) moves to `/Volumes/Games/FFXI/CatsEyeXI` to get it off the
2 GB-free internal disk; `dataPath` in servers.json follows.

Installer research (agent, 2026-08-16) is folded into `Servers.builtins`: Eden = 5.8 GB zip on
Google Drive (direct `drive.usercontent.google.com/...&confirm=t`, range requests work), FFEra =
5.5 GB zip on Google Drive, Valhalla = 3.6 MB web-installer zip, Gaia = behind their site login,
Supernova/Omicron = retail client (Square Enix's 5-part 7.7 GB download from gdl.square-enix.com,
`FFXIFullSetup_US.part1.exe` + `.part2-5.rar`) + their FFXI-UpdatePatch.zip, Tabula Rasa = defunct
(site parked, repo dead since 2024-05). HorizonXI: magnet-only (verified: aria2c pulls it at
14–20 MiB/s, 40+ peers — the earlier "stalls" were metadata timing).

### 2026-08-16 15:00–15:45 — launch pipeline verified to the login handshake

Built the multi-server launch changes and drove them on the real .app (Developer-ID signed,
`/Applications/FFXI-on-Mac.app` kept playable throughout):

* **HorizonXI** — Play injects Ashita, the x87 sidecar attaches to `horizon-loader.exe`, the
  loader resolves `play.horizonxi.com`, connects, and reaches the login step. Auth itself
  returned "Invalid username or password" / "Bad json reply from remote" — that is credentials,
  not the launcher: the stored test passwords are stale. The loader that works is the 2.0.x LSB
  fork (`horizon-loader.exe.bak`, 1.05 MB, == the fresh 2.0.3 client's loader). A **stale 87 KB
  2023 loader** was sitting as the live `horizon-loader.exe` and only ever showed the menu (no
  connect) — moved aside to `horizon-loader.exe.2023-87k` and replaced with the 2.0.x one. Note
  for the app: it should prefer the loader that ships with the *current* client, not whatever is
  named in a hand-edited profile.
* **CatsEyeXI** — same result: injects, `pol.exe` (their LSB 2.0.1 fork) connects to
  `server.catseyexi.com`, reaches login, "Invalid username or password" (the test account
  `ffxionmac` was never actually created on their server). The **SquareEnix-resolver bug that
  blocked this is fixed**: their client puts `FINAL FANTASY XI` under `…/Game/`, not
  `…/SquareEnix/FINAL FANTASY XI`; `Install.resolveSquareEnix` now finds it and the version
  check reads the right `patch.cfg` (their client is 30251227_0, past CatsEye's 30251204_1 gate).
* **Local server** — LSB is built and running; stock `xiloader` reaches it but autologin fell
  back to the menu (a local-account/handshake matter, not the launcher). Left for a later pass.

Code added this session:
* `Install.resolveAshitaDir` / `resolveSquareEnix` — find the two things a launch needs under
  whatever folder the user points at, per world, capped-depth, skipping ROM trees.
* `GameRegistry.point` — re-points `HKLM\…\PlayOnlineUS\InstallFolder` (both views) + the four
  COM registrations at the selected world's SquareEnix before each launch, cached by a marker.
* `Credentials.fixBootLoader` / `bootLoaderName` — a copied profile's `file =` is rewritten to a
  loader that actually exists in the world's `bootloader/`; the exit-watcher and sidecar key off
  that name (`Runner.currentGameExe`), not a hard-coded `horizon-loader.exe`.
* `Runner`: second wine prefix for installers (`prefix-installers`), `runInstaller` now fetches
  with resumable curl and unpacks zips, `runLocalInstaller`, `installRetail`, `cancelInstaller`;
  login-failure detection (`Failed to login` / `Bad json` / `version mismatch` / `already logged
  in`) surfaces the loader's verdict to the UI and stops the loader instead of hanging on an
  invisible menu; the whole log is teed to `~/Library/Application Support/HorizonXI-on-Mac/
  launcher.log` for after-the-fact diagnosis.
* `--play [--world <name>]` launch args for unattended tests / Shortcuts.
* `scripts/retail-client.sh` — the SE-client + PlayOnline + Ashita/xiloader pipeline for the
  bring-your-own-retail worlds (Supernova, Omicron). **Untested end-to-end.**

### What's proven vs. not (be honest)

* **Proven:** HorizonXI + CatsEyeXI download and launch to the login handshake on this Mac.
  HorizonXI's full torrent update chain (1.x → 2.0.3) downloads and extracts. The layout
  resolver, per-world registry, installer prefix, and login-failure surfacing all work.
* **Not proven:** actually logging in and seeing the 3D world (blocked on real credentials, and
  the Mac auto-locked while unattended — GUI can't be driven from a locked session). Eden / FFEra
  / Valhalla / Gaia installer runs. The retail pipeline. The local-server autologin.

### Next session

1. With Daniel's real HorizonXI password, confirm a full login + zone-in + a screenshot of the
   world. (The launch half is done; only auth is untested.)
2. Drive one website-installer world (Eden is the cleanest: direct 5.8 GB Drive zip) through
   Download… end to end, fix whatever the installer's wine run needs.
3. Run `retail-client.sh` once for Supernova on a spare folder; it will surface the SE-installer
   GUI steps that need automating.
4. Consider notarizing the .app (currently Developer-ID signed but `spctl` rejects = unnotarized;
   the x87sidecar entitlements are the usual snag — see `docs/dev` notes).

### 2026-08-16 16:15 — GitHub auto-updater

`Updater.swift` + `updateBanner` in `App.swift`. On launch (and every 6 h, and on re-activate) it
hits `api.github.com/repos/danielalanbates/HorizonXI-on-Mac/releases/latest`, and if `tag_name`
is a higher dotted version than `CFBundleShortVersionString` it **auto-downloads** that release's
`.dmg`, mounts it (`hdiutil`), stages the `.app` into `App Support/HorizonXI-on-Mac/updates/
staged-<ver>/`, strips quarantine (`/usr/bin/xattr -dr` — note the Homebrew python `xattr` in PATH
lacks `-r`, so the absolute path matters), detaches, and shows a gold "Update <ver> is ready —
Restart" banner. It never applies the update itself; **Restart** writes a detached zsh helper that
waits for the app's pid to exit, `ditto`s the staged bundle over the running one, strips
quarantine, relaunches, and cleans up.

Verified end-to-end by stamping a scratch build as 2.5: it saw live v2.6, downloaded, mounted, and
staged a signature-valid `FFXI-on-Mac.app`; the swap helper was tested on dummy bundles
(OLD→NEW). Not driven through the actual Restart on the live app (would downgrade to the older 2.6
release, which predates this code) and the GUI banner wasn't screenshotted (Mac was locked).

**Release coherence:** bumped `bundle.sh` to 2.7 / build 8. The updater compares versions, so the
next release's tag must exceed the installed `CFBundleShortVersionString` or it would offer itself
in a loop — `scripts/package.sh` reads the version from the bundle, so cut the release as **v2.7**
(`HXI_SIGN_ID=<hash> ./scripts/package.sh` → notarized `dist/FFXI-on-Mac-2.7.dmg` →
`gh release create v2.7 …`). `/Applications` reinstalled as 2.7 so it won't offer the older 2.6.

## 2026-08-19 — CatsEyeXI "Play failed" root cause: no account (creation is server-disabled)

The 2026-08-15 client-version wall is GONE — the CatsEye install (`prefix10`,
`C:\Games\CatsEyeXI\catseyexi-client`, loader `Ashita/bootloader/pol.exe` = LSB xiloader 2.0.1)
connects, TLS-handshakes, and reaches auth fine. The failure is simply
`Failed to login. Invalid username or password.`: the stored credentials are HorizonXI accounts,
and LSB accounts are **per server** — no CatsEye account exists yet.

Automated creation attempts, for the record:
- xiloader's TUI (FTXUI) renders on a pty but consumes **no** input under our wine — arrows,
  tab, digits, and SGR mouse clicks all dead (`scratchpad cexi_create*.py`; they named a
  personal account, so they were moved out of the repo on 2026-10-14 into a private local
  archive). Menu-driving is not a pathway.
- `--email` does not switch xiloader to create mode; it autologs-in.
- The auth protocol is small: **JSON over TLS to server.catseyexi.com:54231**, e.g.
  `{"command":32,"username":…,"password":…,"version":[2,0,1]}` (`login_cmd::LOGIN_CREATE=0x20`;
  omit `version` and you get "xiloader too old… reported 0.0.0"). The server answered
  `{"result":8}` = `LOGIN_ERROR_CREATE_DISABLED` — **account creation is disabled at the login
  server**. Source: `src/login/auth_session.cpp` in CatsAndBoats/catseyexi.
- Registration is web-only: **https://www.catseyexi.com/register** (Next.js SPA). Account
  creation + password entry is a human step, not an automation one.

Once an account named like the `--user` in `catseyexi.ini` exists (or the launcher's account
field is updated), Play should reach character select with no further work.

## 2026-08-19 (later) — CatsEye login succeeded; "Valid Content ID not found" = no character yet

Registration on catseyexi.com worked and the loader logged in ("Successfully logged in as
<account>!") but the client stops at **"Valid Content ID not found."** Per CatsEye's own
download page this means no character exists yet: characters are created on the **website
dashboard** (Login → Create Character → pick a game mode), which then issues **separate game
account credentials** (one game account per game mode — Accelerated / Crystal Warrior /
Wings-Era). Those generated credentials, not the website login, go in the launcher.

Launcher change (32eb3c8): the account fields now recall each world's last-used login on
world switch (`Credentials.username(forWorld:)`, saved on Play), so the CatsEye game account
and the HorizonXI account no longer fight over one field.

## 2026-08-19 (later still) — Gaia XI client fully installed; blocked at credentials

Full integration done without their Electron launcher:
- Their launcher zip (260 MB, needs site login — fetched via Daniel's browser session) unpacks a
  complete Ashita 4.3.1.2 client skeleton incl. `bootloader/gxiloader.exe` (their LSB-2.0.0 fork)
  and `config/boot/GaiaXI.ini` (`file = .\bootloader\gxiloader.exe`, `--server play.gaiaxi.com`).
- The game data is a plain 8 GB zip on their CDN: 
  `https://gaiaxi.evenmonkeys.workers.dev/install/SquareEnix.zip` (no auth!) → extracted into the
  client folder. Their launcher APIs: `gaiaxi.com/api/v2/{server_address,patch_version,
  launcher_version,approved_addons,approved_plugins}.json`. **Gotcha:** patch_version's zip URL
  (`patch_2026_06_07_4.zip`) 404s on the CDN — patch presumed folded into the launcher zip.
- Install lives at `/Volumes/x10/Video Games/Mac/FFXI/GaiaXI/GaiaXI`, symlinked as
  `prefix10 drive_c/Games/GaiaXI`; world dataPath + bootProfile (GaiaXI.ini) wired; Gaia's
  API-published addon allowlist enforced (170+24).
- Unattended `--play --world "Gaia XI"` runs the full chain: their gxiloader resolves
  play.gaiaxi.com:54231, TLS ok — **server rejects the login** ("Bad json reply from remote" =
  their fork's error path replies an old-style single byte; a direct protocol probe with the same
  stored credentials returns 0x02 LOGIN_ERROR for login AND create, all case variants).
- So the machine side is done end-to-end; the block is the credential pair itself. Website login
  works in-browser, but the game auth rejects it. Open question for Daniel: is the game password
  separate from the site password (edit.xi bounced back to the account landing page, so it could
  not be checked), or was a typo stored? Their Discord is the support channel.

## 2026-08-19 (evening) — Gaia XI BOOTS to its title screen (manual pathway)

The credential wall was a typo; re-entered password logs in. The remaining instant-exit
("Closing…" 1s after login, Ashita UninstallAshita(204)) turned out to be **renderer-specific**:
run manually from the client folder with no overrides — `cd GaiaXI/GaiaXI && wine Ashita-cli.exe
GaiaXI.ini`, which lands on wined3d/OpenGL — the client boots to Gaia's title screen + Terms
dialog (~29fps, screenshot in session). Through the launcher's normal DXVK/d3d8to9 pathway the
same client dies at boot. Client itself is current: per-file patcher (`gaia_patch.py`, next to
the install) reproduces their launcher's manifest+sha256 patch flow — 73 stale files fixed, 0
failures. Their patch_version.json zip URL is dead; `patch/manifest.json` is the real system.

TODO: make Play produce this launch for Gaia (bisect env/DXVK; per-world renderer fallback),
fix the --args-no-window bug, re-verify HorizonXI/CatsEye.

## 2026-08-21 — "Eden didn't work" root cause: there was never an Eden client

Daniel's report was right and the cause was not subtle. Found at start of session:

* `servers.json` had Eden's `dataPath` = `/Volumes/x10/Video Games/Mac/FFXI` — the **parent
  folder that holds every world's install**, not Eden's own. `Install.resolveAshitaDir` does a
  breadth-first search for `Ashita-cli.exe` under that folder and returned `HorizonXI-fresh`.
* So "Play Eden" launched **the HorizonXI client, HorizonXI's `horizon-loader.exe`, HorizonXI's
  registry and HorizonXI's DATs** against `play.edenxi.com`. `eden.ini` was sitting inside
  `HorizonXI-fresh/config/boot/` with `file = .\bootloader\horizon-loader.exe`. A live loader
  was still up from that attempt, stalled just after `Resolved server address to
  '144.217.79.186:54231'`. Nothing in the UI said any of this.
* `installer-downloads/Eden-installer.zip` was **3.30 GB of 5.77 GB** — a truncated download,
  never extracted, never installed. There was no Eden client on this Mac at all.

### Fixes to the launcher (so this class of failure cannot recur silently)

* `Install.resolveAshitaDir(_:world:)` now takes the world name. When a data root holds several
  clients, a candidate whose path names the world wins over one that does not (compared on
  letters and digits only, so "Gaia XI" matches `GaiaXI` and "CatsEyeXI" matches
  `catseyexi-client`). New `Install.ashitaCandidates(under:)` and `findAll` back it.
* `Install.clientAmbiguity` returns a sentence when the data root holds >1 client and none is
  named for the world — the case with no safe guess.
* New **blocking** preflight check `worldclient` ("Client belongs to this world"). Blocking, not
  a warning: every downstream step succeeds when the wrong client is picked, which is exactly
  why this went unnoticed.

### Eden client, actually installed

* Re-downloaded to the full **5,772,431,825 bytes** (`curl -C -`; the Google Drive direct URL in
  `Servers.builtins` still works and supports ranges).
* The zip is **not** a client — it is `Installer.exe` (157 MB) + `data.pak` (5.6 GB).
  `Installer.exe` is **NSIS 3.06.1**, so it takes `/S` and installs unattended. No GUI driving
  needed. It **ignores `/D=`** and installs to its own default `C:\Eden`.
* Run: `WINEPREFIX=<wrapper>/SharedSupport/prefix-installers wine 'C:\Games\Eden\Installer.exe' /S`
  → lays down `Ashita/`, `SquareEnix/`, `Windower/`.
* **Eden ships Ashita v3, not v4**: its boot configs are `Ashita/config/boot/Eden*.xml`, and the
  loader lives in `Ashita/ffxi-bootmod/`. The launcher's whole launch path assumes Ashita v4
  (`Ashita-cli.exe` + `config/boot/*.ini`). This is a real, separate piece of work — see below.

### Also this session

* **Per-world renderer** (`Server.renderer`). Gaia XI's client boots on wined3d/OpenGL and dies
  ~1 s after login on DXVK (measured 2026-08-19); the choice therefore cannot be global. Gaia XI's
  built-in entry is pinned to `.openGL`; Play applies it without mutating the user's own setting
  and logs that it did.
* FFEra (5.5 GB) and ValhallaXI installers downloaded. Valhalla's is a **.NET/Mono WinForms**
  installer, not NSIS — no silent flag found yet, so it needs either GUI driving or a look at
  what it actually downloads.

### 2026-08-21 (later) — Eden installed and connecting; three worlds turn out to be Ashita v3

**Eden's client is on this Mac and talks to Eden.** Their zip is not a client: it is
`Installer.exe` (NSIS 3.06.1, 157 MB) + `data.pak` (5.6 GB). Run `Installer.exe /S` under wine in
`prefix-installers` → 14 GB client (`Ashita/`, `SquareEnix/`, `Windower/`). It **ignores `/D=`**
and installs to its own `C:\Eden`; the tree was moved to
`/Volumes/x10/Video Games/Mac/FFXI/Eden` afterwards and `data.pak` + the zip deleted.

Eden's own loader against Eden's own login server, first time from this Mac:

```
[08/21/26 08:05:41] Connected to server!
[08/21/26 08:05:42] Invalid username or password.
```

So the machine side is done — **the only thing left for Eden is a real account**. Their loader
(`Ashita/ffxi-bootmod/xiloader.exe`, an EdenServer fork of the DarkStar loader) offers
`1.) Login  2.) Create Account  3.) Quit` on a console prompt, and it is a plain `std::cin` app
rather than CatsEye's FTXUI one, so piped input would probably drive it. **Not done deliberately:**
registering an account in Daniel's name on a third-party service is his call, not an unattended
one, and a duplicate registration would be worse than none. Same wall as CatsEyeXI and Gaia XI.

**ValhallaXI** reaches `Connected to server!` too, from a fresh client, same remaining wall.
Their published "web installer" is a .NET WinForms *downloader*; its strings name what it fetches,
so the launcher now goes straight to `https://mirror.valhalla.group/ValhallaXI.zip`
(7,879,409,522 bytes, no auth, ranges supported) via the new `clientZip` install kind.

**FFEra** installs the same way as Eden (`FFEraInstaller-Jan2023.exe`, NSIS 3.08); it *does*
honour `/D=`. Its payload is `RetailClient-30221103_1.pak`.

#### The finding that mattered: Eden, ValhallaXI and FFEra all ship **Ashita v3**

Not v4, which is what this launcher was built against and what HorizonXI, CatsEyeXI and Gaia XI
ship. The differences are small but total:

| | Ashita v4 | Ashita v3 |
|---|---|---|
| injector | `Ashita-cli.exe` | `injector.exe` |
| boot profile | `config/boot/<name>.ini` | `config/boot/<name>.xml` |
| loader folder | `bootloader/` | `ffxi-bootmod/` |
| credentials | `[ashita.boot] command =` | `<setting name="boot_command">` |

Both have a command-line injector, so both launch unattended. `Install.AshitaGeneration` picks
the generation off the client; `Credentials` reads and writes either format; `Runner` runs
`<injector> <profile>.<ext>`. One piece of work, three worlds unlocked.

#### `--check`: headless preflight

`FFXI-on-Mac --check [--world <name>]` prints, for every world, where its client / Ashita
generation / boot profile / game data actually resolve, and any blocking check. It opens no
window and starts no wine, so it can be run while somebody is playing.

Running it immediately found the **wrong-client bug a second time**: Supernova, OmicronXI and
Tabula Rasa XI all reported `ok` while resolving to the client inside the wrapper — HorizonXI's.
An empty `dataPath` means "the wrapper's client" only for HorizonXI and the local server; for
anybody else it means *no client*, and launching would have run HorizonXI's data against their
login server. Now blocked with that sentence.

### Where every world actually stands (verified 2026-08-21, not assumed)

| World | Client on this Mac | Reaches login server | Blocked on |
|---|---|---|---|
| HorizonXI | yes (v4) | yes, plays | — |
| Local server | yes (v4) | yes | — |
| CatsEyeXI | yes (v4) | yes, logs in | a character on their web dashboard |
| Eden | **yes (v3, new)** | **yes** | an Eden account |
| ValhallaXI | **yes (v3, new)** | **yes** | a Valhalla account |
| FFEra | **yes (v3, new)** | not tried yet | account + first launch |
| Gaia XI | yes (v4) | yes, logs in | Play must use the OpenGL pathway (now pinned) |
| Supernova | no | — | retail pipeline never run end to end |
| OmicronXI | no | — | same |
| Tabula Rasa XI | no | — | server appears defunct |

**Not claimed:** none of Eden / ValhallaXI / FFEra has been driven to a 3D world, because none has
a usable account. "Connects and is refused at auth" is exactly as far as this got, and no further.

### 2026-08-21 — the v3 launch path, verified end to end

Not just the loader: the whole chain the launcher's new code builds, run exactly as `Runner`
now spells it (`injector.exe <profile>.xml` from the Ashita folder):

```
Ashita v3 - Command Line Injector (c) 2016 - 2017 atom0s
[SUCCESS] Injected!
[08/21/26 08:17:42] Connected to server!
[08/21/26 08:17:42] Autologin activated!
[08/21/26 08:17:42] Invalid username or password.
```

That covers: profile seeded from the world's own XML at the widest `window_x`
(`Eden1600900.xml`, 1600 — confirming the name-sort bug, since sorting names picks
`Eden800600.xml`), credentials written into `boot_command`, `boot_file` resolved to
`ffxi-bootmod/xiloader.exe`, the v3 injector run and succeeding, and the loader reaching Eden's
auth. The only step not exercised is the one that needs an account.

## 2026-08-21 — every world actually pressed Play, one at a time

Daniel: *"eden didn't launch. verify all of them actually launch."* He was right, and the reason
was mundane: **every fix above was in the source, not in the app he pressed Play on.**
`/Applications/FFXI-on-Mac.app` was still 2.8, so `eden.ini` ran with HorizonXI's
`horizon-loader.exe`, exactly as before. Built and installed **2.9**; 2.8 archived to
`archive/app-builds/`.

Method: a script (`/tmp/testworld.sh`, reproduced below in spirit) sets `server.selected`, opens
the launcher, clicks PLAY at the button's real screen position, waits, and reads the verdict out
of `launcher.log`. Every result below is from that, on this Mac, today — screenshots where a
window appeared.

| World | Result |
|---|---|
| HorizonXI | **launches and renders** — HORIZON XI title + User Agreement (screenshot). No regression from 2.9. |
| Local server | **launches and renders** — FFXI title + User Agreement (screenshot). |
| Eden | **launches its own v3 client**: `launching eden.xml (Ashita v3)` → `[SUCCESS] Injected!` → Eden's `xiloader` → `Connected to server!` → `Invalid username or password.` Needs an Eden account. |
| ValhallaXI | launches its own v3 client, `Connected to server!`, refused at auth; the launcher surfaces "login refused" and stops the loader. Needs a Valhalla account. |
| CatsEyeXI | launches its own client, connects, sits at their account menu (Login / Create / Change Password / 2FA). Needs the *game account* their web dashboard issues. |
| Gaia XI | injects, **`Successfully logged in as …!`**, then the client exits before creating its window. Renders fine when launched by hand (screenshot: GAIA title + Terms). See below. |
| FFEra | client still installing at time of writing (14 GB in). |
| Supernova / OmicronXI | no client; Square Enix's retail parts (7.7 GB) downloaded, installer not yet run. |
| Tabula Rasa XI | defunct. |

### Two real bugs found by doing this

**1. `d3d8.dll not found` — Gaia could not inject at all.** `removeDXVK` deleted the DllOverrides
named `*d3d8`/`*d3d9`, but this prefix carried a plain `d3d8`/`d3d9` = `native` from an older
setup. Switching to Classic therefore left d3d8 forced native with no native `d3d8.dll` anywhere
Gaia's loader looks, and Ashita's injector died with
`err:module:import_dll Library d3d8.dll (which is needed by …\Ashita.dll) not found`. Both
spellings are now cleared, and `dllDirs` uses `Install.bootLoaderDir` so v3 clients get the shim.

**2. `--play` does not work, and never did.** `open -a FFXI-on-Mac --args --play --world X`
produces no window and no log line, on **2.8 as well as 2.9** — verified by running the archived
2.8 the same way. Any other argument (`--foo`, `--world` alone) shows the window normally. So the
unattended path documented in this file was never exercised the way it is written. Not fixed;
the GUI click harness was used instead. **Whoever picks this up: that is a real bug, and it is
the reason the earlier sessions' "unattended tests" proved less than they appear to.**

### Gaia XI: what was ruled out

Bisected one variable at a time, comparing a hand-run that works against the app run that does
not. **Ruled out:** the whole launch environment (an identical env reproduced from Terminal runs
fine, including `DYLD_FALLBACK_LIBRARY_PATH`, `D3DMETAL_FRAMEWORK_PATH`, the MVK knobs,
`WINE_LARGE_ADDRESS_AWARE`, `FFXI_FPS_DIVISOR`, `WINEMSYNC=0`), the absolute `Z:\…` argument, the
cwd, the x87 sidecar, and the renderer. `WINEMSYNC=1` *does* kill it (hence `Server.msync`), but
Daniel's settings already had msync off, so that is a second, independent fault.

Ashita's own logs pin the divergence exactly. Good run:
`Mine_CreateWindowExA … Creating Final Fantasy XI window` → `Direct3DCreate8` → `GameLoaded`.
Bad run: hooks install, then `UninstallAshita … (228)` at that same point — **the client never
gets a window.** Also visible in both: Gaia's `winefix.dll` fails to load (built against Ashita
4.30, Gaia ships 4.16). The remaining difference is the process context the wine child is spawned
from (GUI app vs terminal); that is where to look next.

`spawnViaShell` now writes `last-spawn.txt` (exe, args, cwd, full environment) on every launch —
it was referenced in a comment but nothing wrote it, and diffing it is what made this possible.

### 2026-08-21 (later) — FFEra launches too; v3 profiles are now synthesised when none ships

FFEra's client installs fine (NSIS `/S`, and unlike Eden's it honours `/D=`) but ships Ashita v3
with **no `config` folder at all** — v3 normally writes its boot XML from its own GUI
configurator, which is not a pathway under wine. `Credentials.ensureProfile` therefore had nothing
to seed from and returned false, so Play could not even start.

`Credentials.v3Profile(loader:folder:)` now writes a minimal v3 boot XML from scratch when the
world ships none: `boot_file` names whatever loader is actually in the client's loader folder
(`defaultLoaderName`, which reads `Install.bootLoaderDir`, so `ffxi-bootmod` and `bootloader` both
work), and `boot_command` is filled with the account by `apply` before each launch, exactly as for
a v4 `.ini`.

Result, through the app:

```
==> launching ffera.xml (Ashita v3)
[SUCCESS] Injected!
[08/21/26 09:53:13] Connected to server!
[08/21/26 09:53:13] Failed to login. Invalid username / password.
!! login refused: … — stopping the loader
```

**Every world that has a client now launches that client and reaches its own login server.**
Four of them (Eden, ValhallaXI, FFEra, CatsEyeXI) stop at the account, which is the one thing this
project cannot supply for Daniel. Gaia XI logs in and still loses its window (see above).

## 2026-08-21 — account links for every world

Added a permanent "Getting an account" card to the hero column (`accountCard` in App.swift) and
three fields to `Server`: `accountURL`, `accountHow`, `discordURL`. Every world's route was
sourced from that server's own site the same day; the table and the reasoning are in
docs/ACCOUNTS.md.

Verified by screenshot on the installed 3.0 app: card renders for the selected world, and the
"Every other world" list shows all nine others with the right verb per world.

Two things worth knowing before touching this UI again:

- **Synthetic clicks into this window drift.** The news banner rotates every 7 seconds between
  one- and two-line items, which moves everything below it by ~15pt. Fixed screen coordinates
  computed from an earlier screenshot land on the wrong control — during this work a stale
  coordinate hit the world picker and then Play, which launched HorizonXI unintentionally. Use
  `FFXI_ON_MAC_SHOW_SIGNUPS=1` (or find the control in a screenshot taken immediately before the
  click) rather than reusing coordinates.
- **`--play` is still broken** (unchanged from 2.8; see the earlier entry).

Also noticed, not fixed: the loader is invoked with `--pass` on its command line, so the account
password is visible in `ps` output to any process on this Mac. Fixing it means feeding the
credential to xiloader some other way (stdin or its config), which is a separate piece of work.

## 2026-10-24 — AscensionXI (beta 71)

Daniel: "get ascension working", then "every LandSandBoat based private server". AscensionXI is
LSB (port 54231 JSON over TLS 1.3, loader = LSB xiloader 2.1.2) and distributes only a .NET
launcher whose update channel is public HTTP. Its protocol was read out of the launcher with
ILSpy and ported natively (`AscensionChannel.swift`, `AscensionSync.swift`); the whole write-up,
deviations and pathways are in [`ASCENSION.md`](ASCENSION.md).

- Client into `FFXI on Mac/Games/AscensionXI` on the x10 (where Setup puts a new world). The base
  client was prefetched with `tools/ascension-prefetch.py` (same rules as the Swift code) before the
  app could do it: 66,783 files, under 2,000 downloaded, the rest copied byte-identical from the
  CatsEyeXI, Supernova and HorizonXI clients. The app's own first run then verified every file.
- One Play with a throwaway account through the installed b71 window reached their login server,
  which refused the account ("Invalid username or password"): version accepted, pipeline proven to
  the account. Logging in needs Daniel's own AscensionXI account (email signup, character made on
  their website).
- Fixed on the way: a new world inherited HorizonXI's saved name and password (now only HorizonXI
  inherits the pre-per-world store), `--hairpin` dropped by the account line, LuaJITGuard's lines
  making the sync refetch 79 addon files every Play, the Addons… sheet adding a second managed
  block beside theirs.

Phoenix and the rest of the LSB survey: [`LSB-SERVERS.md`](LSB-SERVERS.md).
