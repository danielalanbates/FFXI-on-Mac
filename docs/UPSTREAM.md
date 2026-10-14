# Upstream reports

Two bugs found in this project's own debugging that are not ours to fix. They were written up to
be filed verbatim; **read the staleness gate below before filing** — #1 has since been superseded.
Nothing here has been filed. Filing is a public action on someone else's tracker and is Daniel's call.

Environment when these were measured: MacBook Pro M1 (Apple M1, 8 GB), macOS 26.5, wine-10.0
(Sikarugir / Gcenx build) running x86_64 under Rosetta, 32-bit Windows game (Final Fantasy XI).

> **⚠ Staleness gate — read before filing (updated 2026-09-04).** These reports were measured on
> the **older stack above**: M1, wine-10.0 (Gcenx), **MoltenVK 1.2.10**. The project has since moved to
> a MacBook Pro **M2 Pro**, **athei `wine-cx-26.3.0-1`** (new-wow64), and **MoltenVK 1.4.1**. Filing on
> someone else's tracker is a public action — **re-verify each report still reproduces on the current
> versions first**, or it may describe an already-fixed or misdiagnosed bug. In particular:
>
> - **#1 (MoltenVK duplicate buffer binding) is SUPERSEDED — do not file.** `docs/FOG-INVESTIGATION.md`
>   §3 later disproved it on MoltenVK 1.4.1: `render_state_t` binds to `[[buffer(1)]]` and
>   `spvDescriptorSet0` to `[[buffer(0)]]` — **no collision** — and argument buffers make no difference.
>   The black world it blamed on MoltenVK was actually the DXVK `pushConstSize` typo in §3a below (a
>   zero-sized fragment push-constant range), which is version-independent and already fixed in DXVK 2.x.
> - **#2 (wined3d drops BC/DXT)** was found on wine-10.0's wined3d Vulkan backend. The shipped stack
>   renders through DXVK, not wined3d, so it is untested on the current athei wine — confirm the
>   `DXT1`–`DXT5` rows are still missing from `init_vulkan_format_info` on current wine before filing.

---

## 1. MoltenVK — SPIRV-Cross assigns two uniform buffers to the same Metal binding

> **SUPERSEDED / DO NOT FILE (2026-09-04).** Disproven on MoltenVK 1.4.1 — see the staleness gate
> at the top and `docs/FOG-INVESTIGATION.md` §3. No buffer collision occurs; the black world was the
> DXVK `pushConstSize` typo (§3a), already fixed in DXVK 2.x. The report below is kept as the
> historical trail on MoltenVK 1.2.10 only.

**Where:** KhronosGroup/MoltenVK
**Affects:** MoltenVK 1.2.10. Any D3D9 fixed-function title under DXVK 1.10.3.
**Severity:** total — the application renders nothing at all.

Compiling DXVK's D3D9 fixed-function fragment shader produces Metal source in which
`render_state_t` and `D3D9FixedFunctionPS` are both assigned `[[buffer(0)]]`:

```
[mvk-error] VK_ERROR_INITIALIZATION_FAILED: Shader library compile failed (Error code 3):
program_source:112:135: error: cannot reserve 'buffer' resource location at index 0
fragment main0_out main0(main0_in in [[stage_in]],
                         constant render_state_t& render_state [[buffer(0)]],
                         constant D3D9FixedFunctionPS& consts [[buffer(0)]], …)
[mvk-error] VK_ERROR_INVALID_SHADER_NV: Fragment shader function could not be compiled into pipeline.
```

DXVK then reports `DxvkGraphicsPipeline: Failed to compile pipeline` for every fixed-function
pipeline. Its own HUD, which does not use those shaders, still draws — so the window shows a
frame-rate counter and draw-call count over a completely black scene, which is a very misleading
failure mode.

**Workaround:** `MVK_CONFIG_USE_METAL_ARGUMENT_BUFFERS=1`. With argument buffers the collision
disappears, pipeline compilation succeeds, and the game renders.

**Suggested fix:** the descriptor-binding assignment should not hand the same Metal buffer index
to two distinct descriptors when argument buffers are off.

---

## 2. wine — wined3d's Vulkan backend rejects every BC/S3TC texture format on MoltenVK

**Where:** WineHQ Bugzilla, component `wined3d`
**Affects:** wine 10.0, `HKCU\Software\Wine\Direct3D` `renderer=vulkan`, on macOS/MoltenVK.
**Severity:** high — every compressed texture in every D3D8/D3D9 game is dropped, so 3D
content renders untextured. **Fix is five table rows; patch below.**

With the Vulkan renderer selected, adapter init logs:

```
warn:d3d:init_vulkan_format_info Unsupported format WINED3DFMT_DXT1
warn:d3d:init_vulkan_format_info Unsupported format WINED3DFMT_DXT2 … DXT5
warn:d3d:init_vulkan_format_info Unsupported format WINED3DFMT_BC1_TYPELESS … BC7_TYPELESS
```

