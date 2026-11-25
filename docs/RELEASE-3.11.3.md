**Play no longer stays greyed out when a world refuses the login** (#92). Eden's login program words its refusals differently from the other worlds, so the launcher didn't recognise them and Play sat there. Now you see Eden's own message ("Invalid username or password.", "Too many connections…") and the button comes back.

**Already on 3.11?** The launcher offers this update itself. **On 3.10 or earlier?** Download the `.dmg` below and drag FFXI on Mac into Applications, replacing the old copy. Quit the game first.

**First open:** the app is signed but not notarized by Apple. macOS blocks the first open; allow it under **System Settings → Privacy & Security → Open Anyway**.

### Fixed
- Login refusals from Eden's login program end Play with its message instead of a greyed button.
- Adding a server under the name of a world already listed (such as "eden" or "edenxi") selects that world instead of making a second copy without its login program.
- Worlds you added yourself now have **Edit** and **Remove** in the world menu.

### What has been tested
One Mac: an M1 MacBook Pro with 8 GB on macOS 27.2. Eden's real login program was run under the launcher's Wine against a local test server, and its output is in the self-tests, which all pass. Not tried: logging in to Eden's real server.

Built from launcher 956a2ff, Vanaguide 6682094 and VanaVoice afa7209.

---

Apple Silicon · macOS 13 or later · Developer ID signed, not notarized. No Square Enix data is redistributed here. The game's Wine is LGPL 2.1 software, downloaded separately by Setup; see the [mirror's page](https://github.com/danielalanbates/FFXI-on-Mac/releases/tag/wine-cx-26.3.0-1) for its source.

Licence: PolyForm Noncommercial 1.0.0 with a 10% revenue rider for commercial use. All rights reserved, Bates LLC · [batesai.org](https://batesai.org) · help@batesai.org
