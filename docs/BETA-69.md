# Beta 3.10 build 69 (local only)

Branch `beta-b69`, on top of `release-3.10` (48719f6). Local beta: no GitHub release, nothing
pushed, not installed.

One change: when the player resizes the game window, the picture keeps its shape.

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

Setup & Diagnostics → **Keep the game window's shape**, on by default (`PerfSettings.keepWindowShape`,
decoded field by field like every other setting, so older saved settings get it on). Off: the
dylib is not inserted and nothing differs from 3.10. `HXI_GAME_ASPECT=` in extra environment
removes only the ratio; `FFXI_GAMEWINDOW_DEBUG=1` there puts one line per action in the log.

The launch log file gets `i  window shape: kept at WxH when the game window is resized`, and
`last-spawn.txt` now records `HXI_GAME_ASPECT` (nothing secret).

### With the remembered window size

3.10 remembers the size the window is left at and opens there next time, scaled down to fit the
screen with both sides together. With the lock, the size the player leaves is always in the
profile's proportion, so the remembered size keeps the same shape too (to within the even-number
rounding WindowMemory applies, a fraction of a percent).

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
  only thing it ever changes is a qualifying window's content aspect ratio. Setting it does not
  move or resize the window (checked).
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

If the window still stretches: Setup & Diagnostics → extra environment → `FFXI_GAMEWINDOW_DEBUG=1`,
Play, and open the log. `gamewindow: loaded; keeping game windows at W:H (carry on)` from the
client, then `key: window 0x… now keeps W:H`, means the lock is set and AppKit is not honouring it
for this window; no `gamewindow:` lines from the client means the dylib did not arrive (look for
`gamewindow: carrying the inserted libraries through …`).

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
