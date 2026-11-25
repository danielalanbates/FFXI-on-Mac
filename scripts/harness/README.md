# Benchmark harness

The point of this directory is that a frame-rate claim in this project should be reproducible by
running one command, not by squinting at an overlay. Every number in `docs/PERFORMANCE.md` and
`docs/SETTINGS-SWEEP.md` came out of `bench.py`.

These scripts drive Daniel's install directly (paths are hard-coded at the top of `bench.py`);
they are checked in as a record of how the measurements were taken and as a starting point, not
as a general-purpose tool.

## bench.py

```sh
./bench.py --tag baseline                       # character select, default settings
./bench.py --tag div1 --env FFXI_FPS_DIVISOR=1  # one environment override
./bench.py --tag low --profile profiles/s-all-low.json
./bench.py --tag light --enters 0               # stop at the rules screen instead
```

It kills stale clients, applies the variant, launches the game, presses Return until the draw
count says the heavy scene has been reached, samples for `--sample` seconds, screenshots the game
window in the background (`screencapture -l <window>`, which works even when the window is
occluded), kills the client and writes `results/<tag>.json`.

A variant is a JSON profile with any of: `env`, `registry` (FFXI's own settings, applied through
Ashita's `[ffxi.registry]` block), `dxvk_conf`, `dlls`, `renderer`, `addons`.

Frame rate comes from `DXVK_FPS_LOG`, which our `d3d9.dll` writes. It also reports per-frame
draws, render passes, barriers and queue submits, so a change that helps the frame rate can be
told apart from one that just changes the scene.

**Scene choice.** Character select: ~1841 draws, deterministic, reachable with two keypresses,
and no character is in the world, so killing the client afterwards is safe. The rules-of-conduct
screen (`--enters 0`) is the light-scene equivalent at ~380 draws.

## fpsvideo.py

Frame rate for pathways that do not use our DXVK — counts visually distinct frames in a screen
recording with ffmpeg's `mpdecimate`. Cross-check it against `DXVK_FPS_LOG` on a DXVK run before
trusting it: it under-reports on a scene that is genuinely static.

## renderer.sh

Swaps the wrapper's wine D3D translation DLLs between wine's own builtins, DXMT (native Metal)
and DXVK's d3d11. Run `./renderer.sh save` once before the first switch and `restore` after.

## install-d3d9.sh

Copies a built `d3d9.dll` to all five paths the game can load it from. Missing one silently
tests the old build. The paths are the old siku.app prefix's, and they are hard-coded.

## cursorprobe.c

Tests whether a `d3d9.dll` leaves the game's own Win32 cursor alone across
`IDirect3DDevice9::ShowCursor`. That is the DXVK 1.10.3 bug that hid FFXI's Hardware Mouse; see
`docs/CURSOR-DXVK.md`.

- The stock vendor DLL should FAIL and a DLL rebuilt with the backport should PASS.
- The build and run commands are in its header. Run it in a throwaway prefix only, never while a
  game runs.

## addons/fpslog

An Ashita Lua addon that logs frame rate, zone and rendered-entity count to CSV — renderer
agnostic, so it measures pathways that have no DXVK in them. **It does not currently load**:
Ashita.dll in this install is interface 4.16 and every bundled plugin, including the `Addons`
Lua host, is 4.15, so the plugin manager rejects them all. Kept for when that is fixed.
