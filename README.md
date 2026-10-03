# FFXI on Mac

Play Final Fantasy XI on an Apple Silicon Mac. No Windows, no virtual machine, no Boot Camp,
no Terminal.

<div align="center">

### [⬇️ Download FFXI on Mac (.dmg)](https://github.com/danielalanbates/FFXI-on-Mac/releases/latest)

[![Download](https://img.shields.io/badge/Download-FFXI%20on%20Mac-2ea44f?style=for-the-badge&logo=apple&logoColor=white)](https://github.com/danielalanbates/FFXI-on-Mac/releases/latest)

Apple Silicon · macOS 13 or later · v3.9 is signed but not notarized

</div>

![Murn in Selbina](docs/img/murn-in-selbina.png)

Works with **HorizonXI**, CatsEyeXI, Eden, Supernova, OmicronXI and other FFXI private servers.
It can also run a server on your own Mac if you want to play offline.

---

## How to play — the whole thing

1. **Open the `.dmg` and drag *FFXI on Mac* into Applications.** Version 3.9 is signed but not
   notarized; see its release notes if macOS blocks the first open.
2. **Press *Install wine…*** It's the button on the front screen. Go make coffee; it takes about
   five minutes and asks for your Mac password once.
3. **Pick the world you want** from the **CHANGE WORLD** menu.
4. **Press *Download…*** on the card that appears, and choose a folder to put the game in.
   That's it — the launcher fetches that world's game files for you and sets everything up.
   This part is big (15–30 GB) and slow. Leave it running; you can close the lid.
5. **Make an account** on that world's website — the launcher links you straight to it.
6. **Type your account name and password, press PLAY.**

Nothing else. No Terminal, no Homebrew, no downloading a client from somewhere else first.

If anything goes wrong, open **Setup & Diagnostics** inside the app. Every check names the exact
thing it couldn't find, and **Repair** fixes the usual causes automatically.

---

## Performance status

These measurements predate macOS 27:

| Measured on an M1 MacBook Pro, 8 GB (the only Mac this has been tested on) | Frame rate |
| --- | --- |
| Out in the world, every setting maxed at 4K | ~24 fps |
| Out in the world, max settings, lighter zone | ~28 fps |

On macOS 27.0.1, the M1 test machine has been reported unplayably slow. A fresh in-world FPS
measurement is still needed; the earlier numbers do not describe current performance.

The current investigation is in [`docs/MACOS-27-PERFORMANCE.md`](docs/MACOS-27-PERFORMANCE.md).

---

## What you're downloading, and why it isn't all one file

Three pieces end up on your Mac. **The launcher gets two of them for you** — you only ever press
buttons.

| Piece | Size | How you get it |
| --- | --- | --- |
| **FFXI on Mac** (this launcher) | 5 MB | the download button above |
| **Wine** (runs Windows programs on a Mac) | ~250 MB | press ***Install wine…*** — automatic |
| **The FFXI game itself** | 15–30 GB | press ***Download…*** — automatic |

The game files aren't inside the 5 MB download because they're Square Enix's property and nobody
is allowed to hand them out. So the launcher fetches them the same way your server's own Windows
launcher would. **You still don't have to do anything by hand** — that's what the *Download…*
button is. If someone offers you a single file with the game already in it, they are giving away
Square Enix's client, which they may not do.

**Do I need to own FFXI already?** No. You don't need a Square Enix account, a PlayOnline ID, or
a copy of the game. Every world the launcher supports gets you a client for free, and the launcher
does the fetching.

**What are these servers?** HorizonXI, CatsEyeXI, Eden and the rest run
[LandSandBoat](https://github.com/LandSandBoat/server) or a fork of it — an open-source server
written from scratch, containing none of Square Enix's code. It needs Square Enix's *client*,
which is why they all install the real game. Square Enix has not licensed or endorsed any of it;
these communities have simply run openly for years while retail FFXI sits in maintenance mode.
This project redistributes no Square Enix data at all.

---

## The worlds

Pick one from **CHANGE WORLD**. Each world keeps its own game folder and its own login, so you can
have several installed side by side. **Every one of them is a single *Download…* button** — the
differences below are just what happens behind it.

| World | What *Download…* does | Tested end-to-end here |
| --- | --- | --- |
| **HorizonXI** | fetches their client the way their own launcher does — a 9.4 GB download, then their updates, up to the current version | ✅ downloaded, launched, reached login |
| **CatsEyeXI** | runs CatsEyeXI's own launcher for you; it installs their full client (~15 GB) | ✅ downloaded, launched, reached login |
| **Supernova, OmicronXI** | downloads Square Enix's own **free** client (7.7 GB), installs it, updates it through PlayOnline, then adds the world's files on top. Slow — hours — but every step is automatic | ⚙️ fully automated, not yet run start-to-finish |
| **Eden, FFEra** | downloads their installer (a 5–6 GB zip) and runs it | ⚙️ wired up, not yet run start-to-finish |
| **ValhallaXI** | downloads their small web-installer, which pulls the client | ⚙️ wired up, not yet run start-to-finish |
| **Gaia XI** | their zip is behind a login, so it opens their site — then press **Run installer…** on the file you saved | ⚙️ needs that one manual step |

"Tested end-to-end here" is deliberately honest: HorizonXI and CatsEyeXI were downloaded and
launched on the test Mac all the way to the server's login screen. The others are coded from each
server's published installer but haven't been driven start-to-finish yet — see
[`docs/SERVERS-WORKLOG.md`](docs/SERVERS-WORKLOG.md) for exactly what is and isn't proven.
Logging *in* always needs your own account, made on that server's own site.

**Where the game goes.** You choose the folder, per world, the first time you press *Download…*.
Any drive works, including an external one. The launcher itself can live anywhere.

**Already downloaded an installer?** **Setup & Diagnostics → Run installer…** runs any `.exe`
(or a `.zip` containing one) you already have.

---

## Things you might run into

**"FFXI on Mac would like access to Developer Tools."** Say yes. It's Apple's oddly-worded way of
asking *"may this app run Wine?"* — Wine's own developers don't notarise their builds, so macOS
checks with you. It has nothing to do with Xcode.

**A macOS password prompt during *Install wine…*** That's Rosetta 2 installing — Apple's
translation layer. FFXI is a 32-bit Intel game and needs it.

**The game window opens and closes right away.** Press **Repair** in Setup & Diagnostics.

**Red error lines when the game starts.** Three Ashita plugins (`Nameplate`, `PacketFlow`,
`Deeps`) were built for an older Ashita and don't load. Harmless — everything else works.
Details: [`docs/ADDONS.md`](docs/ADDONS.md).

**The sound doesn't move when I change my Mac's output device.** It should now — the launcher
follows your Sound Output setting while the game runs (*Follow the Mac's sound output*, on by
default). If it doesn't, say so in an issue; the mechanism is at
[`docs/AUDIO.md`](docs/AUDIO.md).

**The world looks black or has no textures.** Set the **Renderer** menu back to
*Metal / DXVK (recommended)*. The other options exist for debugging and draw incorrectly.

**"The game's data has been updated."** That world wants a newer client version than yours. The
launcher checks this before Play and tells you both numbers.

**It can't find my game folder.** The game folder has to be on a normal Mac-formatted drive
(APFS or Mac OS Extended). It will not work from an exFAT or FAT32 drive.

Anything else — [open an issue](../../issues) with your Mac model, macOS version, your server,
and whatever the log pane says.

---

## Addons

Ashita addons work — HXUI, statustimers, the usual set. The **Addons** screen only shows the ones
your server actually allows, and says where that list came from. On HorizonXI an unapproved addon
can get you banned, so this matters more than it sounds.

## Running your own server

Pick **Local server** in the World menu and press **Set up server**. The launcher builds
[LandSandBoat](https://github.com/LandSandBoat/server) on your Mac — about half an hour and 12 GB
the first time. After that, Play starts the server and the game together. You still need a game
client; a server isn't a game.

## Helping out

This has been tested on exactly one Mac. Most useful, in order:

- **Frame rates from other Macs** — model, memory, macOS version, where you were standing.
- **Worlds other than HorizonXI and CatsEyeXI** — what worked, what didn't.
- **Bug reports with the log pane contents.** The log usually says exactly what went wrong.
- **Code** — see [`CONTRIBUTING.md`](CONTRIBUTING.md).

Questions are welcome, including basic ones. Nobody here was born knowing what a Wine prefix is.

---

## For the technically inclined

Everything above happens automatically. If you'd rather do it by hand, or you're debugging:

- [`docs/SETUP.md`](docs/SETUP.md) — the step-by-step manual route (Homebrew, Rosetta, Sikarugir
  Creator, building the wrapper, installing the client, registering the COM servers).
- [`docs/X87-WALL.md`](docs/X87-WALL.md) — the big one. FFXI's floating-point math ran at ~1% of
  native speed under Rosetta. Fixing it took the game from 11 fps to 28.
- [`docs/MAX4K.md`](docs/MAX4K.md) — where the remaining frames go, and the fast trick that turned
  out to break the game.
- [`docs/FINDINGS.md`](docs/FINDINGS.md) — why the game exited silently for weeks.
- [`docs/AUDIO.md`](docs/AUDIO.md) — why a running game used to ignore the Mac's sound-output
  setting, and the CoreAudio interposer that fixes it.
- [`docs/ADDONS.md`](docs/ADDONS.md), [`docs/BRANDING.md`](docs/BRANDING.md),
  [`docs/PATHWAYS.md`](docs/PATHWAYS.md) — addons, title art, the three renderers compared.

Building it yourself needs only Apple's Command Line Tools:

```sh
./app/bundle.sh          # build the .app
./scripts/package.sh     # build the .dmg
```

Tested on: MacBook Pro M1, 8 GB, macOS 26.5, Wine 10.0 (Sikarugir), Ashita 4.3.1.2.

## Credits

Standing on other people's work: [Ashita](https://github.com/AshitaXI),
[DXVK](https://github.com/doitsujin/dxvk), [d3d8to9](https://github.com/crosire/d3d8to9),
[MoltenVK](https://github.com/KhronosGroup/MoltenVK),
[x87sidecar](https://github.com/athei/x87sidecar),
[LandSandBoat](https://github.com/LandSandBoat/server), and the HorizonXI team.

## Licence

GPL-3.0. Third-party components and their licences: [`vendor/NOTICE.md`](vendor/NOTICE.md).

Not affiliated with HorizonXI, Square Enix, or the Ashita project. Final Fantasy XI is a trademark
of Square Enix Holdings Co., Ltd.
