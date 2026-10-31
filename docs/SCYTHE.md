# Scythe

Added in beta 76 (2026-10-24). **Scythe** (<https://scythe-bbq.pages.dev>, Discord
`discord.gg/9KDDH3XQfY`) is a level-99 custom world (Master Levels to 50, Rhapsodies of Vana'diel, a
custom hub zone); footer "Powered by LandSandBoat", and port 54231 answers LSB's JSON ("'2.1.x'").
Accounts are made in the loader ("choose Create Account" in the xiloader console): here, **Create
account** on the account card. "You may use up to two accounts per player for dual-boxing, with both
online simultaneously" → two clients.

## What their launcher does (read, not guessed)

Scythe Launcher 3.0.39 (.NET 8 WPF single-file app, SHA-256 matching their site's), unbundled and
read with ILSpy. The full report with file:line citations into their code is kept with the research:
`~/Downloads/lsb-survey/specs/scythe/PROTOCOL.md` (decompiled code beside it).

| what | where | how it is trusted |
| --- | --- | --- |
| the release | `https://212-28-177-210.sslip.io/launcher/channel/current.json` | ECDSA P-256 / SHA-256 signature (64-byte r‖s, Base64) over the `release` object as System.Text.Json writes it (top level, 2-space indent, CRLF); key embedded in their launcher |
| the client's file list | `/launcher/client/releases/<releaseId minus -rN>/manifest.json` (65,062 files, 14.87 GB, retail **30260429_1**) | must hash to the signed `target`: SHA-256 of `"scythe-client-tree-v1\n"` + per file `path\0length\0SHA\n` (upper hex), files sorted case-insensitively **on the backslash form** |
| each file | `/launcher/client/objects/<aa>/<sha lower-case>` | length + SHA-256 |
| Ashita | `/launcher/runtime/ashita-v4.3.1.1-<sha>.zip` (Ashita-v4beta 7f4133d) | SHA-256 pinned in their launcher |
| loader | embedded in their launcher: LandSandBoat xiloader **v1.1.5** (byte-identical to LSB's GitHub release) | SHA-256 |

Their match step copies each file from any FFXI install on the PC that has it byte for byte and
downloads the rest; a newer retail client is downgraded file by file to their pin. Their boot profile
`config/boot/scythe.ini`: `--server 212.28.177.210`, `gamemodule = FFXiMain.dll`, all resource
overrides off, the sandbox polplugin on with `[sandbox.paths]`, no script.

## What this launcher does (`ScytheSync.swift`)

The same, natively: signature verified with CryptoKit (`signedBytes` re-indents the served object,
which reproduces their 740 signed bytes exactly; their real release verifies in the self-test), the
file list bound to the signed target, files from donors (`RetailClient`, exact matches only) or
fetched by hash, their Ashita and their loader by hash, their profile. Two differences:

| theirs | here | why |
| --- | --- | --- |
| sandbox polplugin on, `[sandbox.paths]` to the Windows folders | `sandbox = 0` | this launcher points the Wine prefix's PlayOnline registry at each world's client, as for every other world |
| no `script` key | `script = scythe.txt` (Ashita's thirdparty, addons, screenshot) | a defined script; the addon panel edits it |
| newer-retail leftovers moved to `TEMP/.scythe-preserved-…` | a fresh folder has none; a file their next release drops is removed | nothing else lives in this folder |

Measured 2026-10-24: 63,808 of their 65,062 files are byte-identical to retail 30260904_1 (13.98 of
14.87 GB), so about 0.9 GB comes from Scythe.

## Not verified

- Logging in. **Loader contradiction**: every 2026 LandSandBoat login refuses old non-JSON loaders
  (`auth_session.cpp`: "old non-json xiloader" → `LOGIN_ERROR_VERSION_UNSUPPORTED`), and v1.1.5
  (2025-08) predates LSB's JSON login (v2.0.0, 2025-11), yet their launcher ships it and their JSON
  answer asks for 2.1.x. Their login must still take the old protocol. If logging in fails with the
  loader's "version" error, set `ScytheChannel.loader` to v2.1.2 (`RetailWorld.loaders["2.1"]`).
- Their written rules on third-party launchers (their own launcher offers an "External" route that
  runs any Ashita or Windower profile on the verified client).

## Pathways if it breaks

- **"not signed by Scythe's key"**: they rotated their key; read `scythe-release-public-key.pem` out
  of their new launcher (unbundle, ILSpy) and update `publicKeyX/Y`.
- **"does not match their signed release"**: their manifest shape or tree-hash rule changed; re-read
  `ClientMatchTreeSnapshot.cs` in their new launcher.
- **A new release**: nothing to do; the next Play fetches the changed files.
