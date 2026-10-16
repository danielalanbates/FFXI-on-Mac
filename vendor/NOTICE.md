# vendor — third-party binaries

Everything here ships inside `FFXI-on-Mac.app/Contents/Resources/` (`app/bundle.sh`), so the
renderer and the x87 fix need no download. `ashita-send.exe` is this project's own (below).
`bundle.sh` also copies [`licenses/`](licenses) to `Contents/Resources/ThirdPartyNotices/` and
`LICENSE` to `Contents/Resources/LICENSE`;
`scripts/package.sh` adds `LICENSE.txt` and a combined `Third-Party Notices.txt` to the disk
image. `dxvk.conf` is this project's own file. Checked against the tree on 2026-10-14.

| File | Upstream | Source | Modified | Licence |
| --- | --- | --- | --- | --- |
| `d3d8to9.dll` | [crosire/d3d8to9](https://github.com/crosire/d3d8to9) | v1.15.1 (a1246e6, 2026-08-09) | no | BSD 3-Clause |
| `dxvk-1.10.3-x32-d3d9-horizonxi.dll` | [doitsujin/dxvk](https://github.com/doitsujin/dxvk) | v1.10.3 + `patches/dxvk-1.10.3-horizonxi-fencewait.patch`, rebuilt 2026-08-20 (2da0ccb) | **yes** | zlib/libpng |
| `libMoltenVK-1.4.2.dylib` | [KhronosGroup/MoltenVK](https://github.com/KhronosGroup/MoltenVK/releases/tag/v1.4.2) | v1.4.2 release (30bd913, 2026-09-26) | no (re-signed) | Apache 2.0; includes cereal (BSD 3-Clause) |
| `x87sidecar-coop` | [athei/x87sidecar](https://github.com/athei/x87sidecar) | cooperative build of upstream 238a214 (5fe2410, 2026-08-19); Rosetta `decode_opcode` pattern changed for macOS 27's libRosettaRuntime 2026-09-24 (**3c7c2f6**) | **yes** | MIT |
| `x87sidecar_entitled` | [athei/x87sidecar](https://github.com/athei/x87sidecar) `rosetta_loader` | upstream 238a214 + `patches/x87sidecar-attach-pid.patch` (5fe2410, 2026-08-19) | **yes** | MIT |
| `ashita-send.exe` | this project's own: [`tools/ashita-send.c`](../tools/ashita-send.c) | `scripts/build-ashita-send.sh`: Homebrew mingw-w64 14.0.0 / GCC 16.2.0, i686, `-static -s`, no PE timestamp (2026-10-15) | n/a | this project's `LICENSE`; contains the mingw-w64 runtime (ZPL 2.1) and libgcc (GCC Runtime Library Exception) |

SHA-256 of the vendored files:

```
ab6bf7a9a9f4b3e66a75ca038d8d10289c88acbfe8d52c3b5a8a9a259cb26cd5  d3d8to9.dll
e5f1a6b9698d36f3b4e50c4cf7e4070a85a43e27c6eb46f50c8f345b6c565490  dxvk-1.10.3-x32-d3d9-horizonxi.dll
aef00b13bcc808adf15b85bef9ae67393d92be7ed5dfe41cad16fa809e4a4c5f  libMoltenVK-1.4.2.dylib
bdb3923da4517019d2822e93d3df5393d01733b14c61daae9afb766ad92ef2c7  x87sidecar-coop
96155993ed7385e0361b53d38d458918540279edb372a14223a0df162eed7337  x87sidecar_entitled
b6dba2d935d4a601f4d1eb08fc645aa1178d295eac7272dd67e5f128e1928ff1  ashita-send.exe
```

MoltenVK's release tar: SHA-256 `f95765a6229cb7b915990a2890ce12ebe36a730b021545d3d52ae69ce4c4024e`.
Copyright The Brenwill Workshop Ltd. / Khronos Group. The dylib statically links SPIRV-Cross and
SPIRV-Tools (Apache 2.0) and cereal (BSD 3-Clause, pinned a56bad8 by MoltenVK 1.4.2).

## Licence texts

`licenses/README.txt` is the index (what ships, modified or not, copyright holders). Canonical
texts, fetched from upstream on 2026-10-14: `d3d8to9-BSD-3-Clause.txt` (tag v1.15.1),
`DXVK-zlib.txt` (tag v1.10.3), `MoltenVK-Apache-2.0.txt` (tag v1.4.2; MoltenVK has no NOTICE
file), `cereal-BSD-3-Clause.txt` (a56bad8), `x87sidecar-MIT.txt` (identical to upstream master).
`mingw-w64-runtime-ZPL-2.1.txt` is the `COPYING` of Homebrew's mingw-w64 14.0.0_3, added
2026-10-15 for the runtime start-up code linked into `ashita-send.exe`.

## Signing, as `bundle.sh` actually does it

`HXI_SIGN_ID` (a certificate hash), else the first Developer ID Application identity in the
keychain; `HXI_ADHOC=1` forces ad-hoc.

1. `xattr -c` on the whole staged bundle (iCloud/Drive detritus makes codesign refuse).
2. `x87sidecar-coop`: hardened runtime + secure timestamp, no entitlements (the notary rejects
   nested executables without a timestamp; measured 2026-08-20).
3. `x87sidecar_entitled`: hardened runtime + `x87sidecar-entitlements.plist`, which holds
   `com.apple.security.cs.debugger` only. `get-task-allow` is deliberately absent: the notary
   rejects any submission containing it.
4. `audiofollow.dylib` and `libMoltenVK-1.4.2.dylib`: hardened runtime + secure timestamp
   (v3.9's MoltenVK was ad-hoc, which alone blocks notarisation).
5. The app last, hardened runtime, **without `--deep`**, so the nested signatures above are
   sealed as they are. Signing a nested binary after the app breaks the app's seal.
6. `codesign --verify --deep --strict`.

Ad-hoc builds follow the same order with `-s -` (the coop sidecar keeps its own signature).

## x87sidecar

Patches Rosetta 2's x87 emulation with a native ARM64 JIT. FFXI's 32-bit client does its
floating-point math in x87, which stock Rosetta runs at roughly 1% of native speed
(`docs/X87-WALL.md`); in-world that was ~11 fps stock vs 28.5 with the sidecar (August), and
37.9–51 fps medians on macOS 27.0 (`docs/BETA-59.md`).

- `x87sidecar-coop` is the one Play uses: the patched wine reads `ROSETTA_X87_PATH` and runs the
  game under it cooperatively (`docs/WINE-BUILD.md`). On by default on every macOS from b59.
- `x87sidecar_entitled` is the attach-by-pid mode (`--attach <pid>`), which needs the debugger
  entitlement. Broken on macOS 26.5.2+ (cross-process i-cache flush); kept for older systems.
- **Known gap:** the 2026-09-24 macOS 27 change to `x87sidecar-coop` has no source or patch in
  this repo, so it cannot be rebuilt after the next Rosetta update. Recovering it (diff against
  a fresh 238a214 build, or redo from upstream) is open.

## ashita-send.exe

This project's own Windows program, not a third-party binary; it is vendored here so a bundle
build needs no mingw-w64. `app/bundle.sh` copies it to `Contents/Resources/ashita-send.exe`. It is
not codesigned (a Windows program; the app's seal covers it as a resource).

When the Addons… sheet is applied while that world's client is running, the launcher runs it
under the game's own wine, in the game's prefix, with the running wineserver's sync mode, and it
hands the changed `/addon load|unload` and `/load|/unload` lines to Ashita's Thirdparty plugin
through the plugin's own shared memory (`WindowerMMFKeyboardHandler_<pid>`). Protocol, exit codes
and what it never sends: the comment at the top of `tools/ashita-send.c`; launcher side:
`app/Sources/HorizonXILauncher/LiveAddons.swift`; tests: `scripts/tests/ashita-send-test.sh`
(a fake plugin, throwaway prefix, never with a game running); details: `docs/BETA-66.md` (B).

Rebuild: `scripts/build-ashita-send.sh`. It fails unless the import table is KERNEL32 and the C
runtime only (UCRT `api-ms-win-crt-*`; no user32). Same source and toolchain give the same bytes
(checked: two builds, one SHA-256 above). Update the hash here when the source changes.

## Why these exact versions

DXVK 2.x and 3.x require Vulkan 1.3 and the `geometryShader` feature. Metal has no geometry
shaders, so MoltenVK can never expose one and those releases can never run on Apple Silicon —
3.0.2 loads, enumerates the M1, and rejects it. 1.10.3 predates that requirement. Gcenx's macOS
repack of 1.10.3 omits `d3d9.dll` entirely, so it has to come from doitsujin's release.
MoltenVK 1.4.2 has been bundled since beta 46 and installed into the launch wine
(`docs/CHECKPOINT-2026-09-26.md`; hosted post-warmup average 49.1 fps that day).

The DXVK patch's contents (two upstream fixes, the read-back fence wait, the probes) are
described in [`../patches/README.md`](../patches/README.md) and `docs/MAX4K.md`.
