# 4K at max settings — where the frames actually are

Updated 2026-08-14. Everything here is measured on the **local LandSandBoat server**, standing in
the same spot in Southern San d'Oria, 40-second samples, with x87sidecar attached and
`FFXI_FPS_DIVISOR=1`. Profile: `profiles/lsb-max4k.json`. Reproduce with:

    python3 inworld.py --tag <name> --boot lsb.ini --profile profiles/lsb-max4k.json --sample 40

## The number

**The 30 fps target is NOT met, and the entry below claiming it was is retracted.** The 46.8 fps
figure came from a change that breaks the game: see "Why the fast number is not real". The honest
number at 4K max is **~24 fps**.

4K, every FFXI graphics setting at maximum:

| configuration | fps median | draws/frame |
| --- | --- | --- |
| baseline, run A | 24.88 | 2440 |
| baseline, run B (same session as the fix) | 18.59 | 2102 |
| `MVK_CONFIG_PREFILL_METAL_COMMAND_BUFFERS=1` | 22.30 | 2100 |
| `DXVK_EARLY_BUFFER_COPY=1` | 21.84 | 2448 |
| `d3d9.presentInterval = 0` (no vsync) | 25.46 | 2406 |
| **`D3D9_RT_READBACK_NOWAIT=32`, run A** | **46.82** | 1824 |
| **`D3D9_RT_READBACK_NOWAIT=32`, run B** | **42.93** | 1876 |

Baseline varies by 6 fps between runs — in-game time of day and how many other characters are
standing in the square both move it.

**The flag is off by default.** It doubles the frame rate and breaks the game.

## Why the fast number is not real

Daniel found it in about a minute of play: NPCs blink in and out of existence roughly once a
second. `blinkprobe.py` takes a burst of frames 0.25 s apart in a static scene and diffs
consecutive ones:

| build | median | p90 | max | spikes (>3× median) |
| --- | --- | --- | --- | --- |
| `D3D9_RT_READBACK_NOWAIT=32` | 0.023 | 0.493 | 0.512 | **17 of 39** |
| unmodified | 0.021 | 0.023 | 0.026 | 0 of 39 |

The cause is exactly what "skip the wait" means: the GPU is still writing the buffer the game
then reads, so the visibility test gets a half-written answer and the thing it controls is culled
at random.

**The read-back is not a lens flare.** It decides whether *entities render at all*. A second
attempt (`ReadbackShadow` in `d3d9_device.cpp`) kept a CPU copy of the last completed read-back
and served that instead of the in-flight buffer, which does remove the flicker — by removing the
NPCs. Standing in the same spot in Southern San d'Oria:

- unmodified, 24.4 fps: Shard of Sunlight, Varchet and ellouine all present and stable
- shadow read-back, 53.8 fps: **the plaza is empty**, no flicker because nothing is drawn

A stale or zeroed visibility result reads as "not visible", so every entity it governs
disappears. Feeding the game anything other than the true, completed read-back breaks it. The
shadow code is left in place behind the same off-by-default flag, because the measurement is
worth keeping, but it is not a fix and must not be shipped on.

**What would actually work** is making the wait cheap rather than skipping it: the 26 ms is spent
waiting for a whole frame of queued GPU work to drain before the copy lands. Issuing the
read-back copy at the top of the frame, or on its own queue, would let it complete before the
game asks — exact, not approximate. That is the next thing to try.

## What the cost actually was

FFXI renders a **16×16 `D3DPOOL_DEFAULT` / `D3DUSAGE_RENDERTARGET`** surface and immediately locks
it to read the result back — a lens-flare / sun-visibility occlusion test. It does this about
**four times per frame**, ~100 times a second.

