# DXVK patches

Two patches, each a complete patch against a clean `v1.10.3` checkout. Apply exactly one; they
do not stack (the second fails at its first hunk). The three earlier patches they replace are in
`archive/2026-08-11/patches/`.

- **`dxvk-1.10.3-horizonxi-fencewait.patch` builds the shipped DLL**
  (`vendor/dxvk-1.10.3-x32-d3d9-horizonxi.dll`). It is the other patch plus the read-back fence
  work of 2026-08-20 (`docs/MAX4K.md`) and, since b70, the device-lost fix (below). Use this one.
- `dxvk-1.10.3-horizonxi.patch` is the 2026-08-14 state (d6f40f4) without the fence work. It is kept
  for bisecting. A DLL built from it ignores `D3D9_RT_READBACK_FENCE=32`, which the launcher sets on
  every run (`Settings.swift`), so the in-world read-back wait goes back from ~9 to 28.8 ms a
  frame.

Both carry the cursor fix (below) since 2026-10-16, as the same hunk. Only the fencewait patch
carries the device-lost fix: its `dxvk_queue.cpp` hunks sit on fencewait's queue log, and the
bisect patch never ships.

## Which patch built the b69 DLL

Checked 2026-10-16, read-only:

- **git.** The vendor DLL last changed in 2da0ccb (2026-08-20 16:49:24 -0700), together with the
  fencewait patch. Every change to the DLL since e8bb014 came with a fencewait change.
  `dxvk-1.10.3-horizonxi.patch` last changed in d6f40f4 (2026-08-14).
- **strings.** Apply each patch to a clean v1.10.3 and diff the two trees. The fencewait patch adds
  code in 7 files and removes nothing; it only widens two `if` conditions. It adds seven
  environment variables, and all seven are in the DLL (`strings -a`): `D3D9_RT_READBACK_FENCE`,
  `D3D9_RT_EARLY_FENCE`, `D3D9_RT_UNBIND_FLUSH`, `D3D9_PERIODIC_FLUSH`, `D3D9_RT_FENCE_PROBE`,
  `D3D9_RT_IDENT_PROBE` and `DXVK_QUEUE_LOG`. The shared ones (`DXVK_KEEP_DEPTH`,
  `FFXI_FPS_DIVISOR`, the probes) are there too.
- **PE header.** The time stamp is 2026-08-20 16:49:24 -0700, which is 2da0ccb's commit time
  (epoch 1787269764).
- **Toolchain.** The DLL's embedded header paths show Homebrew mingw-w64 14.0.0_3 and GCC 16.2.0,
  which is what is installed now. No build-directory path is embedded.
- **Live use.** `vendor/NOTICE.md` already says "v1.10.3 + fencewait, rebuilt 2026-08-20". The live
  `d3d9.dll` beside the client is byte-identical to the vendor DLL. Today's HorizonXI spawn record
  has `D3D9_RT_READBACK_FENCE=32`.

**A rebuild reproduces it (checked 2026-10-17).** The recipe below, with b69's fencewait patch
(`git show 5716690:patches/dxvk-1.10.3-horizonxi-fencewait.patch`) on a fresh v1.10.3 clone, gives
a DLL of the same size (3,403,776 bytes) that differs from the shipped one in 4 bytes only:

- the export directory's time stamp (file offset 0x30B004): the shipped DLL has its link time,
  1787269011 (2026-08-20 16:36:51 -0700), the rebuild has `SOURCE_DATE_EPOCH`;
- the PE checksum (0xD8), which follows from it.

The PE header time stamp (0x88) and every other byte, code included, are identical.

## SHA-256 of the shipped DLL

```
e5f1a6b9698d36f3b4e50c4cf7e4070a85a43e27c6eb46f50c8f345b6c565490  b69 and earlier: fencewait, no cursor fix (2da0ccb)
70ba566455fbd084f190dfe03c857fbf9b267c599230314f77a48dcb6998e4e3  b70: fencewait with the cursor fix and the device-lost fix (2026-10-17)
```

The b70 DLL is 3,403,776 bytes, the same size as b69's (`.text` +904 bytes, `.rdata` +160, within
the same section alignment). Its imports and export count are b69's. `strings -a` finds
`D3D9Cursor::ShowCursor: Software cursor not impl` and `horizonxi: GPU device lost; drawing
stopped, the game keeps running so it can be` in it and in neither b69's DLL nor the baseline
rebuild. GCC stores only the head of each literal in `.rdata` and writes the tail with immediate
moves, which is why neither string is found whole.

## Build

