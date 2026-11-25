# Beta 103 — current update offers and visible screenshot controls

An update that reached **Restart** previously stopped participating in all scheduled and
activation checks. If GitHub later withdrew or replaced it, the old line stayed on screen
until the player pressed Restart. The final install check already refused obsolete releases,
but the visible suggestion could remain stale for days.

Ready and failed-Restart offers now use the existing six-hour / one-hour-on-activation schedule
to check release metadata. The matching verified release keeps its current state without
repeating a download, mount or signature check. An authoritative withdrawal clears the line;
a replacement goes through normal staging and verification before it is offered. Offline,
rate-limit and server failures preserve the last verified offer silently.

The metadata response is tied to the exact offered release. If Restart has started, the offer
has already cleared, or a replacement is being shown, the old response cannot change state or
prune staging files. Final Restart verification and active-client/job/embedded-guide guards
remain in place. No new timer, automatic restart or GUI launch is added.

Dependency releases were checked before this source change; see the October 29 continuation in
[DEPENDENCIES-2026-10-27.md](DEPENDENCIES-2026-10-27.md). Runtime pins remain unchanged.

## Screenshot mode

**Screen Reading…** is available in the companion's ordinary UI, without a command-line flag.
The tabs occupy their own row so the controls fit the existing 620 × 460 minimum window.
Capture still starts only after explicit window selection and **Start Reading**; **Find Game
Window** is the only normal UI action that may request Screen Recording permission. Merely
opening the guide also leaves the OCR recognizer unloaded, even if screenshot mode was used
previously. The ten-second sampling, two-sample matching and local-only processing remain as
documented in [SERVER-SAFE-GUIDE.md](SERVER-SAFE-GUIDE.md). Making the controls available does
not establish any server's approval of screen tools.

## Validation

| Check | Result |
| --- | --- |
| Native release launcher / companion build | Passed |
| Updater offline suite | 116/116, including ten new offer-refresh checks |
| Companion parser/catalogue/achievement suite | 121/121, including initial capture inactivity |
| Primary action | 94/94 |
| Server catalogue | 19/19 |
| Hidden layout | All six scenarios at 620 × 460 and 1000 × 720, followed by shrink checks, passed |
| Compact guide render | Inspected; Screen Reading button visible, tabs and content fit |

Tests used explicit Downloads state/temp directories and the recovered guide library. The
current toolchain's `--show-bin-path` resolves `launcher-build/arm64-apple-macosx/release`;
the older `out/Products/Release` binaries in this workspace are historical. An initial run
against the latter was recognized from the rendered old header and superseded by the results
above, which include the new test names. All API fixtures are synthetic. No screen capture,
game input, application replacement or release publication is performed by these checks.

Signed build-103 launcher and standalone-guide candidates were then packaged in the recovered
Downloads workspace, from clean source commit `4085ec9` and explicit current guide/voice addon
roots. Both passed deep strict signature verification. Packaged updater (116), companion
parser/catalogue (121) and bundled-addon-source checks passed. Neither candidate was installed
or launched as a GUI; the installed playable bundle and running companion were preserved.

## Continuing the larger launcher goal

This beta is a source fix and local candidate, not a stable public binary release. Current
server integration gaps remain those documented in [LSB-SERVERS.md](LSB-SERVERS.md), including
Phoenix/Titan custom authentication and client handling, and the survey's unverified worlds.
Catalogue/parser tests are not successful game logins. Actual local gameplay, navigation,
narration and controlled Mac frame-time comparisons remain separate acceptance evidence.

Copyright © 2026 Bates LLC / Daniel Bates. All rights reserved.
[batesai.org](https://batesai.org) · help@batesai.org.
