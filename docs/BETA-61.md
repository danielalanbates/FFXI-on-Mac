# Beta 3.9 build 61 (local only)

Branch `beta-b61`, on top of `beta-b60` (31b2f94). Local beta: no GitHub release, nothing pushed.

Daniel, live on b60, 2026-10-15 12:20, on the install Setup built
(`…/FFXI on Mac/FFXI on Mac Wine.app`): "i pressed play and it says starting but nnothing
happened". His standing goal: "the user needs to be able to do all of this without help coding it
on the backend. the launcher is supposed to be a completely self contained system".

## What happened

launcher.log, two presses (passwords stripped when read):

1. `pointing PlayOnline registry` → `launching horizonxi.ini (Ashita v4)` → `injector exited 0`
   → `game exited`. Not one line from Ashita.
2. The registry pointed again, Ashita injected, then the boot loader printed *"Ashita Bootloader
   (c) 2014 - 2017 … written by atom0s for use with the DarkStar private server project"*,
   `Autologin activated!`, `Connected to server!`, `Resolving host: macbookpro.lan`, and its menu
   (`What would you like to do? 1.) Login 2.) Create New Account … Enter a selection:`) 831 times
   in five minutes: its stdin is never a terminal here, so it read end-of-file and asked again.
   No window. `ps`: `.\\bootloader\\pol.exe --server play.horizonxi.com --user … --pass …`.

## Cause (press 2, verified)

A client this launcher installs has **no `config/boot/horizonxi.ini`**: HorizonXI's own launcher
writes that file each time it starts the game, and their client download ships without it.
`Credentials.ensureProfile` therefore seeded it from Ashita's `example-privateserver.ini`
(3.6 KB, `name = Example Configuration`), whose `file = .\\bootloader\\pol.exe` is Ashita's generic
DarkStar-era boot loader. HorizonXI needs `horizon-loader.exe`, which sits right beside it in
`bootloader/` (with `pol.exe` and `xiloader.exe`). `fixBootLoader` only replaced a loader that was
*missing*, so it kept `pol.exe`.

Daniel's working profile (the old `siku.app` install, 21 KB, written by HorizonXI's launcher)
against the new one, by section and key (passwords stripped):

