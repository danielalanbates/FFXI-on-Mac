# AscensionXI

Added in beta 71 (2026-10-24). Daniel: *"actually first get ascension working. that private
server"* — then *"the goal is to get every LandSandBoat based private server working in our
launcher."*

**AscensionXI** (<https://www.ascensionffxi.com>, Discord `discord.gg/e924EXBC6m`, 65 members on
2026-10-24) is a level-75-era Ironman world: no auction house or trading, an optional hardcore
mode, and "Ascension" (send a 75 job back to 1 for permanent perks). Login host
`play.ascensionffxi.com`. Rules (`/rules`): one account per person, **multiboxing not permitted**,
and *"Addons supplied through the AscensionXI launcher are approved for use. If you want to use
another addon, speak with an admin and get approval before using it."*

## Which emulator: LandSandBoat (verified)

- Port 54231 answers TLS 1.3 and LSB's own JSON:
  `{"error_message":"Your xiloader is too old.\nPlease update to version '2.1.x'.\nYour client reported '0.0.0'."}`
  (`scripts/login-probe.py`, which now includes it).
- Their loader's notice: *"Based on LandSandBoat xiloader v2.1.2, revision 370a1a11…"*.

## What their launcher does (read, not guessed)

Their only distribution is `AscensionXI.exe` (`/download/launcher`, 2,268,672 bytes, sha256
`41a50b82…dbc51` on 2026-10-24): a .NET Framework 4 WinForms app, GPL-3, version 3.6.0. Its source
repository (`github.com/henkpoa/AscensionXI`) is private, so the protocol was read from the binary:
decompiled with ILSpy (`ilspycmd` 11.1 on the .NET 10 runtime, both installed under
`~/Downloads/dotnet-tools`; the C# went to `~/Downloads/ascension-research/decompiled`). `Core.cs`
is the whole protocol. Its player profile (`Core.PlayerProfile`): name `Prod-Public`, boot ini
`ascensionxi-prod-public.ini`, overlay `ascensionxi-prod`, channel `http://dl.ascensionffxi.com:54290`
with fallback `http://dl2.ascensionffxi.com:54290` (plain HTTP; `dl` is a CNAME to a duckdns home
host in Sweden, `dl2` and `play` are the same Hetzner address).

### The channel

| path | what | notes |
| --- | --- | --- |
| `/environment` | `prod` | a folder is bound to one environment for good (`.client-environment`) |
| `/base/client-manifest.json` | every file of a full client: `{version 1, client_version, revision, published, source "files/", zip, files{path: {sha256, size}}}` | 15.5 MB, 101,707 files, 28.0 GB (2026-10-08 revision `441ee66b4358`, client `30260904_1`). Their launcher asks with If-Modified-Since against `.base-manifest.json`'s mtime |
| `/base/AscensionXI-client.zip` | the same client zipped | 14.8 GB, ranges supported |
| `/base/files/<path>` | one file of it | |
| `/manifest.json` | their DATs: `{version 2, files, files_hd, launcher, launcher_dev, compatibility{client_version, runtime_files}}` | 280 KB; 559 files, 409 MB. `runtime_files` pins FFXiMain.dll, Ashita.dll, Ashita-cli.exe, ashita.datmap.ini, ashita.pointers.ini by sha256 |
| `/dats/<path>`, `/dats-hd/<path>` | the overlay files | into `Ashita/polplugins/DATs/ascensionxi-prod[-hd]/` (XIPivot) |
| `/addons/catalog.json` | approved addons and plugins: `{version 1, sources, switchOff, entries[{name, kind, enabled, required, ignoreUpdates, files{rel: {url, sha256, size}}, remove, archives[{url, from, into, size}]}]}` | 2.2 MB, 91 entries, 95 MB of files from raw.githubusercontent / codeload.github.com or the channel |
| `/launcher/dist/AscensionXI.exe` | the launcher itself | named in `manifest.json` › `launcher` |

### Every Play (`Core.Run`)

1. Resolve the channel (primary, else fallback).
2. `EnsureBaseClient`: a first install downloads the zip and unpacks it; otherwise
   `RoutineBaseCheck` — If-Modified-Since on the base manifest, fetch the files whose sha changed,
   delete the ones that went away.
3. Fetch `manifest.json`; `ValidateRuntime` (the pinned runtime files must match, byte for byte).
4. `SyncOverlay` for `ascensionxi-prod` (and `-hd` with HD on): fetch mismatches, prune extras.
5. `SyncAddons`: install/update every catalog entry (archives when worth it), enable the defaults
   once (`addons.json` › `seen`), enforce `required`, apply `switchOff` once, rewrite one fenced
   block of the boot script.
6. Fetch the manifest again; a different content hash means "a release changed during this
   update; retry".
7. Remove dev files, rewrite `pivot.ini`, write their loader (`ascensionxi-loader.exe`) out of the
   launcher's own resources, set the boot profile's `file=` to it, then start
   `Ashita-cli.exe ascensionxi-prod-public.ini` with the account in a `--json` file.

## What this launcher does (`AscensionChannel.swift`, `AscensionSync.swift`)

The same steps, natively, as **Setup** (every file checked) and **before every Play** (only what
changed; ~3–4 s when nothing did). Differences, all deliberate:

| theirs | here | why |
| --- | --- | --- |
| downloads the 14.8 GB zip | fetches files one by one from both mirrors (8 at a time), after copying every file that is byte-identical (same path, size, sha256) in another FFXI client on the Mac | on the test Mac under 2,000 of 66,783 files (~1 GB) came from the channel; the rest matched CatsEyeXI/Supernova/HorizonXI files |
| HD textures, HD maps, LoFi music on | off | texture memory is the frame rate on an 8 GB Mac. `launcher.json` in the client root turns each on with their own keys (`hd`, `hdMaps`, `lofiMusic`) |
| re-hashes every file every Play | caches size + mtime + sha256 (`.ffxi-on-mac/hashes.json`) | a Play reads 400+ MB of overlay otherwise. Every file still has to match the channel's sha to be kept |
| probes the channel with `/manifest.json` | `/environment` on both mirrors at once | 5 bytes instead of 280 KB |
| fetches the 2.2 MB catalog every Play | If-Modified-Since against `addons-catalog.json` (their own cache file, dated as the channel's Last-Modified) | the manifest itself is always fetched whole: every DAT is checked against it |
| re-checks the manifest after every update | only when the update wrote something | nothing written, nothing mixed |
| Repair restores the boot profile and boot script to the published copies | a full check keeps both when they exist | theirs switches off every addon the player turned on and turns retired ones back on. A *new* published copy still comes in through the update |
| runs Ashita with `--json <file>` | `--user/--pass` like every world here, plus `--hairpin` (`Server.loaderOptions`) | `Credentials.apply` rewrote the whole `command` and used to drop `--hairpin` |
| gamepad and graphics from its own settings | the launcher's Graphics panel | one place for every world |
| runs `AscensionXI.exe` | reads it as data: `DotNetResources.ascensionLoader` walks the PE's CLI resources (8-byte aligned, length-prefixed) and takes the one native PE plus the GPL licence and notice | no Wine Mono, no WinForms window. If the launcher ever changes shape, the stock `xiloader.exe` their base client ships stays in place; their login server accepts it too |

The loader's licence and notice are written beside it
(`ascensionxi-loader-LICENSE.txt`, `-NOTICE.txt`), as their launcher does. Nothing of theirs is in
this repository or the app.

Also part of b71 because AscensionXI exposed them:

- **Credentials**: a world never played here used to inherit the global account name *and* the
  password stored under the bare name from before per-world keys — HorizonXI's. Selecting
  AscensionXI filled in Daniel's HorizonXI login, and Play would have sent it to Ascension's server.
  Now only HorizonXI inherits those (`Credentials.inheritsLegacyAccount`).
- **LuaJITGuard**: Play prepends its `jit.off()` lines to every allowed addon's entry file; the sync
  then saw 79 changed files and fetched them all again on every Play. An entry file that is the
  catalog's file with only the guard in front now counts as current (`withoutJITGuard`).
- **Addons… sheet**: on a script with their fence it edits their block in place instead of adding
  HORIZON markers (two blocks would ping-pong).
- **servers.json**: the new install kind is written as `website`, which 3.10 and older can read
  (an unknown value made the whole file unreadable and reset every world); the curated value comes
  back from `builtins` on load. Unknown kinds now read as `website` instead of throwing.
- **App Transport Security**: their channel is plain HTTP, so the bundle's Info.plist allows
  insecure loads for `ascensionffxi.com` only (and local networking, for the self-test).

## Verified (2026-10-24, test Mac, no game running)

- `--selftest-ascension`: 50 checks against a fake channel on 127.0.0.1 — install with a donor,
  packs skipped, overlay sync and prune, addons from the channel, an absolute URL and an archive,
  obsolete-file removal, their script block, `addons.json`, pivot.ini, the loader out of a synthetic
  .NET PE, `--hairpin` kept, If-Modified-Since on the base manifest and catalog, a new release
  (changed and removed files), a tampered runtime refused, Repair, offline, Stop, the Addons sheet,
  servers.json compatibility, the addon policy, the account rule, the JIT guard.
- Every other suite on the b71 app: 27 suites pass (boot-profile's "no other world declares a
  loader" check now names AscensionXI as the one that does).
- Real channel, `--ascension-sync`: first run verified all 66,783 base files, fetched the 559 DATs
  and 91 addons (7,053 files; dlac, mobdb, tTimers and XIUI from their archives), installed their
  loader (sha256 `e61b6c78…88c6`, the same bytes ILSpy's resource dump gives). A no-change run:
  `ok(changed: 0)` in 3.7 s.
- One deliberate Play through the installed b71 window (`--play --world AscensionXI`) with a
  throwaway account that does not exist: the update ran (nothing to do), the profile switched to
  `ascensionxi-loader.exe`, the registry was pointed at their `Game` folder, Ashita 4.3.2.1 injected
  under wine-coop with the x87 sidecar, their loader resolved `play.ascensionffxi.com`, completed
  TLS, autologin, and the server answered **"Failed to login. Invalid username or password."** — the
  expected answer for that account, so the loader version is accepted. The launcher caught it and
  stopped the loader. The profile was put back as it was.

## Not verified

- **Logging in, character select, zoning, playing.** Needs a real AscensionXI account: register
  at <https://www.ascensionffxi.com/register> (email), then create a character on their website
  (`/account/create-character`) — the game cannot make one. Then type the account in the launcher
  and Play.
- Frame rate on their client at their default graphics (their profile ships 1920×1080 with 2048
  background resolution; the Play-time fit opened it at 1648×928 on this screen).
- Their HD pack on the Mac (11 GB) — off by default; unmeasured.
- A real new release from their channel (the delta path is covered by the self-test only).

## Pathways if this breaks

1. **Their channel format changes** (`manifest.json` version ≠ 2, base ≠ 1, catalog ≠ 1): a line
   goes to launcher.log and the fields are still read. If the reading breaks, decompile the new
   `AscensionXI.exe` (`dotnet ilspycmd.dll -p -o out AscensionXI.exe`, see above) and diff `Core.cs`.
2. **The loader can't be read out of a new launcher**: Play keeps the stock `xiloader.exe` (LSB
   2.1.x), which their login server accepted for the version check. Their own build differs only in
   its "website-only character menu policy".
3. **Their channel is down**: Play still starts with the files from the last update (`offline`).
4. **Run their own launcher instead**: `AscensionXI.exe --sync-only Prod-Public --client-root <root>`
   does steps 1–7 without a window (it needs Wine Mono in the installer prefix; untried).
5. **Fresh Mac without donor clients**: everything comes from the channel (~14 GB at ~0.8 MB/s per
   mirror; both are used). The 14.8 GB zip is the fallback if per-file fetching is ever refused.
