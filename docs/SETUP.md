# START HERE — setting up, in plain English

You do not need Terminal. You do not need to know what Wine is. You press four buttons.

## The short version

1. **Drag *FFXI on Mac* into your Applications folder** and open it. Version 3.9 is signed but
   not notarized; its release notes explain the extra first-open step if macOS blocks it.
2. **Press *Install wine…*** on the front screen. About five minutes. It asks for your Mac
   password once (that's Rosetta, Apple's own translation layer). Four steps go green and you're
   done with it forever.
3. **Pick your world** from the **CHANGE WORLD** menu.
4. **Press *Download…*** and choose where to put the game. This downloads 15–30 GB, so it takes a
   while — start it and go do something else. You can close the laptop lid.
5. **Make an account** on that world's website. The launcher has a link straight to it.
6. **Type your account name and password, press PLAY.**

That's the whole thing. Everything below is detail you only need if something goes wrong.

---

## Do I need to already own FFXI?

**No.** You do not need a Square Enix account, a PlayOnline ID, a disc, or an existing copy of the
game. Every world the launcher supports can get you a client for free, and the *Download…* button
does the fetching.

The game files aren't inside the launcher's 5 MB download for one reason: they're Square Enix's
property and nobody may hand them out. So the launcher fetches them the same way that world's own
Windows launcher would. You still just press a button. Anyone offering you one file with the game
already inside it is giving away Square Enix's client, which they may not do.

## What ends up on your Mac

| Piece | Size | How you get it |
| --- | --- | --- |
| **FFXI on Mac** (the launcher) | 5 MB | the `.dmg` you already opened |
| **Wine** (runs Windows programs on a Mac) | ~250 MB | press ***Install wine…*** |
| **The FFXI game** | 15–30 GB | press ***Download…*** |

