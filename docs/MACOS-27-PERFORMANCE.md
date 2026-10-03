# macOS 27.0.1: Wine update and slow gameplay investigation

2026-10-02, M1 MacBook Pro (8 GB), macOS 27.0.1 (26A434). This is a current-state note,
not a new frame-rate claim.

## Confirmed Wine launch issue

The active `prefix10/.update-timestamp` contains `1787146421\r\n`, matching the patched
Wine's `share/wine/wine.inf` mtime. The launcher's stale check split on space and LF only;
`Int("1787146421\r")` failed, so it ran `wineboot -u` on every launch. Wine displayed its
configuration progress window in front of the game.

The game also used two Wine builds on the same prefix. Renderer and PlayOnline registry edits
ran the wrapper Wine (`wine.inf` mtime 1775860812), then Play used the patched cooperative Wine
(`wine.inf` mtime 1787146421). Each build could mark the prefix stale for the other. The fix
splits on all whitespace, uses the same Wine build for registry edits and Play, and hides only
the updater's own Wine app when a real one-time prefix update is needed. A genuine prefix update
now holds the shared maintenance lock and disables Play until it finishes, so the client cannot
start while Wine is rewriting the prefix. Build verification is
complete; a cold launch after the current game session ends must confirm no update window.

With the client idle on 2026-10-02, a read-only `reg query` through the patched Wine and active
prefix exited 0, found PlayOnline's `0001` value, and left `.update-timestamp` at
`1787146421\r\n` (the patched `wine.inf` mtime). This checks the Wine/prefix pairing; it does
not exercise the renderer or registry writes, the launcher UI, or actual gameplay.

## Performance evidence and limits

- The running game log shows DXVK 1.10.3+ through MoltenVK 1.4.2 on the Apple M1 GPU.
- The launched environment has msync, fast math, command pooling, the exact readback fence,
  the 60 fps divisor, and `ROSETTA_X87_PATH` enabled.
- The client used roughly one CPU core. Lower texture/resolution settings previously failed to
  improve the CPU-bound scenes (`SETTINGS-SWEEP.md`), which is consistent with the report but
  does not establish the new frame rate or prove a Metal regression.
- The bundled August x87 helper predates `--probe`. Upstream `athei/x87sidecar` at
  `4048fcf436876f26c799ba2fa340ec73f4cca95e` built locally and its read-only `--probe`
  reported the macOS 27 Rosetta runtime **supported**. That does not prove the older bundled
  helper attached to the live HorizonXI client. Do not replace the shipping helper without a
  local-world A/B test and real play-session check.
- Upstream's current cooperative smoke test explicitly checks only correct execution, not x87
  JIT acceleration. The project's own August measurement found 2.98 fps with a failed cooperative
  hook versus 58.02 fps with stock Rosetta in the same rules scene. On macOS 27 the launcher now
  defaults to stock Rosetta; `FFXI_ON_MAC_X87=1` is an explicit experimental override for a
  controlled local-world A/B test. This is a precaution based on the measured failure mode, not
  a new gameplay FPS result.

### Offline x87 check on this Mac

With no game client or local server running, `scripts/tools/cpubench.c` was compiled as a 32-bit
Windows console program using `i686-w64-mingw32-gcc -O2 -mfpmath=387` and run once per setting
through the patched Wine on the active, already-current prefix. Its `--stdout` option avoids
writing the result into the playable prefix. The three runs used the same Wine build and source;
only `ROSETTA_X87_PATH` changed. `ROSETTA_DISABLE_AOT` was not set by the shell.

| 2026-10-02 setting | x87/long | double (also x87 with this compiler flag) |
| --- | ---: | ---: |
| Stock Rosetta | 4.262 s | 5.299 s |
| Bundled `x87sidecar-coop` | 0.352 s | 0.125 s |
| Fresh upstream `x87sidecar` | 0.360 s | 0.195 s |

All exited 0; the prefix timestamp remained `1787146421\r\n`. The bundled helper therefore
accelerates a direct 32-bit Wine process on macOS 27. This does **not** show that Ashita's child
`horizon-loader.exe` receives the hook or that in-world FPS improves. The one-run numbers do not
support replacing the bundled helper with upstream yet. Keep stock Rosetta as the launcher default
until the local-world A/B and normal play check establish which path is faster and visually sound.

Apple's [macOS 27 release notes](https://developer.apple.com/documentation/macos-release-notes/macos-27-release-notes)
call for reassessing Rosetta compatibility after upgrading, but do not establish that Metal
rendering regressed here. Upstream's [x87sidecar compatibility notes](https://github.com/athei/x87sidecar#compatibility-and-correctness)
document `--probe` and macOS 27 support.

## Next verification when the game is idle

1. If logged in, type `/shutdown` in game chat and wait for the client to exit. Do not kill it.
2. Install the signed local beta, keeping the previous playable app archived in Downloads.
3. Cold-launch once and confirm no Wine update window. Confirm the prefix timestamp stays at
   the patched Wine's `wine.inf` mtime after renderer/registry setup and Play.
4. Use only local LandSandBoat for a short, manual DXVK FPS-log comparison at the same scene
   with stock Rosetta and the current/newly built x87 helpers. Do not run addon tests on hosted
   servers. Restore the faster proven setting only after a visually clean normal play session.
5. Keep the public v3.9 release unchanged until the stability gates in
   `RELEASE-WHEN-STABLE.md` pass; no low-settings result should be called a performance win.
