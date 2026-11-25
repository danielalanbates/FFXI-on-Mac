# Phoenix native sign-in groundwork (beta 113)

Phoenix is **not playable through this integration yet**. Connect Phoenix (Beta) starts an
account-access check on Phoenix's own website. It does not connect a game client or enable Play.

The unmodified Windows launcher 0.0.116 was installed with Microsoft WebView2 156.0.4314.58
in a dedicated test prefix. Sikarugir Wine10, the installed athei CrossOver/Wine11, and today's
native Apple Silicon athei arm64-11.20-5 all failed to keep the WebView2 frontend functioning.
The native engine produced a page fault. Chromium compatibility switches did not resolve this.
No successful sign-in or gameplay was observed. Sky UI inspection was unavailable; process
liveness was explicitly not treated as GUI success. Failed adapter code is archived under
archive/2026-10-30/phoenix-official-wine. No broken Wine adapter is exposed in the launcher.

## Current native flow

1. Bind an ephemeral listener to IPv4 loopback only, with random state and a five-minute expiry.
2. Open `https://phoenix-xi.com/launcher-auth?port=...&state=...` in the normal Mac browser.
   Phoenix handles Discord sign-in. The launcher never collects a password.
3. Validate callback method/path/Host/state, reject duplicate state/token parameters and control
   characters, consume one callback, and exchange its one-time token at Phoenix's
   `/api/auth/one-time-token/verify` endpoint. No redirects are followed with authentication.
4. Read the account-gated `https://gamefiles.phoenix-xi.com/manifest.json` with the returned
   session in memory. Save only a schema whose values have been replaced by type names at
   `Downloads/FFXI-Phoenix/manifest-schema.json`. Neither token nor session is saved or logged.
5. Report the result. The installer, updates, game launch token/2FA and loader remain pending.

The live account contract has not been verified. Endpoint behavior was identified from Phoenix's
own public website and interoperability inspection of its official launcher, not a published API
support guarantee. A valid Phoenix account sign-in is required to inspect the real manifest;
unauthenticated fetches returned HTTP401. Do not infer working gameplay from fixture tests.

Only about 6 GB was free before runtime tests. Full client installation will need more free space
or a game directory the user explicitly chooses on a larger drive. Do not copy Horizon game
files into Phoenix or change Horizon's prefix. No hosted addon/bot tests, staff messages,
credential publication or account creation took place.

## Checks

`swiftc -parse-as-library app/Sources/HorizonXILauncher/PhoenixSetup.swift tools/PhoenixSetupSelfTest.swift -o <scratch>/phoenix-auth-check`
then run that check: callback state/Host/path/size, duplicate parameters, control characters,
session status handling and complete diagnostic-value redaction. Run launcher
`--selftest-server-catalog`, `--selftest-primary-action`, `--selftest-addon-policy` as well.
These checks must not open a browser, sign in, create a game client or alter real profiles.

Sources: https://phoenix-xi.com/getting-started and its official launcher download;
https://phoenix-xi.com/launcher-auth and its public page module;
https://github.com/athei/wine-build/releases/tag/arm64-11.20-5.
