# Beta 3.10 build 71 (local only)

Branch `beta-b71`, from `beta-b70` (c721e2a). Local beta: no GitHub release. **Installed in
`/Applications` on 2026-10-24** (b70 archived as
`~/Downloads/FFXI-on-Mac-build/archive-apps/FFXI-on-Mac-3.10-b70.app`), with no game running.

One new world and four fixes it exposed:

- **AscensionXI** is a world: Setup installs its client from their own update server, and every
  Play first makes the same update their launcher makes (their DATs, addons, loader and whatever
  their client changed). Everything about it: [`ASCENSION.md`](ASCENSION.md).
- A world never played here no longer comes up with HorizonXI's account name and password filled
  in (Play would have sent them to that world's login server).
- A world's own loader arguments survive the account line (`Server.loaderOptions`; AscensionXI's
  `--hairpin`).
- The LuaJIT guard Play adds to addons no longer looks like a change to AscensionXI's sync.
- The Addons… sheet edits AscensionXI's own block of `default.txt` instead of adding a second one.
- A forwarded `--play` for the world already selected reads the account saved for it since the
  window opened (it went in with empty fields).

## Files

| file | what |
| --- | --- |
| `AscensionChannel.swift` (new) | the channel's formats, parsing, settings (`launcher.json`), `pivot.ini`, `--json` removal, the addon policy, donor discovery, `AscensionScript` (their `AddonScript`, line for line) |
| `AscensionSync.swift` (new) | one install or update: HTTP over both mirrors, base client (full or delta, donors), runtime check, overlays, addons (archives, removals), retired files, pivot, loader, boot profile; `HashCache` |
| `DotNetResources.swift` (new) | reads a .NET PE's manifest resources; finds their loader, licence and notice |
| `AscensionSelfTest.swift` (new) | `--selftest-ascension` (fake channel on 127.0.0.1, 50 checks) and `--ascension-sync [--install] [--root <folder>]` (the real thing, headless, prints every line) |
| `Servers.swift` | `InstallKind.ascensionChannel` (written as `website` for older builds; unknown kinds read as `website`), `loaderOptions`, the AscensionXI entry |
| `Runner.swift` | `syncAscension` job: busy, progress on the button (`ascensionProgress`), Stop |
| `App.swift` | Setup / Download… run the full check; Play runs the update first, then launches; `ascensionJob` |
| `Credentials.swift` | `inheritsLegacyAccount`; `apply(options:)` |
| `AddonPolicy.swift`, `Addons.swift` | AscensionXI's allowlist (their catalog + base client); their fenced block |
| `bundle.sh` | ATS exception for `ascensionffxi.com` (+ local networking) |
| `BootProfileSelfTest.swift` | one check restated: AscensionXI is the one other world that names a loader |
| `tools/ascension-prefetch.py` | the one-off that fetched the first client (kept for reference) |

## Tests (2026-10-24)

- `swift build`: clean apart from the two pre-existing capture warnings in Runner.swift.
- All 27 `--selftest-*` suites on the bundled app: pass (`--selftest-ascension` 50/50, boot-profile
  43/43, primary-action 87/87, install-location 107/107, …; the log is
  `~/Downloads/FFXI-on-Mac-build/b71-selftests.log` for the first build).
- `scripts/tests/gamewindow-test.sh` was not re-run: nothing it covers changed.
- Real channel, headless: full install check, then `ok(changed: 0)` in 3.7 s.
- One deliberate Play of AscensionXI through the installed window with a non-existent account:
  reached their login server, which refused the account. Details in ASCENSION.md › Verified.

## Needs Daniel

1. **Logged in on 2026-10-24** with Daniel's account: character select reached, his character
   listed (ASCENSION.md › Verified). Still to see in the world: addons load (`/addon list` shows
   their defaults: axmap, casper, chains, dlac, nexus, …), zoning, `/shutdown`.
2. Frame rate on their default profile (1920×1080 window, 2048 background); compare with
   HorizonXI at the same settings.
3. Nothing changed for HorizonXI: Play it once and confirm it is as before (its account fields,
   its loader, its addons).
