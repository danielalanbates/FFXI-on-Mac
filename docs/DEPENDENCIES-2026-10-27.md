# Dependency review — 2026-10-27

This review precedes structural work on beta 82. It changes no runtime pins, Wine prefixes,
installed apps, macOS settings, or game files. The existing hosted game session must remain
playable. No hosted server was used for addon, bot, or dependency testing.

## Preserved baseline

| Component | Evidence and retained setting |
| --- | --- |
| macOS | Read-only `sw_vers`: 27.0.1, build 26A434, Apple silicon. |
| Rosetta | `pkgutil --pkg-info com.apple.pkg.RosettaUpdateAuto` finds an installed receipt. Receipt presence alone is not a runtime correctness test. |
| Game Wine | `scripts/game-wine.sh` pins athei/wine-build `cx-26.3.0-1`; archive SHA-256 `ec2a9e4d438917a26e381c01367773df79c3b0d6f0504b8183464619cad7e661`. Existing installed Wine is retained. |
| x87 acceleration | Existing bundled `x87sidecar-coop`, `ROSETTA_X87_PATH` and the existing attachment/failure guard. The bundled binary is not silently replaced with a newer upstream build. |
| Rendering | Existing DXVK 1.10.3+ and MoltenVK 1.4.2 path, including project-specific readback/cursor fixes. |
| NX compatibility | Existing `WINE_DISABLE_NX_COMPAT=1`, whose rationale is documented in [beta 66](BETA-66.md). |

[WINE-BUILD.md](WINE-BUILD.md) records the pin and its comparison against the playable tree.
[MACOS-27-PERFORMANCE.md](MACOS-27-PERFORMANCE.md) includes later corrections to older x87
conclusions. Its isolated x87 timings and historical world FPS must not be described as a
current controlled benchmark or evidence that the machine has reached its highest possible
performance. This review did not execute Wine or launch a game.

## Upstream releases checked