Each read-back has to wait for the GPU to reach that point, which drains the entire pipeline. A
probe added to `D3D9DeviceEx::WaitForResource` and `SynchronizeCsThread` (`DXVK_STALL_LOG=<path>`,
milliseconds blocked per frame) measured the baseline frame as:

    fps    map_wait_ms  map_wait_n  map_blocked_ms  map_blocked_n  sync_cs_ms  sync_cs_n
    24.9   28.8         4.0         25.8            4.0            3.0         8.0

**26 ms of a 40 ms frame with the client blocked, doing nothing, inside four lock calls.** That is
the whole gap between 25 fps and 50, and it explains every other measurement this project ever
took: a GPU at ~10% busy, two threads each at ~60–75% of a core with neither saturated, and a
frame rate that refused to move when renderer work was removed.

`D3D9_LOCKIMAGE_PROBE` confirms the attribution is total — every single stalling lock in a 40 s
sample is that same `16×16, pool 0, usage 0x1, format 21` surface, no other shape appears.

`D3D9_RT_READBACK_NOWAIT=<max edge in px>` skips **only the wait**, and only for
`D3DPOOL_DEFAULT` render targets no larger than that edge. The copy is still issued, so the
surface still gets refreshed. With it on, all three stall counters read exactly `0.00` — and the
game breaks, for the reasons above. It stays as a measurement tool, not a setting to turn on.

## Scheduling the read-back earlier: no demonstrated gain

Tried 2026-08-14, because the previous entry named it as the thing that would work. It does not,
or at least it cannot be shown to on this machine.

`D3D9_RT_READBACK_EARLY=<max edge in px>` records the image->buffer copy in `SetRenderTarget`,
when the game stops drawing to the small surface, instead of at `Lock`. `Flush()` follows it
(`D3D9_RT_READBACK_EARLY_FLUSH=0` separates the two effects), so the copy is submitted with a
whole frame left to complete rather than sitting in the batch that Present flushes. Nothing about
what the game reads changes: the wait still happens and the data is still this frame's, complete.

**Three runs each, same build, flag off vs on:**

| | runs (fps median, 40 s in-world) | median |
| --- | --- | --- |
| flag off | 20.52, 27.30, 23.15 | 23.15 |
| flag on | 25.38, 26.63, 27.26 | 26.63 |

The medians differ by 3.5 fps and **the ranges overlap almost completely** -- the best baseline run
beats every flagged run. n=3, and the baseline spread alone is 6.8 fps. There is no effect here
worth claiming. The flag stays off by default and stays in the tree as a measurement, not a fix.
A first pair of runs looked like +2 fps; that was one run each, and it did not survive repeats.

**The first two attempts at this measured nothing at all,** which is the part worth remembering.
The early path was gated on "the game has locked this subresource before", which never becomes
true: instrumentation (`Logger::err` counters on both the lock and the unbind) showed
`candidate=0` after 6,500 locks of a 16x16 render target. FFXI creates a **fresh** render target
for each visibility test, so a per-object flag can never be set in time. Gating on the shape
alone -- `D3DPOOL_DEFAULT`, `D3DUSAGE_RENDERTARGET`, at most 32 px a side -- makes it fire ~8,000
times a run. Two builds were benchmarked and written up before that was checked. **A frame rate
that did not move and an optimisation that never ran are indistinguishable from the outside; add
the counter first.**

With it firing, the block inside `Map` falls from 28.6 ms to 26.7 ms. That is the real result: the
client is not waiting for the 1 KiB copy, it is waiting for the GPU to finish the draws that
produce the surface, and no amount of scheduling moves that. Reaching 30 fps needs the visibility
test to stop serialising the frame, not to be scheduled better.

## Dead ends, so they are not retried

