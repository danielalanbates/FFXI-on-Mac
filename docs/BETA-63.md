# Beta 3.9 build 63 (local only)

Branch `beta-b63`, on top of `beta-b62` (b3ff2ae). Local beta: no GitHub release, nothing pushed.

One feature: DXVK's pipeline state cache is carried across installs and sessions, so an install
Setup has just made (or moved) does not start cold. Plus findings on why the install made on
2026-10-15 runs worse than siku.app did -- the biggest of which is not the cache at all (§E).

## A. Why

Daniel, 2026-10-15: "I have the settings turned almost all the way down and the game is still
almost unplayable. it's extremely jittery … whenever I run around and it loads a new character, my
computer freezes for like 5 seconds while it renders".

DXVK 1.10.3 (the only DXVK that runs on MoltenVK: 2.x needs geometryShader) builds a graphics
pipeline the first time a draw needs it, on the drawing thread: SPIR-V, MoltenVK's SPIR-V -> MSL,
then Metal's compiler. On this 8 GB Mac under memory pressure that is the stall. It appends every
pipeline it built to `<exe>.dxvk-cache` in DXVK_STATE_CACHE_PATH (`C:\dxvk-cache`, Settings.swift),
and the next session builds those on background threads as soon as their shaders appear.

The install Setup made that morning (`/Volumes/x10/Video Games/Mac/FFXI/FFXI on Mac/FFXI on Mac
Wine.app`, prefix10) had no cache to start from. Read from copies (§C): 184 pipelines mid-session,
**169 of them already in siku.app's cache** (1,132 pipelines, last written 2026-10-02). Same
d3d9.dll and d3d8.dll in both prefixes (SHA-1 e36057fa2f95… / 75bf2c21f342…), so the keys match:
the new install was re-building, with stalls, pipelines the Mac had built before.

## B. The file format, from the source

Source: DXVK v1.10.3 (`e4fd5e9 [meta] Release 1.10.3`), the tree the bundled d3d9.dll is built from
(`/Volumes/x10/Video Games/Mac/FFXI/hxi-workspace/src/dxvk-1.10.3`). Our patches touch none of the
state cache's format: `git diff` there shows only `#include <cstdint>/<cstddef>` added to
`dxvk_state_cache.h`, `dxvk_state_cache_types.h` and `dxvk_graphics_state.h`; `dxvk_state_cache.cpp`
is unchanged.

**File header** -- `dxvk_state_cache_types.h:56-62`:

```cpp
struct DxvkStateCacheHeader {
  char     magic[4]   = { 'D', 'X', 'V', 'K' };
  uint32_t version    = 10;
  uint32_t entrySize  = 0; /* no longer meaningful */
};
static_assert(sizeof(DxvkStateCacheHeader) == 12);
```

**Entry** -- `dxvk_state_cache.cpp:14-17` (header), `:719-728` (layout as written):

```cpp
struct DxvkStateCacheEntryHeader {
  uint32_t stageMask : 8;
  uint32_t entrySize : 24;
};
...
// General layout: header -> hash -> data
stream.write(reinterpret_cast<char*>(&header), sizeof(header));
stream.write(reinterpret_cast<char*>(&hash), sizeof(hash));     // Sha1Hash, 20 bytes
stream.write(data.data(), data.size());
```

Little-endian, stageMask in the low byte (confirmed on the real files: byte 0 of every entry is
`0x11` = vertex + fragment, bytes 1-3 its size). Data is at most `MaxSize = 1024` bytes (`:27`).

**Hash check** -- `:534-541`; the hash is plain SHA-1 of the data (`sha1_util.cpp`, OpenBSD SHA1):

```cpp
if (!stream.read(reinterpret_cast<char*>(&header), sizeof(header))
 || !stream.read(reinterpret_cast<char*>(&hash), sizeof(hash))
 || !data.readFromStream(stream, header.entrySize))
  return false;
// Validate hash, skip entry if invalid
if (hash != data.computeHash())
  return false;
```

