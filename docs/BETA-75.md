# Beta 3.10 build 75 (local only)

Branch `beta-b75`, from `beta-b74`. Local beta: no GitHub release.

- **MistXI** and **Moghouse XI** are worlds, through one new route for LandSandBoat worlds that ship
  no client: retail FFXI from the identical files of other worlds' clients on this Mac, Ashita v4,
  and the exact LandSandBoat xiloader release each server takes (2.1.2 and 2.2.0; LSB refuses any
  other major.minor). Everything about it: [`RETAIL-WORLDS.md`](RETAIL-WORLDS.md).
- `RetailClient` is DriftwoodXI's client step, now shared (no change in what it does).
- MistXI: their addon list (101 addons, 23 plugins), two clients, their online count. Moghouse XI:
  Create account (no signup page).

## Files

| file | what |
| --- | --- |
| `RetailWorldSync.swift` (new) | `RetailClient` (client from donors + viewer), `RetailWorld` (loader pins, specs, profile, script, MistXI's list), `RetailWorldSync` |
| `RetailWorldSelfTest.swift` (new) | `--selftest-retail-world`, `--retail-world-sync --world <name> [--install] [--root]` |
| `DriftwoodSync.swift` | its client step is `RetailClient` |
| `Servers.swift` | `InstallKind.retailWorld`; MistXI and Moghouse XI |
| `Runner.swift`, `App.swift` | `syncRetailWorld`; Setup/Play route it |
| `AddonPolicy.swift`, `ServerFeeds.swift` | MistXI's list and online count |
| `Headless.swift`, `VanadreamsSelfTest.swift` | the several-clients and Create-account lists name MistXI and Moghouse XI |

## Tests

- All 31 suites pass on the b75 app (`--selftest-retail-world` 19; DriftwoodXI's 32 after its client
  step moved to `RetailClient`).
- The real installs (headless, `--retail-world-sync --world … --install`) into
  `x10/…/FFXI on Mac/Games/MistXI` and `…/Moghouse XI`: each 65,053 retail files present and SHA-256
  checked (65,052 copied from other worlds' clients, 0 missing), PlayOnline Viewer from AscensionXI's
  (same build), Ashita 4171c74, xiloader 2.1.2 / 2.2.0 by hash; MistXI's six addons removed; `ok`,
  15 GB each. Footprint stayed under 70 MB.
- The Play-time check: 0.65 s, one 304.
- `--login-version`: play.mistxi.com wants 2.1.x, ffxi.cc 2.2.x.

## Needs Daniel

1. MistXI: sign up at <https://mistxi.com/create-account/>, type that login in the window, **Play**.
2. Moghouse XI: type the account name and password you want, **Create account**, then **Play**.