| Upstream | Current finding | Implication for this project |
| --- | --- | --- |
| [WineHQ](https://www.winehq.org/?page=documentation) | Stable Wine 11.0; development 11.20, released October 16. The primary site returned 403 to direct retrieval; its current indexed primary page supplied the version/date. | Generic Wine is not a drop-in substitute for the cooperative, game-tested build. NTSYNC is a Linux feature, not a Mac performance claim. |
| [CodeWeavers stable changelog](https://www.codeweavers.com/crossover/changelog) | CrossOver 26.3.0, July 21. CrossOver 26 uses Wine 11.0, D3DMetal 3.0 and DXMT 0.72. | No cited release note establishes an FFXI-specific fix or speedup. |
| [athei cx-26.3.0-9](https://github.com/athei/mach9/releases/tag/cx-26.3.0-9) | October 13; newer x86 Wine branch. Minimum macOS 15; revised per-process compatibility configuration. The former `athei/wine-build` repository now redirects to `athei/mach9`. | A smaller candidate migration than changing CPU architecture, but it still needs isolated-prefix testing of x87 attachment, NX behavior, login, rendering and audio. Preserve the current pinned download URL/digest until that succeeds. |
| [Mach9 arm64-11.20-4](https://github.com/athei/mach9/releases/tag/arm64-11.20-4) | October 27; current ARM64 bundle based on Wine 11.20, FEX, Mesa, DXMT and vkd3d-proton. | New architecture candidate. Its presence is not evidence of FFXI compatibility. See the migration path below. |
| [x87sidecar 1.9.0](https://github.com/athei/x87sidecar/releases/tag/v1.9.0) | October 13; native 80-bit register storage and correctness/crash fixes. | This remains a Rosetta cooperative path. Upstream microbenchmarks on another Mac do not establish FFXI gains here. Test the matching Wine/sidecar combination as a unit. |
| [mtld3d 0.15.1](https://github.com/athei/mtld3d/releases/tag/v0.15.1) | October 26; D3D9 correctness fixes, including occlusion queries, sRGB writes and fixed-function rendering. | A Metal rendering candidate; the project's D3D8 proxy, readback, fonts, cursor and cutscene paths still need validation. |
| [Apple Game Porting Toolkit](https://developer.apple.com/games/game-porting-toolkit/) | GPTK 4, with Metal 4 evaluation and profiling tools. | Useful for a separate profiling lab. It does not establish a direct replacement for the project's D3D8-to-D3D9 path. |
| [Apple macOS 27.2 release notes](https://developer.apple.com/documentation/macos-release-notes/macos-27_2-release-notes) | Apple lists macOS 27.2 build 26B123 on October 26. The retrieved developer notes do not establish a specific FFXI or Rosetta performance fix. | Review compatibility before a future user-managed OS update; do not upgrade the active playable machine unattended. |

Apple's [September Rosetta notice](https://developer.apple.com/news/?id=w5ngl9k2) says general
Intel-app support lasts through macOS 27 and a narrower legacy-game subset remains afterward.
Do not assume this launcher's x86 Wine runtime qualifies for that exception. Rosetta is managed
as part of macOS; the receipt version is not a separate upstream release to install manually.

## ARM64/FEX migration pathway

The current [Mach9 architecture](https://github.com/athei/mach9) runs ARM64 Wine without
Rosetta and uses FEX to execute Windows x86 code. D3D9 defaults to mtld3d; newer graphics APIs
use other bundled backends. Its `WINE_COMPATDB` format and Rust writer API changed recently.
This is a candidate for reducing reliance on Rosetta, not a demonstrated performance result
for FFXI.

- Keep it in a separate Downloads lab and separate Wine prefix, with separately pinned
  archive digest, release tag and configuration. Never point its first run at the playable
  prefix or replace the existing `wine-coop` tree.
- Do not carry over `ROSETTA_X87_PATH`, `ROSETTA_DISABLE_AOT`, the cooperative sidecar, or
  Rosetta attachment probes. Those belong to the x86/Rosetta architecture. FEX has its own x87
  implementation, precision settings and compatibility requirements.
- Validate the launcher/injector and FFXI DLLs as well as the main loader. Existing DXVK and
  readback patches cannot be assumed to apply to mtld3d. Check startup, login, zones, text,
  cursor, effects, audio/cutscenes and orderly `/shutdown` on the user's own local LSB server.
- Run a single client at a time. The upstream release notes warn that server protocols changed
  between ARM64 releases; do not solve this by killing any active playable wineserver. Use an
  isolated prefix and wait until the relevant test session has exited normally.
- Compare the same local-world scene, character, resolution, camera and settings. Record
  median and tail frame times, CPU/kernel load, memory pressure, input and visual correctness.
  Keep competing workload observations in the report; never close other apps to manufacture
  an idle benchmark.
- Retain a fallback to the measured x86 stack until the candidate passes gameplay validation.
  Replacing an architecture and changing renderer simultaneously makes attribution difficult;
  retain separate results for each supported backend where practical.

## Release decision

Continue shipping the preserved runtime pins while source fixes are beta-tested. Publish a
public app release only after a stable play session and local-only addon/guide checks. A
weekly release is a possible cadence, not a timer that publishes an unverified build.

Project: [batesai.org](https://batesai.org) · support: help@batesai.org.

Copyright © 2026 Daniel Alan Bates. All rights reserved, subject to the repository license.

## Continuation check — 2026-10-28

Rechecked the primary [Mach9 releases](https://github.com/athei/mach9/releases),
[x87sidecar releases](https://github.com/athei/x87sidecar/releases) and
[mtld3d releases](https://github.com/athei/mtld3d/releases). They still list
`arm64-11.20-4`, `v1.9.0` and `v0.15.1`, respectively, matching this review.
The machine still reports macOS 27.0.1. No runtime or OS update was installed.

## Continuation check — 2026-10-29

Before the beta 103 updater change, primary release pages were checked again. They still
list [Wine 11.0 stable / 11.20 development](https://www.winehq.org/news/announce.php),
[CrossOver 26.3.0](https://www.codeweavers.com/crossover/changelog),
[Mach9 arm64-11.20-4 and cx-26.3.0-9](https://github.com/athei/mach9/releases),
[x87sidecar v1.9.0](https://github.com/athei/x87sidecar/releases),
[mtld3d v0.15.1](https://github.com/athei/mtld3d/releases), and
[MoltenVK v1.4.2](https://github.com/KhronosGroup/MoltenVK/releases).
Direct WineHQ retrieval returned 403; its indexed primary news and official
[Wine-Announce release](https://list.winehq.org/hyperkitty/list/wine-announce%40list.winehq.org/thread/BXK6IO4YFZW4O5CABDN5SOOFY3ZYTJP3/)
confirm development 11.20 on October 16.

Read-only local inspection now reports macOS 27.2 build 26B123 and a Rosetta receipt version
1.0.0.0.1792711153. This is an inventory correction to the October 28 paragraph, not an OS
update performed by this work. Receipt presence does not establish FFXI compatibility or
performance. The preserved Wine, DXVK, MoltenVK and sidecar pins stay unchanged; candidate
runtime migration still requires the isolated gameplay and performance checks above.
