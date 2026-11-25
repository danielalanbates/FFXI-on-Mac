**Quit the game before pressing Restart.** On 3.8 and 3.9 the launcher downloads this update by itself and shows Restart, but their Restart does not check for a running game. If the launcher has not come back as 3.10 a minute after Restart, download the `.dmg` below and drag **FFXI on Mac** into Applications, replacing the old copy.

New here? Download the `.dmg` below, drag **FFXI on Mac** into Applications, open it and press **Setup**.

### Smoother
- Fixes the main cause of the heavy stutter, multi-second freezes and very slow zone loads. Wine was switching off no-execute protection for the whole game, which under Rosetta cost about 90,000 page faults a second; with it kept on, the same screen measured about 3,000. Credit to [athei/wine-build#3](https://github.com/athei/wine-build/issues/3), which found the same problem.
- The launcher keeps the list of shaders your Mac has already built and carries it into new installs, so they are prepared in the background instead of stalling the game the first time they are needed.
- Play no longer repeats setup work that is already done.
- The launcher does less work while you play.

### One button
- The big button always shows the next step: **Setup**, **Update**, **Repair**, **Play** or **Stop**, with one short line saying why. You will no longer see a greyed-out PLAY.
- **Setup** installs everything: Rosetta 2, Wine, the patched Wine that HorizonXI stays logged in under, and the game. Earlier versions did not install the game's Wine, and the HorizonXI download needed Homebrew.
- Setup asks where to put everything and keeps it all in one *FFXI on Mac* folder. It shows the free space and turns down drives that won't work (exFAT, network, cloud-synced or too small), and says why.
- If the folder you choose already has HorizonXI, Setup uses it and does not download the game again.
- Progress names each step, and the percentage only goes up.
- A fresh HorizonXI install now needs about 28 GB of disk at its peak. Before, it briefly held a second copy of the game.

### New
- HorizonXI news in the launcher: server notices, patch notes and known issues. Click a post to read all of it.
- Addon changes (**Addons… → Apply**) reach a running game straight away instead of waiting for the next Play. This is new and has been tested on a stand-in but not yet in a live game. If a change doesn't show up, it still applies at the next Play.
- A new install gets your macros, equipment sets, keybinds and addon settings from the install you played before. Your login is never copied. This is new and has been tested outside the app only.
- A new install uses the graphics settings you saved for that world.
- At Play you get one line, and only when it matters: Low Power Mode, low memory, the Mac running hot, or the local server running alongside a hosted world (with a button to stop the server).
- From now on, launcher updates stay silent until one has been downloaded and verified: signed by this project, notarized by Apple and checksum-matched. Restart is disabled while a game is running.

### Fixed
- HorizonXI clients that the launcher downloads now log in. They had been starting the wrong boot loader.
- The Graphics panel was writing the wrong settings. For example, turning off environment animations turned off the hardware mouse. The panel now has the right controls, including texture and map compression, mip mapping up to 6, and sound channels.
- If you relaunch the launcher mid-game, it takes back the running game with a working Stop and clears out leftover Wine processes. This has not yet been tried in a real session.
- The window no longer selects the saved account name when it opens, so typing meant for another app can't overwrite it.
- The launcher never switches to another install on its own. If the drive your install is on is missing, the button names that drive. The install list under "Remember me" is gone. Use the folder button to switch installs.
- The game window no longer opens squeezed when a size remembered on a bigger display doesn't fit the screen. Before, names and the whole picture could look too narrow.
- If the x87 speed-up fails to attach, the next launch uses standard Rosetta automatically.
- Wine windows no longer pop up when Wine updates its settings.
- The VanaVoice narrator now quits when the game does.
- Frame-rate addons (fps, autofps, fpslog) are now switched off at Play on worlds with an approved-addon list, such as HorizonXI; they still load on the local server. The Metal HUD frame-rate toggle has been removed.

### What has been tested
Testing so far is on one Mac: an M1 MacBook Pro with 8 GB, macOS 27.0.1, playing HorizonXI. Four things have not been tried for real yet: Setup on a Mac that starts without Rosetta, Homebrew or the game's Wine; updating a 3.8 or 3.9 copy to this one with its Restart button; taking back a running game after a relaunch; and the first launcher update after this one. Frame rates on 3.10 have not been measured yet, so numbers from other Macs are very welcome in [Issues](https://github.com/danielalanbates/FFXI-on-Mac/issues).

Built from launcher 5f3759d, Vanaguide e2c1609 and VanaVoice 29a8ec9.

---

Apple Silicon · macOS 13 or later · signed and notarized. No Square Enix data is redistributed here.

Licence: PolyForm Noncommercial 1.0.0 with a 10% revenue rider for commercial use. All rights reserved, Bates LLC · [batesai.org](https://batesai.org) · help@batesai.org