then the data must decode (`:543-642`): shader keys for each stage bit (24 bytes each; the result
of that read is ignored), for compute a 48-byte binding mask, otherwise a packed render pass (3 + 8×2
bytes) that must pass `validateRenderPassFormat` (`:1044-1064`), binding mask 48, ia 2, il 2, rs 4,
ms 4, ds 2, om 2, dsFront 4, dsBack 4, attribute/binding counts ≤ 32 (`:596-598`), 8 swizzles × 1,
8 blends × 4, attributes × 4, bindings × 4, then a u32 spec-constant mask and one u32 per bit (12).
A read that does not fit fails without consuming (`DxvkStateCacheEntryData::read`, `:103-111`).
Sizes from `dxvk_limits.h` (MaxNumActiveBindings 384 -> 12 u32), `dxvk_shader_key.h`
(`VkShaderStageFlags m_type; Sha1Hash m_sha1;`) and the bitfield classes in
`dxvk_graphics_state.h`. On Daniel's 1,335 real entries every one decodes to its last byte.

**What DXVK does with…** -- `readCacheFile`, `:377-461`, and the constructor, `:152-188`:

- *an invalid entry* (hash mismatch, undecodable): skipped and counted (`:443-445`); any count
  makes `readCacheFile` return false (`:452-457`), and the constructor then truncates the file and
  rewrites the header plus every valid entry (`:159-187`, "in case we're recovering a corrupted
  cache file").
- *an entry size over 1024*: `readFromStream` returns false *without reading* (`:85-90`), the
  stream is still good, so it counts as invalid and the next header is read from right after the
  hash.
- *duplicates*: nothing; both are loaded (`m_entries.push_back`, `:432-433`). DXVK avoids writing
  one at run time (`addGraphicsPipeline`, `:203-211`).
- *a truncated tail*: the short `stream.read` fails, `else if (ifile)` is false, so it is not counted
  (`:428-446`) and the file is **not** rewritten; the writer thread later opens it with
  `std::ios_base::app` (`:965-969`) and appends after the partial entry, which corrupts the
  alignment of everything appended after it until a later read finds invalid entries and rewrites.
- *a version mismatch*: v2-v9 are converted and the file rewritten (`:396-421`, `:459-460`); a
  version above 10 or below 2, or a header `entrySize` other than the expected 0 for v8+, makes it
  discard the whole file -- the constructor truncates it to a fresh header (`:408-417`).
- *a bad or short header*: "Failed to read state cache header" -> a new, empty file (`:391-394`).

**File name** -- `:1007-1016` and `util_env.cpp:60-70`: `DXVK_STATE_CACHE_PATH` + `/` +
`env::getExeBaseName()` + `.dxvk-cache`, where `getExeBaseName` drops a `.exe` in any case.
horizon-loader.exe -> `horizon-loader.dxvk-cache`.

**Why a warm cache helps, and its limit** -- `dxvk_graphics.cpp:63-86`: a draw whose pipeline is
not built yet builds it right there ("at worst we're going to stall a state cache worker and the
current thread needs priority"). With a cache, `registerShader` (`dxvk_state_cache.cpp:251-287`)
queues every cached state for a shader pair to the worker threads the moment both shaders exist.
d3d8 FFXI draws through DXVK's fixed-function shaders, which are created at draw time
(`d3d9_fixed_function.cpp:2405`, `:2428`), so the *first* draw of a new shader pair may still build
its own pipeline; every other state of that pair is built ahead by the workers instead of stalling
a later draw.

## C. The real caches (read-only copies)

Copied, never opened in place, to `~/Downloads/FFXI-on-Mac-build/fixture/dxvk-cache/`:

| file | bytes | version | valid | invalid | repeats | tail |
|---|---|---|---|---|---|---|
| siku.app prefix10 `C:\dxvk-cache\horizon-loader.dxvk-cache` (2026-10-02 20:11) | 334,208 | 10 | 1,132 | 0 | 0 | 0 |
| new install prefix10 `C:\dxvk-cache\horizon-loader.dxvk-cache` (copied 16:43, game running) | 54,252 | 10 | 184 | 0 | 0 | 0 |
| siku.app `C:\CatsEyeXI-Launcher\CatsEyeXI-Launcher.dxvk-cache` | 4,461 | 10 | 19 | 0 | 0 | 0 |

old ∩ new = 169, only in old 963, only in new 15, union 1,147. Every entry is stage mask `0x11`.
Two independent readers agree: the launcher's Swift parser (`--selftest-dxvk-cache`, §F) and a
separate Python reading of the same rules.

## D. What the launcher does (DXVKStateCache.swift)

- **Mac copy:** `~/Library/Application Support/HorizonXI-on-Mac/dxvk-cache/<exe>.dxvk-cache`, one per
  executable.
- **Before Play** (`Runner.launch`, after the renderer step, once `gameExe` is known): only when the
  renderer is Metal (DXVK) and **no client is running anywhere** (`!clientsLive`), merge the Mac copy
  into the prefix's `C:\dxvk-cache\<exe>.dxvk-cache`. On its own thread; Play waits at most 3 s. If
  it is not done by then, a `CommitGate` makes sure it never renames afterwards, so the file DXVK
  opens is never replaced under it.
- **After the session** (the exit watcher's "game exited"): every `*.dxvk-cache` in the prefix's
  `C:\dxvk-cache` is merged into the Mac copy, on a detached utility task. The prefix is only read,
  so a second client still playing there does not matter (an entry it is half-way through appending
  is a tail, left for next time).
- **First run** (after the window's install scan): seed the Mac copy from the caches in the
  installs the launcher knows -- `install.last` and the window's installs list (which includes
  siku.app). Per install it lists only `C:\dxvk-cache`, `drive_c`, each folder directly in
  `drive_c`, and the boot loader's folder: a few dozen listings, never a walk. A `.seeded` marker
  (with the paths it used) makes it once; finding nothing leaves no marker, so a drive that was not
  mounted yet is tried again next start.
- **Merge rules:** keep every entry the target has, add every source entry it lacks (byte-for-byte
  comparison; DXVK writes from a memset state, so equal pipelines are equal bytes), never write an
  entry DXVK would skip. Write only when something is added or something DXVK would skip can be
  dropped (that also repairs a cut-off tail before DXVK appends after it). Written whole beside the
  target, fsynced, read back and checked (all valid, count right), then renamed over it; refused
  if the target changed meanwhile. A target that is not a v10 cache is never written; a source
  that is not is skipped. One merge into the Mac copy at a time across processes (flock, close-on-
  exec). Files over 32 MB are refused.
- **Log:** one line per step to launcher.log only (`logFileOnly`), nothing on screen, e.g.
  `dxvk cache: prefix horizon-loader.dxvk-cache +963 (184 -> 1147)`.

Headless:

- `--selftest-dxvk-cache` -- everything in a folder of its own under $TMPDIR (§F).
- `--dxvk-cache-report [--prefix <path>]` -- read-only: every cache of the install in use and the
  scanned installs, the Mac copy, and what Play, the end of a session and the first-run seed would
  each do (dry-run merges).
- `--dxvk-cache-warm [--prefix <path>]` -- what the window does, now: seed (first run), then merge
  into the install in use. Refuses, writing nothing, while any FFXI client runs.

## E. siku.app vs the new install: boot profile (read-only, passwords masked)

`config/boot/horizonxi.ini`, siku.app (2026-10-02 20:13) vs the new install (2026-10-15 16:27),
compared key by key:

| key | siku.app | new install | meaning (Ashita's own comment block in the ini) |
|---|---|---|---|
| `[ffxi.registry] 0001/0002` | 1280 × 720 | **1920 × 1080** | window (render) size |
| `0003/0004` | 512 × 512 | **4096 × 4096** | background / map texture resolution |
| `0037/0038` | 960 × 540 | **1920 × 1080** | menu resolution |
| `0018` | 4 | 2 | texture compression (0 high, 1 low, 2 uncompressed) |
| `0019` | 0 | 1 | map compression (0 compressed, 1 uncompressed) |
| `0021` | 0 | 1 | hardware mouse |
| `0029` | 12 | 20 | max sounds |
| `0020` | 1 | 0 | unknown/unused |
| `0024` | 0 | -1 | unknown/unused |
| `0041` | 1 | 0 | beta UI |
| `padmode000`, `padsin000` | set | -1 | gamepad |
| `[ashita.polplugins] sandbox` | 1 | 0 | Sandbox plugin |
| `[ashita.fonts] d3d8.family` | absent | Arial | |
| `[sandbox.paths]` | present | absent | |

Same in both: 0000 = 6 (mip mapping, best), 0011 = 2, 0017 = 0, 0034 = 1 (windowed), 0035 = 1,
`[ashita.window.startpos]`, `[ashita.input]`, `[ashita.taskpool]`, `[ffxi.direct3d8]` (all -1).

The launcher's own stored HorizonXI graphics choice (`graphics.settings.horizonxi` in
`org.batesai.horizonxi-on-mac`) is 1280 × 720, 512 textures, 960 × 540 UI, mip 4, compression 2,
bump off, environment off, 12 channels -- exactly what siku.app's file holds. **Those settings were
written into siku.app's profile and never into the new install's.** The Graphics panel writes the
profile only on Apply (App.swift, `graphics.write(to:)`), Play re-applies only the renderer's keys
(`Credentials.applyIniOverrides(perf.renderer.iniOverrides, …)`), and the panel opens on what the
profile on disk says (`openGraphics`). The new install's render, texture, menu and sound values are
those of a stock HorizonXI profile -- the same as `app/Resources/horizonxi-boot.ini`, which seeds a
client that has none: 1920 × 1080, 4096, 20 sounds. (Which file it was copied from is not
recorded; several of its other keys differ from that template.) So the new install draws 2.25× the
pixels with 64× the background-texture pixels, uncompressed, on an 8 GB Mac with ~100 MB free.
Not changed here (Daniel's settings); reported.

Also found, not changed: `GraphicsSettings.iniOverrides` writes texture compression to `0011`,
mip mapping to `0018`, bump mapping to `0019` and environment animation to `0021`; Ashita's own
documentation in the same file says `0011` = environment animations, `0018` = texture
compression, `0019` = map compression, `0021` = hardware mouse, `0000` = mip mapping, `0017` =
bump mapping. That is why siku.app's profile has `0018 = 4` (out of range for texture
compression): the panel's "mip mapping 4".

dxvk.conf: siku.app's `C:\HorizonXI\dxvk.conf` (maxFrameLatency 1, cachedDynamicBuffers, 4 compiler
threads) never applied -- the b59 note in Settings.swift records that the 2026-10-02 session logged
5 compiler threads and no "Found config file". Both installs effectively ran DXVK's defaults plus
the state cache; no difference there.

## F. Tests

Built with `nice -n 19 swift build -c release --scratch-path ~/Downloads/FFXI-on-Mac-build/swift-build`
(no game running; 52-59 s incremental). No new warnings from this change.

`--selftest-dxvk-cache`: **all 38 checks passed**. Everything happens in
`$TMPDIR/ffxi-dxvk-cache-selftest-<uuid>` (removed afterwards); the real caches are only copied
in (their SHA-1s are compared before and after), and the launcher's Application Support copy is
listed before and after (unchanged). Covered: the header bytes; synthetic graphics and compute
entries; SHA-1 mismatch; hash-correct but undecodable entries (colour layout 5, depth layout 2,
33 attributes, data 2 bytes short) -- all four built to fail exactly the check DXVK makes, and
cross-checked against the separate Python reader; size over 1024 (skipped, next entry read
24 bytes on); a half-written tail; repeats; v9, v11, a non-zero header entry size, not a cache,
an empty file; merges into nothing, with nothing new (not written, same mtime), dry runs, a
target with a bad entry + a repeat + a tail (rewritten, every good entry kept), a corrupt
source (only its good entries taken), refused targets left byte for byte, a v9 source skipped
and named, no empty file created, a closed CommitGate (no rename, no temp left); the real files
(1,132 / 184 / 19 entries, all valid; old into new 184 -> 1,147 in 10-12 ms, idempotent); the
launcher flow on made-up installs (where caches are looked for, `.bak` files ignored, seed
once, seed retried when nothing was found, warm before Play keeps the prefix's entries first,
second Play adds nothing, keep after a session picks up an appended entry, no Mac copy -> no
write, `dxvk.conf` not taken for a cache).

Every other suite, same binary:

| suite | result |
|---|---|
| addon-policy, addon-source, addon-installer, addon-profile, addon-scrub, addon-install | all passed |
| cursor-fix, guide-disabled, narration-disabled, multiworld, updater, perf, ui-text | all passed |
| retroachievements | 47/47 |
| primary-action | 77/77 |
| setup-progress | 27/27 |
| boot-profile | 43/43 |
| news | 36/36 |
| leftovers | 26/26 |
| single-instance | all passed |
| install-location | **103/107** -- the same 4 fail on the b62 sources (stashed this change, rebuilt, ran: identical 4 FAILs): "new layout: found and reused, no second wrapper", "... Setup works beside it … builds no wrapper", "a second Setup in the same folder reuses the moved install", "... when that install is the chosen folder's own FFXI on Mac, the folder is refused". Not caused by b63; not investigated here. |

`--dxvk-cache-report` on this Mac (read-only, 1.4 s including the /Volumes scan) found exactly
the three caches in §C (the new install's then at 1,155 after §G), and predicted the first-run
seed as `horizon-loader 0 -> 1155`, `CatsEyeXI-Launcher 0 -> 19`.

## G. The live install

Done at 17:05, as soon as the session that was running ended (polled every 30 s; no client,
loader, injector or sidecar in `ps`, checked again right before writing):

- Backup: `…/FFXI on Mac Wine.app/Contents/SharedSupport/prefix10/drive_c/dxvk-cache/horizon-loader.dxvk-cache.bak-2026-10-15-b63`
  (66,383 bytes, 225 entries -- the session had grown it from 184; SHA-1 18a9f374…). A copy is also
  in `~/Downloads/FFXI-on-Mac-build/fixture/dxvk-cache/new-final/`.
- Merged siku.app's 1,132 into it, the same rules, temp file + fsync + read back + unchanged-check
  + rename: **225 -> 1,155 entries, 340,933 bytes**, 0 invalid, 0 repeats, 0 tail. Every entry of
  the backup and every entry of siku.app's file is in it (202 were in both; 23 are only from
  today's sessions).
- Then `--dxvk-cache-warm` (this build) seeded the Mac copy: `seeded the Mac copy from 3 cache(s)
  in 2 of 2 known install(s): CatsEyeXI-Launcher.dxvk-cache +19 (0 -> 19),
  horizon-loader.dxvk-cache +1155 (0 -> 1155)` and found the prefix `already has all 1155`. The
  Mac copy `~/Library/Application Support/HorizonXI-on-Mac/dxvk-cache/horizon-loader.dxvk-cache`
  is **byte-identical** to the prefix's file -- the Swift merge and the Python one, done
  independently, produced the same bytes.

The installed launcher is still the earlier build: nothing was installed into /Applications.
The warm prefix is there for the next Play whichever launcher starts it; the carry-over itself
(warm before Play, keep after) runs once this build is the one installed.

## H. Risks and what was not tested

- **Not measured in game.** No session has been played on the warm cache yet (the rules here
  forbid launching the game). What to look for next session: no multi-second freeze the first
  time a character or area that siku.app had seen is drawn; launcher.log's `dxvk cache:` lines.
- **The limit of a warm cache** (§B): fixed-function shaders are made at draw time, so the very
  first draw of a new shader pair can still build its pipeline on the drawing thread; the other
  cached states of that pair are built by DXVK's workers. A warm cache also means more background
  compile work right when a shader pair appears (DXVK's worker threads, lowest priority).
- **It may not be the main cause of the jitter.** §E: the new install renders 1920 × 1080 with
  4096 background textures and a 1920 × 1080 menu, where siku.app (and the launcher's own stored
  choice) is 1280 × 720 / 512 / 960 × 540 -- on an 8 GB Mac with ~100 MB free and 2.3 GB of swap.
  That is Daniel's call to change; not touched.
- The Mac copy only grows (dead entries from an older d3d9.dll stay; harmless, DXVK never builds
  them). Past 32 MB a file is refused and merging stops -- ~100,000 entries; FFXI has ~1,200.
- Play waits up to 3 s for the warm step; on a slow or sleeping drive the client starts with the
  prefix's own cache (logged), never with a file replaced under it (CommitGate).
- `--dxvk-cache-warm` and the window seed from the same known installs: `install.last` plus the
  scan's list. A cache in an install the scan does not reach is not seeded (by design: no disk
  walks).
- A prefix whose `DXVK_STATE_CACHE_PATH` is overridden (Settings' extra environment) to somewhere
  other than `C:\dxvk-cache` is not followed. Daniel's override says `C:\dxvk-cache` too.
- `install-location` self-test: 4 failures that predate this change (§F).
