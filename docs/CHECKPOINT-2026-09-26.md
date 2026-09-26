# Checkpoint 2026-09-26: movement stutter fixed (merge into docs/NEXT.md when Drive responds)

- Hosted stutter causes: LSB stack running alongside (8 GB swap), old CrossOver MoltenVK on macOS 27, DXVK 1.10.3 synchronous shader compiles.
- Fix 1: stop LSB while playing hosted.
- Fix 2: MoltenVK 1.4.2 in ffxi-runtime/wine-coop/wine/lib/external/libMoltenVK.dylib (backup .bak-metal4-2026-09-25). Hosted post-warmup: avg 49.1 fps, 85% >=30.
- Fix 3: DXVK 3.1.1 d3d9.dll (sha256 265888c3...97fa) shipped inside the app under the old filename dxvk-1.10.3-x32-d3d9-horizonxi.dll, because the launcher reinstalls it on every Play. Vendored in Drive repo as vendor/dxvk-3.1.1-x32-d3d9.dll. Daniel: "running way better".
- Before a public release: rename dll + renderer label to 3.1.1 in Renderer.swift/bundle.sh; install MoltenVK 1.4.2 during runtime setup; one timed movement run on LSB.
- Play at 1280x720 on the 1440x900 Retina screen.

## Correction (14:10)
- DXVK 3.1.1 never ran: MoltenVK lacks geometryShader, DXVK 2.x/3.x find "No adapters" and the client terminates. Archived under archive/not-working/.
- Beta 46 = MoltenVK 1.4.2 (bundled, auto-installed into the launch wine) + patched DXVK 1.10.3. Narration off by default via perf.settings.
- LSB benchmark at 14:06 was invalid: swap 5.3/6.4 GB, disk 2.3 GB free, game RSS 86 MB, 0.4 fps at 1,500 draws. Reboot, then benchmark with only the game and LSB open.
- Security TODO: the loader command line carries the account password (visible in ps).
- Local benchmark addon: addons/benchrun (/benchrun <secs> runs a circle via autorun). LSB only.

## LSB vetting run (14:20, beta 46, 1280x720, drawdistance world/mob 10, camera distance 30)
| Scene | avg | min | max | >=30 | draws |
|---|---|---|---|---|---|
| Standing, N. San d'Oria (settled) | 23 | 22.6 | 23.4 | 0% | 2,631 |
| Standing, first 60 s incl. warmup | 8.9 | 0.1 | 23.1 | 0% | 2,331 |
| Running circle (/benchrun 120) | 5.0 | 0.1 | 23.4 | 0% | 2,422 |
- Running pattern: ~70 s at 0-2 fps, then a steady 16, then stalls again. Internal disk was doing 4,000 IO/s at 155 MB/s (swap) and swap grew to 4.6 of 6.1 GB. Game RSS 114 MB. The run was bound by paging, not the renderer.
- Background CPU during the run: fileproviderd 92% (after iCloud eviction), contactsd 50%, hybridsearchd 43%, xi_map 30% (1 GB RSS).
- The 39 fps baseline (09-25) used default draw distance (~1,500 draws). Max draw distance adds ~75% draws, so it is CPU/draw-bound near 23 fps even without swap.
- Next: reboot to clear swap, then the same three rows at default and at max draw distance. If running stays paging-bound, host LSB off this 8 GB Mac (e.g. the Oracle box) so only the client runs locally.

## Spin/turn stalls: DXVK state cache was never written (14:35)
- No horizon-loader.dxvk-cache existed anywhere, so every session recompiled all pipelines; turning the camera = compile stalls.
- Fix: DXVK_STATE_CACHE_PATH=C:\dxvk-cache (launcher default in Settings.swift; Renderer.installDXVK creates the dir). Already set for Daniel via perf.settings extraEnv.
- Back-to-back 60 s running laps, max draw distance: lap 1 avg 7.5, lap 2 avg 13.2 (cache 28 KB -> 55 KB). Swap was 5.1 GB throughout, so the absolute numbers are still paging-bound.
- Source compiles; not yet bundled (game was running). Build as beta 47 next.

## HorizonXI hosted retest (15:20-15:45) and the macOS background-load finding
- Steady view: 56-58 fps at ~1,100-1,450 draws. Spinning the camera / crowds: frequent 1-5 fps seconds.
- GPU never idle-waits (gpuidle 0, no syncs). x10 (game data) near idle during hitches.
- Hitches line up 1:1 with the internal SSD doing 100-1,250 MB/s and ~3,000 pageins/s. Busiest processes then: mobileassetd, modelcatalogd, ANECompilerService, assistant_service (Apple Intelligence model install; /System/Library/AssetsV2 = 13 GB), plus suggestd, backupd, Google Drive.
- Stopping suggestd + one Time Machine run: 23 -> 54 fps avg over 45 s. Crowds still drop to ~3 fps while the model install runs.
- Plan: let Apple Intelligence finish (or turn it off), reboot, retest hosted with the camera spin + a crowd.
- Known limitation: the account password reaches horizon-loader.exe as `--pass` on the command line (visible in `ps`) and sits in config/boot/*.ini. The loader only accepts it as an argument, so the fix needs loader support (stdin or an env var); not a launcher-only change.
