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

### Dependency review, 2026-10-03

The Mac still has athei's `wine-cx-26.3.0-1` cooperative Wine. Upstream's
[`cx-26.3.0-6`](https://github.com/athei/wine-build/releases/tag/cx-26.3.0-6)
keeps no-execute enabled under Rosetta for 32-bit programs without `NX_COMPAT`,
which upstream says otherwise crawl. The HorizonXI `horizon-loader.exe`, `pol.exe`,
`xiloader.exe`, and `Ashita-cli.exe` inspected here all report `DllCharacteristics
0x8140` with `NX_COMPAT`, so that specific fix is not established as the cause
of this game's slowdown. A module loaded later could differ. Do not replace the
shared playable Wine tree based on this release note alone.

The current [x87sidecar](https://github.com/athei/x87sidecar/releases/tag/v1.7.0)
documents macOS 27 support and cooperative attachment through patched Wine.
Our bundled sidecar accelerated an isolated 32-bit Wine x87 benchmark on 27.0.1,
but that does not show it attached to `horizon-loader.exe`. The older in-world
failed-handshake case was a 19x loss when AOT was disabled, so keep the stock
Rosetta default until one controlled local-world comparison proves the complete
launch path and a normal play session stays visually correct.

[mtld3d 0.11](https://github.com/athei/mtld3d/releases/tag/v0.11.0) is a newer
direct D3D9-to-Metal candidate, but its documented requirements list macOS 15
and 26, and this project's DXVK readback and cursor paths have not been checked
against it. It belongs in a separate local experiment, not in the installed app
or public release yet.

At this check the 8 GB Mac had about 6.7 GB of swap in use, a second game was
using more than one CPU core, and the game volume was 98% full (about 64 GB free).
Those are concurrent resource pressures, not proof of a macOS dependency failure.
Do not compare FPS while that load is present, and do not close the other apps to
manufacture an idle test. Once the Mac is naturally idle, measure the shipped
Play path with its FPS log on a local world at the same scene before and after
any dependency change. Keep addons off hosted worlds.

With no FFXI client running, one background cold launch of the installed,
notarized local beta on 2026-10-03 showed only the launcher process after five
seconds, no `wineboot` or wineserver, and the prefix timestamp still matched
the patched Wine's `wine.inf` mtime (`1787146421`). This checks the idle launch
path without opening a game. It does not verify the Wine window behavior after
a genuinely stale prefix or measure gameplay speed.

1. If logged in, type `/shutdown` in game chat and wait for the client to exit. Do not kill it.
2. Install the signed local beta, keeping the previous playable app archived in Downloads.
3. Cold-launch once and confirm no Wine update window. Confirm the prefix timestamp stays at
   the patched Wine's `wine.inf` mtime after renderer/registry setup and Play.
4. Use only local LandSandBoat for a short, manual DXVK FPS-log comparison at the same scene
   with stock Rosetta and the current/newly built x87 helpers. Do not run addon tests on hosted
   servers. Restore the faster proven setting only after a visually clean normal play session.
5. Keep the public v3.9 release unchanged until the stability gates in
   `RELEASE-WHEN-STABLE.md` pass; no low-settings result should be called a performance win.

The old `scripts/harness/bench.py` and `inworld.py` are historical measurements, not a safe
one-command check for this install: their paths point at `~/Games`, and the harness calls
`kill_all()` on Wine and game processes. Do not run them on Daniel's current wrapper or while
any client is live. The local comparison needs a single controlled launch at a time and a
confirmed `/shutdown` for any logged-in character.