```sh
git clone --depth 1 --branch v1.10.3 --recurse-submodules https://github.com/doitsujin/dxvk.git
cd dxvk
git apply /path/to/patches/dxvk-1.10.3-horizonxi-fencewait.patch
export SOURCE_DATE_EPOCH=1787269764      # the shipped DLL's PE time stamp (ld and strip read it)
meson setup --cross-file build-win32.txt --buildtype release build32
nice -n 19 ninja -j2 -C build32 src/d3d9/d3d9.dll   # the d3d9 target alone; same d3d9.dll as a full ninja
i686-w64-mingw32-strip -o d3d9.dll build32/src/d3d9/d3d9.dll
shasum -a 256 d3d9.dll
```

Toolchain used for b70 (2026-10-17): Homebrew mingw-w64 GCC 16.2.0, meson 1.10.1, ninja 1.13.0.
The d3d9 target is 181 steps, about 2 minutes at `-j2` on this Mac.

**Release order for b70.** Do not build while a game runs; the Mac has 8 GB.

1. **Baseline.** Done 2026-10-17. Use the same recipe on a fresh clone with b69's patch
   (`git show 5716690:patches/dxvk-1.10.3-horizonxi-fencewait.patch`; the current file also has the
   device-lost hunks, so excluding the cursor file no longer gives the baseline). It gave
   `625efb5e…`: the shipped `e5f1a6b9…` except for the export time stamp and the checksum (see
   above).
   - If the bytes differ anywhere else, compare `i686-w64-mingw32-objdump -d` of the two DLLs.
   - A difference beyond the time stamps and checksum means this recipe does not rebuild the
     shipped renderer. Stop, and do not ship a rebuilt DLL.
2. **Build.** Done 2026-10-17: the full patch gave `70ba5664…` (the table above, and
   `vendor/NOTICE.md`), now the vendor DLL; `app/bundle.sh` ships it.
3. **Probe.** Not run yet (it needs Wine). Build `scripts/harness/cursorprobe.c` with:

   ```
   i686-w64-mingw32-gcc -std=c11 -O2 -Wall -Wextra -static -s -Wl,--no-insert-timestamp -o cursorprobe.exe scripts/harness/cursorprobe.c -ld3d9
   ```

   Run it as its header says: a throwaway prefix only. Expected results:
   - the stock DLL prints FAIL (exit 1);
   - the new DLL prints PASS (exit 0).
4. **A/B on the local LSB world.** Follow `docs/CURSOR-DXVK.md`. Do not use HorizonXI for it.

The shipped app needs no install script. The launcher puts the bundled DLL beside the client on
Play (`RendererSetup.ensureFiles`/`apply`).

`scripts/harness/install-d3d9.sh <dll>` is a bench tool. It copies a DLL into the five load paths
of the old siku.app prefix, which are hard-coded. Never use it on a prefix whose game is running.

## What is in it

**Two upstream bugs, both worth submitting** (see `docs/UPSTREAM.md`):

- `d3d9_fixed_function.cpp`: `info.pushConstSize` was assigned `m_pushConstOffset`.
  - For fixed-function pixel shaders that offset is 0, so no fragment push-constant range was
    declared.
  - Desktop drivers bind push constants anyway. MoltenVK honours the declaration, so every fog
    constant arrived zeroed and the whole world rendered in the fog colour.
- `dxvk_adapter.cpp`: D3D9 required `geometryShader`, `robustBufferAccess` and `shaderCullDistance`
  unconditionally.
  - Metal has none of them, and D3D9 needs none of them.
  - Making them conditional let DXVK run on MoltenVK 1.4.1 instead of only on 1.2.10. 1.2.10 was
    the one version that falsely claimed to support them.

**One upstream fix, backported (2026-10-16): the cursor.**

- `d3d9_cursor.cpp` is DXVK b0b46fd075 (PR #3562, first in v2.3).
- With no D3D cursor set, 1.10.3's `ShowCursor` called `SetCursor(NULL)`. That erased FFXI's
  Hardware Mouse cursor, a Win32 `.ani`.
- Now it only records visibility. `SetHardwareCursor` is unchanged.
- See `docs/CURSOR-DXVK.md`.

**One upstream bug, fixed our own way (fencewait only, b70): a lost device froze the game.**

- 1.10.3's submit thread called `m_device->waitForIdle()` on a failed submission while holding
  the queue's `m_mutex`. `waitForIdle` → `lockSubmission` → `synchronize` locks `m_mutex` again (a
  non-recursive SRW lock) and waits for that same entry to leave the queue. The renderer
  deadlocked; every D3D9 call blocked; the game stopped pumping window messages and could not be
  closed (2026-10-16 21:31, a Metal GPU recovery; `docs/BETA-70.md` §5).
- Upstream v2.3 (5d119673) stopped waiting there on `DEVICE_LOST`. Not backported as is: 2.3's
  queue is a different design.