The game then renders correct geometry with correct fonts and UI — those textures are
uncompressed — and every model and terrain surface as flat untextured grey.
See `docs/img/vk-untextured.png` beside `docs/img/gl-charselect.png`, which is the same screen on
the OpenGL renderer.

**Root cause, confirmed in the source.** `init_vulkan_format_info` in `dlls/wined3d/utils.c`
matches against a static table that contains `WINED3DFMT_BC1_UNORM`..`BC7_UNORM_SRGB` but none of
`WINED3DFMT_DXT1`..`DXT5`. Those are *different enum values* — the DXT ids are FourCCs
(`'DXT1'` = 0x31545844), used by every D3D8/D3D9 title. The lookup misses and the function returns
before it ever calls `vkGetPhysicalDeviceFormatProperties`, so this is not a driver query result
at all. `init_format_texture_info`, the GL backend's table, does carry the DXT rows — which is why
the same game textures correctly on `renderer=gl`.

**Patch:** five rows.

```c
{WINED3DFMT_DXT1, VK_FORMAT_BC1_RGBA_UNORM_BLOCK, },
{WINED3DFMT_DXT2, VK_FORMAT_BC2_UNORM_BLOCK,      },  /* premultiplied alpha */
{WINED3DFMT_DXT3, VK_FORMAT_BC2_UNORM_BLOCK,      },
{WINED3DFMT_DXT4, VK_FORMAT_BC3_UNORM_BLOCK,      },  /* premultiplied alpha */
{WINED3DFMT_DXT5, VK_FORMAT_BC3_UNORM_BLOCK,      },
```

Verified by binary-patching the shipped `wined3d.dll` to the same effect
(`scripts/dxt-patch.py`): every texture appears, and the game renders correctly in-zone on the
Vulkan renderer at 2-3x the OpenGL frame rate.

Supporting evidence that the hardware was never the problem:

- `MTLDevice.supportsBCTextureCompression` is `true`, both natively and in an x86_64 process
  under Rosetta (`scripts/bc-probe.swift`).
- The behaviour is identical on MoltenVK 1.2.10 and on 1.4.2, so it is not a MoltenVK version
  issue.
- DXVK 1.10.3 on the same MoltenVK does **not** complain about BC formats at all, which suggests
  the formats are in fact available and wined3d's acceptance check is what rejects them.

Also visible on the same run, and probably worth a separate report — the Vulkan backend has no
representative for a dozen fixed-function render states:

```
err:d3d:validate_state_table State STATE_RENDER(WINED3D_RS_COLORKEYENABLE) should have a representative.
… LIGHTING, SPECULARENABLE, COLORVERTEX, NORMALIZENORMALS, RANGEFOGENABLE, VERTEXBLEND,
  AMBIENTMATERIALSOURCE, DIFFUSEMATERIALSOURCE, EMISSIVEMATERIALSOURCE,
  SPECULARMATERIALSOURCE, LOCALVIEWER
```

---

## 3. DXVK — the two fixes in our patch, and whether they are worth filing

Both live in `patches/dxvk-1.10.3-horizonxi.patch`. Assessed 2026-08-11; the honest answer is
that neither is a good upstream PR, for different reasons.

### 3a. Zero-sized fragment push-constant range for fixed-function pixel shaders

`src/d3d9/d3d9_fixed_function.cpp` assigned `info.pushConstSize = m_pushConstOffset`. For
fixed-function *pixel* shaders that offset is 0, so `DxvkShader::defineResourceSlots` skipped
`definePushConstRange` and the pipeline layout never listed `VK_SHADER_STAGE_FRAGMENT_BIT`.
Desktop drivers bind push constants regardless; MoltenVK honours the declaration, so
`render_state_t` — fog colour, scale, end, density, alpha ref — arrived zeroed. `fog_end == 0`
clamps the fog factor to 0 and every lit surface renders in the fog colour, which FFXI sets to
black. Sky, fonts and UI skip FFP fog, which is exactly why they always looked correct.

**Do not file.** This is already correct in DXVK 2.x (`info.pushConstSize =
sizeof(D3D9RenderStateInfo)`), which independently confirms the diagnosis. 1.10.3 is an EOL
branch and a PR against it would be closed. It is documented here because anyone else pinned to
1.10.3 for MoltenVK reasons will hit it, and because the symptom — a black world with a correct
sky — is very hard to attribute without knowing this.

### 3b. D3D9 demanding Vulkan features Metal does not have

`src/d3d9/d3d9_device.cpp` required `geometryShader`, `robustBufferAccess` and
`shaderCullDistance` unconditionally for D3D9. Metal has none of the three, and D3D9 needs none
of them. Making them conditional is what let DXVK 1.10.3 run on **MoltenVK 1.4.1** instead of
only on 1.2.10 — the one version that falsely claimed to support them.

**Probably not fileable either.** Upstream DXVK does not target Metal or MoltenVK, so "relax a
requirement because one non-target driver lacks it" is not a change they have a reason to take,
and on 1.10.3 it has the EOL problem as well. The right home for it is a MoltenVK-oriented DXVK
fork, or MoltenVK itself growing honest emulation of the features.

Filing either remains Daniel's call — nothing has been submitted.
