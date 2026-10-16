# Licensing

## This project's own code — PolyForm Noncommercial 1.0.0 + 10% commercial rider

Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved. https://batesai.org ·
help@batesai.org

- **What it covers:** the launcher (`app/`), the scripts (`scripts/`, `tools/`), this project's own
  addons (`addons/winecursor`, `fpslog`, `lslog`, `mousediag`) and the documentation. Terms:
  [`LICENSE`](LICENSE).
- **`app/Resources/horizonxi-boot.ini`** (bundled) is this project's own file too: Ashita v4's
  setting names and HorizonXI's stock values, which are configuration facts, written with our own
  comments. No Ashita or HorizonXI text is copied into it (docs/BETA-61.md).
- **Noncommercial use is free.** Commercial use (shipping this, or a derivative of it, in a product
  or service that earns revenue) needs a separate licence from Bates LLC; standard terms are 10%
  of the gross revenue attributable to it. Ask at help@batesai.org.
- **Earlier copies keep the licence they were taken under.** Relicensed 2026-08-22 (06c9520).
  Copies taken before that date remain MIT (from fa0fb65, 2026-08-11); the first commits of
  2026-08-08 to 08-11 carried GPL-3.0 (11b489e) and briefly Apache-2.0 (50b6c94).
- **Contributions** come in under the contributor licence in
  [`CONTRIBUTING.md`](CONTRIBUTING.md#licence-of-contributions).

## Components we do NOT own, and the terms that actually govern them

Our licence has **no effect** on any of these. We cannot relicense other people's work, and
neither can anyone else who republishes it. Full texts of everything the app bundles:
[`vendor/licenses/`](vendor/licenses); what is vendored and how it is built:
[`vendor/NOTICE.md`](vendor/NOTICE.md).

| component | licence | in the app / DMG? |
| --- | --- | --- |
| DXVK 1.10.3 and our patches to it (`patches/dxvk-*.patch`) | zlib/libpng | **bundled**; the patches stay zlib, being derivative |
| d3d8to9 v1.15.1 | BSD 3-Clause | **bundled** |
| MoltenVK 1.4.2 (statically includes SPIRV-Cross, SPIRV-Tools, cereal) | Apache 2.0 (cereal: BSD 3-Clause) | **bundled** |
| x87sidecar (athei) | MIT | **bundled** |
| mingw-w64 runtime start-up code, inside our `ashita-send.exe` | ZPL 2.1 (parts public domain / BSD) | **bundled**, as part of that program |
| Vanaguide, VanaVoice | Bates LLC, each with its own `LICENSE` | **bundled**, licence beside each |
| `addons/FFXIFriendList` (Tanyrus) | GPL-3.0 | in the repo only, **not bundled** |
| `addons/gmtools` (SQLCommit) | MIT | in the repo only, **not bundled** |
| `patches/lsb-linkshell-zone-backlog.patch` | GPL-3.0 (LandSandBoat derivative) | in the repo only |
| Ashita v4 + server plugins | GPL-3.0 / each server's terms | **no** — comes with the server's client install |
| wine: Sikarugir 10.0 (*Install wine…*) | LGPL 2.1 | **no** — fetched by Setup from Sikarugir's own GitHub releases on the user's Mac |
| wine: athei `wine-cx-26.3.0-1` ("wine-coop", the game's Wine) | LGPL 2.1 | **no** — fetched by `scripts/game-wine.sh` from athei/wine-build's own GitHub release on the user's Mac (pinned size and SHA-256), or already on the Mac |
| aria2 1.35.0 (`aria2c`, HorizonXI's torrents) | GPL-2.0-or-later | **no** — Homebrew's if installed, else fetched by `update-client.sh` from aria2's own GitHub release on the user's Mac (pinned SHA-256; its `COPYING` kept beside it) |
| CrossOver itself (the app, its proprietary add-ons) | proprietary, commercial | **no** — never used or shipped |
| FFXI game data | Square Enix, all rights reserved | **no** — never |

Our DXVK patches in `patches/` are derivative works of DXVK and are therefore **zlib**, not this
project's licence. That is deliberate: it is also what upstream DXVK requires for contributions,
so those fixes can be submitted without a relicensing problem.

**Wine and CodeWeavers, corrected 2026-10-14.** CodeWeavers publishes the source of the wine inside
CrossOver under LGPL 2.1. athei's `wine-cx-26.3.0-1` (athei/wine-build), the wine Play prefers
because the wrapper's own wine drops the client a second after login (`docs/WINE-BUILD.md`), is
built from that published source, so it is LGPL like any other wine. What is proprietary is
CrossOver the product, not the wine source. This project redistributes no wine binary at all:
*Install wine…* downloads Sikarugir's LGPL build from Sikarugir's own GitHub releases on the user's
Mac, and since b60 Setup fetches the patched wine the same way: `scripts/game-wine.sh` downloads
`wine-cx-26.3.0-1-macos-x86_64.tar.xz` from athei/wine-build's own release (pinned there by size and
SHA-256, the aria2 model) into the folder the user chose, or it is found where it is already
installed. Its source is CodeWeavers' published LGPL source and athei/wine-build's build scripts,
both public. Shipping either wine inside our image would bring the LGPL's source/relink
obligations with it.

## On "it's on GitHub with an open licence, so it's safe"

It is not, and this is worth being blunt about because the failure mode is expensive.

A LICENSE file is a *claim of ownership*, not proof of it. If someone copies proprietary code
and attaches MIT to it, they had no right to grant that licence, so nobody downstream receives
a valid one. "It said MIT on GitHub" is not a defence — the liability follows whoever ships
the result. A convincing repackage of a commercial product with a permissive licence attached
is the **most** dangerous case, precisely because it looks clean.

The safe test is provenance, not the licence file: does the code trace back to a project that
genuinely owns it?

## Why we do not need a CrossOver substitute at all

CrossOver is CodeWeavers' **commercial distribution of wine** plus proprietary additions.
Wine itself is LGPL 2.1 and free for anyone to use, modify and redistribute.

So the answer is not to find a clone of CrossOver. It is to use **real wine**:

- **WineHQ's official macOS build** (`wine-stable`, currently 11.0) — WineHQ's own release,
  LGPL 2.1, unambiguous provenance.
- Or wine built from source, which is the fully clean option and lets us carry our own patches.
  CodeWeavers' published wine source counts: athei's `wine-cx` is exactly that.

Homebrew marks the official cask as failing the macOS Gatekeeper check. That is a
**notarisation** gap, not a licensing one, and it does not affect us: we sign and notarise our
own `.dmg` with the project's Developer ID anyway.

Things to check while shopping for an engine: Kegworks and Wineskin ship *both* pure-wine
engines and CrossOver-derived ones (names containing `CX`, e.g. `WS12WineCX64Bit`). A `CX` engine
is fine when it is built from CodeWeavers' published LGPL source; it is not fine when its
binaries were lifted out of a CrossOver app bundle. Check the provenance, not the name.

## Current status of the shipped wrapper

**Corrected 2026-08-14.** An earlier version of this file said the wrapper in use (`siku.app`)
was CrossOver-derived. It is not, and that mistake made bundling look blocked when it wasn't.

The wrapper *Install wine…* assembles runs [Sikarugir](https://github.com/Sikarugir-App/Sikarugir)
wine 10.0 — an open-source Wineskin fork of upstream WineHQ, **LGPL 2.1**. `wine --version`
reports `wine-10.0 (Sikarugir)`, the binaries carry no CodeWeavers strings, and `ntdll.so`
carries upstream wine's new-WoW64 strings rather than CodeWeavers' `wine32on64`. Since
2026-08-21 Play prefers athei's `wine-cx` when it is installed (see above).

The wrapper *does* contain CrossOver leftovers — `Frameworks/moltenvkcx/`,
`SharedSupport/wine.cx32bak/`, `SharedSupport/prefixcx24/` — but nothing in the live path loads
any of them, and they are excluded from any package (and can be deleted outright, reclaiming
about 845 MB). Evidence and md5s: [`docs/BUNDLING.md`](docs/BUNDLING.md).

So every component in the live stack is redistributable, and bundling wine for a public beta is
a packaging job — LGPL source/relink obligations for wine, nothing more. Tracked in
`docs/PHASE2-PACKAGING.md`.
