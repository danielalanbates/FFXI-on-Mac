# Phoenix native installation and launch — beta 116

Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
https://batesai.org · help@batesai.org

## Verified contract (2026-10-30)

Phoenix’s official Windows launcher 0.0.116 and its authenticated CDN manifests are the sources. No password or browser session is saved by this integration.

- Browser approval returns a one-time code to a state-bound loopback listener. The code is exchanged at `/api/auth/one-time-token/verify` for an in-memory session.
- Game, Ashita and EraDAT manifests are at `https://{gamefiles,ashita,eradats}.phoenix-xi.com/manifest.json`. The archive URLs are **relative** to these endpoints; the older beta assumed absolute URLs and therefore never installed anything.
- Game baseline archive: 5,992,098,554 bytes; Ashita: 53,801,222; EraDATs: 218,027,878. Verify archive SHA-256, extract, then verify **every file**. This baseline required 16,793 file updates/additions. Verified replacements come from `/files/<manifest path>`, authenticated to the corresponding CDN.
- Game and Ashita share `client/`. EraDATs belongs at `client/polplugins/DATs/EraDATs`, enabled through the vendor’s Pivot polplugin.
- `POST /api/v1/auth/game/launch-token`, JSON `additionalClient: false`, returns `data.token`, `data.expiresAt`, `data.multiClientAllowed`. The token is requested after installation and prefix preparation, so a long download does not consume its lifetime.
- Phoenix’s vendor loader accepts `--json <file>` with `login_token`, `server`, `authport`, `dataport`, `viewport`, `profileport`, `hide`, `language`. The exact token values are never logged.
- The vendor Ashita profile’s `ashita.boot.file` points to `bootloader/phoenix-loader.exe`; `gamemodule` remains `ffximain.dll`. Sandbox paths point exclusively to the Phoenix client.

## Isolation and runtime

Everything substantial is stored in the agreed Phoenix folder on x10. Archives stream there directly instead of using the startup volume’s URLSession download-task temporary directory. Six repair requests share an ephemeral session; large files stream to the destination volume.

`prefix/` contains independent Windows state. Its first 32-bit setup uses the selected wrapper’s Wine, then the launcher uses the existing patched CrossOver Wine for the game. Latest upstream arm64 release checked: arm64-11.20-5, published 2026-10-30; changing the established game runtime is not part of this work.

Microsoft’s x86 VC runtime is downloaded from its official endpoint and checked against a pinned size/digest. A changed package fails closed. Only the isolated Phoenix wineserver may be stopped for preparation, after checking no Phoenix loader is running. A character/game is never stopped to install this feature.

The launch uses the repository’s documented shell/file-redirection method, with separate argv values, to avoid the known Foundation spawn issue. No optional addons, VanaGuide or narration are loaded by the Phoenix profile. The short-lived launch-token JSON is mode 0600 under a mode 0700 directory, removed after injector exit or 120 seconds. Browser credentials remain in memory only.

## Validation and limits

Pure checks cover callback state/host/duplicate parameters, manual callback validation, token redaction and launch-token parsing, relative URLs, host boundaries, sizes, and streaming success/HTTP/oversize/truncation failures. Release compilation is required. Live test results must be appended below; compilation and a spawned injector alone are not evidence of gameplay.

Remaining limitations: account-specific 2FA launch flows are rejected with an account requirement message; they are not guessed or bypassed. UI cancellation/resume and full integration with the generic launcher session/Stop controls need follow-up. Completed client installations are keyed by all three manifest versions and archive digests. Do not enable public Play verification or mark this server verified without evidence from the real game.

## Live test

Authenticated installation completed: all 66,382 files were verified, including 16,793 baseline repairs. The installed local client is separate from Horizon.

The first native launch probe failed before game startup because an idle `wineserver -k` returns exit code 1. Confirmed in Wine’s `server/main.c` (`exit(!kill_lock_owner(...))`) and `server/request.c`: no lock owner returns zero from `kill_lock_owner`. The fix accepts 0/1 only for `-k`, followed by a bounded `-w` that must succeed. An offline native preparation probe now reaches `NATIVE_PREFIX_READY`.

Callback/download/token checks and release compilation pass. Live game startup is being verified separately; a spawned injector is not evidence of gameplay. Sessions and launch tokens are never committed. No hosted addon or bot tests are authorized.
