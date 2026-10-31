# Beta 3.10 build 73 (local only)

Branch `beta-b73`, from `beta-b72`. Local beta: no GitHub release.

- **DriftwoodXI** is a world. They ship no game files: Setup puts retail FFXI (their build,
  `30260904_1`) together from the identical files of other worlds' clients on this Mac, checked file
  by file against their published list, then their Ashita bundle, its core and their 33 addons from
  their public content repo, the profile and script their Linux page describes. Every Play first
  fetches what changed. Everything about it: [`DRIFTWOOD.md`](DRIFTWOOD.md).
- Their online count shows beside the world (`/api/players`).
- Their addon allowlist (158 names) is the world's addon policy.

## Files

| file | what |
| --- | --- |
| `DriftwoodSync.swift` (new) | `DriftwoodChannel` (client list, `ashita.json`, `content.json`, treeHash, profile, script, allowlist) and `DriftwoodSync` (client from donors → viewer → bundle → core → addons → profile, script, pivot.ini) |
| `DriftwoodSelfTest.swift` (new) | `--selftest-driftwood` (fake site and donor), `--driftwood-sync [--install] [--root]`, `--driftwood-treehash <folder>` |
| `Servers.swift` | `InstallKind.driftwoodContent` (stored as `website` for older builds), the DriftwoodXI entry |
| `Runner.swift`, `App.swift` | `syncDriftwood`; Setup/Play route it, with other worlds' clients as donors |
| `AddonPolicy.swift`, `ServerFeeds.swift` | their allowlist; their online count |

## Tests

- All 29 suites pass on the b73 app (`--selftest-driftwood` 32).
- `--driftwood-treehash` on their real `dwah` package gives the published `853d00a9…`.
- The real install (headless, `--driftwood-sync --install`, into
  `x10/…/FFXI on Mac/Games/DriftwoodXI`): all 65,053 files of their list present and SHA-256
  checked (65,052 copied from other worlds' clients on this Mac, 0 missing), PlayOnline Viewer identical to
  AscensionXI's, bundle `20260920-1151`, core 4.3.2.1, 33 addons; `ok`, 15 GB.
- The Play-time update on that install: 3 s, nothing downloaded.
- `--login-version xi.driftwoodgaming.com`: "requires 2.1.x", the loader their bundle carries.

## Needs Daniel

1. Register at <https://xi.driftwoodgaming.com/register>, type that account in the window, **Play**.
