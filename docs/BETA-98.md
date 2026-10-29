# Beta 98 — VanaGuide resize verification

Copyright © 2026 Daniel Bates / Bates LLC. All rights reserved.
[batesai.org](https://batesai.org) · help@batesai.org

The installed guide was build 96 while build 97 source already removed the fixed-size root
and enabled content-minimum window resizing. Beta 98 retains that change and adds a bounded,
hidden verifier so it can be checked while the owner plays.

| Check | Result |
| --- | --- |
| Release compilation, companion | Passed |
| Hidden production-view layout, five tabs | Passed at 620 × 460 and 1000 × 720, and shrinking back |
| Synthetic guide previews | Visually inspected compact and expanded; text wraps and panel grows |
| Parser/catalogue with current local guide source | 110 checks passed |
| Installed b96 updater rules | Passed; this is an offline rule test, not a release download/restart |
| Installed b96 performance rules | Passed; this does not establish maximum FPS |
| Updated launcher release compilation | Passed |
| Companion selection fixtures | Seven passed, including replacement at the same path |
| Updated launcher guide-disabled, updater and UI-text suites | Passed |
| Packaged launcher deep signature and companion selection suite | Passed |

Run `VanaguideCompanion --selftest-layout [--layout-output <directory>]` for the new check.
It creates hidden windows only, uses a synthetic guide/character, disables the normal
on-appear loading and periodic refresh, and exits. Normal app startup and the single-instance
guard are retained. No screen permissions, hosted server connection or game input are used.
Preview files and raw test logs belong in Downloads, outside Git.

## Dependency check before changes

The current machine reports macOS **27.2 (26B123)**, rather than the 27.0.1 baseline in the
previous review, and has a Rosetta installation receipt. `softwareupdate --list` reports no
new software. No OS or runtime update was installed during this pass.

Primary release pages still list [Mach9 arm64-11.20-4](https://github.com/athei/mach9/releases),
[x87sidecar 1.9.0](https://github.com/athei/x87sidecar/releases),
[mtld3d 0.15.1](https://github.com/athei/mtld3d/releases), and
[CrossOver 26.3.0](https://www.codeweavers.com/crossover/changelog).
These match the candidates already recorded in [the dependency review](DEPENDENCIES-2026-10-27.md).
The playable Wine/renderer/sidecar pins remain in place. Any performance claim on 27.2 needs
fresh controlled local-world measurements. The rule suite observed high swap use, which can
affect smoothness; no unrelated app was closed or system setting changed.

## Installation and remaining work

Installed `/Applications/VanaGuide Server-Safe.app` **3.10 build 98**, signed with the same
Developer ID certificate as build 96. The existing embedded guide accepted a normal quit;
the standalone copy was installed, its predecessor archived in Downloads, and it was reopened
once in the background. The installed copy passes strict deep signature and hidden layout
verification. Process inventory confirms exactly one guide, running from the standalone path.

The launcher and a game client remain running. The launcher's binary SHA-256 is unchanged,
and the same client PID remains present; no game commands or hosted addon tests were sent.
The launcher update remains pending until its game/runtime and launcher have exited normally.
Never kill a logged-in client; use `/shutdown` if logout becomes necessary.

A signed launcher candidate is ready at
`~/Downloads/ffxi-guide-resize-build/candidate-launcher/FFXI-on-Mac.app`, with its matching
nested build 98 guide. Its recorded source revision is `05f2fe4`; it passed strict deep
signature verification and the packaged companion-selection suite. This is a local beta
candidate, not a notarized public release. No automatic installer or relaunch watcher was left.

The build 96 launcher prefers its embedded copy when no guide is already running. Keep the
standalone guide open, or open it directly from Applications, until the launcher is updated
after play. Replacing or re-signing its embedded bundle during play is unsafe.

The updated launcher source selects the newest compatible embedded/standalone guide by
version and build, keeping embedded priority only on a tie. It checks the app identity,
executable and minimum macOS version, and reads the plist directly so a standalone replacement
is not hidden by cached bundle metadata. `--selftest-guide-companion` checks these decisions
using disposable app fixtures; it never opens them. A running guide is still reused without
opening another instance. This launcher change remains pending installation after play.

Source publication is separate from a stable public binary release. Keep the public release
gates in [RELEASE-WHEN-STABLE.md](../RELEASE-WHEN-STABLE.md).
The live local test records distinguish teleport regression from walking and narrator sink
delivery from audible output. Real sequential walking, audible cutscene coverage, remaining
server compatibility and guide suggestions still need their own evidence; these layout checks
do not close those requirements.
