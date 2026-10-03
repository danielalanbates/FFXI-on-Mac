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

On 2026-10-03 the newer upstream sidecar built at `4048fcf` reported `supported`
from `--probe` against this Mac's installed Rosetta runtime. The upstream
`wine-cx-26.3.0-7` archive was downloaded and unpacked only in a disposable
Downloads dependency lab; its SHA-256 matched GitHub's release digest
`4009323ede6aa430563d5451c13a735221df0f91c394a7d99c3c3426a0b3454e`.
This is artifact and runtime compatibility evidence, not a successful HorizonXI
launch. Do not copy that Wine over the playable tree on this basis. Daniel has
explicitly withheld permission for independent game FPS testing; any game A/B
comparison must wait for his authorization and be confined to a local world.

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

The launcher now hides its own Wine application on both launch and subsequent
activation during prefix maintenance, because Wine can bring the update window
forward after the process first appears. The release build compiled, and the
local beta passed app notarization, stapling, strict deep code-signature
verification, and Gatekeeper assessment before installation. The previous
notarized app is archived in Downloads. The new installed app opened once with
no Wine process observed five seconds later. A genuinely stale-prefix update
has not been exercised, and no game FPS test was run.

An isolated follow-up tried to create a new Wine prefix in Downloads with the
same patched Wine and a one-shot copy of the launch/activation observer. The
prefix timestamp reached the expected `wine.inf` mtime, but the outer `wineboot
-u` process did not exit within two minutes. The observer received no matching
application notifications and the diagnostic timed out, so this does **not**
validate the hide behavior. Its source is retained under Downloads in
`horizonxi-work/archive-local-test/prefix-window-check-inconclusive.swift`;
the generated prefix was removed after stopping its own wineserver. No FFXI
client or FPS measurement was involved. Do not repeat this test automatically.

Subsequent static inspection found a concrete flaw in the hide predicate:
`playWine` selects `/Volumes/Games/FFXI/wine-coop`, a symlink to the same tree
under `/Volumes/x10/Video Games/Mac/FFXI/wine-coop`. Wine processes report
the latter path. `standardizedFileURL` left the symlink unresolved, so the old
prefix comparison returned false for the actual Wine executable; resolving
symlinks on both sides makes it true. The archived one-shot diagnostic has the
same old predicate and therefore cannot validate the new one. A disposable
`swift -e` comparison verified false before and true after resolution. This
explains why the previous launch-only hide hook could miss Wine, but an actual
stale-prefix window check on the installed app remains pending.
The resolved-path fix compiled in the release build. The replacement local beta
passed app notarization, stapling, strict signature verification and Gatekeeper,
was installed with the prior app archived in Downloads, and launched once with
no Wine process seen after five seconds. The installed executable's SHA-256
matched the notarized beta. None of these checks exercises a genuinely stale
prefix or game performance.

After internal free space recovered, a fresh disposable prefix and three
one-shot stale-prefix updates completed with Wine exit 0 and returned its
`.update-timestamp` to the matching `wine.inf` mtime. No FFXI client was
launched. The corrected NSWorkspace observer matched no Wine app in those
runs. In one of two runs that sampled the frontmost app during maintenance, it
changed for about eight seconds, then returned to the original app; the other
run saw no change. The sampling code did not record the process on the first
change, so this is **not** evidence that Wine came forward or that the hide
hook succeeded. The source for the one-shot check is archived in Downloads as
`horizonxi-work/archive-local-test/prefix-window-check-resolved-inconclusive.swift`.
The generated prefix was removed. Do not rerun this test automatically.
The launcher's startup task now checks the remembered install's prefix before
consuming a queued `--play` request. Previously that command ran first and
the background prefix check waited for the full volume discovery, leaving a
window where Wine could start its own foreground update. This ordering change
compiled in a release build; it has not been exercised with a stale installed
prefix or an actual game launch.
Play also checks staleness while holding its launch lock, before changing
shared client files or spawning Wine. If stale, it refuses that click and
schedules prefix maintenance after releasing the lock; the user can press Play
after maintenance finishes. This closes the manual-click race with startup
maintenance. The release build compiled, but the real stale-prefix UI behavior
is still unverified on the installed app.
The current beta for commit `d57976e` is staged at
`/Users/daniel/Downloads/horizonxi-work/beta-d57976e/FFXI-on-Mac.app`.
Apple accepted notarization submission `7716261e-4629-4a92-a0c3-5b2880890989`;
the app was stapled and passed strict signature and Gatekeeper checks. The
installed launcher was still running, so this beta was **not** copied to
`/Applications/FFXI-on-Mac.app`. When the launcher and all clients have exited
normally, archive the installed app in Downloads and install this beta. The
earlier `beta-0e9a93e` bundle remains in Downloads as a superseded build.

