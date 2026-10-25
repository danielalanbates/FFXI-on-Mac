# Beta 3.10 build 74 (local only)

Branch `beta-b74`, from `beta-b73`. Local beta: no GitHub release.

- **PegasusXI** is a world. Setup reads their release zip on their CDN by Range — its directory,
  then each file — so the 13.9 GB zip is never downloaded or stored whole; every file is inflated and
  checked against the zip's CRC-32. Every Play asks their index (95 bytes) whether a release is out,
  and fetches only the files it changed. Their Windows tools are not installed, and the player's own
  files (settings, macros, scripts) are never reset. Everything about it: [`PEGASUS.md`](PEGASUS.md).
- Their online count shows beside the world (`/api/status`); their approved addon list (88 names) is
  the world's addon policy.
- The self-test fake server answers Range requests (`TestChannel`).
- `HashCache` takes the hash it keeps (SHA-256 by default; CRC-32 for PegasusXI) and can forget a file.
- **Memory fix** for every world sync: the first real PegasusXI install grew to an 11 GB footprint
  (swap filled the internal disk from 17 to 10 GB free before it was stopped). Its threads never
  drained an autorelease pool, so every 1 MB read buffer was kept. Each read, file and download now
  runs in its own pool, in PegasusSync and in the per-file loops of AscensionSync and DriftwoodSync
  (`AscensionChannel.sha256(of:)` already did). The resumed install stayed under 130 MB.
- The world self-tests remove their temporary folder (`exit()` skips `defer`; 34 were left in `$TMPDIR`).

## Files

| file | what |
| --- | --- |
| `PegasusSync.swift` (new) | `PegasusChannel` (index, ZIP64 end records and directory, wrapper, skipped and player files, CRC-32, approved list) and `PegasusSync` (index → directory → plan → Range fetch + inflate + CRC → removals → their state file) |
| `PegasusSelfTest.swift` (new) | `--selftest-pegasus` (fake CDN, Info-ZIP zips, one ZIP64) and `--pegasus-sync [--install] [--root]` |
| `Servers.swift` | `InstallKind.pegasusPack` (stored as `website` for older builds), the PegasusXI entry |
| `Runner.swift`, `App.swift` | `syncPegasus`; Setup/Play route it |
| `AddonPolicy.swift`, `ServerFeeds.swift` | their approved list; their online count |
| `AscensionSync.swift` | `HashCache(url:hasher:)`, `forget` |
| `AscensionSelfTest.swift` | `TestChannel` answers `Range` with 206 / `Content-Range` |
| `AscensionSync.swift`, `DriftwoodSync.swift` | an autorelease pool per file in the big loops |
| `*SelfTest.swift` | temporary folder removed before `exit()` |

## Tests

- All 30 suites pass on the b74 app (`--selftest-pegasus` 26).
- The real install (headless, `--pegasus-sync --install`, into `x10/…/FFXI on Mac/Games/PegasusXI`):
  their 1.2.4 directory read by Range (107,720 entries, ZIP64), 105,408 files written (19 Windows-only
  skipped), `ok`, 26 GB. Stopped once at ~60% (the memory leak above), resumed: 91,496 already right,
  13,912 fetched (2.41 GB).
- A Repair pass afterwards: all 105,408 files CRC-32 checked, 0 to fetch.
- The Play-time check: 0.5 s, one 95-byte request.
- `--login-version`: play.pegasusxi.com wants 2.1.x (their bundled loader is 2.1.1).

## Needs Daniel

1. Register at <https://pegasusxi.com/new_accounts/index.html>, type that account in the window, **Play**.
