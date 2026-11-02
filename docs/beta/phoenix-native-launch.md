# Phoenix native installation and launch — beta 120

Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
https://batesai.org · help@batesai.org

## Verified contract (2026-10-31)

Phoenix’s official Windows launcher 0.0.116 and its authenticated CDN manifests are the sources. No password or browser session is saved by this integration.

- Browser approval returns a one-time code to a state-bound loopback listener. The code is exchanged at `/api/auth/one-time-token/verify` for an in-memory session.
- Game, Ashita and EraDAT manifests are at `https://{gamefiles,ashita,eradats}.phoenix-xi.com/manifest.json`. The archive URLs are **relative** to these endpoints; the older beta assumed absolute URLs and therefore never installed anything.
- Game baseline archive: 5,992,098,554 bytes; Ashita: 53,801,222; EraDATs: 218,027,878. Verify archive SHA-256, extract, then verify **every file**. This baseline required 16,793 file updates/additions. Verified replacements come from `/files/<manifest path>`, authenticated to the corresponding CDN.
- Game and Ashita share `client/`. EraDATs belongs at `client/polplugins/DATs/EraDATs`, enabled through the vendor’s Pivot polplugin.
- `GET /api/v1/auth/me` returns `data.username`. The loader requires this non-empty account name alongside the token to activate automatic login; a token-only payload opens its interactive menu. The profile stays in memory, and only the required username goes into the private loader JSON.
- `POST /api/v1/auth/game/launch-token`, JSON `additionalClient: false`, returns `data.token`, `data.expiresAt`, `data.multiClientAllowed`. The token is requested after installation and prefix preparation, so a long download does not consume its lifetime.
- Phoenix’s vendor loader accepts `--json <file>` with `username`, `login_token`, `server`, `authport`, `dataport`, `viewport`, `profileport`, `hide`, `language`. The exact token values are never logged.
- The vendor Ashita profile’s `ashita.boot.file` points to `bootloader/phoenix-loader.exe`; `gamemodule` remains `ffximain.dll`. Sandbox paths point exclusively to the Phoenix client.

## Isolation and runtime

Everything substantial is stored in the agreed Phoenix folder on x10. Archives stream there directly instead of using the startup volume’s URLSession download-task temporary directory. Six repair requests share an ephemeral session; large files stream to the destination volume.

`prefix/` contains independent Windows state. Its first 32-bit setup uses the selected wrapper’s Wine, then the launcher uses the existing patched CrossOver Wine for the game. Latest upstream arm64 release checked: arm64-11.20-5, published 2026-10-30; changing the established game runtime is not part of this work.

Microsoft’s x86 VC runtime is downloaded from its official endpoint and checked against a pinned size/digest. A changed package fails closed. Only the isolated Phoenix wineserver may be stopped for preparation, after checking no Phoenix loader is running. A character/game is never stopped to install this feature.

The launch reuses `Detach.spawn`, the repository’s established detached bridge and regular-file output handling, to avoid the documented Foundation ancestry and external-volume launch issues. Private vendor output is kept under the Phoenix private directory, outside the repository. No optional addons, VanaGuide or narration are loaded by the Phoenix profile. The short-lived launch-token JSON is mode 0600 under a mode 0700 directory, removed after 120 seconds by a single detached cleanup command, even if the launcher quits. Browser credentials remain in memory only.

## Validation and limits

Run `tools/test-phoenix-setup.sh` for the offline checks (build products and fixtures stay in Downloads). Pure checks cover callback state/host/duplicate parameters, manual callback validation, token redaction and launch-token parsing, relative URLs, host boundaries, sizes, and streaming success/HTTP/oversize/truncation failures. Release compilation is required. Live test results must be appended below; compilation and a spawned injector alone are not evidence of gameplay.

Remaining limitations: account-specific 2FA launch flows are rejected with an account requirement message; they are not guessed or bypassed. UI cancellation/resume and full integration with the generic launcher session/Stop controls need follow-up. Completed client installations are keyed by all three manifest versions and archive digests. Do not enable public Play verification or mark this server verified without evidence from the real game.

