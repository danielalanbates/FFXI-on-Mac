# Beta 3.10 build 69 (local only)

Branch `beta-b69`, from 48719f6, with `release-3.10` (e441246, the published 3.10 plus its docs)
merged in. Local beta: no GitHub release, nothing pushed, not installed.

Three changes:

- When the player resizes the game window, the picture keeps its shape (below).
- The game window's title always reads "FFXI on Mac", not the character's name
  ([The window title](#the-window-title-always-ffxi-on-mac)).
- **Addons…** opens at once, with a spinner while it reads the folders
  ([Addons… opens at once](#addons-opens-at-once)).

## Why

Daniel, 2026-10-16, after 3.10's Play-time fit: *"when the player adjusts the window it always
maintains its aspect ratio"*.

FFXI creates its Direct3D back buffer once, at the boot profile's `[ffxi.registry]` 0001 x 0002,
and never resizes it. Wine's Mac driver lets the window be dragged to any shape and the renderer
scales that fixed buffer to fill it, so a window dragged wider squeezes every character and name
sideways and a taller one stretches them.

## How it works

`window/gamewindow.c` → `app/Resources/gamewindow.dylib` (universal arm64 + x86_64, built by
`scripts/build-gamewindow.sh`, committed like `audiofollow.dylib`). It is inserted into the game's
wine with `DYLD_INSERT_LIBRARIES`, next to audiofollow (`audiofollow.dylib:gamewindow.dylib` when
both are on).

1. At Play, after the Play-time fit (3.10, `Runner.launch`), the launcher reads the boot
   profile's own 0001 and 0002 (`GameWindow.launchSize`) and puts them in `HXI_GAME_ASPECT`, for
   example `2560x1440`. That is exactly the size the client is started at.
2. In every wine process except wineserver, the dylib's constructor parses `HXI_GAME_ASPECT`
   (whole numbers 1…32768, ratio between 1:4 and 4:1) and, only if it is valid, observes
   `NSWindowDidBecomeKeyNotification` and `NSWindowWillStartLiveResizeNotification` on
   CoreFoundation's local notification center. What AppKit posts through
   `[NSNotificationCenter defaultCenter]` reaches those observers (checked by the native test; on
   macOS 27 the two are not the same object, but delivery is all that is needed).
3. When one is posted for a window, on the main thread, and the window is an `NSWindow` (wine's
   are `NSPanel` subclasses), titled, resizable, not full screen and at least 320x240 points
   (the client's 640x480 floor under wine's Retina mode), it calls
   `setContentAspectRatio:` with that size. AppKit then keeps every drag of an edge or a corner in
   proportion. It is set when the window becomes key, so even the first drag is already locked,
   and again at each live-resize start.

Without a valid `HXI_GAME_ASPECT` nothing is observed. The window's own shape is deliberately not
used as a fallback: the dylib cannot tell the game window from any other titled window, and the
shape the window has may already be wrong (a window bigger than the screen is cut down on one side
only, the bug 3.10 fixed), so a guess could lock in exactly the squeeze this exists to prevent.
The launcher only sets the variable when the profile names both 0001 and 0002.

Wine's own resize path does not undo it: wine's `windowWillResize:toSize:` asks the Windows side
through `WM_SIZING` (`query_resize_size`, athei/wine `cx-26-patched`), and keeps AppKit's size
unless a window procedure handles `WM_SIZING` and returns TRUE; `DefWindowProc` does not.

### Setting

Setup & Diagnostics → **Keep the game window's shape and title** (was "…shape" before the title
was added; one setting, because both live in the one dylib), on by default
(`PerfSettings.keepWindowShape`, decoded field by field like every other setting, so older saved
settings get it on). Off: the dylib is not inserted and nothing differs from 3.10.
`HXI_GAME_ASPECT=` in extra environment removes only the ratio, `HXI_WINDOW_TITLE=` only the
title; `FFXI_GAMEWINDOW_DEBUG=1` there puts one line per action in the log.

The launch log file gets `i  window shape: kept at WxH when the game window is resized`, and
`last-spawn.txt` now records `HXI_GAME_ASPECT` (nothing secret).

### With the remembered window size

As released in 3.10 (merged here): `WindowMemory.remember()` keeps 3.9's rule, and Play fits the
profile to the screen in the pure `WindowMemory.playSettings` — a size that does not fit is scaled
down with both sides together, a profile that fits is never cut, and an earlier fit of the stored
size grows back on a bigger screen. `HXI_GAME_ASPECT` is read from the profile after that fit has
written it, so the ratio is always the size the client really starts at. With the lock, the size
the player leaves is in that proportion, so what is remembered keeps the same shape too (to within
the even-number rounding WindowMemory applies, a fraction of a percent).

## The x87 sidecar strips DYLD_INSERT_LIBRARIES — and the carry

Checking that `DYLD_INSERT_LIBRARIES` actually reaches the game showed that it does not whenever
x87 acceleration is on (the default):

- Wine execs every i386 process as `x87sidecar-coop --cooperative <loader> <args>` when
  `ROSETTA_X87_PATH` is set (athei/wine `3804c30b`, `preloader_exec`). The sidecar's parent then
  `execv`s the loader with its own environment (athei/x87sidecar `rosetta_loader/src/main.cpp`).
- The bundled sidecar is signed with the hardened runtime (Developer ID, no entitlements, as
  notarization needs). dyld strips every `DYLD_*` variable from a restricted process's environment
  before `main()`.
- Measured 2026-10-16 with a copy of the installed sidecar: `gprintenv DYLD_INSERT_LIBRARIES`
  exec'd directly prints the dylib and its constructor runs; exec'd through the sidecar it prints
  nothing and nothing loads.

So without more, gamewindow.dylib would never reach an accelerated client — and neither has
audiofollow since the cooperative path shipped (see `docs/AUDIO.md`, 2026-10-16).

The dylib therefore also carries the list across that one exec:

- At load, where `ROSETTA_X87_PATH` and `DYLD_INSERT_LIBRARIES` are both set, it copies the list
  into `HXI_DYLD_INSERT_LIBRARIES` (dyld leaves other names alone).
- It interposes `execv`. When wine execs exactly `<ROSETTA_X87_PATH> --cooperative /abs/loader …`,
  it execs `<sidecar> --cooperative /bin/sh -c 'export DYLD_INSERT_LIBRARIES="$HXI_DYLD_INSERT_LIBRARIES"; exec "$@"' hxi-carry /abs/loader …`
  instead. The sidecar runs sh where it would have run the loader; sh puts the list back and execs
  the loader in place.
- The pid never changes (execv, then exec), so the sidecar's handshake, which is keyed to that
  pid (`x87sidecar.<pid>`), is unaffected. Only `DYLD_INSERT_LIBRARIES` is restored; every other
  `DYLD_*` variable stays stripped, so the client resolves its libraries exactly as before.
- If the rewritten exec fails, wine's own exec runs. `FFXI_GAMEWINDOW_CARRY=0` turns the carry off.
  Any other exec, and any sidecar call without `--cooperative` and an absolute loader path, passes
  through untouched.

Why it went unnoticed: an ad-hoc build leaves the vendored sidecar's ad-hoc signature (no hardened
runtime) in place, and that strips nothing; the 2026-08-26 audiofollow check was made with one.
Developer ID builds (the installed app, every release) sign the sidecar with the hardened runtime.

Side effect, deliberately kept: with "Follow the Mac's sound output" also on, audiofollow reaches
an x87-accelerated client again in a Developer ID build. On this Mac the 3.10 sessions ran with
that setting off (`last-spawn.txt` had no `DYLD_INSERT_LIBRARIES`), so here only gamewindow is
inserted.

Other pathways considered: entitling the sidecar with `allow-dyld-environment-variables` (would
also load the dylibs into the sidecar itself, under library validation, where a failed insert can
stop the launch), handling `WM_SIZING` in a modified `d3d8to9.dll` (DXVK pathways only, a rebuilt
render shim, and no way to test it here without the game), and an Accessibility observer in the
launcher (a new permission prompt, and it can only correct a window after it has been dragged
wrong).

## Safety

- The dylib links only libSystem and the Objective-C runtime, both in every process already.
  CoreFoundation is opened at load only when there is a ratio to keep and never in wineserver
  (on macOS 27 it brings Foundation with it); every other wine process loads it anyway, because
  wine's `ntdll.so` links it. AppKit is never loaded by the dylib. In services.exe and the other
  windowless wine processes nothing is ever posted, so nothing happens.
- Every Objective-C call is guarded (class check, `respondsToSelector:`), main thread only, and the
  only things it ever changes are a qualifying window's content aspect ratio and, with
  `HXI_WINDOW_TITLE`, a game window's title and Window-menu item (two method overrides, each
  installed once; see [The window title](#the-window-title-always-ffxi-on-mac)). Setting the
  ratio does not move or resize the window (checked).
- `setContentAspectRatio:` is only called with a positive size. No allocation on the notification
  path; the carry builds its argv on the stack.
- Missing or wrong-architecture dylib: not inserted (`InsertedLibrary.bundled` reads the Mach-O
  header for an x86_64 slice, as `AudioFollow` always did; that code moved, unchanged, into
  `InsertedLibrary.swift`).
- Signed like audiofollow: ad-hoc by the build script; `bundle.sh` re-signs it with the Developer ID,
  hardened runtime and a secure timestamp before the app, so notarization treats it as it treats
  audiofollow.

## Tests

`scripts/tests/gamewindow-test.sh` (never shows a window: activation policy Prohibited, windows
deferred and never ordered front; exits by itself). All passed, 2026-10-16, macOS 27.0:

- **Window test, arm64 and x86_64 under Rosetta** (the x86_64 slice is the one wine loads; its
  `frame` call goes through `objc_msgSend_stret`): with `HXI_GAME_ASPECT=1920x1080`, a live-resize
  notification locks an NSPanel subclass (titled, closable, miniaturizable, resizable, 960x540
  points) to 1920:1080; becoming key locks a plain NSWindow; a 320x240-point window counts; a
  window that already had 4:3 is put on 1920:1080; the frame does not move or change size and the
  window is never visible. Left alone: a window that is not resizable, a borderless one, one of
  200x150 points, a qualifying window whose notification is posted off the main thread. A string,
  a number and no object posted under those names are ignored without a crash. A post through
  `NSNotificationCenter.defaultCenter` reaches an observer on `CFNotificationCenterGetLocalCenter()`
  (on macOS 27 they are not the same object, but delivery is what the dylib needs).
- **Invalid or missing `HXI_GAME_ASPECT`** — unset, empty, `banana`, `1920x0`, `0x1080`,
  `1920x1080x2`, `100000x1`, `1920X1080`, `800x100` (8:1), `x1080`, `1920x`, `-1920x1080`: nothing
  is locked, on both architectures.
- **Processes without AppKit** (a plain C program, both architectures, exit 0): with no ratio,
  nothing but the dylib loads (no CoreFoundation, Foundation or AppKit); the same program named
  `wineserver`, ratio set, still loads none of them; any other process with a ratio opens
  CoreFoundation (on macOS 27 that brings Foundation and ~300 other images, which every wine
  Windows process loads anyway through `ntdll.so`) and never AppKit.
- **The carry** (x86_64 stand-in for wine and for the client, under Rosetta, with the real
  sidecar re-signed with the hardened runtime as `bundle.sh` signs it): exec'd directly the client
  gets the dylib; through the sidecar with the carry off it gets no `DYLD_INSERT_LIBRARIES` and no
  dylib (the problem, reproduced); with the carry on it has the dylib, the same pid wine exec'd
  from (the handshake's pid), and its arguments unchanged (`two words`, `q'u"o te`). Run once
  more by hand against a copy of the installed app's Developer ID sidecar, paths with spaces:
  same three results.

Launcher (`swift build -c release`, separate scratch dir; no new warnings): `--selftest-perf` gains
15 checks — on by default and kept on for settings saved before b69, off survives save/load; dylib
missing ⇒ environment untouched; `audiofollow:gamewindow` joined with `:` and never listed twice;
unknown launch size ⇒ dylib without a ratio; the ratio refused exactly where the dylib refuses it;
the launch size is the profile's 0001 x 0002 (CRLF profile), none without 0002, with 0002 = 0, or
without a profile; setting off ⇒ neither; setting on ⇒ `HXI_GAME_ASPECT=2560x1440` and both
dylibs in order; `HXI_GAME_ASPECT=` in extra environment removes the ratio; last-spawn.txt records
it; a non-Mach-O file is never inserted.

All 26 `--selftest-*` suites of the built launcher, run with no game running (so including
`--selftest-leftovers`, `--selftest-addons-live` and `--selftest-perf`): **923 checks, 0 failures**
(perf 60, install-location 107, updater 79, primary-action 77, multiworld 72, graphics 69,
carryover 62, addons-live 51, retroachievements 47, boot-profile 43, dxvk-cache 39, news 36,
ui-text 33, setup-progress 27, leftovers 26, install-selection 21, addon-profile 16,
single-instance 14, addon-policy 8, cursor-fix 7, addon-install 6, addon-scrub 6,
narration-disabled 5, addon-installer 4, addon-source 4, guide-disabled 4).
`VanaguideCompanion --selftest-parser`: 1 failure, "every real guide step has a zone, level, or
tag" — it parses the Vanaguide checkout in Google Drive, not this repo, and nothing in
`VanaguideCompanion` changed here.

## Not verified

- **Nobody has dragged the game window with this build.** The native test proves the ratio is set
  on wine-shaped windows and that the carry delivers the dylib through the real sidecar binary;
  it cannot drag a window (nothing here may show one). That AppKit then keeps a live drag in
  proportion is AppKit's documented behaviour, not something measured on the game.
- The carry has been exercised with a stand-in for wine (the same `execv` call, run under
  Rosetta) and the real sidecar, not with wine itself. The one thing that would break a launch is
  the sidecar or sh failing to exec the loader; the test shows the loader stand-in receives its
  arguments and pid unchanged.
- audiofollow inside an x87-accelerated client (only when its setting is on).

## In-game check (Daniel)

1. Install b69 and press Play as usual.
2. Drag the bottom-right corner of the game window: the window keeps its shape while it grows and
   shrinks, and names and characters keep their proportions.
3. Drag only the right edge, then only the bottom edge: the other side follows so the shape stays.
4. Quit the game and press Play again: it opens at the size you left, same shape.
5. Log in: the title bar, Mission Control (and the Window menu) say **FFXI on Mac**, not your
   character's name, and still do after zoning and after logging out to the character screen.
6. In the launcher press **Addons…**: the sheet opens at once with a small spinner and
   "Searching…", then the list; Apply is greyed out until the list is there.

If the window still stretches: Setup & Diagnostics → extra environment → `FFXI_GAMEWINDOW_DEBUG=1`,
Play, and open the log. `gamewindow: loaded; keeping game windows at W:H (carry on)` from the
client, then `key: window 0x… now keeps W:H`, means the lock is set. After each drag,
`resize ended: window 0x… is WxH points, in proportion with W:H` means it held;
`OUT OF PROPORTION with (the game overrode the size)` means the game's window procedure answered
`WM_SIZING` with its own size, which AppKit lets win (see Review). No `gamewindow:` lines from the
client means the dylib did not arrive (look for `gamewindow: carrying the inserted libraries
through …`).

## Not covered

- **The green button** is macOS full screen for wine's resizable windows (wine gives them
  `NSWindowCollectionBehaviorFullScreenPrimary`, `adjustFullScreenBehavior:`). Full screen fills the
  display, so on a display of another shape (a 16:10 MacBook with a 16:9 profile) the picture is
  stretched to the display, as in 3.10. The lock leaves full-screen windows alone.
- **Zoom** (Option-click the green button, or double-click the title bar when that is set to
  Zoom): wine allows it for a resizable window that is not maximized (`windowShouldZoom:`) and
  AppKit zooms to the screen's visible frame as wine computes it (`windowWillUseStandardFrame:`).
  The aspect ratio constrains live resizing by the user, so the zoomed window is expected to take
  the screen's shape; not measured.
- macOS window tiling (dragging to a screen edge, Window ▸ Move & Resize) sets the frame directly
  and is not constrained either.
- A world whose client opens another titled, resizable window of at least 320x240 points (a retail
  PlayOnline window, say) gets the same ratio on it.

## Review (2026-10-16)

Adversarial review of `48719f6..81e1070`: every claim above checked against the code, against
upstream source (athei/wine `cx-26-patched` and `3804c30b`, athei/x87sidecar `238a214`, read
only) and against the installed `wine-coop` binaries, and every test rerun. Nothing was launched,
installed or pushed; every build and process test waited until no game was running.

**Does the lock engage under wine? Yes, unless the game answers `WM_SIZING`.**
- WineWindow resizes through AppKit's own tracking: its `sendEvent:` override only handles
  title-bar drags of maximized windows and otherwise calls `[super sendEvent:]`; its
  `setFrame:display:` overrides call super; `constrainFrameRect:toScreen:` is about screens. It
  never sets `contentAspectRatio` or `resizeIncrements` itself.
- Measured on macOS 27 with AppKit's per-drag computation (`_frame:resizedFromEdge:withDelta:
  withEvent:`, on hidden windows; now in `gamewindow-test.m`): the ratio is applied *before*
  `windowWillResize:toSize:` and the delegate's answer is final. A +300-point right-edge drag gives
  1260x540 unlocked and 1120x630 locked; a delegate that answers 1000x400 gets 1000x400.
- WineWindow is its own delegate and returns AppKit's size unless the window procedure handles
  `WM_SIZING` and returns TRUE (`query_resize_size`); wine's `DefWindowProc` does not handle it.
  Whether FFXI or Ashita does is still unknown. No swizzle was added for that case: there is no
  evidence it happens, and overriding the game's own answer would start a size tug-of-war through
  `WM_WINDOWPOSCHANGING`. Instead, with `FFXI_GAMEWINDOW_DEBUG=1`, the dylib now logs at the end of
  each live resize whether the window kept the ratio, so the in-game check can tell.

**The carry, end to end.** The installed `wine-coop` `ntdll.so` re-execs through the sidecar with
`execv(ROSETTA_X87_PATH, [sidecar, --cooperative, loader, …])`, which the interpose catches. The
loop guard (`WINELOADERNOEXEC`) and the sidecar's own variables (`ROSETTA_DISABLE_AOT`,
`X87_SIDECAR_BOOTSTRAP`) pass through `/bin/sh` (bash 3.2 here). That shell also keeps variables
whose names are not identifiers and reads neither `ENV` nor `BASH_ENV`; it adds `PWD` and `SHLVL`,
which the launch script's own shell already set. The carry test now does wine's real cooperative
handshake from the stand-in client, against the hardened sidecar. Through the carry, the sidecar
attaches, installs its x87 JIT hook and replies, x87 arithmetic runs, and the dylib is mapped,
with CoreFoundation opened before the handshake as in the client. Without the carry the result is
the same except for the dylib.

**Process scans.** For the life of the game, the sidecar's command line now carries the `/bin/sh`
step (`… --cooperative /bin/sh -c export DYLD_INSERT_LIBRARIES="$HXI_DYLD_INSERT_LIBRARIES"; exec
"$@" hxi-carry <wine> <loader> …`, read from `ps`). `LiveClients.parse` still files it under the
client's host and still counts it as the sidecar, an injector keeps its boot file, Leftovers still
adopts the session and reads its `WINEPREFIX` (4 new self-test checks).

**Fixed.**
- `gw_log` wrote with stdio, including from wine's forked child (the carry's log line). If another
  thread held the `stderr` lock at `fork()`, that child would block forever (debug mode only).
  It now formats into a buffer and writes each line with one `write(2)`.
- Added the debug-only end-of-resize report above. The dylib was rebuilt; before the change the
  committed slices matched a fresh build of the source exactly (signatures stripped).

**Checked, no change needed.** `bundle.sh` signs `gamewindow.dylib` exactly like audiofollow
(Developer ID, hardened runtime, timestamp) before the app. `package.sh` only verifies the app
`--deep --strict`. `publish-release.sh` only requires v3.9's files to still be present, so a new
file passes. The wine loader is unsigned, so dyld honours the insert. `DYLD_FALLBACK_LIBRARY_PATH`
stays stripped in accelerated clients, as before. `GameWindow.aspect` and the dylib refuse the
same values. `PerfSettings.environment` is used only for Play.

**Tests rerun (no game running).** `scripts/tests/gamewindow-test.sh`: all passed on arm64 and
x86_64 under Rosetta, including the new drag-order checks, the debug report and the handshake
through the carry. Release build in `swift-build-b69` gave only the two older warnings. All 26
`--selftest-*` suites passed: 927 checks, 0 failures (multiworld 74, leftovers 28).

**Still not verified.** A real drag of the game window, and macOS 27's window-manager resize path
if it bypasses AppKit's tracking. Whether FFXI or Ashita handles `WM_SIZING`. Zoom, full screen
and tiling (not covered, see above). The carry under real wine (it was tested with the real sidecar
and a stand-in that does wine's exact exec and handshake). Notarization of the new dylib
(`package.sh` not run).

## The window title: always "FFXI on Mac"

### Why

Daniel, 2026-10-16: the game window's title should always read "FFXI on Mac". At login Ashita
calls `SetWindowText` with the character's name ("Murn"), and wine's Mac driver copies every
Windows title to the Cocoa window: `macdrv_set_cocoa_window_title` runs `[window setTitle:]` and
then, for a window that is ordered in and in the window cycle, `[NSApp changeWindowsItem:window
title:… filename:NO]` (athei/wine `cx-26-patched`, `dlls/winemac.drv/cocoa_window.m`). When the
window is ordered in, wine adds its Window-menu item with `[self title]`. So the name showed in
the title bar, Mission Control, the Dock's window list and the Window menu.

### How

In `window/gamewindow.c`, the dylib that already reaches the client through the carry. The
launcher sets `HXI_WINDOW_TITLE=FFXI on Mac` wherever it inserts the dylib (`GameWindow.apply`,
same setting); `last-spawn.txt` records it.

- With `HXI_WINDOW_TITLE` set (1…255 bytes of UTF-8, else ignored), the dylib also observes
  `NSWindowDidBecomeMainNotification` and `NSWindowDidChangeOcclusionStateNotification` (posted
  when a window comes on screen, even with the app in the background; not per frame) besides
  `DidBecomeKey`. `NSWindowDidUpdateNotification` is not used (it fires constantly).
- A **game window** for the title is one whose class is or descends from `WineWindow` (wine's
  class, an `NSPanel`; checked by name in the class chain, so AppKit's own panels never count),
  titled, resizable and at least 320x240 points. Message boxes are not resizable and keep their
  titles; so do small windows and any window that is not wine's.
- The first time a game window is seen on the main thread, the dylib replaces `-setTitle:` on
  `WineWindow`, once, keeping the implementation it had (WineWindow does not implement it, so
  that is NSWindow's): a game window gets `HXI_WINDOW_TITLE`, every other window the title it was
  given. It does the same for `-changeWindowsItem:title:filename:` on NSApp's class
  (`WineApplication`, which inherits NSApplication's), so the Window menu matches. `NSApp` is read
  with `dlsym`, never created; AppKit is never loaded by the dylib.
- At that sighting, and every later one, the title is set at once if it differs, and the window's
  existing Window-menu item is renamed (only an existing one: `changeWindowsItem:` would add one).
- The Windows side is untouched: `GetWindowText` still returns what the game set, so Ashita and
  addons see the character's name as before.
- Debug (`FFXI_GAMEWINDOW_DEBUG=1`): `title: -setTitle: overridden on WineWindow`,
  `key: window 0x… now reads "FFXI on Mac"`, `title: window 0x… asked for another title; it stays
  "FFXI on Mac"` (the requested title is never logged: it is the character's name).

Checked against the installed `wine-coop`: its `x86_64-unix/winemac.so` defines `WineWindow` and
`WineApplication` and calls `changeWindowsItem:title:filename:`.

### Tests

`scripts/tests/gamewindow-test.sh`, new `title` mode of `gamewindow-test.m`, arm64 and x86_64
under Rosetta, never showing a window. Runtime-made classes under wine's names (`WineApplication :
NSApplication`, `WineWindow : NSPanel`) and a Window menu as wine builds it; titles set through
wine's exact sequence (`setTitle:`, then `changeWindowsItem:` for a window in the menu):

- before any notification nothing is overridden or retitled; a message box, a titled resizable
  window that is not wine's, a 200x150 wine window and non-window objects install nothing;
- first seen through each of key, main and occlusion (three runs): the title is "FFXI on Mac" at
  once and so is its Window-menu item; only `WineWindow` and `WineApplication` changed (NSWindow,
  NSPanel, NSApplication untouched); key still locks the ratio alongside, the others do not;
- "Murn" at login and any later title become "FFXI on Mac", title and menu; also with the window
  observed by KVO (a runtime subclass), and KVO still fires; a game window made later reads it
  from its first title and gets its menu item under it; notifications never add a menu item;
- the message box, the other window and the small one keep their own titles (and menu items),
  an empty title stays empty;
- `HXI_WINDOW_TITLE` unset (ratio set, so the dylib is watching): nothing changes, nothing is
  overridden; empty, 256 bytes or not UTF-8: ignored;
- processes without AppKit: a title alone opens CoreFoundation, never AppKit; `wineserver` with a
  title opens nothing.

Result 2026-10-16: **280 PASS, 0 FAIL** (the whole script, with the earlier ratio and carry tests).
`--selftest-perf`: title wherever the dylib goes, none with the setting off, `HXI_WINDOW_TITLE=`
removes only the title, last-spawn.txt records it. `--selftest-leftovers`: a title with spaces in
a `ps -E` line does not disturb reading `WINEPREFIX`.

### Not verified

- Not seen on the game: whether the occlusion notification arrives before Ashita's rename (if not,
  the name shows until the window becomes key or main, then changes). Mission Control and the
  Dock read the window server's title, which AppKit updates with `setTitle:`; not looked at.
- A retail PlayOnline window, if a world opens one titled and resizable, would read "FFXI on Mac"
  too.

## Addons… opens at once

### Why

`openAddons()` read the plugin and addon folders, every addon's Lua header and the newest client
log on the main thread, and only then opened the sheet. On an external drive that takes long
enough that the click looked like it did nothing.

### How

- The sheet opens at once. Where the list will be it shows a small spinner and "Searching…"
  (`AddonSuite.scanningLabel`); the "nothing installed" line is not shown until the scan is back.
- `AddonSuite.sheetContents` (the scan, the server-list filter with its hidden count, and the
  refused-plugin line) runs in a utility-priority `Task.detached` and fills the sheet on the main
  actor. Each scan takes a generation number: a result for a sheet that was closed, or rescanned
  since, is dropped.
- **Apply**, **Enable all** and **Disable all** are disabled while it scans. Apply writes exactly
  the list on screen (`itemsToWrite` is `addonItems`, filtered on a restricting policy), so
  pressing it during the scan would have turned every addon off; it also refuses inside the action.
- **Get** (local-world extras) rescans the same way after installing, and switches the new addon on.
- Per-world behaviour is unchanged: the same policy filter, hidden count and note, the local-world
  extras section, and the Apply safeguards.

### Tests

`--selftest-ui-text` (5 new): the label is one short word; on a temporary install, unrestricted
lists every plugin and addon (never winefix, never a folder without its `.lua`) with none hidden;
an allowlist lists only what it allows and counts the rest (fps is local-only); no published list
shows everything; the refused-plugin line comes with the result and names the Lua host. The
sheet itself was not opened (no UI harness).

### Not verified

Nobody has opened the sheet in this build; how long the spinner shows on the x10 drive has not
been measured.

## Tests after the merge, the title and the spinner (2026-10-16)

No game running for any of them; release build in `swift-build-b69`, only the two older warnings.

- After merging `release-3.10`: `--selftest-graphics` 74 (69 before, release-3.10's own checks),
  `--selftest-perf` 60.
- `scripts/tests/gamewindow-test.sh`: 280 PASS, 0 FAIL.
- All 26 `--selftest-*` suites: **941 checks, 0 failures** (perf 63, install-location 107,
  updater 79, primary-action 77, multiworld 74, graphics 74, carryover 62, addons-live 51,
  retroachievements 47, boot-profile 43, dxvk-cache 39, ui-text 38, news 36, leftovers 29,
  setup-progress 27, install-selection 21, addon-profile 16, single-instance 14, addon-policy 8,
  cursor-fix 7, addon-install 6, addon-scrub 6, narration-disabled 5, addon-installer 4,
  addon-source 4, guide-disabled 4).
