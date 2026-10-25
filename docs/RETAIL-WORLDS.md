# Plain retail worlds (MistXI, Moghouse XI)

Added in beta 75 (2026-10-24). One route for LandSandBoat worlds that publish no client and no
launcher this one needs to follow: their players install retail FFXI, Ashita v4 and LandSandBoat's
xiloader, and boot with `--server <host>` (each world's own setup guide). `RetailWorldSync.swift`.

| world | login | loader | account | clients | addons | sources |
| --- | --- | --- | --- | --- | --- | --- |
| **MistXI** | `play.mistxi.com` | 2.1.x → v2.1.2 | website (mistxi.com/create-account, Discord verification) | 2 ("Dual boxing: Allowed ( maximum 2 per IP )") | their list: 101 addons + 23 plugins ("Only items on this list are permitted") | mistxi.com/server-info, getting-started; api.mistxi.com/status.php; their launcher's source (github.com/mistxi/mistxi_launcher) |
| **Moghouse XI** | `ffxi.cc` | 2.2.x → v2.2.0 | at the login server (Create account) | 1 (no rule published) | none published | moghouse.cc/getting-setup, the Ashita guide |

Both answered LandSandBoat's JSON on port 54231 on 2026-10-24 ("'2.1.x'" and "requires version
2.2.x"). LSB's login checks the loader's major.minor exactly (`src/login/auth_session.cpp`), so a
newer loader is refused as well: each world gets LandSandBoat's own release of its series, pinned by
SHA-256 (`RetailWorld.loaders`: 2.0.1, 2.1.2, 2.2.0). MistXI's own launcher fetches *latest* (2.2.0
since 2026-09-27), which their server refuses.

## What it does

1. **Client**: retail FFXI, build 30260904_1, from the identical files of other worlds' clients on
   this Mac (`RetailClient`, shared with DriftwoodXI): each of the build's 65,053 files is taken only
   from a donor whose copy hashes the same, checked against DriftwoodXI's public list of that build
   (`xi.driftwoodgaming.com/api/manifest`, the only published SHA-256 list of a retail build; it names
   retail files only). PlayOnline Viewer from a donor on the same build. No Square Enix installer
   (hours under Wine), no download.
2. **Ashita v4** at the commit VanadreamsSync pins (`4171c74c`, v4.3.2.1), which is also the `main`
   MistXI's launcher tracks, into `Ashita/`. A new pin reinstalls it over the old one.
3. **xiloader** of the server's series into `Ashita/bootloader/xiloader.exe`, re-fetched if it is
   ever not the pinned file.
4. **Profile** `config/boot/<world>.ini` from Ashita's `example-privateserver.ini` (name, loader,
   `--server <host>`, script) and **script** `scripts/<world>.txt` (Ashita's thirdparty, addons,
   screenshot and winefix plugins; no addon forced on), written only when missing: after that they
   are the player's.
5. MistXI only: the six addons their launcher deletes from Ashita's bundle
   (`GitHubAshitaService.cs` `unwantedAddons`: skeletonkey, ahgo, allmaps, instantah, instantchat,
   paranormal) are removed.

Every Play: the list with If-Modified-Since (one 304), the Ashita pin and the loader's hash. Layout:
`<folder>/Ashita/`, `<folder>/Game/FINAL FANTASY XI`, `<folder>/Game/PlayOnlineViewer`, state in
`<folder>/.ffxi-on-mac/`.

## Not done here, on purpose

- MistXI's `FFXI-UpdatePatch.zip` (5 MB): it makes a client look 2010-old so PlayOnline's Check Files
  downloads the whole update chain. Applied to a current client without that update, it downgrades
  it. This client is already current retail.
- Their launcher's copy of `PlayOnlineViewer/data` into `FINAL FANTASY XI/data` and its reboot gate:
  Windows-only (AscensionXI's client runs here without either).

## Not verified

- Logging in. MistXI's status says client `30260805_0`; this one is `30260904_1` (newer). LSB's
  default `VER_LOCK` takes newer clients and their 1.6.0 launcher prints "Client is NEWER than server
  (OK)", but only a login proves it. Moghouse says it runs "at or near retail patch level"; if it
  wants a newer build than 30260904_1 the login says "The game's data has been updated".
- Whether Moghouse's server has account creation on (Create account answers result 8 if not).

## Adding another world like these

A `RetailWorld.Spec` (name, host, profile, script, loader series, any addons to remove) and a
`Server` entry with `installKind: .retailWorld`. Probe the login first
(`--login-version <host>`) for the series.