## Live test

Authenticated installation completed: all 66,382 files were verified, including 16,793 baseline repairs. The installed local client is separate from Horizon.

The first native launch probe failed before game startup because an idle `wineserver -k` returns exit code 1. Confirmed in Wine’s `server/main.c` (`exit(!kill_lock_owner(...))`) and `server/request.c`: no lock owner returns zero from `kill_lock_owner`. The fix accepts 0/1 only for `-k`, followed by a bounded `-w` that must succeed. An offline native preparation probe now reaches `NATIVE_PREFIX_READY`.

Callback/download/token checks and release compilation pass. Live game startup is being verified separately; a spawned injector is not evidence of gameplay. Sessions and launch tokens are never committed. No hosted addon or bot tests are authorized.

The initial direct Foundation injector probe returned 0 but left no game process. That was not a successful game launch. The beta 119 path now uses the same Detach bridge as the existing launcher; its live result remains to be recorded.

The detached vendor loader reported that its JSON input did not exist: removing the token file on injector exit races the resumed loader. Beta 118 keeps the private JSON for 120 seconds instead. The injector’s successful exit must never trigger immediate token-file deletion.

Read-only inspection of the vendor loader confirmed its autologin condition requires a non-empty username and either password or login token. An authenticated `/api/v1/auth/me` request supplies the username; no password is requested or stored. The previous token-only probe reached the loader menu, not FFXI, and that unlogged test loader was stopped before further work.


## Beta 120: authenticated game startup

The legacy root Ashita manifest supplies xiloader 2.1.1, which the live server explicitly rejects (requires 2.2.x). Preparation now installs the genuine official `phoenixffxi/xiloader` release `v2.2.0-phoenix.2`, not a version-string modification. The 1,303,040-byte release SHA-256 is `e1282885f668e3b099faae8eda061f8cdf144f855ab6be8c7ca1e954919b732c`; this also matches both loader aliases in the authenticated current stable Ashita manifest. Public GitHub downloads never receive the Phoenix browser session. Redirects are restricted to GitHub's HTTPS release hosts. The previous loader is archived locally.

On 2026-10-31 at 09:51 PDT, the isolated native launch reported **Successfully logged in**, **Connected to server**, **Connected to profile server**, and **Profile loaded**. Read-only process inspection confirmed FFXi.dll, FFXiMain.dll, polcore.dll and Wine d3d8.dll loaded; MoltenVK initialized and the client remained running. The authenticated game was left open. No optional addon or bot was tested on Phoenix.

This is evidence of authenticated client startup, **not verified character selection or world entry**. Native window inspection was unavailable. Ashita's resource update logged item-DAT file-size validation errors, so full playability remains unverified. Do not silently replace files underneath the running client, terminate it, or call the public server verified.

### Current data investigation and safe continuation

The install-complete receipt verifies the legacy/root manifest baseline only. Current metadata exists at gamefiles `/v2/stable/manifest.json` and ashita/eradats `/stable/manifest.json`. Snapshots are stored privately on the agreed external drive. Stable versions observed: game `01d04952ad73` (66,360 files), Ashita `7f51c79b1d33` (150 files), EraDATs `a96d2a913d98` (155 files). Compared with the baseline, 1,312 game files (~1.05 GB) and 90 EraDAT files (~346 MB) differ. The DLL hashes also differ. The current stable archive/object URL contract remains unresolved: attempted direct resolution returns HTTP 404. This does not prove the vendor CDN is broken.

All 155 current EraDATs have been staged **separately** at `Phoenix/staging/eradats-a96d2a913d98` from the official `phoenixffxi/Era-DATs` repository at manifest source commit `a0069a335c7edc0b6712bc7542f27c573855124a`. Every size and SHA-256 matches the vendor manifest, including files reused from the verified baseline. The active client was not changed. The one-shot staging tool is in the private Downloads investigation workspace; it needs no credentials. This staged overlay is not yet applied or proven to resolve all resource errors.