Wine is free and open source ([Sikarugir](https://github.com/Sikarugir-App/Sikarugir), the
successor to Wineskin, LGPL 2.1). It is not CrossOver and costs nothing. The launcher fetches it
fresh from Sikarugir's own GitHub releases and assembles it on your Mac, which is why it isn't
just bundled in.

> **`sikarugir.com` is not that project.** The real one is the GitHub link above. Sikarugir's own
> README tells anyone who arrived from that domain to scan their Mac for malware.

## What *Install wine…* is doing

Four steps, each shown as it finishes:

1. **Rosetta 2** — Apple's translation layer. FFXI is a 32-bit Intel game from 2002, so it's
   required. Installed automatically via the normal system password prompt.
2. **Downloading Wine** — about 250 MB from Sikarugir's GitHub releases. Checked against a pinned
   SHA-256 before anything is built from it.
3. **Building the wrapper** — the pieces are assembled at `~/Applications/FFXI on Mac Wine.app`.
4. **Creating the Windows drive** — a blank `C:` drive, ready for the game.

If a step fails partway, press **Install wine…** again. Finished steps are skipped, so it picks up
where it stopped rather than starting over.

## What *Download…* is doing

Whatever your world's own launcher does — the app just does it for you, inside the wrapper,
into the folder you picked:

- **HorizonXI** — their 9.4 GB client download, then their update chain.
- **CatsEyeXI** — runs CatsEyeXI's own launcher, which installs their ~15 GB client.
- **Supernova / OmicronXI** — downloads Square Enix's own free client (7.7 GB), installs it,
  updates it through PlayOnline, then puts the world's files on top. This one takes hours. It's
  still just the one button.
- **Eden / FFEra / ValhallaXI** — downloads and runs their installer.
- **Gaia XI** — their download is behind a login, so it opens their site; save the file, then use
  **Setup & Diagnostics → Run installer…** on it.

**Already downloaded an installer yourself?** **Setup & Diagnostics → Run installer…** takes any
`.exe` (or a `.zip` with one inside) and runs it in the right place.

**Where it goes.** You choose the folder the first time, per world. Any drive works, external
included — but it must be Mac-formatted (APFS or Mac OS Extended). An exFAT or FAT32 drive will
not work.

## Choosing a renderer

**Leave it on *Metal / DXVK (recommended)*.** That's the one that draws the game correctly. The
other options exist for debugging and are known to draw wrong in various ways — the launcher says
how under each one, and [`PATHWAYS.md`](PATHWAYS.md) has the measurements.

## Do not update the client unless you have to

**Being a version or two behind is normal, and the game plays fine.** Servers accept a slightly
older client; the launcher says so in the log and lets you Play.

Only use **Setup & Diagnostics › Update…** when the world has actually published an update *and*
the game is turning you away — the login server answers *"The game's data has been updated"* and
refuses to connect. That is the signal. Nothing else is.

Why the caution: the update is a multi-hour download that rewrites files inside a working install.
If it stalls part-way the client is left mid-update, which is a worse problem than being one
version behind. The launcher keeps the renderer files and the speed-up loader across an update,
but it cannot un-break a half-applied one. The same rule applies to CatsEyeXI, whose client can
only be updated by their own launcher.

## When something goes wrong

Open **Setup & Diagnostics** in the app. Every check names the exact file or setting it couldn't
find, and **Repair** re-runs the whole configuration for you.

**"FFXI on Mac would like access to Developer Tools."** Say yes. It's Apple's oddly-worded way of
asking *"may this app run Wine?"* — Wine's developers don't notarise their builds, so macOS checks
with you first. Nothing to do with Xcode.

**The game window opens and closes immediately.** Press **Repair**.

**Red error lines at startup.** Three Ashita plugins (`Nameplate`, `PacketFlow`, `Deeps`) were
built for an older Ashita and don't load. Harmless.

**The world is black or untextured.** Renderer is on the wrong setting — see above.

## Running your own server

Pick **Local server** in the World menu: instead of logging into somebody else's world, the
launcher builds [LandSandBoat](https://github.com/LandSandBoat/server) on this Mac and the client
connects to `127.0.0.1`. You still need a game client — a server is not a game.

Press **Set up server** and it will, in order: install Apple's command line tools and Homebrew if
missing, install LandSandBoat's dependencies (cmake, luajit, zeromq, openssl, mariadb, pkgconf),
clone the source, create and import the database, and compile the four server processes. Budget
half an hour or more the first time. Finished steps are skipped, so if it stops you press the
button again.

**Disk space:** about 12 GB. The launcher shows what's free and refuses to start a build below
9 GB, because running the disk to zero halfway through a compile is a worse failure than not
starting one.

After setup, **Play** starts the server and then the client. The first login with a new account
name creates that account.

Everything lives in `~/Games/lsb`, and all of it is the shell script
[`scripts/lsb-server.sh`](../scripts/lsb-server.sh) — run `./lsb-server.sh status|setup|start|stop`
by hand if you'd rather watch it work.

Two things this changes about the client, only in your local copy: the server accepts the older
xiloader that ships with private-server clients, and the client-version lock is turned off. Both
are needed for a client built for one server to talk to another, and neither is something you
would do to a server other people use.

## About these servers

HorizonXI, CatsEyeXI, Eden and the rest run
[LandSandBoat](https://github.com/LandSandBoat/server) or a fork of it — an open-source server,
written independently, that speaks FFXI's network protocol. It contains none of Square Enix's
code. What it *needs* is Square Enix's client, which is why every one of them installs the real
game rather than handing you a repack.

Square Enix has not licensed or endorsed any of this. These communities have run openly for years,
and retail FFXI has been in maintenance mode for a long time, but "long tolerated" is not the same
as "permitted", and this project doesn't claim otherwise. What it does claim is narrower and firm:
**no Square Enix data is redistributed here.**

---

# Appendix: doing it all by hand

**You almost certainly don't need this.** It's here for when the buttons fail, or you want to see
each piece. Ten minutes, mostly waiting on downloads.

### 1. Homebrew, if you don't have it

Paste into Terminal (Applications → Utilities → Terminal) and press Return:

```sh
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

### 2. Rosetta 2

```sh
softwareupdate --install-rosetta --agree-to-license
```

### 3. Sikarugir (Wine for macOS)

```sh
brew trust Sikarugir-App/sikarugir
brew install --cask Sikarugir-App/sikarugir/sikarugir
```

That puts **Sikarugir Creator** in your Applications folder.

### 4. Make the wrapper

Open **Sikarugir Creator**. Under *No engine selected*, click **Change**, pick
**`WS12WineSikarugir10.0_6`** — the exact build this project is tested on. It downloads ~160 MB;
the arrow next to it disappears when it's done, then click the name again to select it.
**Do not pick anything with `CX` in the name** — those are CrossOver-derived and commercial.
Click **Create**, name it `FFXI`, leave the location alone.

You get `~/Applications/Sikarugir/FFXI.app`, about 1.4 GB — Wine and a blank Windows drive, no
game yet. Nothing to configure; close Sikarugir Creator.

### 5. Put the game in it

Double-click your `FFXI.app` wrapper → **Install Software** → point it at your server's Windows
installer and let it run. Or drag an existing game folder off a Windows PC into:

```
~/Applications/Sikarugir/FFXI.app/Contents/SharedSupport/prefix/drive_c/
```

(Right-click `FFXI.app` → *Show Package Contents* → `SharedSupport` → `prefix` → `drive_c`.)

### 6. Renderer files

The launcher's **Renderer** menu does this. By hand: copy `vendor/d3d8to9.dll` as `d3d8.dll` and
`vendor/dxvk-1.10.3-x32-d3d9-horizonxi.dll` as `d3d9.dll` into both the game folder and its
`SquareEnix/FINAL FANTASY XI/` subfolder, then in the wrapper:

```sh
wine reg add "HKCU\Software\Wine\DllOverrides" /v "*d3d8" /d native /f
wine reg add "HKCU\Software\Wine\DllOverrides" /v "*d3d9" /d native /f
```

### 7. Register the game's COM servers

```sh
wine regsvr32 /s "C:\HorizonXI\SquareEnix\FINAL FANTASY XI\FFXi.dll"
```

…and likewise `FFXiMain.dll`, `FFXiVersions.dll`, and
`"C:\HorizonXI\SquareEnix\PlayOnlineViewer\viewer\com\polcore.dll"`.

[`scripts/install.sh`](../scripts/install.sh) is the exact sequence **Repair** runs.

### 8. Open FFXI on Mac

It finds the wrapper on its own — it looks in `/Applications`, `~/Applications` and every mounted
volume. If it doesn't, **Setup & Diagnostics** names exactly what's missing.
