# Which wine the game runs under

**The wrapper's own wine kills the client one second after login. Use the patched CrossOver wine.**

Measured 2026-08-21, same prefix, same boot profile, same 66-variable environment, twice each:

| wine | result |
| --- | --- |
| `siku.app/Contents/SharedSupport/wine/bin/wine` (the Sikarugir wrapper's own) | "Successfully logged in" → **"Closing..." one second later**, process gone |
| `/Volumes/Games/FFXI/wine-coop/wine/bin/wine` (athei/wine-build `wine-cx-26.3.0-1`) | logs in, reaches the world, runs indefinitely (58 fps) |

The wrapper's wine announces `err:environ:init_peb starting L"C:\HorizonXI\Ashita-cli.exe" in
experimental wow64 mode`, which the patched build does not; that is the likeliest culprit but has
not been isolated further, because the fix costs one line and the isolation does not.

This is the same *symptom* as the 2026-08-19 launch-death (docs/LAUNCH-DEATH.md, fixed by
`spawnViaShell` + `wineserver -w`) and a different cause — that one was about how Foundation wired
the child's stdio, this one is about which wine binary runs. Both had to be fixed for Play to work.

## What the launcher does

`X87Sidecar.patchedWine()` returns the wine-coop binary if it is installed, and `Runner.launch`
prefers it **whether or not** x87 acceleration is on (it is off by default now — see
docs/X87-WALL.md). Without it the launcher falls back to the wrapper's wine and says so in the log
strip, because a silent one-second exit after login is the least debuggable failure this project
has produced twice now.

**So wine-coop is no longer optional.** It arrived as an x87 experiment; it is now the only wine
that plays. 1.1 GB unpacked, per machine, not in the app bundle.

## Where Setup gets it (b60)

The main button's Setup installs it, after Wine and before the game download, with
`scripts/game-wine.sh install "<chosen>/FFXI on Mac"` → `<chosen>/FFXI on Mac/wine-coop/wine/bin/wine`.
The pin lives in that script and nowhere else:

| | |
| --- | --- |
| release | this repo's `wine-cx-26.3.0-1`: a repack of athei/wine-build `cx-26.3.0-1`, which athei deleted in 2026-11 (issue #89) |
| URL | `https://github.com/danielalanbates/FFXI-on-Mac/releases/download/wine-cx-26.3.0-1/wine-cx-26.3.0-1-macos-x86_64-repack.tar.xz` |
| size | 152,312,088 bytes |
| SHA-256 | `a99e3029135e5df9985280efa00738d73c8d2fa092e9a5552a1096412a487bb8` (the repack; the deleted original was 203,696,924 bytes, `ec2a9e4d…e661`) |
| layout | top level `wine/` (`wine/bin/wine`, `wine/bin/wineserver`, …): 3,692 files, 1.13 GB |

curl, resumable (`-C -`, five attempts, a stalled minute ends an attempt); size and SHA-256 are
checked **before** anything is unpacked; `/usr/bin/tar` unpacks into a temp folder beside
`wine-coop` and one rename puts it in place; the tarball is deleted once unpacked. A download that
does not match is deleted and nothing else changes. Its progress is the main button's
"Setting up… N%". It is x86_64 and unsigned, so it needs Rosetta 2, which Setup installs first
(macOS's administrator prompt) when `arch -x86_64 /usr/bin/true` fails.

**The mirror (2026-11-20).** athei renamed wine-build to mach9 and deleted every `cx-*` release, so
the original URL answers 404 and no copy of the tarball survives here or on the Wayback Machine.
The mirror was packed from the measured copy below: `.DS_Store` left out, and
`libMoltenVK.dylib.bak-pre-1.4.2` (`02adfe96…`, the release's own) stored as `libMoltenVK.dylib`.
Unpacked and re-hashed before upload: 3,692 files and 4 symlinks, every file identical to the
measured copy apart from that MoltenVK, `bin/wine` `a84a059a…`, `bin/wineserver` `395e30e7…`. It is
therefore the same tree the 2026-10-15 check found in the original, in a different archive. To
re-pin: pack a `wine/` tree the same way, upload it to a release that is **not** marked latest
(the updater reads `/releases/latest`), and change the three values in `scripts/game-wine.sh`. A
dead address now says "no longer at its download address" instead of blaming the connection.
Source: CodeWeavers' published CrossOver 26.3.0 wine source, and athei's build scripts at the
`cx-26.3.0-1` tag of athei/mach9 (the tag outlived the release; if it goes too, rdbell/wine-build
and other forks carry it).

**Is it the wine that was measured?** (This check was made against the original download.) Checked 2026-10-15: every one of its 3,692 files was hashed
against the copy HorizonXI was measured on (`/Volumes/x10/Video Games/Mac/FFXI/wine-coop/wine`,
read-only). 3,691 are identical, `bin/wine` (`a84a059a…`), `bin/wineserver` (`395e30e7…`),
`lib/wine/x86_64-unix/*.so` and `lib/wine/i386-windows/*.dll` included, and so are its 4 symlinks.
The one difference is `lib/external/libMoltenVK.dylib`: that copy holds MoltenVK 1.4.2
(`aef00b13…`, the same file as `vendor/libMoltenVK-1.4.2.dylib`) with the release's own kept
beside it as `libMoltenVK.dylib.bak-pre-1.4.2` (`02adfe96…`, identical to the release). That swap
is the launcher's own `Renderer.upgradeCoopMoltenVK`, which Play on the default Metal renderer
(DXVK) applies to whichever wine-coop it finds, so a fresh download becomes the same tree on its
first Play.

`X87Sidecar.patchedWine()` looks in the remembered "FFXI on Mac" folder first, then the places it
was installed by hand before b60 (`/Volumes/Games/FFXI/wine-coop`, Application Support's
`ffxi-runtime/wine-coop`, and two x10 paths), so existing installs keep the copy they have.

## `--play` works again, with one condition

`--play` had done nothing since it was written, and the reason turned out to be two separate
things:

1. It failed silently. Every failure path in `play()` set `notice`, which is `@State` read back in
   the same synchronous scope — so it still read empty and nothing was logged. Those paths now log
   to the run log as well, and `Runner.tee` mirrors the log to stderr for `--check`/`--play`.
2. **It must be started through `open`, not by running the binary.** Launched straight from a
   shell, the client comes up with no window driver at all:

       err:macdrv:macdrv_init Failed to start Cocoa app main loop
       err:winediag:nodrv_CreateWindow The explorer process failed to start.

   That is the "no window, no log" symptom recorded against `--play` for weeks. Use:

       open -a /Applications/FFXI-on-Mac.app --args --world HorizonXI --play

   Verified 2026-08-21: logs in, draws, and stays up.
