# Recovered beta verification — October 29, 2026

Recovered phoenix-population source into Downloads/ffxi-recovery-20261029/launcher without overwriting the Google Drive checkout or installed playable app. Release launcher and companion compilation passed on macOS27.2. This is beta verification, not a public release or complete gameplay acceptance.

| Check | Result |
| --- | --- |
| Recovered launcher updater | All passed |
| Server catalogue | 19/19 |
| Primary action | 94/94 |
| News | 40/40 |
| Addon policy | All passed |
| RetroAchievements fake transport/disposable Keychain | 63/63 |
| Companion parser/catalogue against recovered guide library | 120/120 |
| Updater embedded-companion protection fixtures | 8/8 |
| Packaged launcher updater/catalogue/addon-source | All passed |
| Launcher and standalone guide deep strict signatures | Passed |

Candidates under the recovered Downloads workspace: candidate-launcher/FFXI-on-Mac.app (build101), candidate-guide/VanaGuide Server-Safe.app (build101), candidate-voice/VanaVoice.app (1.5.3). None was installed or launched as a GUI. Existing Swift Sendable/deprecation and debug-module path warnings remain; compiles succeeded.

Guide source includes PR26 diagonal sidestep geometry and PR27 blocked-corner smoothing fixes. Voice source includes PR12 cancellation ownership and PR13 complete pending-dialogue retention. Each remains an unmerged source PR. Packaging the launcher copies the voice addon; the separate VanaVoice candidate contains the native narration changes.

## Remaining acceptance

A hosted launch remained present, so no local game commands, hosted addon tests or runtime replacement occurred. Strict unassisted sequential quest acceptance, visual navigation, actual modest-volume narration, audible cancellation/Pause and current Mac performance A/B measurements remain unverified. Phoenix/Titan integration and other survey gaps remain open. RA tests use fake responses; live API refresh and routes for every achievement remain unverified. Screenshot timing exists at ten seconds; server policy approval cannot be inferred from a successful offline test.

Install candidates only after launcher/game/runtime exit normally. Preserve the playable bundle and archive replacements. No watcher, repeated GUI launch, test loop or public release was added.
