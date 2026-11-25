# Beta 3.10 build 76 (local only)

Branch `beta-b76`, from `beta-b75`. Local beta: no GitHub release.

- **Scythe** is a world: their signed client release (ECDSA P-256, verified natively), their file
  list bound to it, files copied from this Mac byte for byte or fetched from Scythe by SHA-256, their
  pinned Ashita and loader. Everything about it: [`SCYTHE.md`](SCYTHE.md).
- **LevelDown 99** is a world: its server runs an older client than retail, so its client is their own
  archive (named on their wiki, 5.5 GB, downloaded straight into the world's folder and unpacked
  without the `USER/` folders of whoever packed it), then Ashita and xiloader 2.2.0. See
  [`RETAIL-WORLDS.md`](RETAIL-WORLDS.md).
- `FileDownload`: large downloads written where they are going and resumed after Stop (never through
  the internal disk's temporary folder).
- Every donor-built client gets an empty `FINAL FANTASY XI/USER` (no file list carries it), and its
  PlayOnline Viewer from the same build or else the newest (`version.dat`), preferring one without a
  PlayOnline member's mail.
- `RetailClient` can fetch what no donor has (Scythe) and match exactly (no `patch2.cfg` leeway).

## Files

| file | what |
| --- | --- |
| `ScytheSync.swift` (new) | `ScytheChannel` (key, signed bytes, release, manifest, tree hash, profile, script) and `ScytheSync` |
| `ScytheSelfTest.swift` (new) | `--selftest-scythe` (their real release + a fake signed site), `--scythe-sync [--install] [--root]` |
| `FileDownload.swift` (new) | streamed, resumable download to a file |
| `RetailWorldSync.swift` | `ClientArchive` (wiki page → version + Drive file), `installArchive`; LevelDown 99's spec; `RetailClient.assemble(mayDiffer:fetch:)`; USER folder; viewer ranking |
| `RetailWorldSelfTest.swift` | the archive route (7-Zip made by bsdtar, a USER folder in it), the wiki parser |
| `Servers.swift` | `InstallKind.scytheChannel`; Scythe and LevelDown 99 |
| `Runner.swift`, `App.swift` | `syncScythe`; Setup/Play route it |
| `Headless.swift`, `VanadreamsSelfTest.swift` | the several-clients and Create-account lists |

## Tests

- All 32 suites pass on the b76 app (`--selftest-scythe` 18, including their real release verifying
  with their real key; `--selftest-retail-world` 25).
- Scythe, real install (headless, `--scythe-sync --install`): their live release verified, its file
  list bound to the signed target, 63,841 files copied from other clients on this Mac and 1,221
  downloaded from Scythe, each length + SHA-256 checked; Ashita 4.3.1.1 and xiloader 1.1.5 by hash;
  `ok`, 14 GB. Play-time check: 0.9 s, one request.
- LevelDown 99, real install: their wiki named 30260203_0; the 5.5 GB archive unpacked by bsdtar
  (64,905 files, no `USER/` from it), PlayOnline Viewer 1.18.15e, Ashita, xiloader 2.2.0; `ok`, 20 GB
  with the kept archive. Play-time check: one page request.
- `--login-version`: LevelDownFFXI.com wants 2.2.x; Scythe 2.1.x (see SCYTHE.md on its loader).

## Needs Daniel

1. LevelDown 99 and Scythe: type the account name and password you want, **Create account**, **Play**.
