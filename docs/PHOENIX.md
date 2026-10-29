# Phoenix XI — catalog entry, Mac integration pending

Build 101 adds **Phoenix XI** to the world picker at Daniel's request. This is a catalog entry,
**not playable Mac support**. Its subtitle says “Mac support pending”; the main button says
**Server Info** and opens the official getting-started page. Setup, forwarded Play and the final
client launch path refuse before saving credentials, opening companions or changing game files.
The existing Horizon installation is not reused as a Phoenix client.

## Primary sources checked October 28, 2026

| Source | Finding |
| --- | --- |
| https://phoenix-xi.com/ | Homepage showed 1,110 players online during this inspection. LSB-based, level 75 era. |
| https://phoenix-xi.com/getting-started | Official launcher supports Windows, Linux and Steam Deck; no macOS download. Website account, optional 2FA. |
| https://phoenix-xi.com/approved-addons | Updated October 20. Allowlist covers addons, plugins, third-party programs and standalone tools. Unlisted tools require a ruling; modified versions require their own review. |
| https://phoenix-xi.com/blog/phoenix-launch-update/ | October 5: modern LSB, launcher character autologin and platform diagnostics. |
| https://launcher.phoenix-xi.com/linux/install.sh | Official Linux bootstrap inspected as text only; never executed. |

The earlier October 24 survey identified `play.phoenix-xi.com`, a custom xiloader 2.2.x fork,
account-gated game files, and a short-lived `login_token` supplied with `--json`. That is prior
research, not an authentication contract validated in this change. Do not send a conventional
username/password boot command and call this support.

No account was created, no game client was connected, no hosted addon was tested, and no approval
ticket was sent. The tools list does not list this launcher, VanaGuide or VanaVoice. The launcher
uses an empty conservative allowlist for Phoenix until an exact integration has been reviewed.
A separate screenshot program is not automatically exempt from Phoenix's standalone-tool rules.

## Remaining implementation work

1. Obtain an explicit ruling for this launcher integration and exact companion versions through
   Phoenix's official website ticket process. The owner must authorize sending that request;
   this research does not contact staff on their behalf.
2. Obtain a documented, approved authentication contract or licensed official launcher source.
   Preserve email/2FA/trusted-device behavior; never bypass account-gated downloads or device rules.
3. Implement dedicated Phoenix client manifests, checksums and updates in an isolated data folder.
   Keep its credentials and transient launch tokens separate from all other worlds. Redact tokens
   from logs; do not persist them in boot profiles or publish them in diagnostics.
4. Add offline auth/expiry/2FA/update fixtures and an isolated loader test. Hosted addon/bot tests
   remain prohibited by the workspace's instructions.
5. Only remove the pending guard after a working, permitted native Mac route is demonstrated.
   An official Windows launcher under Wine is a possible alternative, but its WebView/runtime,
   login, updater and custom loader have not been proven on this Mac. Linux AppImage/Flatpak is
   not a macOS executable.

## Verification

`--selftest-server-catalog` exercises pure sorting, migration, persisted Phoenix identity,
non-playable primary actions, addon restrictions and strict public-counter parsing. Existing
`--selftest-primary-action`, `--selftest-news` and addon-policy checks cover adjacent behavior.
These checks do not establish a working Phoenix login.
