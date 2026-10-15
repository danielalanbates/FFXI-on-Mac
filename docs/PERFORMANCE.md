# Where the frame time actually goes

Written 2026-08-11. This document replaces the performance model in `FINDINGS.md` and
`BATCHING.md`. Those two described a renderer-bound game and proposed a draw-call batcher as the
route to 30 fps. **That model was wrong**, and the measurements below say why. Read this before
acting on anything in the older documents.

Everything here is measured on an M1 MacBook Pro (8 GB), macOS 26.5.2, at the character-select
scene unless stated otherwise. The instrumentation is in `patches/dxvk-1.10.3-horizonxi.patch`
(and `patches/d3d8to9_probe.hpp` for the layer above); the harness is `scripts/harness/bench.py`.

---

## The short version

| where the time goes | share of the frame |
| --- | --- |
| **FFXI's own code** | **~75%+** |
| DXVK's D3D9 state-setting entry points | ~6% |
| DXVK's draw submission | ~3% |
| `Present` — DXVK, MoltenVK, Metal, the GPU handoff | ~12% |
| d3d8to9 | ~6% (measured separately, on the rules screen) |
| Ashita's D3D8 proxy | not measurable as a cost — removing it makes the game *slower* |

**Skipping every single draw call — rendering literally nothing — moves character select from
12.0 fps to 10.7 fps.** It does not get faster. That one number settles the argument: the
translation stack is not what is costing the frame.

The frame rate is limited by how fast a 2002 32-bit x86 game engine runs under Rosetta, plus the
per-call overhead of the wrapper chain it is calling through. Neither is fixable by optimising
DXVK, MoltenVK, or the batching of draws.

**In the world it is worse, and for a different reason.** Standing still in a Mog House — one of
the lightest scenes in the game, ~850 draws — the client runs at **7.5 fps while using 13% of
one CPU core**, stalling ~120 ms per frame with the renderer idle. That is not slowness, it is
waiting, and it is the single biggest thing left to find. It has its own document:
**`docs/INWORLD-STALL.md`**, written as a bug report with everything already ruled out.

---

## How this was measured

Four probes were added to our DXVK build, each behind an environment variable so they cost
nothing when off:

| variable | what it records |
| --- | --- |
| `DXVK_FPS_LOG` | per second: fps, and per-frame draws / render passes / barriers / submits |
| `DXVK_PRESENT_PROBE` | per second: fps, ms spent **inside** `Present`, ms spent **outside** it |
| `DXVK_DRAW_PROBE` | per second: draw count, ms inside draws, ms inside D3D9 setters, and a histogram of every D3D9 API call by kind |
| `DXVK_SKIP_DRAWS` | isolation switch: accept draws and discard them |

`DXVK_FPS_LOG` matters on its own: it means the frame rate no longer has to be read off an
on-screen overlay, so every configuration is measured with the same instrument, headlessly, from
a script.

## What the probes said

**1. Present is cheap; the game is not.** At the rules-of-conduct screen — a static 2D dialog
with 380 draws — `Present` takes **0.04 ms** and the time between presents is pinned at
**37–40 ms**. At character select `Present` costs ~10 ms and the outside time is ~70 ms.

**2. Draws are cheap.** ~11,000 draws/second cost **19 ms of each second** inside DXVK. That is
**1.9 µs per draw** and under 2% of wall-clock time. DXVK's D3D9 layer is not slow.

**3. The API call volume is enormous.** Per second, at ~12 fps:

```
SetRenderState          140,000      SetStreamSource      12,574
SetVertexDeclaration     19,314      draws                12,250
SetTransform             16,876      SetFVF                9,639
SetSamplerState          15,886      SetVertexShader       9,675
SetTexture               15,850      SetTextureStageState 10,255
```

**~265,000 D3D9 calls per second — about 12,000 per frame, of which only ~560 are draws.**
FFXI issues roughly eleven `SetRenderState` calls per draw. Every one crosses FFXI → Ashita's
D3D8 proxy → d3d8to9 → DXVK. Only ~0.22 µs of the per-call cost is inside DXVK — but the two
layers above it were subsequently measured too, and they are not the answer either: d3d8to9 is
6% of the frame, and removing Ashita entirely makes the game *slower*. The volume is real; the
cost of carrying it is in the client.

**4. Removing the renderer changes nothing.** `DXVK_SKIP_DRAWS=1` at character select:
**10.7 fps**, versus 12.0 fps with the renderer doing its full job.