| setting | old, working | new, from Ashita's example | matters? |
| --- | --- | --- | --- |
| `[ashita.boot] file` | `horizon-loader.exe` | `pol.exe` | **yes**: the only loader that logs in to HorizonXI |
| `[ashita.polplugins] pivot` | `1` | absent | **yes**: HorizonXI's own DATs and music are XIPivot overlays |
| `[ashita.polplugins] sandbox` | `1` | `0` | no: both measured working (Sandbox.swift's table); with `0` the registry `GameRegistry.point` writes is what the game reads |
| `[sandbox.paths]` common/pol/ffxi | HorizonXI's | absent | only with Sandbox on |
| `[ffxi.registry]` 0001–0004, 0018–0021, 0024, 0029, 0037/0038, 0041, pad* | Daniel's graphics | Ashita's | no: display settings |
| `[ashita.fonts]` | `d3d8.height` etc. | `d3d8.family = Arial` | no: personal |

Also outside the profile: `config/pivot/pivot.ini`'s `root_path` on the new client is
`C:\Games\HorizonXI\polplugins\DATs`, a folder that does not exist in this prefix (HorizonXI's
launcher rewrites it; on the old install it reads `C:\HorizonXI\polplugins\DATs`). With pivot
on and that root, XIPivot finds none of HorizonXI's overlays.

## The fix

**1. Each world names its loader** (`Server.loader`, refreshed from the built-in list like
`maxClients`, never read from servers.json). HorizonXI declares `horizon-loader.exe`, and so does
the local world, which plays through the same client and loader (MultiWorld; every `lsb*.ini` on
Daniel's old install names it): on a fresh client its `lsb.ini` is still copied as before, from
`horizonxi.ini` or, with none yet, from Ashita's example, which names `pol.exe`.
`Credentials.fixBootLoader(…, loader:)` makes `[ashita.boot] file` name the declared loader
whenever it is in `bootloader/`, even over another loader that exists. Without a declaration the
old rule holds (a loader that exists stays; a missing one becomes the first known one present).
The hosted worlds declare none and keep exactly what they had: CatsEyeXI's own 1 MB loader *is*
called `pol.exe`; Gaia XI's profile names `gxiloader.exe`, Supernova's `xiloader.exe`. `file` is
now read and written in `[ashita.boot]` only (it used to be the first live line starting with
"file", anywhere).

**2. HorizonXI's profile ships in the app.** `app/Resources/horizonxi-boot.ini`
(`Server.bootTemplate`; bundled by `app/bundle.sh`, which refuses to build without it). A new
`horizonxi.ini` is made from it — never from Ashita's example — with the world's host in `command`
and, when the client's SquareEnix folder is not `<client>\SquareEnix`, its real Windows path for
Sandbox. It is HorizonXI's own stock profile (`config.stock/boot/horizonxi.ini` on the old
install) with no account, no machine path and no personal choice, written with this project's own
comments (no Ashita or HorizonXI text copied). What it keeps, and why:

| section / key | value | why |
| --- | --- | --- |
| `[ashita.launcher]` autoclose, name | `1`, `HorizonXI` | Ashita's own launcher only; name was "Example Configuration" |
| `[ashita.boot] file` | `.\\bootloader\\horizon-loader.exe` | the loader HorizonXI's login server takes |
| `command` | `--server play.horizonxi.com` | `Credentials.apply` writes the account into this line before every Play |
| `gamemodule`, `script`, `args` | `ffximain.dll`, `default.txt`, empty | stock; without `script` no addon or plugin loads |
| `[ashita.language]` playonline, ashita | `2`, `2` | English, stock |
| `[ashita.logging]` level, crashdumps | `5`, `1` | stock; Ashita's logs and crash dumps are what diagnose a launch |
| `[ashita.taskpool] threadcount` | `-1` | stock (Ashita decides) |
| `[ashita.resources]` *.use_overrides | `1` | stock |
| `[ashita.window.startpos]` x, y | `-1` | stock (centred) |
| `[ashita.input]` (8 keys) | stock | stock (docs/MOUSE.md: `mouse.unhook` measured to make no difference here) |
| `[ashita.misc]` *.silent | `0` | stock |
| `[ashita.polplugins]` sandbox, pivot | `1`, `1` | HorizonXI's stock and Daniel's working pair; Play repairs Sandbox's interface bypass if it is ever off (Sandbox.swift) |
| `[ffxi.direct3d8]` presentparams.* | `-1` | stock (the game decides) |
| `behaviorflags.fpu_preserve` | `0` | stock; the renderer's override sets it to `1` on DXVK at every Play, and only rewrites a line that exists |
| `[ffxi.registry]` 0000–0045, padmode000, padsin000 | stock | HorizonXI's defaults: 1920×1080 window and menu, 4096 textures, mip mapping 6, windowed (0034 = 1), gamepad map. Two changes: **0029 = 20** (sound channels at their maximum, as in `scripts/max.json`: Daniel's rule is max settings, and stock ships the lowest, 12) and **0042 = -1** (stock names a Windows screenshot folder; `-1` leaves it to the game) |
| `[sandbox.paths]` common, pol, ffxi | HorizonXI's (`..\SquareEnix\…`) | where Sandbox tells the game its files are |

Dropped from Daniel's profile as personal: his 1280×720 window, 512 textures, 960×540 menu, 0018
4 / 0019 0 / 0021 0, `[ashita.fonts]`.

**3. An existing profile is completed, never rewritten.** At every Play, under the launch lock
and before anything reads the profile (`Credentials.prepareProfile`, called from the launch's
`beforeLaunch`, ahead of the account line), a world with a template gets each setting
`BootProfile.required` lists *only when the profile has no live line for it*:

- `[ashita.boot] command` (`--server <host>`): `Credentials.apply` fails without the line;
- `[ashita.boot] script = default.txt`: no script, no addons or plugins;
- `[ashita.polplugins] pivot = 1`: HorizonXI's overlays;
- `[ffxi.direct3d8] behaviorflags.fpu_preserve = 0`: so the renderer's override has a line to set;
- `[sandbox.paths]` (template values) — only when the profile has Sandbox on.

A value the user set (`pivot = 0`, `sandbox = 0`, any graphics key) is never changed; the account
line is never touched; line endings stay the file's own. pivot.ini's `root_path` is pointed at
this client's own `polplugins\DATs` only when the folder it names does not exist and that one
does. Each change is one `i  …` line in launcher.log; nothing is shown to the player.