The internal data volume fell to roughly 2.3 GB free during this check, while
swap remained around 6 GB and Google Drive/File Provider plus another game
were active. This is a separate resource-pressure concern for future gameplay
verification, not evidence that Wine or a rendering dependency regressed.
On 2026-10-03, with no FFXI client running and the launcher at 0% CPU, three
short `ps` samples showed `suggestd` near 98-99% CPU, `fileproviderd` at
29-78%, and `corespotlightd` at 25-68%. This is sustained background load
across those samples, but it does not establish which service caused game lag
or whether those processes remain busy during play. Internal free space was
about 10 GB and the external x10 volume about 64 GB (98% used). Check these
processes and memory pressure again during a user-authorized game session
before attributing the regression to Wine or changing system-wide indexing.
A read-only `otool -L` audit of the patched Wine executable, 29 native Wine
modules, and 13 bundled external libraries found no references to absent
Homebrew or external-volume absolute library paths. Apple system libraries
are supplied through the dyld shared cache, so their lack of a visible file
at `/usr/lib` or `/System/Library` is not a missing dependency. This audit
does not cover libraries Wine loads dynamically or prove the renderer works
in-game; it narrows the "broken dependency" hypothesis only for static links.

The last game-session log (2026-10-02) was only about 163 KB, but after login
it contained 1,556 repeated `ConvertFormat: Unknown format encountered: 65`
lines from DXVK and 529 MoltenVK warnings. This is log/UI noise and extra
formatting and file writes; its contribution to frame time is unmeasured. The
launcher now defaults to `DXVK_LOG_LEVEL=error` and `MVK_CONFIG_LOG_LEVEL=1`
for routine play, preserving errors while suppressing those warnings. Both
upstream projects document these controls: [DXVK logging](https://github.com/doitsujin/dxvk/blob/master/README.md#debugging)
and [MoltenVK configuration](https://github.com/KhronosGroup/MoltenVK/blob/main/Docs/MoltenVK_Configuration_Parameters.md#mvk_config_log_level).
An explicit environment setting or the launcher's extra environment lines can
restore more detailed logs when diagnosing a failure. This is a logging change,
not a verified FPS improvement; no game was launched to test it.
The release build compiled, and the updated local beta passed notarization,
stapling, strict signature verification, and Gatekeeper before installation.
The previous app was archived in Downloads. The installed launcher opened once
with no Wine or FFXI client process observed five seconds later; its executable
matched the notarized beta by SHA-256. The quiet logging behavior itself has
not been exercised in a game session.

1. If logged in, type `/shutdown` in game chat and wait for the client to exit. Do not kill it.
2. Install the signed local beta, keeping the previous playable app archived in Downloads.
3. Cold-launch once and confirm no Wine update window. Confirm the prefix timestamp stays at
   the patched Wine's `wine.inf` mtime after renderer/registry setup and Play.
4. Daniel explicitly withheld permission for independent game FPS tests on 2026-10-03. Only
   after he authorizes one, use local LandSandBoat for a short, manual DXVK FPS-log comparison
   at the same scene with stock Rosetta and the current/newly built x87 helpers. Do not run
   addon tests on hosted servers. Restore the faster proven setting only after a visually clean
   normal play session.
5. Keep the public v3.9 release unchanged until the stability gates in
   `RELEASE-WHEN-STABLE.md` pass; no low-settings result should be called a performance win.

The old `scripts/harness/bench.py` and `inworld.py` are historical measurements, not a safe
one-command check for this install: their paths point at `~/Games`, and the harness calls
`kill_all()` on Wine and game processes. Do not run them on Daniel's current wrapper or while
any client is live. The local comparison needs a single controlled launch at a time and a
confirmed `/shutdown` for any logged-in character.
