# Every LandSandBoat world (survey of 2026-10-24)

Daniel, 2026-10-24: *"The goal is to get every Landsandboat based private server working in our
launcher."* This is the list to work through, one world at a time, the way AscensionXI was done
([`ASCENSION.md`](ASCENSION.md)): read the world's own launcher or install guide, port its install
and update steps, prove one Play reaches its login server, then let Daniel log in.

**How the survey was made.** A research workflow swept github.com/XiPrivateServers/Servers (all
`servers/*.md`), ffxiprivateservers.com (21 profiles), nostalgic.gg, r/FFXIPrivateServers (RSS;
its wiki and JSON API refused), LandSandBoat's README/wiki, BG-Wiki, FFXIAH and web searches. Every
login host came from the world's own boot profile, launcher config or connect guide, and each was
probed once on port 54231 the way `scripts/login-probe.py` does (LSB answers JSON over TLS).
Downloads it made (864 MB, never executed) are in `~/Downloads/lsb-survey/`.

## Already in the launcher

HorizonXI, CatsEyeXI, Gaia XI, Supernova, OmicronXI, the local world, **AscensionXI** (b71),
**Vanadreams** (b72) and **DriftwoodXI** (b73).
Cut for their codebase: Eden, FFEra, ValhallaXI (DarkStar lineage). Stopped: Tabula Rasa XI.

## LandSandBoat worlds not yet in the launcher

| World | Login host | Population (2026-10-24) | How a player gets the client | Rules that matter here | Verdict |
| --- | --- | --- | --- | --- | --- |
| **Phoenix XI** (phoenix-xi.com) | `play.phoenix-xi.com` (xiloader **2.2.x**) | **1,185 online** (their status API), Discord 5,276 | Their launcher (Tauri; Windows, Linux AppImage, Flatpak) downloads everything, and **every game file is behind their account login** (401 without a session). Loader is their xiloader fork, given a single-use `login_token` via `--json` | "Use only tools on the Approved Addons list ... Anything else is forbidden. Ask for a ruling before you use an unlisted addon." Single-box, one account per IP; the launcher sends a device id and MAC address | **Needs Phoenix staff's OK first** (Daniel's call: an unsanctioned launcher risks his account). Then: their auth API (`api.phoenix-xi.com/api/v1`, better-auth session → launch token), their manifests, their loader |
| **Titan XI** (titan-xi.com) | `play.titan-xi.com` (2.1.x) | 100+ characters in beta; launched 2026-10-24 | Public: launcher 1.6.28 and the full client zip (8.1 GB, ranges). Login by a launch ticket from `titan-xi.com/api/v1/launcher/ticket` passed with `--json` | "Do not bypass launcher authentication ... Use the official Titan launcher and keep it updated." Characters made on the website; no multibox | **Needs Titan staff's OK first** — their rules require their launcher |
| **Vanadreams** (fairywitch.ca) | `vanadreams.online` (2.2.x) | 21 online, 82 players this week (their status API) | Public chunked client: `vanadreams.org/download/client/30260904_1/manifest.json`, 72 zips (8.8 GB → 17 GB), each with sha256. Launcher source public (github.com/VanaDreams/vanadreams-ashita) | "As many accounts and characters as you want, boxing welcome, mules welcome, your addons welcome." Account made in the loader on first login | **Added in b72** ([`VANADREAMS.md`](VANADREAMS.md)) |
| **PegasusXI** (pegasusxi.com) | `play.pegasusxi.com` (2.1.x) | not published | Public full client zip, 13.9 GB (`cdn.pegasusxi.com/download/PegasusXI_1.2.4.zip`, ranges), Ashita + xiloader + `config/boot/PegasusXI.ini` inside | No bots, no hacks; multibox not stated (so one client) | **Next** — the existing `clientZip` route; news JSON at `pegasusxi.com/launcher/news.json` |
| **DriftwoodXI** (xi.driftwoodgaming.com) | `xi.driftwoodgaming.com` (2.1.x) | 44 online (`/api/players`) | Bring your own current retail client; their Ashita bundle is public (`DriftwoodXI-Content/ashita.json` → a 44 MB zip, Ashita 4.3.2.1, `driftwood.ini`, `driftwood.txt`). They publish a Linux launcher and a Wine guide | Allowlist of 158 addons at `/addons`; no multibox. Website signup | **Added in b73** ([`DRIFTWOOD.md`](DRIFTWOOD.md)): retail client from identical files already on this Mac + their bundle and addons |
| **MistXI** (mistxi.com) | `play.mistxi.com` (2.1.x); legacy 99 world `legacy.mistxi.com` (2.0.x) | not readable | Retail client + `mistxi.com/FFXI-UpdatePatch.zip` (5 MB) + Ashita + LSB xiloader | Dual box allowed (2 per IP). Addon allowlist on their site. Website signup | **Next** — the Supernova/Omicron retail route |
| **Moghouse XI** (moghouse.cc) | `ffxi.cc` (2.2.x) | low | Retail client + xiloader `--server ffxi.cc` | Fun server (GM level 1 for all); dual box yes (listing) | Next — retail route |
| **Scythe** (scythe-bbq.pages.dev) | `212.28.177.210` (2.1.x) | none found | Retail client, which their launcher pins (and may downgrade) to `30260429_1` from a signed public channel (`/launcher/channel/current.json`: 65,062 files, 14.9 GB) | Two accounts per player, dual box allowed | Later — a channel like Ascension's; read their launcher first |
| **LevelDown 99** | `LevelDownFFXI.com` (2.2.x) | none found | Retail + patch files from a Google Drive folder + LSB xiloader | 2 active + 1 mule (listing) | Later — Drive folder download |
| **Olympus XI** (olympus-games.dev) | `172.96.141.132` (2.2.x) | 1 online (open beta) | Their Electron launcher installs or reuses retail, then patch sets from public GitHub releases; custom login cert | No multibox/addon rules published | Later — beta, one player |
| **Legendary Relaunch** | `15.204.112.102` (2.1.x, custom ports) | none found | Retail + their launcher | **Invite-only**: "Ask in our Discord and a GM will set you up with a login." Multibox freely | Later — needs a GM-made account anyway |
| **Eventide XI** (eventide-xi.com) | `66.85.152.250` | ~50 online (Reddit, 2025-12) | Public full client zip, 8.2 GB, ranges, sha256 published | Single-box. Account made in the loader | **Codebase unclear** — answers the binary `0x02` (an old login build, like Gaia XI), and the operator maintains an AirSkyBoat fork. Daniel's rule is LSB only; decide before adding |
| **ff11sf** (Chinese, 99 + 75) | `game.ff11sf.com`, `75.ff11sf.com` (2.1.x) | none found | Own launcher via lanzouj file-share links | **Allows speed hacks and auto-play bots**; their README threatens to attack every other server if theirs is attacked | **Not added** — not a community this launcher should send anyone to |

