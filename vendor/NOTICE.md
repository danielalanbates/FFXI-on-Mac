# vendor — third-party binaries

Redistributed so `HXI_METAL=1 ./scripts/install.sh` works without a network round-trip. Both are
freely redistributable; neither is modified.

| File | Upstream | Version | Licence |
| --- | --- | --- | --- |
| `d3d8to9.dll` | [crosire/d3d8to9](https://github.com/crosire/d3d8to9) | v1.15.1 | BSD 3-Clause |
| `dxvk-1.10.3-x32-d3d9.dll` | [doitsujin/dxvk](https://github.com/doitsujin/dxvk) `x32/d3d9.dll` | v1.10.3 | zlib |
| `x87sidecar_entitled` | [athei/x87sidecar](https://github.com/athei/x87sidecar) `rosetta_loader` | built 2026-08-12 | MIT |

## x87sidecar_entitled

Patches Rosetta 2's x87 emulation with a native ARM64 JIT — FFXI's 32-bit client runs its
floating-point math through x87, which Rosetta emulates at roughly 1% of native speed (see
`docs/X87-WALL.md`); this is the fix, worth 11.3→28.5 fps in-world at max settings. Built from
source with one local patch, `../patches/x87sidecar-attach-pid.patch`, adding an `--attach <pid>`
mode: without it the sidecar can only patch a process it launches itself, but Ashita runs the
actual game in a child process (`horizon-loader.exe`) that a launch-time wrap never reaches.

Built with the `get-task-allow` and `com.apple.security.cs.debugger` entitlements
(`x87sidecar-entitlements.plist`) required to attach to another process at all. `bundle.sh`
re-signs it individually with that plist *after* the app's own deep-sign, which otherwise
overwrites it with the app's entitlements (none) and silently breaks attaching.

**Why these exact versions.** DXVK 2.x and 3.x require Vulkan 1.3 and the `geometryShader`
feature. Metal has no geometry shaders, so MoltenVK can never expose one and those releases can
never run on Apple Silicon — 3.0.2 loads, enumerates the M1, and rejects it. 1.10.3 predates that
requirement. Gcenx's macOS repack of 1.10.3 omits `d3d9.dll` entirely, so it has to come from
doitsujin's release.

## dxvk-1.10.3-x32-d3d9-nofog.dll

DXVK 1.10.3 (doitsujin/dxvk, zlib/libpng licence), built here from the v1.10.3 tag with two
patches in `../patches/`:

* `dxvk-1.10.3-build-gcc14.patch` — build fixes only. GCC 14 / mingw-w64 14 no longer include
  `<cstdint>` transitively, and mingw now defines `_D3DDEVINFO_RESOURCEMANAGER` itself, so DXVK's
  old workaround became a redefinition.
* `dxvk-1.10.3-ffp-fog.patch` — the functional change. Fixed-function fog is bypassed, because it
  reads `render_state_t`, the uniform block MoltenVK mis-binds on Metal. See docs/PATHWAYS.md.

Build: `meson setup --cross-file build-win32.txt --buildtype release builddir32 &&
ninja -C builddir32 src/d3d9/d3d9.dll`, then `i686-w64-mingw32-strip -s`.

The unpatched `dxvk-1.10.3-x32-d3d9.dll` is kept beside it for comparison.

## libMoltenVK-1.4.2.dylib
MoltenVK v1.4.2, unmodified macOS dylib from https://github.com/KhronosGroup/MoltenVK/releases/tag/v1.4.2
(release tar SHA-256 f95765a6229cb7b915990a2890ce12ebe36a730b021545d3d52ae69ce4c4024e).
Copyright The Brenwill Workshop Ltd. / Khronos Group. Licensed under the Apache License 2.0.
