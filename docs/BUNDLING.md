# Bundling — the blocker is smaller than it looked

Written 2026-08-11. The then-current `HANDOFF.md` §5 (now `archive/docs-2026-08/`) recorded bundling
as blocked because "the wrapper in use (`siku.app`) is CrossOver-derived (`moltenvkcx/`,
`wine.cx32bak/`, `prefixcx24/`)". Those three directories are real, but they are **leftovers, not
the engine in use**. The wine that actually runs the game is not CrossOver's.

## What is actually running

```
$ siku.app/Contents/SharedSupport/wine/bin/wine --version
wine-10.0 (Sikarugir)
$ cat siku.app/Contents/SharedSupport/wine/version
wine sikarugir 10.0 (revision 6)
```

[Sikarugir](https://github.com/Sikarugir-App/Sikarugir) is an open-source Wineskin fork; its
wine is wine, under LGPL 2.1. `ntdll.so` in it carries upstream wine's new-WoW64 strings
(`starting %s in experimental wow64 mode`), so this is an upstream-lineage build, not
CodeWeavers' `wine32on64`.

MoltenVK is the stock Khronos build, and it is the one that gets loaded:

```
$ md5 -q Contents/Frameworks/libMoltenVK.dylib          e73daec1…
$ md5 -q Contents/SharedSupport/wine/lib/libMoltenVK.dylib   e73daec1…   (same)
$ md5 -q Contents/Frameworks/moltenvkcx/libMoltenVK.dylib    8adbfb16…   (different, unused)
[mvk-info] MoltenVK version 1.4.1
```

So the live stack is:

| component | licence | redistributable |
| --- | --- | --- |
| Sikarugir wine 10.0 | LGPL 2.1 | yes, with the LGPL's source/relink obligations |
| MoltenVK 1.4.1 | Apache 2.0 | yes |
| DXVK 1.10.3 + our patches | zlib | yes |
| d3d8to9 | BSD 3-Clause | yes |
| Ashita v4 + HorizonXI plugins | GPLv3 / HorizonXI's own terms | user installs from HorizonXI |
| FFXI game data | Square Enix | never — user supplies |

**Nothing in the graphics path needs CodeWeavers' build.** The CrossOver-derived directories are
dead weight and can simply be excluded from any package — and deleted from a working install,
which also reclaims about 845 MB:

```
Contents/Frameworks/moltenvkcx        5.9M
Contents/SharedSupport/wine.cx32bak   523M
Contents/SharedSupport/prefixcx24     316M
```

## Why upstream WineHQ was not the answer, and Sikarugir is

The previous session extracted WineHQ 11.0, got the game rendering under it, and measured
**4.7 fps against 25.0** on this wrapper, then recorded the gap as the top open question.

The gap is consistent with what `docs/PERFORMANCE.md` measured this session: the frame is
dominated by ~265,000 D3D9 API calls per second crossing the wrapper chain, so the cost of a
single API call crossing dominates everything else. A wine build with a slower 32-bit/64-bit
transition pays that cost 265,000 times a second and loses by a large multiple — which is what
5× looks like. It is not a rendering difference.

That makes the practical answer straightforward: **ship the engine that is already known to be
fast on this workload and is already redistributable.** Sikarugir publishes its wrapper and
engines; the launcher's first-run step should fetch a pinned Sikarugir engine rather than asking
the user for CrossOver, and rather than shipping a wine that is 5× slower.

## What the package should contain

- `FFXI-on-Mac.app` — the launcher, with the account fields it already has
- our `d3d9.dll` (patched DXVK) and `d3d8to9.dll`, inside the bundle
- a first-run step that downloads and verifies a pinned Sikarugir engine
- a first-run step that points at, or runs, HorizonXI's own client installer for the game data

The game data (~27 GB, Square Enix's) is never redistributed, and never will be. That is the one
part the user must bring, exactly as they do on Windows.

## LGPL obligations, if the engine ships inside the DMG

Fetching at first run keeps this simple, but if a build ever ships wine inside the package:
carry the LGPL 2.1 text, state which wine it is and where its source is, and keep the engine a
separate, replaceable directory so a user can substitute their own build. All three are already
true of the Sikarugir layout.