- **MoltenVK command-buffer prefill** — 22.30 fps against a 24.88 baseline. Worse. (An earlier
  session's 58 fps figure for this was character select, not the world.)
- **Early buffer copies** (`DXVK_EARLY_BUFFER_COPY=1`, our patch) — 21.84. Worse.
- **Render-pass spills** — 604,924 in a 40 s run, dominated by `copyBuffer`, ~250 breaks against
  2440 draws. It looks like the answer and is not: removing them costs frames. Symptom, not cause.
- **Disabling vsync** — +0.6 fps. Noise.

The pattern across all four: this frame was never limited by renderer work, so removing renderer
work never helped. It is limited by one blocking read-back — which is real, and load-bearing, and
cannot simply be skipped.

## Harness notes

Two bugs in `bench.py` aborted every 4K run before this work was possible, both fixed:

- `game_is_frontmost()` asked `NSWorkspace.frontmostApplication()`, which in a detached harness
  process is frozen at whatever was frontmost when the process started. It asks System Events now.
- `click_to_focus()` clicked the title bar; at 4K the window frame starts at `x = -1, y = 30`, so
  that click landed on the menu bar and focused Finder. It falls back to the middle of the window.

A locked screen (`frontmost=loginwindow`) still stops a run dead and always will.

`DXVK_DRAW_PROBE` crashes the client at 4K with the sidecar attached. `DXVK_STALL_LOG` was written
to be cheap enough not to (two clock reads per instrumented call, no allocation) and does not.

## 2026-08-20: cooperative x87 baseline, and two more dead ends

With the cooperative sidecar + CX-26.3 wine (see X87-WALL.md), the honest number stands:
**23.7 fps median in-world at 4K max** (`inworld-coop-aot`). Two more config-level levers
measured against that baseline, same session:

| configuration | fps median |
| --- | --- |
| cooperative baseline (maxFrameLatency=1 already in dxvk.conf) | 23.68 |
| + `d3d9.presentInterval = 0` (vsync off) | 23.16 — no gain, reverted |
| + `MVK_CONFIG_SYNCHRONOUS_QUEUE_SUBMITS=0` | 20.90 — worse, rejected |

Config space is exhausted. Anything past ~24 fps at these settings requires engine-level
work on the visibility read-back (dedicated-queue submission for the 16×16 surface's draw
set, or convincing the client not to serialise on it) — DXVK source territory.

## 2026-08-20 (later): the fence fast path — first real dent in the read-back wall

Root cause finally isolated with a retirement-thread probe (`DXVK_QUEUE_LOG`): the 26 ms
stall was never GPU execution. ~15 submissions/frame retire through DXVK's finish thread
ONE AT A TIME, each `vkWaitForFences` costing ~0.85 ms on MoltenVK (~275 ms of serialized
fence-waiting per second at 10% GPU busy). The visibility lock waits behind that serial
queue.

`D3D9_RT_READBACK_FENCE=<max edge px>` (patches/dxvk-1.10.3-horizonxi-fencewait.patch,
now in the vendored dll, enabled by the launcher at 32): the lock flushes, does a FULL CS
sync (required — capturing the last submission before the flush's own submission is
enqueued would wait an older fence and reproduce the NOWAIT stale-read bug), then waits
directly on that submission's fence, bounded, with fallback to the exact slow path.
**Exact by construction**: the fence signaling means the staging buffer holds this
frame's bytes.

Measured: in-world map_wait 28.8 -> ~9 ms/frame; best run 25.07 vs 23.68 baseline; blink
probe over a live populated dock scene showed no NOWAIT-style entity dropout (spikes an
order of magnitude below the broken signature, consistent with other players moving).
Honesty note: single runs each — the planned 3x3 A/B was cancelled (no unattended
launch loops, standing rule); scene-density spread between runs is larger than the
effect, so treat +1.4 fps as indicative, not proven.

`D3D9_RT_UNBIND_FLUSH` (flush when the small RT is unbound) is also in the patch but
showed no additional gain (24.23 with both, n=1) — left off by default.

Remaining wall: with waits at ~9 ms, the frame is now bounded by the client's own main
thread (~78% of a core, x87 + draw submission). Next fronts: sidecar JIT quality, or
cutting the residual 9 ms (per-texture early fence capture at RT-unbind so the lock
waits a long-signaled fence).

## 2026-08-20 (evening): per-frame dedup of the visibility test — REFUTED before implementation

`D3D9_RT_IDENT_PROBE` (in the fencewait patch) logged every small-RT bind/unbind/lock with
texture identity. 53,941 events on a live in-world run:

- **One single 16x16 texture** serves every visibility test (15k+ locks, one pointer).
- The event stream is a strict `lock, bind, unbind` cycle (`LBULBULBU...`, 17,976 clean
  `BU` pairs between locks, one anomaly). **Every lock is preceded by its own fresh render
  pass into the surface.** Each read is a distinct test of a distinct light/frame state.

Serving a cached per-frame result would therefore hand test N the result of test N-1 —
the NOWAIT corruption class again. Do not re-attempt dedup/caching of this surface.

What the probe DOES establish for the next attempt: the test pass is self-contained
(own tiny RT, re-rendered occluder geometry) and strictly interleaved with main-scene
work. The sound path to killing the residual ~9 ms is submitting the `bind..unbind`
command range on a SECOND VkQueue (own MTLCommandQueue in MoltenVK) so its fence does not
queue behind the frame's main submissions — real DXVK surgery: split command recording at
the bind/unbind boundaries and fence only the side queue at lock time. Read-only shared
resources (geometry, textures) need cross-queue hazard care; the 16x16 + its depth are
exclusively the side queue's.

LSB-local status, corrected after live debugging with Daniel: the pathway WORKS. The
"post-connect close" was simply a missing local account (the DB only had the harness's
lsbtest fixtures; Daniel's login was refused). Account `danielalanbates` now exists in
the local DB (bcrypt row, id 3), and the launcher's Local-server world verified
end-to-end to the title screen. First render on this path is slow (cold DXVK pipeline
cache) — do not judge it by early screenshots. Two real residuals: the cooperative
CX-26.3 wine still page-faults during LSB boot (7B31EF5E — live world unaffected), and
the harness's blind key-driving needs its wait-for-pixels guard (added to inworld.py).

## 2026-08-20 (night): plan-1/3 session — flags, record run, early-fence refuted

- `X87_FAST_ROUND=2` breaks the client at the POL handoff. Rejected; never retry.
- **Project record, measured in-world: 43.5 fps median at 4K max** (fence path +
  cooperative x87, light ~920-draw scene). Crowded scenes still land in the 20s.
- Fence-depth probe (22,668 locks): median pending depth 2, median wait 2.0 ms/lock —
  the residual is per-submission completion latency (~1 ms each on MoltenVK), not GPU
  execution.
- `D3D9_RT_EARLY_FENCE` (copy + flush at RT-unbind, wait that submission at lock):
  REFUTED. fps wash (43.9 vs 43.5), waits worse (5.9 ms median — the unbind flush drags
  the whole frame chunk along), CS/queue threads red-lined from per-test full syncs.
  Root cause is structural: the interleave probe shows the lock follows the unbind
  IMMEDIATELY — no gap for the copy to execute in. Code stays env-gated OFF.
- Surviving architecture for the residual ~2 ms/lock: the SIDE QUEUE, refined estimate
  ~1.3 ms x 3.5 locks ≈ 4.5 ms/frame (43 -> ~52 fps light scenes). Beyond that the wall
  is the client main thread (~90% of a core at 44 fps).
- Harness: hidden-wine-app window enumeration bug fixed (bench.py unhide_wine) — this
  was the "no wine windows" flakiness all along.

## 2026-08-21: side-queue session — the queue does not exist, and two more dead ends

- **MoltenVK exposes exactly one VkQueue (family 0, count 1) — verified against both the
  wrapper's library and upstream v1.4.2 with a direct probe.** The side-queue design as
  "second VkQueue" is impossible without a patched MoltenVK, and this machine has no
  Xcode to build one (a CI build via GitHub Actions is the pathway if ever needed).
- `D3D9_PERIODIC_FLUSH=<draws>` (submit every N draws so GPU work overlaps the CPU
  frame): built, measured at 200 — 40.5 fps vs 43.5/43.9 comparable-scene runs, waits
  1.68 vs 2.0 ms, depth still 2. No win; extra submissions eat the saving. Env-gated
  OFF. (With early-fence also refuted, submission-boundary tuning is exhausted.)
- Suspicious observation for the NEXT investigation: at 44 fps the main thread shows
  ~90-95% CPU-busy while supposedly *blocked* ~7 ms/frame in fence waits — MoltenVK's
  vkWaitForFences may spin rather than sleep. If so, the residual wait is stealing CPU
  from the x87-bound main thread, and a sleeping wait (or MoltenVK fence fix) frees
  real frame time. Verify with a profiler sample of the wait site before believing it.

## 2026-08-21 (later): fence-spin hypothesis REFUTED by profiler sample

/usr/bin/sample of the live client (8 s in-world): the fence wait resolves to
`vkWaitForFences -> _pthread_cond_wait` — a sleeping wait, 366/1079 samples (~34% of the
main thread's wall time). No spin; MoltenVK is efficient here. The waits are genuine
GPU/completion latency, and with NOWAIT (breaks entities), side-queue (no second queue
exists), early-fence and periodic-flush (both measured, no gain) all closed, the
read-back wall is now optimized to its floor on this stack. Remaining upside lives
elsewhere: Metal completion-handler latency inside MoltenVK (needs a CI-built patched
MoltenVK) or making the client's x87 math faster (sidecar upstream). Sample saved
paths + probe tooling: /tmp/game-sample.txt (transient), mvkprobe.c in session notes.

## 2026-09-04: live moving-camera A/B — NOWAIT confirmed unshippable, FENCE baseline clean

The NOWAIT glitch had only ever been shown two ways: `blinkprobe.py`'s static frame-diff
spikes (17/39 pairs) and Daniel's minute of play. This is the first confirmation under a
**live, moving camera**, and it also re-verifies that the shipped FENCE path is visually clean
under the same stress. Run on the local Docker world (`docs/LOCAL-TEST-SERVER.md`) via
`menu-run.py`, human at the screen. Both arms had `D3D9_RT_READBACK_FENCE=32` (the shipped
default); the only variable was `D3D9_RT_READBACK_NOWAIT` layered on top — so this is
*shipped baseline* vs *shipped baseline + NOWAIT*, not vs raw stock.

- **NOWAIT on** (`D3D9_RT_READBACK_NOWAIT=16`): the sun-flare **strobes** — not the predicted
  subtle one-frame brightness lag — whenever the sun is in front of *or* behind the camera
  (lens-flare ghosts throw to the opposite side, so "behind" flickers too). Mob models
  **blink in and out** at certain camera angles. Indoor zones are clean (no sky/sun test).
- **NOWAIT off** (FENCE only, the shipped default): at the identical spots and camera angles,
  both artifacts are gone. Flare brightness tracks occlusion correctly; mobs are stable.

Same corruption class as documented above — skip-the-wait hands the game a half-written
visibility buffer, and that buffer governs whether entities draw, not just flare brightness.
Nothing new mechanically; the value is (a) first confirmation under motion, (b) confirmation
the FENCE default is clean under motion, and (c) a method note below.

**Method note, worth keeping.** `launchctl setenv` bakes the env into the client at `open`
launch, so NOWAIT **cannot be toggled in a running client** — each arm is a fresh launch.
And static per-stage screenshots **cannot** catch this: it is a temporal, frame-to-frame
artifact. Any change that alters rendering semantics needs a live human A/B (relaunch with the
flag flipped, same spot/angle), not screenshots. An earlier "verified safe in harness
screenshots" note for NOWAIT was wrong for exactly this reason.