**4. Preflight says it, Play fixes it.** A new check, `bootprofile` ("Boot profile"), runs for a
world with a loader or template and lists what is wrong ("boots pol.exe, not horizon-loader.exe;
lacks [ashita.polplugins] pivot; pivot.ini's overlay folder is not in this client — Play fixes
this on the way in"). It is in `Primary.fixedByPlay`: it never greys Play and puts nothing under
the button; Setup & Diagnostics and `--check` show it.

**5. The loader's menu is a refused login.** `LoaderOutput.menuMarkers` ("What would you like to
do?", "Enter a selection") join the refusal markers, for the game's output only. Reaching the
menu means the autologin did not happen, whichever loader it is, and nothing can answer it: the
launcher stops the loader at once and shows one line, "HorizonXI didn't accept the login — check
the account name and password." The session ends, and the button goes back to Play (the watch
loop notices within about 7 s). A loader's own refusal ("Failed to login. Invalid username or
password.") still wins when it comes first, as before.

**6. A looping loader cannot fill launcher.log.** `LoaderOutput.RepeatCap`: each distinct line of
the game's output (its `[mm/dd/yy hh:mm:ss]` stamp aside) is written at most 20 times per launch,
then dropped, with one note. Whole lines only; a line split across two reads counts once. 831
menus become 20. The game's own stdout file in `$TMPDIR` is not capped (the loader writes it;
it is overwritten per launch).

## Press 1 (`injector exited 0`, then nothing)

**Not proven.** What the evidence shows (`log show` for 12:18–12:22, read-only):

- Each `wine reg add`/`regsvr32`/`regedit` of `GameRegistry.point` runs as one `do shell script`,
  and that only returns once its wineserver has exited (each osascript ends within 10 ms of its
  server): 11 wineservers, about 6 s each, 12:19:04–12:20:11. The last one (pid 7570) went inactive at
  **12:20:11.564**.
- The game's spawn (osascript 7623) came at **12:20:11.917**, 0.35 s later.
- From then until the second press's registry work at 12:20:26.980 **no wine process and no
  wineserver appeared at all**. launchd logged each of the 11 wineservers before and each one
  after, and RunningBoard every wine of the second press. The injector's wine never reached a
  wineserver and never touched CoreFoundation; there is no crash report.

So press 1 did **not** race the registry session's dying wineserver: that server was gone first,
and the new wine never got as far as connecting to any server. Something ended wine in its first
fraction of a second, before the server and before Ashita: with `ROSETTA_X87_PATH` set, that is
where the patched wine re-execs itself through `x87sidecar-coop` (docs/X87-SIDECAR.md), and b60's
sidecar (installed 11:24) had never run before that press. That is the leading suspect, not a
finding: nothing in the logs names it, and the second press, 70 s later, ran the same sidecar fine
("x87: sidecar live beside the client a minute after it appeared").

What changed for it:

- `stopWineserver` **does** wait for the old server to be gone, not just send `-k`: `-k` itself
  waits on the server's lock (up to ~10 s, then SIGKILL) and `-w` waits for it again. That wait is
  now **bounded** (30 s, `RendererSetup.waitLimit`; it ran unbounded on the main thread), and an
  overrun is one line in launcher.log.
- A launch that ends with no output at all, no process of it ever seen running, no Stop and no
  window (Ashita v4) now says one line, "The game didn't start — press Play to try again.", and
  launcher.log records it. Before, the button just went back to Play.
- The second press pointed the registry all over again (a minute of "Starting…") because Play
  trusted checks taken before the first press. Play now reads `system.reg` again before forgetting
  the registry marker (`Preflight.registryPointed`).

## What Play will now do to Daniel's new install

Checked by `--selftest-boot-profile` on a copy of his `horizonxi.ini` (password masked, in the
fixture folder, deleted after) and his `pivot.ini`, on a fixture client with the same three
loaders; `--check` on the real install (read-only) names the same three problems. On the next
PLAY of HorizonXI:

1. `config/boot/horizonxi.ini`: `file = .\\bootloader\\pol.exe` → `.\\bootloader\\horizon-loader.exe`.
2. Same file: `pivot = 1` added under `sandbox = 0` in `[ashita.polplugins]`. Nothing else in the
   file changes (`sandbox` stays 0, his `command` line, `fpu_preserve`, every registry key).
3. `config/pivot/pivot.ini`: `root_path=C:\Games\HorizonXI\polplugins\DATs` →
   `root_path=C:\HorizonXI\polplugins\DATs` (overlays horizonmusic, horizonoverrides, remapster kept).
4. Then, as every Play: his account into `command`, Ashita boots `horizon-loader.exe`.

launcher.log gets three `i  boot profile: …`/`i  pivot.ini: …` lines; the window shows nothing.

## Tests (2026-10-15, M1 8 GB, macOS 27.0, release build)