**5. Nothing ever exceeded 30 fps** — until the frame divisor was patched (below). Every
measurement in this project's history sits under 30. That is the client's own limiter.

---

## The frame limiter, and the one real win

FFXI limits itself to 60/n frames per second, where n is a divisor the client keeps in memory —
n = 2 (30 fps) by default. Under wine the limiter overshoots: at the static rules screen the
client is only **52% busy** yet still spends 38 ms per frame, well past the 33.3 ms the 30 fps
cap asks for.

Our `d3d9.dll` can now patch that divisor at start-up with `FFXI_FPS_DIVISOR=<n>`, using the same
signature scan and pointer walk as Ashita's own `fps` addon (done in the DLL because Ashita's
plugin host does not load in this install — see below). With `FFXI_FPS_DIVISOR=1` the client
was measured at **33.6 fps**, the first time this project has ever seen a frame above 30.

This does not help heavy scenes, which are nowhere near the cap. It helps exactly where the
client was holding itself back, which is normal play in ordinary zones.

60 fps mode is a setting the retail client supports; this is not a modification to game logic.

---

## Corrections to earlier conclusions

**Draw-call batching will not deliver 30 fps.** `BATCHING.md` measured a 9.9× instancing ratio
and concluded that collapsing 1,891 draws into ~191 would clear the bar. The premise was that
draw submission is what costs the frame. It is 3%. Even a perfect batcher that removed every
draw call would gain about what `DXVK_SKIP_DRAWS` gains, which is nothing. The
`DXVK_FF_INSTANCING` groundwork is left in place and left off; it is not the route.

**Render-pass churn is not the problem either.** FFXI spills DXVK's render pass ~59 times per
frame, 88% of those from `updateFramebuffer`, and the cause is real: the game detaches and
reattaches the depth-stencil ~24,000 times per run as it toggles `ZENABLE`/`ZWRITEENABLE`
between world geometry and UI. Keeping the depth attachment bound (`DXVK_KEEP_DEPTH=1`) is the
correct fix and it does remove those framebuffer changes — but at ~700 render passes per second
the whole phenomenon is worth under 2% of a frame, and keeping the attachment bound adds depth
load/store work that made the measured frame rate slightly *worse* (11.6 vs 12.9 fps). It is off
by default. A red herring, found and priced out.

**The Ashita overlay addons were never running.** The August `HANDOFF.md` §4 (now
`archive/docs-2026-08/`) called disabling them "the most promising thing left". They cannot be
disabled because they never load: Ashita.dll in this install reports interface version **4.16**
while every bundled plugin — `Addons`, `Nameplate`, `PacketFlow`, `Screenshot`, `Sequencer`,
`Thirdparty` — is built against **4.15**, so `PluginManager::Load` rejects all of them, and with the
`Addons` host rejected no Lua addon loads either. Every performance number this project has ever
taken was already addon-free. (This is also a real bug in Daniel's install worth fixing for gameplay
reasons: none of his 22 addons work.)

**Rosetta really is structural, and nothing in the wrapper escapes it.** `libd3dshared.dylib`,
`D3DMetal.framework`, `winemetal.so`, `libMoltenVK.dylib` and `wine` itself are all x86_64-only
in this wrapper — checked with `lipo -archs`. There is no native arm64 component anywhere in the
graphics path, so no part of the translation runs outside Rosetta.

---

## What is left that can move the number

Ranked by measured or expected value:

1. **`FFXI_FPS_DIVISOR=1`** — proven to allow >30 fps. Free.
2. **The client's own settings** — the dominant cost is the client's per-frame work, so the
   settings that reduce that work are the lever. Swept in `docs/SETTINGS-SWEEP.md`.
3. **Removing a wrapper hop.** 265,000 calls a second cross three proxies. dgVoodoo2 implements
   D3D8 directly on D3D11, which removes d3d8to9 entirely and lets DXMT (native Metal, no Vulkan
   and no MoltenVK) replace two more layers. Measured in `docs/PATHWAYS.md`.
4. ~~**Filtering redundant state in d3d8to9**~~ — d3d8to9 was subsequently built from source and
   instrumented: it is **6% of the frame**, so filtering inside it cannot pay. Recipe in
   `docs/D3D8TO9-BUILD.md`; one unverified observation there is that the mingw build measured
   ~15% faster than the shipped MSVC one, which is worth a proper A/B.

What will *not* move it: batching draws, instancing, MoltenVK tuning, render-pass merging,
different Vulkan settings. Those were the previous plan and they are all inside the 20%.