- `dxvk_queue.cpp`: the submit thread no longer waits. Every command list, refused ones too, goes
  to the retirement thread and gets `notifyObjects`, the `m_pending` decrement, `reset` and
  recycle exactly once, so every resource lock, frame-latency wait and `waitForSubmission`
  returns. The first loss the retirement thread sees is logged (`Logger::err`, once:
  `horizonxi: GPU device lost; drawing stopped, the game keeps running so it can be closed`) and
  waited out with one `waitForIdle` from that thread, which holds no lock, so nothing still on the
  GPU is freed under it. A submission that failed without a loss waits on its fence for at most
  2 s (MoltenVK still runs it).
- `d3d9_swapchain.cpp`: on a lost device `Present` flushes, sleeps 16 ms and returns `D3D_OK`;
  acquire and the previous-present check no longer recreate the swap chain (which threw). The
  picture freezes; the game keeps running and closes normally.
- The latch is permanent: MoltenVK never un-loses a device. Recovery from a GPU reset comes from
  `MVK_CONFIG_RESUME_LOST_DEVICE=1` in the launcher's environment, which keeps MoltenVK from
  marking the device lost in the first place. This fix is for a real loss.
- Inert until a submission or fence wait fails.

**One rendering change, on by default (`DXVK_KEEP_DEPTH=0` disables it):** keep the depth-stencil
attached while depth and stencil are disabled, instead of detaching it.

- Detaching changes the attachment set. That forces a new framebuffer and spills the render pass.
- FFXI toggles `ZENABLE`/`ZWRITEENABLE` constantly, so this was ~24,000 render-pass breaks per
  session.
- The pipeline's depth state already says "don't test, don't write", so nothing in the picture
  changes.

**The read-back fence (fencewait only), `D3D9_RT_READBACK_FENCE=<max edge px>`:**

- A lock of a small render target waits on its own submission's fence instead of behind DXVK's
  one-at-a-time fence retirement.
- The bytes are the same as on the slow path. The launcher sets it to 32.
- `D3D9_RT_EARLY_FENCE`, `D3D9_RT_UNBIND_FLUSH` and `D3D9_PERIODIC_FLUSH` are experiments in the
  same patch. They are off unless set. See `docs/MAX4K.md`.

**One client tweak, `FFXI_FPS_DIVISOR=<n>`:** patch FFXI's frame-rate divisor
(1 = 60 fps target, 2 = 30 fps, the client default).

- It uses the same signature scan and pointer walk as Ashita's `fps` addon. It lives here because
  Ashita's plugin host did not load in that install.
- It writes game memory. The DLL does nothing unless the variable is set.
- The launcher sets it to 1 by default (`Settings.swift` `fpsDivisorOne`, no per-world check).
  Today's HorizonXI spawn record has `FFXI_FPS_DIVISOR=1`.

**Measurement probes, all off unless their variable is set** (see `docs/PERFORMANCE.md`):

- `DXVK_FPS_LOG`, `DXVK_PRESENT_PROBE`, `DXVK_DRAW_PROBE`, `DXVK_PASS_PROBE`, `DXVK_FB_PROBE`,
  `DXVK_STALL_LOG` and `D3D9_LOCKIMAGE_PROBE`;
- `DXVK_SKIP_DRAWS`;
- the older `DXVK_BATCH_PROBE` / `DXVK_FF_INSTANCING`;
- fencewait's `D3D9_RT_FENCE_PROBE`, `D3D9_RT_IDENT_PROBE` and `DXVK_QUEUE_LOG`.

**What a normal launcher run changes:** the two upstream fixes, the cursor fix, `DXVK_KEEP_DEPTH`,
the read-back fence and `FFXI_FPS_DIVISOR=1`. The device-lost fix changes nothing until the GPU
fails a submission.

---

# LandSandBoat linkshell zone-gap patch

`lsb-linkshell-zone-backlog.patch` is a server-side patch, not a client one. It applies to a
[LandSandBoat](https://github.com/LandSandBoat/server) checkout — written against `627e5671` —
and makes a character's linkshell replay the chat it missed while crossing a zone line.

```sh
cd ~/Games/lsb/server            # or wherever lsb-server.sh put it
git apply /path/to/lsb-linkshell-zone-backlog.patch
cmake --build build --target xi_map -j 4
```

It touches five files, all under `src/map/`: `linkshell.h`, `linkshell.cpp`, `ipc_client.cpp`,
`utils/charutils.cpp` and `packets/c2s/0x00a_login.cpp`. Nothing outside `xi_map` is affected and
there is no schema change, so `git checkout` on those five files and a rebuild puts stock
behaviour back.

**Licence:** LandSandBoat is GPLv3 and this patch is a derivative of it, so this patch is GPLv3
too — unlike the rest of this repository. Do not relabel it.

**Read `docs/LINKSHELL-ZONING.md` before using it.** It has the measurements, the reason the
obvious one-line version silently does nothing, and the two limits that matter: it only helps a
server running a single `xi_map` process, and one message can still be lost to a race with the
client's own connection teardown.