- `--selftest-boot-profile` (new, `HXI_FIXTURE_DIR=~/Downloads/FFXI-on-Mac-build/fixture`): 39/39
  (38/38 with `HXI_BOOT_PROFILE_SAMPLE`/`HXI_PIVOT_SAMPLE`, the masked copy above, on the build
  before the local world declared its loader). The b60 profile
  (example-seeded, pol.exe + xiloader.exe + horizon-loader.exe) → horizon-loader.exe, pivot
  added, account line byte-identical, every other line kept in order, user values kept, nothing
  on the second Play; CRLF stays CRLF; a user's `pivot = 0` kept; no `file` line → added;
  Sandbox on without paths → paths added; a fresh client → the template, not Ashita's example;
  SquareEnix elsewhere → absolute Sandbox path; CatsEyeXI's profile and pivot.ini untouched;
  Supernova-style missing loader → xiloader.exe as before; the local world on a fresh client →
  copied from Ashita's example as before, booting horizon-loader.exe; Preflight's check → Play
  enabled with nothing said; the menu → one-line refusal, the loader's own refusal first,
  ordinary output and job output not; 831 menus → 20; split lines whole; CRLF counted.
- The other 18 suites: all pass (`--selftest-primary-action` 77/77, `--selftest-install-location
  ~/Downloads/FFXI-on-Mac-build/fixture` 107/107, `--selftest-setup-progress` 27/27,
  `--selftest-retroachievements` 47/47, the rest "all checks passed"). Run without its fixture
  argument, `--selftest-install-location` fails 4 checks (103/107); b60 documents it with the
  argument, and with it all 107 pass.