Next: wait for normal in-game `/shutdown`, apply the staged verified core update with backups, then perform one manual native launch and inspect character/world entry. Do not interrupt an authenticated game for installation, use Horizon as a mutable donor, substitute guessed DAT formats, or bypass the loader protocol.

Beta 120 release compilation, local bundle signature verification and offline Phoenix checks passed. Existing primary-action checks passed 95/95 and catalog checks 19/19 earlier in the same investigation. Local beta installation is not a stable public release.


### Completed staging and verification (2026-10-31)

The base-client download blocker has been resolved for the actual FFXI game data. Square Enix's `pc001.pol.com:53001` patch service supplies version `30261006_0`, matching Phoenix's stable source metadata. A private, one-shot research helper fetched 1,112 changed files through the PlayOnline patch protocol. **Every decoded file matches Phoenix's independent SHA-256 and size**, with no mismatches. Staging: `Phoenix/staging/retail-01d04952ad73`. Protocol reference: [kuluu-ffxi ffxi-install](https://github.com/jondwillis/kuluu-ffxi/tree/1b611a74e0211892bf141ad849ebca175cb7ddee/ffxi-install), GPL-3.0; this research helper and reference source are outside the launcher repository/bundle.

The 200 remaining stable-manifest differences all belong to `SquareEnix/PlayOnlineViewer/`; they are excluded from this FFXI-core update, not falsely marked current. The vendor optional `zonetrace.dll` is also unchanged and not loaded.

A read-only complete proposed-data check passed: **65,255 manifest entries**, comprising the FFXI game core and the 155-file EraDAT overlay. It found **1,202 replacements** needed (1,112 core plus 90 overlay). Each target is already correct or has a verified staged replacement. The active game/client remains unchanged.

Private continuation helper: `Downloads/ffxi-recovery-20261029/phoenix-lab/apply-staged-core.py`. `--verify-only` performs the above check without modifying the active installation. Normal mode refuses if any Phoenix loader is running, re-verifies before replacement, backs up changed files under `Phoenix/archive/stable-core-<timestamp>`, and writes `stable-core-overlay.json` separately from the legacy base archive receipt. It never kills a client or launches one. Running-client refusal was checked. **Application and a subsequent live game test have not happened.** The next agent must confirm normal game exit before running normal mode. Keep this an explicitly supervised local beta update; the public installer still uses the legacy baseline and needs a maintainable stable-data download integration before public verification.


## 2026-11-01 local beta follow-up

The performance update had remained staged while the installed beta used Phoenix's older,
independent launch path. A selected Metal preference therefore did not configure Phoenix.
The shared policy now supplies its renderer DLLs, synchronization, x87 environment, DXVK
configuration and graphics overrides; compatibility exceptions remain authoritative. The
isolated syswow64 DLLs are backed up before replacement. Files are prepared only while
Phoenix is idle. No optional addon is introduced.

Read-only inspection of the new Phoenix process confirmed the installed native d3d8/d3d9
DLLs and MoltenVK loaded together. This establishes the intended renderer path, not a measured
FPS improvement or a completed in-world acceptance run. The previous run used Wine's built-in
D3D8/OpenGL; MoltenVK initialization alone was insufficient evidence of DXVK use.

Phoenix bypasses Runner's window monitor. The local beta now samples its sole loader's
window and saves resize deltas to graphics preferences while it runs, leaving the active
profile untouched. The next authenticated launch regenerates the profile from those settings.
Multiple Phoenix loaders are not sampled. The initial frame is the baseline, protecting
against title-bar/border drift. Resizing back to the initial size restores that choice, and
Remember window size remains optional. The installed beta passed all 80 graphics checks;
manual resize/relaunch acceptance is still pending.

Canceling the website approval leaves the loopback listener waiting until its five-minute
expiry. The follow-up candidate gives a repeated Connect an explicit Open Sign-in Page action,
a Start New Sign-in action that replaces the old listener/state, and the existing manual
return-address handoff. No browser session is persisted. UI acceptance of these actions is
pending; preserve those limits in the PR and public release notes.
