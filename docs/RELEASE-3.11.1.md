**Fresh installs work again.** Setup stopped at "The game's Wine didn't download" because the Wine build it fetches was deleted from its original home (#89). Setup now downloads the same files from this project's own mirror.

**Already installed and playing?** Nothing changes for you; this update is optional.

**On 3.10 or earlier? Download the `.dmg` below and drag FFXI on Mac into Applications, replacing the old copy.** Older versions will not update themselves to this one. Quit the game first.

**First open:** the app is signed but not notarized by Apple. macOS blocks the first open; allow it under **System Settings → Privacy & Security → Open Anyway**.

### Fixed
- Setup downloads the game's Wine from this repository's mirror (152 MB, checked against a pinned size and SHA-256 before it is unpacked).
- If a download address ever goes away again, Setup says so instead of blaming the internet connection.

### What has been tested
One Mac: an M1 MacBook Pro with 8 GB on macOS 27.2. The Wine step was run for real against the live mirror into an empty folder, and the setup script tests pass. Not tried: a complete first-time Setup through the launcher window on a clean Mac. Nothing else changed from 3.11. Reports are welcome in [Issues](https://github.com/danielalanbates/FFXI-on-Mac/issues).

Built from launcher 4a09038, Vanaguide 4d85b3b and VanaVoice bd0c4a2.

---

Apple Silicon · macOS 13 or later · Developer ID signed, not notarized. No Square Enix data is redistributed here. The game's Wine is LGPL 2.1 software, downloaded separately by Setup; see the [mirror's page](https://github.com/danielalanbates/FFXI-on-Mac/releases/tag/wine-cx-26.3.0-1) for its source.

Licence: PolyForm Noncommercial 1.0.0 with a 10% revenue rider for commercial use. All rights reserved, Bates LLC · [batesai.org](https://batesai.org) · help@batesai.org
