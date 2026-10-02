# Fog on Metal — what is actually broken, and where to pick this up

Session of 2026-08-11. Goal: reach FFXI's 30 fps cap **with fixed-function fog working**,
rather than with fog bypassed as shipped in 2.1.

**Status: fog is fixed.** Root cause found and corrected — a one-word typo in DXVK 1.10.3
that is harmless on desktop Vulkan and fatal on Metal. See §0. The frame-rate goal is
partly met: 29 fps at menus and light scenes, but 7–9 fps in a crowded city hub, so 30 fps
is *not* universal. Sections 2–3 below are the diagnostic trail that led to the fix and are
kept because they document what was ruled out.

---

## 0. Root cause and fix

`src/d3d9/d3d9_fixed_function.cpp`, in `D3D9FFShaderCompiler::compileShader()`:

```cpp
info.pushConstOffset = m_pushConstOffset;
info.pushConstSize   = m_pushConstOffset;   // <-- should be m_pushConstSize
```

For fixed-function **pixel** shaders `setupRenderStateInfo()` sets `m_pushConstOffset = 0`
and `m_pushConstSize = offsetof(D3D9RenderStateInfo, pointSize)`. The typo therefore makes
`info.pushConstSize` **zero**, and `DxvkShader::defineResourceSlots()` guards on it:

```cpp
if (m_info.pushConstSize) {
  mapping.definePushConstRange(m_info.stage, m_info.pushConstOffset, m_info.pushConstSize);
}
```

So `definePushConstRange` is never called for the fragment stage, and the pipeline layout's
`VkPushConstantRange.stageFlags` never includes `VK_SHADER_STAGE_FRAGMENT_BIT`.

Desktop Vulkan drivers bind push constants to all stages regardless and never notice.
MoltenVK honours the declared range, so `render_state_t` — fog colour, fog scale, fog end,
fog density, alpha ref — arrived as **zeroes** in every fixed-function fragment shader.
With `fog_end = 0`, `clamp((fog_end - depth) * fog_scale, 0, 1)` is 0, so every lit surface
became `mix(fog_color, colour, 0) == fog_color`, and FFXI's fog colour there is black.

That is the black world, across four sessions. Sky, fonts and the 2D UI never go through
the FFP fog path, which is exactly why they always looked right.

The fix is `info.pushConstSize = m_pushConstSize;`. Verified: full daylight render with
correct atmospheric haze at the main menu and in Selbina, fog enabled, no bypass.

This is an upstream DXVK bug worth reporting — it affects any Vulkan driver that respects
push-constant stage flags strictly.

**Update 2026-09-04:** already fixed in DXVK 2.x (`info.pushConstSize = sizeof(D3D9RenderStateInfo)`), so there is nothing to file against the EOL 1.10.3 branch. See `docs/UPSTREAM.md` §3a for the assessment.

---

## 1. DXVK is not actually incompatible with modern MoltenVK

The previous conclusion — "DXVK only runs on MoltenVK 1.2.10, and it works there because
1.2.10 lies about `robustBufferAccess`" — was wrong about the cause. The blocker is three
lines in DXVK's own D3D9 frontend, `src/d3d9/d3d9_device.cpp`:

```cpp
enabled.core.features.geometryShader     = VK_TRUE;
enabled.core.features.robustBufferAccess = VK_TRUE;
enabled.core.features.shaderCullDistance = VK_TRUE;
```

All three are demanded unconditionally. Metal has none of them. MoltenVK 1.2.10 falsely
reports all three as supported, so device creation succeeds; 1.3+ correctly refuse and
`vkCreateDevice` fails with `VK_ERROR_FEATURE_NOT_PRESENT`. That is what made macOS DXVK
look stuck on 1.2.10.

None of the three is actually needed by D3D9:

- `geometryShader` — used only by meta ops that are already guarded at their call site.
- `robustBufferAccess` — governs out-of-bounds behaviour only, not in-bounds correctness.
- `shaderCullDistance` — D3D9 user clip planes need *clip* distance, which Metal has.

Changing them to `supported.core.features.X` lets **DXVK 1.10.3 run on MoltenVK 1.4.1**.
Verified: device created, game renders, 29 fps. Patch in
`patches/dxvk-1.10.3-metal-features-and-fog-probes.patch`.

Note this cuts the other way too: the argument that DXVK's 29 fps "stands on a driver that
lies about its capabilities" is no longer true. It now runs on an honest one.

DXVK 2.x remains genuinely out of reach — relaxing its requirements walks into
`nullDescriptor` and `khrPipelineLibrary`, which are core to its 2.x pipeline architecture.

## 2. The black world is the fog factor, and nothing else

Proven by elimination, all on MoltenVK 1.4.1 with the patched DXVK:

| build | result |
|---|---|
| fog enabled | sky + UI correct, **all lit geometry black** |
| `DXVK_DEBUG_FOGFACTOR_ONE` (fog code compiled and executing, factor forced to 1.0) | **full correct render, 29.4 fps** |

The second row matters: everything else about the patched build — the relaxed features,
MoltenVK 1.4.1, argument buffers — is fine. The entire defect is that the fog factor
evaluates to 0 for world geometry, so `mix(fog_color, colour, 0) == fog_color`, and FFXI's
fog colour here is black.

