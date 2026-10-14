# Client updates and the "The game's data has been updated" error

Written 2026-08-15 after a CatsEyeXI login from the HorizonXI install failed with that message.

## What the message actually is

Every LandSandBoat server compares the retail patch level the client reports (login packet
0x26, offset 0x74) against `login.CLIENT_VER` in its `settings/default/login.lua`. With
`VER_LOCK = 1` (exact) or `2` (this version or newer) an older client gets login error 331,
*"The game's data has been updated. Please update to continue."* Source:
`src/login/view_session.cpp` in <https://github.com/CatsAndBoats/catseyexi>.

It is **not** a DAT/addon problem — it is the FFXI executable/patch level in
`SquareEnix/FINAL FANTASY XI`.

| Install / server | Retail patch level | How known |
|---|---|---|
| Our HorizonXI install (`drive_c/HorizonXI`, HorizonXI 1.9.0) | `30251101_2` | newest id in `FINAL FANTASY XI/patch.cfg` |
| CatsEyeXI requires | `30251204_1`, VER_LOCK 2 | public `login.lua` in their server repo |
| HorizonXI latest launcher payload | 2.0.3 (Aug 2026, ToAU + Ashita 4.3) | `api.horizonxi.com/api/v1/launcher/install-game` |

## What the launcher now does (pre-game check)

`ClientVersion.swift` reads the installed patch level; `Server.requiredClient` (+ live refresh
from `Server.requiredClientURL` in `ServerFeeds`) says what the world needs. `App.launchClient`
refuses to launch when the install is older and says both versions in the notice and the log.

For **HorizonXI**, if `version.json` is behind the API's latest, Play first runs
`scripts/update-client.sh horizon <drive_c/HorizonXI>` (streams into the log), then launches.
The script:

1. `GET api.horizonxi.com/api/v1/launcher/update-game?ver=<installed marketing version>` — a
   list of `{version, marketingVersion, updateZipName, updateMagnetLink, deleteFiles}`.
2. Fetches each zip with **aria2c** (Homebrew) from the magnet — HorizonXI distributes updates
   only as torrents (their Electron launcher uses webtorrent). The script gives metadata three
   60-second attempts in separate aria2 processes, saves the resulting `.torrent`, then starts
   the resumable file transfer. Restarting aria2 between attempts also lets it repair and reload
   its DHT routing cache. Zip sizes: 2.0.0 = 402 MB, 2.0.1 = 1.7 MB, 2.0.2 = 12.5 MB,
   2.0.3 = 24 KB, 2.0.4 = 522 KB. Earlier ones (1.1–1.9.2) publish no size.
3. `ditto -x -k` over the game dir, deletes `deleteFiles`, restores this project's
   d3d8/d3d9/dxvk.conf/dgVoodoo.conf shims, writes `version.json`.

`update-client.sh check <dir>` prints `installed=… horizon=… latest=…`.

**Status: unverified end to end.** On 2026-09-02 a base-client magnet fetched its 175 KB of
metadata from two seeders in 21 seconds after an earlier aria2 process had stalled before metadata
and reported a corrupt user-wide DHT cache. The separate metadata phase now retries that failure
and reuses the saved torrent on later runs. The same test found no seeder for the 2.0.4 update in
25 seconds; retries improve discovery but cannot repair an unseeded torrent. If torrents keep
stalling, the honest fallback is HorizonXI's own launcher on Windows/Parallels and copying the
game folder back — or run their launcher under wine (`drive_c/HorizonXI-Launcher/`, Electron;
untested here).

Note also: HorizonXI 2.0 restructured the install (`.\Game\config\Pivot`, Ashita 4.3, new
required addon `dynamic_entity_renamer`, per horizonxi.com/news.json 2026-08-07). This project's
paths assume the 1.x layout (`HorizonXI/SquareEnix`, `HorizonXI/config/boot`). Applying 2.0.x
zips may move things — check `Install.gameDir`/`squareEnix` afterwards.

## Why CatsEyeXI cannot be auto-updated from here

CatsEye's launcher (`launcher.catseyexi.com/launcher/cexi_launcher_36.zip`, .NET 8 WPF, listed at
`catseyexi.com/launcher_version.txt`) syncs the client from a **private Cloudflare R2 bucket**
using AWS-SigV4 credentials embedded in the executable ("Fetching state file from R2…"). Older
docs describe a `catseyexi-client` git repo, but no public remote exists any more (only
`CatsAndBoats/*` server repos and `CatsEyeXI/catseyexi_dats` from 2022 are public). Extracting
and reusing their embedded keys would be misuse of their credentials, so this project doesn't.

Realistic pathways, in order:

1. **Parallels Win11 → copy the client.** Run CatsEye's launcher in the VM, let it install
   `C:\catseyexi\catseyexi-client\`, then copy that folder into the wine prefix as a *second*
   game dir. Needs `Install` to support a per-server game directory (today it is hard-wired to
   `drive_c/HorizonXI`). Their `Ashita/polplugins/DATs/catseyexi` overlay must ride along.
2. **Run their launcher under wine** — **WORKS as of 2026-08-15** (`scripts/catseye-launcher.sh`,
   button in Setup & Diagnostics when CatsEyeXI is selected). Self-contained .NET 8 WPF starts in
   the prefix; hardware WPF draws a blank white window, so the script sets
   `HKCU\Software\Microsoft\Avalon.Graphics\DisableHWAcceleration=1` and then the install
   wizard renders ("Choose your installation path: C:\Games\CatsEyeXI"). **Blocker found
   2026-08-15 evening:** the wizard's *Continue* button is inert under wine — synthetic clicks
   that demonstrably work on the same window (the path box opens its Select Folder dialog, OK/
   Cancel close it) do nothing on Continue, no window change, no files, nothing on stderr. Best
   guess: its handler does a Windows-only check first (free-space via WMI `Win32_LogicalDisk`, or
   `Directory` ACL probing) that throws under wine and is swallowed. Also: the wine process never
   becomes frontmost via AppleScript and exposes no AX windows, so it can't be driven by AX. To
   dig further run it with `WINEDEBUG=+seh,+ole,+wbemprox` and read the log. `C:\Games\CatsEyeXI`
   was symlinked to `/Volumes/x10/Software/FFXI/CatsEyeXI` (527 GB free) for the attempt; the
   internal disk (14 GB free) cannot hold a second 27 GB client. Not yet done: clicking
   through a full install (their client is a full ~27 GB download; this Mac had 15 GB free), and
   pointing `Install`/`Runner` at `C:\Games\CatsEyeXI\...\Ashita` instead of `C:\HorizonXI` —
   `Install.gameDir` is still hard-wired, so a per-server game dir is the next code change.
3. **Retail PlayOnline updater** (`pol.exe` file check) — needs a live SE account to reach the
   FFXI update step; not usable for private-server players.

Eden/FFEra/others: their `CLIENT_VER` values are unknown (private repos). Add
`requiredClientURL`/`requiredClient` to their `Server` entries when found.

## Other findings from this pass

* `https://horizonxi.com/news.json` **does** exist and returns real news (title, date, html,
  category). `ServerFeeds.swift`'s header comment says no HorizonXI feed exists — that was
  wrong; wire it into the news banner next.
* HorizonXI launcher endpoints: `install-game`, `update-game?ver=`, `queue/*`, `run-game`,
  `misc/status`, `accounts/login` (all under `api.horizonxi.com/api/v1/`), plus
  `horizonxi.com/addons.json`.