Added by the survey's completeness critic (a second pass over sources the first missed):

| World | Login host | What is known | Verdict |
| --- | --- | --- | --- |
| **ImagineXI** (Imagine XI 2.0) | `24.148.24.152` | Server source public ("built on LandSandBoat", modern LSB login); bring your own retail client; launcher zip on GitHub (`markup-ux/imaginexi-updates`). Port unreachable on 2026-10-24; weekly census empty | Later — confirm it is live first |
| **Demiurge / "Chaos Gremlins"** | `xi.chaos-gremlins.party` (inferred) | Answers `0x02` after TLS like Gaia XI and Eventide; "Total Players Online: 1"; retail + update patch + LSB xiloader | Later — host inferred, one player |
| **ZenithXI** | — | LandSandBoat fork in active development (pushed 2026-10-23), not launched | When it launches |
| **Cleopatra XI** | — | Announced; LSB xiloader fork; public DAT manifest on GitHub | When it launches |
| **LevelDown 75** | `ffxileveldown75.ddns.net` | Times out; a third-party note says it merged into LevelDown 99 (2026-09-16). LevelDown's Discord: 1,391 members | Covered by LevelDown 99 if the merge is real |
| **Eventide XI** (update) | — | Discord 1,287 members, 531 online. The operator's own fork is AirSkyBoat (stronger lineage evidence, still not proof of what runs live) | Still Daniel's call |
| **Omega**, **Nasomi** | `lobby.ffxi.party`, `ip.nasomi.com` (third-party sources) | No TLS on 54231: DarkStar lineage by the CODEBASE.md rule | Cut, like Eden |

Answering but not LandSandBoat-confirmed, or not reachable on 2026-10-24: RagnarokXI, LevelDown 75
(port timed out), Demiurge / "Chaos Gremlins" (host parked), DSP Old School (refused), Aurora
(refused), Omega and Nasomi (hosts not published; Nasomi's loader picks one at runtime),
Dragon Ball FFXI (Discord only), ZenithXI and Nocturnal Souls (not launched yet). Dead: ChaosDS,
xiweb, Tabula Rasa XI, Caldera.

## Accounts made at the login server

Several LandSandBoat worlds have no signup page: xiloader's console menu makes the account
(`command 0x20`). This launcher never shows that console, so b72 sends the same request itself
(**Create account** on the account card; `Server.createsAccountAtLogin`). The required loader version
is read from the server's own refusal of version 0.0.0, so the same code works for 2.1 and 2.2
servers. Worlds whose server has `login.ACCOUNT_CREATION` off answer result 8, which is shown as
such.

## Order of work

1. **Vanadreams** — chunk manifest client (native, like AscensionSync but per chunk), stock xiloader.
2. **PegasusXI** — `clientZip`, then the boot profile it ships.
3. **DriftwoodXI** (done, b73), **MistXI**, **Moghouse XI** — a retail client first. All three are on the same
   retail patch as AscensionXI and Vanadreams (`30260904_1`) or close to it: copy the identical
   retail files the way AscensionXI's install does instead of running Square Enix's installer.
4. **Scythe**, **LevelDown 99**, **Olympus XI**, **Legendary Relaunch**.
5. **Phoenix XI** and **Titan XI** only with each staff's written OK (Daniel asks; this project does
   not contact them). **Eventide XI** after Daniel decides on its codebase.
