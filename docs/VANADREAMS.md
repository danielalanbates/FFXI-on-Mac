# Vanadreams

Added in beta 72 (2026-10-24), the second world of [`LSB-SERVERS.md`](LSB-SERVERS.md)'s list.

**Vanadreams** (<https://fairywitch.ca>, Discord `discord.gg/tBpNVBwKqT`) is a level-99 world with
every expansion through The Voracious Resurgence plus custom content. Login `vanadreams.online`
(was `vanadreams.fairywitch.ca`, which still answers). Their status API
(`vanadreams.org/api/public/vanadreams/status`) said on 2026-10-24: online, 22 playing, 161
characters, 82 players that week, client `30260904_1`, `ver_lock 0`. House rules: *"As many accounts
and characters as you want, boxing welcome, mules welcome, your addons welcome."* No web signup:
the loader offers to create the account the first time.

LandSandBoat: port 54231 answers LSB's JSON ("requires version 2.2.x"). Their loader is LSB
xiloader **v2.2.0**, and their server checks the loader's major.minor exactly — a newer one is
refused as "too old" too — so the version is pinned (`Loader.cs` in their launcher says the same).

## What their launcher does (read, not guessed)

Their launcher is open source: <https://github.com/VanaDreams/vanadreams-ashita> (`launcher/`, WPF,
with tests). Setup (`Pages/SetupPage.xaml.cs`):

1. **Ashita v4**: `github.com/AshitaXI/Ashita-v4beta/archive/refs/heads/main.zip`, unpacked into
   the game folder with the archive's top folder dropped.
2. **xiloader v2.2.0** from LandSandBoat's releases into `bootloader\xiloader.exe` (+ the VC++
   runtime on Windows).
3. **Profile** `config\boot\vanadreams.ini` copied from Ashita's `example-privateserver.ini`:
   `command = --server vanadreams.online`, `file =` the loader, `script = vanadreams.txt`.
4. Addons: none ticked except the catalogue's on-by-default items (their own playlist addon).

The client (`Services/ClientInstall.cs`): `vanadreams.org/download/client/<client_ver>/manifest.json`
lists zips (`{name, size, sha256, dest, unpacked}`; 8.8 GB → 17 GB on 2026-10-24). `dest` is
`FINAL FANTASY XI` (default), `PlayOnlineViewer`, or `{ashita}/…` (their title and "modern look"
packs as XIPivot overlays, and the look's effects beside the loader). Each zip: download, check
sha256, unpack, delete, and append `<client_ver> <zip> <sha256>` to `.vanadreams-client.txt`; an
update fetches the zips not yet in that record. XIPivot 4.3.001 is carried inside their launcher;
`pivot.ini` lists `vanadreams-title` then `vanadreams-looks` and has no `root_path`. Registration:
`PlayOnlineUS\InstallFolder` 0001/1000 and nine COM servers (this launcher's `GameRegistry.point`
does the folder keys and the COM servers the loader needs, as for every world).

## What this launcher does (`VanadreamsSync.swift`)

The same steps natively, at **Setup** and (only what is new) **before every Play**:

| theirs | here | why |
| --- | --- | --- |
| Ashita from `main` | the commit `main` was on 2026-10-24 (`4171c74c`) | reproducible; move the pin when Ashita moves |
| XIPivot from inside their exe | HealsCodes' own release, v4.3.001, sha256 pinned | same version, the original source |
| `d3d8.dll` (d3d8to9) and `d3d9.dll` (ReShade) beside the loader: the "modern look" effects | renamed `.off`, their own **Low spec** state | they would load ahead of this launcher's DXVK renderer. The look and title DAT packs stay on |
| VC++ runtime installer | not run | Wine's own msvcrt; HorizonXI's Ashita runs the same way |
| their Graphics page writes the window size into the profile | this launcher's Graphics panel | one place for every world |

Ashita and the client share one folder (their defaults do too): `Ashita-cli.exe`, `bootloader/`,
`config/` beside `FINAL FANTASY XI/` and `PlayOnlineViewer/`. Addons: unrestricted (their rules),
so this launcher's own (Vanaguide, the cursor fix, narration) are allowed here.

Updates: the status API's `client_ver` picks the download list; a zip added to the list later is
fetched by the next Play (their 11 Oct 2026 "modern look" zips came that way); a profile still on
an address they moved from is pointed at the new one.

## Verified (2026-10-24)

- `--selftest-vanadreams`: 24 checks against a fake site on 127.0.0.1 (install, effects off, profile,
  script, pivot order, the record, an added zip, a moved server, a damaged loader refused, offline,
  Stop, a destination outside the folder refused, servers.json).
- The real install: see BETA-72.

## Not verified

- Logging in. The account is made with **Create account** on the account card (b72,
  `LoginAccount.swift`: xiloader's own create request, sent from the launcher, since the loader's
  console is never shown here). Its first step was checked against vanadreams.online; no account
  was created.
- Their custom content's DATs beyond the title and look packs (the look pack is ~600 MB of
  textures; its cost on an 8 GB Mac is unmeasured).

## Pathways if it breaks

- **"Your xiloader is too old"**: they moved the loader version. Read `Loader.cs` in their repo for
  the new `Tag`, update `loaderURL`/`loaderSHA`.
- **A new client version**: the status API names it; the download list path follows. Nothing to
  change unless their manifest's shape changes (`schema` is 1).
- **The effects**: to try them on the Mac, rename `bootloader/d3d8.dll.off` and `d3d9.dll.off` back
  (expect them to fight DXVK; untested).