- `scripts/tests/setup-scripts-test.sh` with `HXI_LAUNCHER_BIN`: 100 ok, 0 failed, 2 skipped (no
  aria2 archive, no game-Wine tarball given) on the first build. Rerun on the final build: 98 ok,
  2 failed, both in part 21 — `--fix` refused Repair ("a game is running in this prefix
  (play.horizonxi.com …)") because Daniel had pressed PLAY on b60 again at about 13:02 and its
  `pol.exe` was looping at the menu (left running, as instructed). The fixture's Repair needs no
  client alive; not rerun after.
- Read-only on Daniel's Mac: `--check` names `…/FFXI on Mac/FFXI on Mac Wine.app [prefix10]`,
  HorizonXI "BAD … Boot profile: … boots pol.exe, not horizon-loader.exe; lacks
  [ashita.polplugins] pivot; pivot.ini's overlay folder is not in this client — Play fixes this on
  the way in" (exit 1, as in b60, other worlds' drives); `--next-action HorizonXI` →
  `play | Play |` (exit 0), and Local server the same (`ok` in `--check`: its `lsb.ini` does not
  exist yet on this client, so there is nothing to fix).

## Not tested (rules for this build: no GUI, no game, no wine on the real install)

- **The live Play.** Nothing here has logged in to HorizonXI with the fixed profile. That
  `horizon-loader.exe` logs in with `sandbox = 0, pivot = 1` on this client is from Sandbox.swift's
  measured table (old install, 2026-08-16), not from this client.
- XIPivot loading HorizonXI's overlays from the corrected `root_path` on this client.
- The menu stop on a live loader, and the button coming back to Play.
- Press 1's cause. If it recurs, launcher.log now says so, and `log show --start … --style
  compact | grep unmanaged.wine` shows whether a wine or wineserver ever started.
- A template-seeded profile with Sandbox on, on a fresh Setup (the template's pair is HorizonXI's
  stock and the old install's, not measured on a Setup-built client).

## Risks

- The local world now forces `horizon-loader.exe` too, whenever it is in `bootloader/`: an
  `lsb.ini` that deliberately named another loader there is changed at Play.
- A HorizonXI client without `horizon-loader.exe` in `bootloader/` keeps whatever its profile
  names (there is nothing better to point at), and Preflight's `bootprofile` check says nothing
  about it either: that client cannot log in to HorizonXI, and nothing here names why.
- A user who points HorizonXI at a deliberately different loader has it replaced at every Play,
  while `horizon-loader.exe` is present. HorizonXI's server takes nothing else.
- `pivot = 1` is added to a HorizonXI profile that lacks the key. If XIPivot misbehaves on some
  client, the user's own `pivot = 0` is respected; the key is never re-added over it.
- The "didn't start" line can appear after a launch that ends silently for a deterministic reason
  (broken wine); pressing Play again then shows it again.
- The bounded wait can start the game beside a wineserver still flushing after 30 s, the old
  "Closing…" case, where b60 would have waited (and held the window) for as long as it took.

## Review fixes

An adversarial review of `beta-b60..beta-b61`, plus a Gemini 2.5 Flash pass over the same diff.

- **The menu with no account asked for the wrong thing.** Worlds whose card says the loader
  window makes the account (Local server, Eden, Supernova) can be played with the account fields
  empty; their loader then opens at its menu having tried no login, and the line said "didn't
  accept the login". `launch` now reads whether the boot command it handed the loader carries a
  non-empty `--user` and `--pass` (`Credentials.bootHasAccount`, sharing `bootServer`'s parsing,
  `Credentials.option`), and without them the line is "<world> needs an account — enter its name
  and password, then press Play." With them, as before. (`bootServer` now also ignores a
  `--server` with nothing after it, falling back to the world's host as when there is none.)
- **`file =` always said `bootloader\`.** The loader is chosen from `Install.bootLoaderDir`
  (`bootloader/` or `ffxi-bootmod/`); the rewritten line now names that folder, so a v4 client
  whose loaders live in `ffxi-bootmod/` is not pointed at a file that is not there.
- The risk above about a HorizonXI client without `horizon-loader.exe` said Preflight lists it; it
  does not.

Checked and left as they are:

- **The template** (`app/Resources/horizonxi-boot.ini`) holds no account, password, user name or
  machine path; neither does any line b61 added (`git log -p beta-b60..beta-b61`), and the built
  binary's only `--pass` strings are the self-tests' fixture values.
- **Other worlds.** CatsEyeXI, Gaia XI, Supernova and the rest declare no loader and no template:
  `fixBootLoader` keeps a loader that exists, as in b60, and `prepareProfile` changes nothing else
  for them. Eden (Ashita v3, XML) is never touched (`fixBootLoader` and `complete` take `.ini`
  only). The local world's loader matches every `lsb*.ini` on the old install
  (`horizon-loader.exe`, which is also what `lsb-server.sh` patches LandSandBoat to accept).
- **Key insertion** keeps the file's line endings, comments, order and every existing value
  (self-test: CRLF, a user's `pivot = 0`, the masked copy of Daniel's profile).
- **The menu marker** cannot fire on a normal HorizonXI login: `horizon-loader.exe` (same SHA-1
  in both installs) prints "Autologin activated!" when it has an account and only reaches "What
  would you like to do?" when the autologin was refused or never tried; it does not print "Enter
  a selection" at all (Ashita's `pol.exe` does). Its refusals all begin "Failed to login", which
  still wins.
- **Play's order** is profile (`beforeLaunch`: loader, missing settings, pivot.ini, then the
  account) → renderer and registry (`GameRegistry.point`) → `fpu_preserve` override → Sandbox
  bypass → `stopWineserver` (bounded wait) → spawn.
- **Nothing greys Play or adds text when ready**: `bootprofile` is in `Primary.fixedByPlay`;
  `--next-action` gives `play | Play |` for HorizonXI and the local world.
- Gemini's two findings were both rejected: (1) "a world with no loader no longer gets a missing
  `file` line added" — b60 never added one either (it only replaced an existing line); (2) "on
  timeout the wait kills `wineserver -w`, not the server" — that is the design: the 30 s bound
  stops waiting, it does not kill the server (listed under Risks).

Tests after the fixes (release build, 2026-10-15): `--selftest-boot-profile` 43/43 (44/44 with
the masked sample of Daniel's `horizonxi.ini` and `pivot.ini`: loader pol.exe → horizon-loader.exe,
pivot added, pivot.ini root fixed, account line unchanged, then stable; the copy deleted after);
the other 18 suites all pass (`--selftest-install-location <fixture>` 107/107,
`--selftest-primary-action` 77/77, `--selftest-setup-progress` 27/27, `--selftest-retroachievements`
47/47); `scripts/tests/setup-scripts-test.sh` with `HXI_LAUNCHER_BIN`: 100 ok, 0 failed, 2 skipped
(no loader was running this time); `--check` (read-only) names the same three HorizonXI problems,
exit 1 for the other worlds' missing drives; `--next-action` `play | Play |` for HorizonXI and
the local world.

Still open from the review:

- The local world's account cannot be made from this launcher: its card says the loader window
  makes it, but no loader window is ever shown (the loader's console is the game's stdout file),
  so its "Create New Account" menu cannot be answered. Before b61 the menu looped unseen; now
  Play stops and asks for an account. The same holds for Eden's and Supernova's cards.
- A HorizonXI account with a one-time code (horizon-loader has `--otp-code` and an "OTP Code:"
  prompt) is not handled; what its loader prints without the code was not observed.

