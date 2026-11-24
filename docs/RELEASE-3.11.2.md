**Installing a world from its own Windows installer works again** (#92). Picking a world's installer (for example Eden's `Installer.exe`, or the `.zip` it came in) used to leave the button greyed at "Setting up" with no progress, then report every game file missing: Eden's installer puts the game in its own folder whatever it is told, and the launcher never looked there.

**Already installed and playing?** Nothing changes for you; this update is optional.

**On 3.10 or earlier? Download the `.dmg` below and drag FFXI on Mac into Applications, replacing the old copy.** Older versions will not update themselves to this one. Quit the game first.

**First open:** the app is signed but not notarized by Apple. macOS blocks the first open; allow it under **System Settings → Privacy & Security → Open Anyway**.

### Fixed
- Wherever a world's installer puts the game, the launcher finds it and moves it into that world's folder, then finishes setting it up. If an earlier attempt already installed it (as in #92), the next Setup uses that copy instead of installing it again.
- The button shows the installer's progress.
- Free space is checked before unpacking or installing, and a picked `.zip` is unpacked on the drive the game goes to.
- Stop works at every step of an install, and a stopped install is never treated as finished.
- A world you added yourself under the name of a known world (such as "Eden") is no longer removed the next time the launcher opens. Its login address and download page are filled in when left blank.
- Repair works for clients that keep their game files beside Ashita rather than inside it.

### What has been tested
One Mac: an M1 MacBook Pro with 8 GB on macOS 27.2. Eden's real installer was run through the launcher's install code with the launcher's own Wine four ways: the installer picked directly, the `.zip` picked, a re-run over a copy a 3.11.1 install left behind, and a Stop part-way followed by a fresh run. Every one ended with the game in the world's folder (14.6 GB) and the progress readout climbing to 99%. New and existing self-tests pass. Not tried: the window itself on a clean Mac, an M5 Mac, logging in to Eden. Eden is not one of the worlds this launcher lists (it is not a LandSandBoat server); adding it yourself is still possible.

Built from launcher BUILT_COMMIT, Vanaguide 4d85b3b and VanaVoice bd0c4a2.

---

Apple Silicon · macOS 13 or later · Developer ID signed, not notarized. No Square Enix data is redistributed here. The game's Wine is LGPL 2.1 software, downloaded separately by Setup; see the [mirror's page](https://github.com/danielalanbates/FFXI-on-Mac/releases/tag/wine-cx-26.3.0-1) for its source.

Licence: PolyForm Noncommercial 1.0.0 with a 10% revenue rider for commercial use. All rights reserved, Bates LLC · [batesai.org](https://batesai.org) · help@batesai.org