Painting the factor to the screen (`DXVK_DEBUG_FOGFACTOR`) confirms it directly: world
geometry is uniformly black, i.e. factor 0 everywhere, not a gradient.

## 3. The generated Metal is correct — the data is not

Dumped with `MVK_CONFIG_SHADER_DUMP_DIR` (see `docs/ffp-fragment-shader.metal`). The
fixed-function fragment shader is well-formed:

```metal
constant bool fog_enabled_tmp [[function_constant(1227)]];
constant uint pixel_fog_mode_tmp [[function_constant(1229)]];
...
fragment main0_out main0(..., constant spvDescriptorSetBuffer0& spvDescriptorSet0 [[buffer(0)]],
                         constant render_state_t& render_state [[buffer(1)]], ...)
...
_139 = precise::clamp((render_state.fog_end - _123) * render_state.fog_scale, 0.0, 1.0);
```

`render_state_t` lands at `[[buffer(1)]]`, `spvDescriptorSet0` at `[[buffer(0)]]` — **no
collision**, contrary to the earlier working theory. The fog maths, the function constants
and the struct layout are all right.

So the shader is correct and the inputs are wrong. `DXVK_DEBUG_SHOW=end` paints
`fog_end * 0.001` with fog disabled: the result is black, i.e. **`fog_end` reads as ~0**.

`render_state_t` is declared `StorageClassPushConstant` — it is a Vulkan **push constant
block**, not a uniform buffer (`d3d9_fixed_function.cpp:224`). DXVK does push the fog
values (`UpdateFog()` → `UpdatePushConstant<FogColor|FogScale|FogEnd|FogDensity>` →
`DxvkContext::pushConstants`). On Metal they arrive zeroed.

Ruled out: argument buffers. Tested with `MVK_CONFIG_USE_METAL_ARGUMENT_BUFFERS=1` and
without — black either way.

**Conclusion: fixed-function render state reaches the fragment stage as zeroes under
MoltenVK. The push-constant delivery path is the defect.**

## 4. Where to pick this up

In rough order of expected value:

1. **Confirm the scope of the zeroing.** `alpha_ref` lives in the same push-constant block.
   If alpha testing also misbehaves, the whole block is dead and this is a clean MoltenVK
   push-constant bug worth reporting upstream. If alpha test works, only part of the block
   is stale and the bug is narrower — likely a missed re-bind when only push constants
   change between draws.
2. **Move `render_state_t` out of push constants into a uniform buffer** in DXVK's D3D9
   frontend. This is the real fix if MoltenVK's push-constant path is unreliable, and it
   does not depend on an upstream MoltenVK release. Touches `SetupRenderStateBlock`, the
   binding setup in `setupRenderStateInfo`, and `UpdatePushConstant`.
3. **Bisect MoltenVK versions** between 1.2.10 and 1.4.1 for push-constant handling; check
   `MVKPipeline`'s `_pushConstantsMTLResourceIndexes` and whether the fragment stage's
   push-constant buffer is re-encoded on `vkCmdPushConstants`.

## 5. Reproducing the harness

```sh
# build (needs meson, ninja, i686-w64-mingw32-gcc from Homebrew)
git clone --depth 1 --branch v1.10.3 https://github.com/doitsujin/dxvk.git
cd dxvk && git apply .../patches/dxvk-1.10.3-build-gcc14.patch
#   plus: add <cstdint>/<cstddef> to headers under src/ that use fixed-width ints (GCC 14)
git apply .../patches/dxvk-1.10.3-metal-features-and-fog-probes.patch
meson setup --cross-file build-win32.txt --buildtype release \
  -Denable_d3d10=false -Denable_d3d11=false -Denable_dxgi=false build32
ninja -C build32 src/d3d9/d3d9.dll
```

Install the DLL to **every** path the game can load it from — missing one silently tests
the old build, which cost real time this session:

```
prefix10/drive_c/HorizonXI/d3d9.dll
prefix10/drive_c/HorizonXI/bootloader/d3d9.dll
SquareEnix/FINAL FANTASY XI/d3d9.dll
SquareEnix/PlayOnlineViewer/d3d9.dll
prefix10/drive_c/windows/syswow64/d3d9.dll
```

Debug switches added by the patch (all env vars, read at shader-compile time):

| var | effect |
|---|---|
| `DXVK_DEBUG_FOGFACTOR` | paint the fog factor as greyscale |
| `DXVK_DEBUG_FOGFACTOR_ONE` | force factor 1.0, fog code still compiled and run |
| `DXVK_DEBUG_SHOW=end\|scale\|density\|depth\|color` | paint that fog input as the colour |

### Driving the game headlessly

- The character-select / main-menu background **is** a valid oracle: on a working build it
  is a full textured landscape, on a broken one a black silhouette under a correct sky.
  No login needed to tell them apart.
- `CGEventPostToPid` does **not** drive FFXI. The window needs real focus. Activation only
  succeeds after hiding every other regular app (`NSRunningApplication.hide()`), then
  retrying `activateWithOptions_` until `frontmostApplication()` matches — see
  `scripts/drive2.py` pattern in this doc's session notes.
- Log out with `/shutdown` in game chat (Enter a few times to open the chat line first)
  rather than killing the process, or the character stays online server-side.
