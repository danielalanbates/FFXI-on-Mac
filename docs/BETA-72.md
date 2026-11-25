# Beta 3.10 build 72 (local only)

Branch `beta-b72`, from `beta-b71`. Local beta: no GitHub release.

- **Vanadreams** is a world: Setup puts their client package, Ashita v4 and the loader their server
  takes together the way their own (open-source) launcher does, and every Play first fetches what
  they added since. Everything about it: [`VANADREAMS.md`](VANADREAMS.md).
- **Create account** for worlds whose accounts are made at the login server, not a website
  (Vanadreams, Supernova): the name and password typed in the window are sent the way xiloader's own
  "Create New Account" sends them (`LoginAccount.swift`). Before this, those worlds' accounts were
  "made in the loader window", which this launcher never shows: the loader was stopped at its menu,
  so a new player had no way in. `--login-version <host>` runs its harmless first step.
- The update-before-Play job is shared by every world that needs one (`Runner.runWorldJob`,
  `InstallKind.updatesBeforePlay`): AscensionXI and Vanadreams today.
- The population counter reads nested JSON keys (Vanadreams' `stats.online`).
- `--ascension-sync` / `--vanadreams-sync` print line by line into a file too.

## Files

| file | what |
| --- | --- |
| `VanadreamsSync.swift` (new) | `VanadreamsChannel` (their download list, destinations, record, profile, script, pivot.ini, moved hosts) and `VanadreamsSync` (status → list → Ashita, loader, XIPivot, zips, effects off, profile, script, pivot) |
| `VanadreamsSelfTest.swift` (new) | `--selftest-vanadreams` (fake site on 127.0.0.1) and `--vanadreams-sync [--install] [--root]` |
| `Servers.swift` | `InstallKind.vanadreamsPackage`, `updatesBeforePlay`; the Vanadreams entry |
| `Runner.swift`, `App.swift` | `runWorldJob` shared by both worlds; Setup/Download/Play route by kind |
| `AddonPolicy.swift` | Vanadreams: unrestricted ("your addons welcome") |
| `ServerFeeds.swift` | Vanadreams' online count; dotted JSON keys |
| `LoginAccount.swift` (new) | LandSandBoat account creation over TLS (version learned from the server's own refusal) |
| `Servers.swift`, `App.swift` | `createsAccountAtLogin` (Vanadreams, Supernova); the Create account button; `accountHow` refreshed from `builtins` |
| `Headless.swift`, `BootProfileSelfTest.swift` | two list checks restated for Vanadreams (several clients allowed; it names its loader) |

## Tests

- All 28 suites pass on the b72 app (`--selftest-vanadreams` 29, `--selftest-ascension` 60).
- The real Vanadreams install (headless, `--vanadreams-sync --install`): 72 client zips (8.4 GB) +
  Ashita + xiloader v2.2.0 + XIPivot, `ok`, 16 GB on disk; effects `.off`; both overlays in pivot.ini.
- `--login-version` against vanadreams.online (2.2), play.ascensionffxi.com (2.1) and
  login.supernovaffxi.com (2.1): both wordings read; nothing created.

## Needs Daniel

1. Vanadreams: type the account name and password you want, **Create account**, then **Play**.
2. Supernova: the same button (its client is the retail route, unchanged).
