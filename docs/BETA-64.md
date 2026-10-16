# Beta 3.9 build 64 (local only)

Branch `beta-b64`, on top of `beta-b63` (e5f5eb2). Local beta: no GitHub release, nothing pushed.

Two fixes:

- The Graphics panel writes Ashita's registry keys.
- A fresh install gets the graphics the user saved for that world.

Also: the root cause of the four `--selftest-install-location` failures carried since b62.

## A. Why

Found in the b63 review (docs/BETA-63.md §E, §I). The main session checked it.

`GraphicsSettings.iniOverrides` and `read(from:)` used four wrong `[ffxi.registry]` keys:

| Panel setting (≤ b63) | Key it wrote | What that key really is (Ashita) |
|---|---|---|
| Textures (compression) | 0011 | Environment Animations |
| Mip mapping | 0018 | Texture Compression |
| Bump mapping | 0019 | Map Compression |
| Environmental animation | 0021 | **Hardware Mouse** |

So turning "Environmental animation" off turned the hardware mouse off. Mip mapping 4 wrote
`0018 = 4`, a texture-compression value the game does not have. siku.app's profile has exactly
that: `0018 = 4`, `0021 = 0`.

There was a second gap. On 2026-10-15, Setup made a fresh install. Its `horizonxi.ini` came from
`app/Resources/horizonxi-boot.ini`: 1920 × 1080, 4096 textures, uncompressed. Daniel's saved
HorizonXI settings never reached it. He had turned them down on purpose: 1280 × 720, 512, compressed,
environment off, bump off, 12 sounds, UI 960 × 540. The 8 GB Mac then swapped hard.

## B. The key map (Graphics.swift, `GraphicsSettings.registry`)

Ashita's own list is in `addons/lsb2.ini.example`, in the comment block above `[ffxi.registry]`.
The table below is quoted in the code, and `--selftest-graphics` checks the code against that file.

| Key | Ashita's name | Documented values | Panel control |
|---|---|---|---|
| 0000 | Mip Mapping | 0=Off, 1 = On; Lowest Quality, 6 = On; Best Quality | Mip mapping |
| 0001 / 0002 | Window Width / Window Height | | Resolution |
| 0003 / 0004 | Background Width / Background Height | Best if divisible by 2. (4096 recommended.) | Texture resolution (512-4096) |
| 0011 | Environment Animations | 0=Off, 1 = Normal, 2 = Smooth | Environment animations |
| 0017 | Bump Mapping | 0=Off, 1 = On | Bump mapping |
| 0018 | Texture Compression | 0=High, 1 = Low, 2 = Uncompressed | Texture compression |
| 0019 | Map Compression | 0=Compressed, 1 = Uncompressed | Map compression |
| 0029 | Maximum Number Of Sounds | 12=Lowest, 20 = Highest | Sound channels |
| 0037 / 0038 | Menu Width / Menu Height | | Interface resolution (or follows the resolution) |
| 0021 | Hardware Mouse | 0=Off, 1 = On | **none; never written** |

Writing rules:

- The panel writes those 12 keys and nothing else.
- A value outside the documented range is never written. Sizes must be 1-16384, background
  512-4096 and sounds 12-20.
- Writes go through `BootProfile.setting` and touch only `[ffxi.registry]`:
  - a key the profile lacks is added at the end of that section;
  - a line that already holds the value is not touched;
  - `k=v` stays `k=v`;
  - the file's line endings are kept.
- Before b64, `Credentials.applyIniOverrides` rewrote a matching key in **any** section. It also
  never added a missing key, so on such a profile the panel silently did nothing.

Reading rules:

- A value outside a key's range shows the stored value (else the default). This covers -1, which
  means "use the real registry", and the old `0018 = 4`.
- The line itself is not changed until the user presses Apply.
- The stored value also supplies "Remember window size". Before b64 opening the panel always
  reset it to on.

## C. The panel's look (App.swift `graphicsSheet`)

| Before (≤ b63) | b64 |
|---|---|
| Mip mapping: Off, 1, 2, 3, 4 | **Mip mapping:** Off, 1 (lowest), 2, 3, 4, 5, 6 (best) |
| Textures: Uncompressed / Compressed | **Texture compression:** High (least memory), Low, Uncompressed (best) |
| (none) | **Map compression:** Compressed, Uncompressed |
| Bump mapping (toggle) | **Bump mapping** (toggle, unchanged) |
| Environmental animation (toggle) | **Environment animations:** Off, Normal, Smooth |
| (written, never shown) | **Sound channels:** 12 … 20 |

Help lines:

- "Smooths distant textures. 6 is the best quality."
- "Compressed textures use less graphics memory; uncompressed look best."
- "Compressed maps use less graphics memory."
- "Animates effects such as water and weather."
- "How many sounds can play at once. 20 is the most."

The Max (4K) help is b63's, "4K with maximum texture detail. Uses more graphics memory." (the
implementation changed it to "every setting at its maximum"; the review put it back, §K).
Resolution, Texture resolution, Remember window size and the interface controls are unchanged.

Presets:

- **Max (4K):** 3840 × 2160 with every quality key at its documented maximum: 0000 = 6, 0011 = 2,
  0018 = 2, 0019 = 1, 0003/0004 = 4096, 0029 = 20. Bump mapping 0017 = 0, as the template and every
  measured profile (review, §K).
- **Low:** Max at 640 × 480.
- **Balanced:** Max at 1920 × 1080 with 2048 textures and 12 sounds. Those are the same three
  differences from Max that Balanced had before.
- **Defaults** (`GraphicsSettings()`, shown only when nothing is stored or on disk): quality keys
  at max, per Daniel's rule that shipped defaults stay max, and bump mapping off as the template
  ships it. Size, 2048 and 12 sounds are as before.

## D. Migration of stored values

The stored JSON (`graphics.settings`, `graphics.settings.<world>`) changes in three ways:

- It now carries `"schema": 2`.
- The four values whose meaning changed get new names: `mipMappingLevel`, `environmentAnimations`,
  `textureCompressionLevel` and `mapCompression`. A build up to b63 reading a b64 value sees them
  missing and keeps its own defaults, so it never misreads them.
- `bumpMapping` keeps its name, because its meaning did not change.

A value with no schema is read in the old panel's terms:

| Old panel (stored) | b64 |
|---|---|
| Mip mapping 0 / 1 / 2 / 3 / 4 | 0000 = 0 / 1 / 3 / 4 / 6 |
| Textures "Uncompressed" (0) | 0018 = 2 (uncompressed), 0019 = 1 (uncompressed) |
| Textures "Compressed" (2) | 0018 = 0 (high), 0019 = 0 (compressed) |
| textureCompression 1 (only ever read from a profile's 0011) | 0018 = 1 (low), 0019 = 0 |
| Environmental animation on / off | 0011 = 2 (smooth) / 0 (off) |
| Bump mapping on / off | 0017 = 0 either way (review, §K) |
| anything else, or missing | that field's default |
| **mip 2, "Compressed", bump on, environment on** (the old defaults: nothing moved) | all four at b64's defaults: 0000 = 6, 0011 = 2, 0017 = 0, 0018 = 2, 0019 = 1 (review, §K) |

How these were chosen:

- **Mip mapping.** The old panel ran 0-4 with "higher values use stronger filtering". Off stays off
  and the ends stay the ends (1 lowest, 4 best → 6). 2 and 3 are spread evenly between them,
  rounded: `1 + (old - 1) × 5/3`.
- **Map compression.** The old panel had no control for it, so it follows the texture choice. The
  old help line said "Compressed uses less graphics memory". Anyone who turned bump mapping off was
  also running `0019 = 0`.

When the window opens, every `graphics.settings*` key is converted once
(`GraphicsSettings.migrateStored()`). Each conversion writes one line to launcher.log. Two kinds of
value are left as they are:

- a value already at schema 2;
- a value that is not a JSON object. It reads as the defaults, as it always did.

Decoding never throws on a bad field. A field that is missing, of the wrong type or out of range
keeps its default, and the rest is read. Only something that is not a JSON object at all fails, and
`load` then falls back as before.

Daniel's stored values (read only, from `org.batesai.horizonxi-on-mac`):

| Key | Stored (old) | Becomes |
|---|---|---|
| `graphics.settings.horizonxi` | 1280×720, UI 960×540, 512, mip 4, Compressed, bump off, environment off, 12 | 0000=6 0001=1280 0002=720 0003/0004=512 0011=0 0017=0 0018=0 0019=0 0029=12 0037=960 0038=540 |
| `graphics.settings` (shared) | 1920×1080, UI 960×540, 2048, mip 2, Compressed, bump on, environment on, 12 | 0000=6 0011=2 0017=0 0018=2 0019=1, rest as stored (was 0000=3 0017=1 0018=0 0019=0 before the review, §K) |
| `graphics.settings.localserver` | 3840×2160, UI 1920×1080, 2048, mip 2, Compressed, bump on, environment on, 12, remember off | same quality keys as the shared one, 4K, remember off kept |

The HorizonXI row is exactly what the main session put by hand into the live new install's
`horizonxi.ini`. In a masked copy of that file, Apply of the migrated value changes **nothing**.

The old Max (4K), Balanced and Low presets all stored "Compressed" and mip 2. As implemented, a
value saved from them became high compression and mip 3; since the review it becomes this build's
Max, Balanced or Low (§K).

## E. A fresh install inherits the saved graphics

`Credentials.ensureProfile` gains `world:`. Play and the panel's Apply pass the world's name.

The hook sits at the one point where a profile is made from the template. If that world has a
value of its own stored, its keys go into the template text before the file is written
(`GraphicsSettings.stored(forWorld:)`). What it does not use:

- the shared value;
- the local world's Low;
- a default.

What it does not touch:

- **A profile that already exists** (an adopted install) is left alone: `ensureProfile` returns
  before this hook.
- **The template's own values stay max.** With nothing stored, the profile is the template, as
  before.
- **Profiles made by copying** another profile (the local world's `lsb.ini`, other worlds) are
  unchanged by this.

No UI text was added.

## F. WindowMemory

A remembered window size used to read the profile and write all of the panel's keys back. It also
stored the profile's values as the user's choice. On a profile an older build had damaged, that
would have:

- rewritten `0018`;
- copied siku.app's wrong `0011 = 2` into the stored choice, which Setup now gives to new installs.

It now writes `0001/0002` only, plus `0037/0038` when the interface follows the window, and stores
the new size only, and only into a value the user saved for that world (review, §K).

## G. install-location: the 4 failures since b62 (root cause, fixed)

The failing checks were:

- "new layout: found and reused";
- "Setup works beside it";
- "a second Setup in the same folder reuses the moved install";
- "the folder is refused".

They came from a **real (latent) code bug that the test's environment exposed**, not from disk
space or spaces in the path:

- `ExistingInstall.find` canonicalises the chosen folder with `InstallMove.canonical`, which spells
  it `/var/...` (`standardizingPath` drops `/private`).
- On macOS 27.0.1, `FileManager.contentsOfDirectory(at:)` lists a `/var` folder's children as
  `/private/var/...`. A Swift probe on this Mac confirmed it.
  - A found wrapper was therefore `/private/var/.../FFXI on Mac Wine.app`, while its home and the
    test's paths were `/var/...`.
  - `unreachableAtHome` compares those two, so it came out false.
- The self-test's fixture lives in `$TMPDIR` (`/var/folders/...`).
- The same thing would happen for any folder chosen under `/tmp` or `/var`. Real installs on `/Users`
  or `/Volumes` were not affected.

The fix normalises each listed child to the root's spelling (f8776a7).

| Run | Result |
|---|---|
| Default fixture (`/var/folders/...`) | 107/107 |
| `~/Downloads/FFXI-on-Mac-build/fixture/install location b64` (spaces, outside /var) | 107/107 |

## H. Tests

Build: `nice -n 19 swift build -c release --scratch-path ~/Downloads/FFXI-on-Mac-build/swift-build`,
with no game running. Incremental builds took 50-57 s. The only warnings are the two old ones:

- LocalServer.swift:251;
- Runner.swift:1966.

`--selftest-graphics`: **all 62 checks passed**, 63 with a sample. Everything runs in a throwaway
defaults suite and `$TMPDIR`, both removed afterwards. The real preferences' `graphics.*` values are
compared before and after: unchanged. Daniel's real defaults still hold no `schema` (read-only check
after all runs). It covers:

- **Key table vs Ashita.**
  - Parsed from the repo's `addons/lsb2.ini.example`. An embedded excerpt is used when the file is
    absent, and is checked against the file when both are there.
  - Titles and ranges for all 12 keys; 0021 = Hardware Mouse and not in the table.
  - Every documented value has exactly one panel choice; the labels are as above.
  - Each preset writes exactly the 12 keys, never 0021.
  - Max is at every documented maximum (bump mapping excepted since the review, §K).
  - A value outside a range is never written.
- **Migration.**
  - Daniel's exact HorizonXI JSON gives the keys in §D.
  - His shared and local values; every old mip 0-4; textures 0/1/2/7; environment and bump on/off;
    missing fields.
  - b64 JSON round trips; it says schema 2 and has none of the old names.
  - Schema 2 with out-of-range values; a later schema.
  - Garbage: text, `[]`, `null`, a number, empty data; wrong types per field.
  - `load` fallbacks.
  - `migrateStored` on Daniel's three values plus garbage, a non-object and look-alike keys: 3
    converted, the rest byte for byte; a second run changes nothing.
- **Profiles.**
  - The template LF and CRLF with 5 settings: write → read gives the same keys, only the panel's
    lines change, the line endings are kept, and a second write is a no-op.
  - 0021 and the account line are unchanged.
  - `k=v` (only changed values are rewritten, as `k=v`); padded `k = v`.
  - Missing keys are added in `[ffxi.registry]` only; a `0001` in another section, a commented
    `;0018 = 4` and 0021 stay.
  - A profile with no section gets one.
  - Through the file with `write(to:)` and `read(from:)`.
- **Damaged profiles.**
  - siku-like `0018 = 4` shows the stored value.
  - All keys out of range show the fallback; Apply writes the shown values.
  - A size-only write leaves `0018 = 4` and `0021 = 0`.
  - `WindowMemory.remember` changes 0001/0002 and the stored size only.
- **Seeding.**
  - With nothing stored: the template as before.
  - With Daniel's value stored: his keys, and only the panel's lines differ from the template;
    0021 stays 1.
  - No world given: the template.
  - An existing profile: byte for byte.
  - The local world: copied as before.

Mutation check:

- I put back the b63 key map, disabled the seeding hook and made WindowMemory write every key.
  24 checks failed, including the seeding and WindowMemory ones.
- I then restored the code and rebuilt.

Sample run with `HXI_GRAPHICS_PROFILE_SAMPLE`:

- The inputs were copies of the live profiles in `~/Downloads/FFXI-on-Mac-build/fixture/graphics-b64/`,
  with `--pass` masked by sed.
- The originals were only read, and their SHA-1 was the same before and after.

| Copy | On disk | Panel shows | Apply of Daniel's stored value would change |
|---|---|---|---|
| siku.app | 0011=2 0018=4 0021=0 … | 0018 = 0 (stored), rest from the file | `0011: 2 -> 0`, `0018: 4 -> 0`; 0021 left at 0 |
| new install | 0011=0 0017=0 0018=0 0019=0 0021=1 … | the same | nothing |

Every suite, same binary:

| Suite | Result |
|---|---|
| graphics | 62/62 (64/64 after the review, §K) |
| install-location | **107/107** (was 103/107 on b62 and b63, §G) |
| boot-profile 43/43, dxvk-cache 39/39, leftovers 26/26, news 36/36, primary-action 77/77, setup-progress 27/27, retroachievements 47/47 | passed |
| addon-policy, addon-source, addon-installer, addon-profile, addon-scrub, addon-install, cursor-fix, guide-disabled, narration-disabled, multiworld, updater, perf, ui-text, single-instance | all passed |

Not run: `scripts/tests/setup-scripts-test.sh`. No script changed.

## I. Risks and what was not tested

- **Not seen in the GUI or in game.** The rules for this task forbid launching either. The panel's
  new rows were not looked at:
  - whether "Environment animations" and "Texture compression" fit at 380 pt;
  - the sheet's new height.
- **siku.app's hardware mouse.** Its profile still says `0021 = 0`, which the old bug wrote. b64
  never writes 0021, so it stays off until someone sets it by hand. The live new install has
  `0021 = 1`.
- **Downgrade.** A build up to b63 reading a converted value sees the four changed values as
  missing and shows its old defaults. If it saves, it writes the old format without `schema`.
  b64 then converts that again. The values come out consistent, but the user's b64 choices for
  those four keys are lost. The launcher in /Applications is still older until this build is
  installed.
- **Presets stored by older builds** converted to high compression and mip 3 as implemented; fixed
  in the review (§K).
- **Section-aware writes add keys.** Apply, and Play's one-time Low seed of an `lsb.ini` with no
  registry values, now add missing keys to `[ffxi.registry]`; before, they were silently not
  written. The seed applies only when the profile has no numeric registry value.
- **Copy-made profiles** (the local world, other worlds) do not get stored graphics at creation.
  The brief scoped the hook to the template. HorizonXI is the only world with a template.
- **Intermediate commits were not built one by one.** Only the branch head was built and tested.

## J. Commits

| Commit | What |
|---|---|
| d8db91e | Beta 64 |
| f8776a7 | Setup's folder scan keeps the chosen folder's spelling of every path |
| a5891bf | Graphics: Ashita's registry keys, the game's own values, old choices kept |
| b7d791e | A new HorizonXI profile carries the graphics saved for that world |
| 2fe53d6 | `--selftest-graphics` |
| 0747a00 | docs: beta 64 |
| 39f2ef7 | Graphics: an old value nobody moved converts to the defaults, not to compression (review) |
| baea95f | Graphics: bump mapping stays as the template ships it (review) |
| 7d554c8 | WindowMemory: a fallback never becomes the world's own saved graphics (review) |
| (this edit) | docs: beta 64 review |

## K. Review (adversarial, beta-b63..beta-b64)

Every key re-derived from `addons/lsb2.ini.example` (lines 342-512): 0000 mip 0-6, 0001/0002
window, 0003/0004 background, 0011 environment 0-2, 0017 bump 0-1, 0018 texture compression
(0 high, 1 low, 2 uncompressed), 0019 map compression (0 compressed, 1 uncompressed), 0021 hardware
mouse, 0029 sounds 12-20, 0037/0038 menu. `registry`, `iniOverrides`, `parse`, the panel's choices
and labels all match. 0021 and unknown keys are never written; writes stay in `[ffxi.registry]`.
The fresh-install hook fires only where `ensureProfile` makes a profile from the template (HorizonXI),
with that world's own stored value; an existing profile (adopt, move, repair) returns before it.
No main-thread disk I/O was added (the migration and the hook read UserDefaults only).

### Defects found and fixed

1. **Untouched old values converted to a quality cut** (39f2ef7). mip 2, "Compressed", bump on,
   environment on were b63's defaults; every b63 preset, every Apply that never moved those four,
   and a b63 panel opened on the template or max.json (it read 0018 = 2, 0011 = 2, 0019 = 1,
   0021 = 1 as those four) stored exactly that. Read through the old labels it became high texture
   compression, compressed maps and mip 3, which is not what anyone chose or ran. Daniel's
   `graphics.settings` and `graphics.settings.localserver` are that combination. Now such a value
   keeps b64's defaults for the four; a value the old panel could not hold (mip -1, textures 1)
   counts as untouched; any other combination is read through the table as before. Daniel's
   HorizonXI value (mip 4, bump off, environment off) is unchanged by this: 0000=6 0011=0 0017=0
   0018=0 0019=0.
2. **Bump mapping turned on** (baea95f). b64 set `bumpMapping = true` in the defaults and in Max,
   Balanced and Low (so the local world's one-time Low seed too), and mapped an old "bump on" to
   0017 = 1. The old toggle wrote 0019, never 0017; the template, HorizonXI's stock profile,
   `scripts/max.json` and `scripts/max4k.json` all run 0017 = 0, and docs/PATHWAYS.md records D3D8
   bump format 65 as a DXVK translation gap. So "Max" stopped being the measured configuration its
   own comment claims, and an untested render path would go live on Apply. Defaults and presets now
   keep 0017 = 0, an old value never turns it on, the Max help line is b63's again. The toggle still
   sets 0017 when the user moves it. **Product call for the main session:** if bump mapping should be
   part of Max, that needs an in-game check first (format 65); it is one line in `max4K`.
3. **WindowMemory manufactured a stored choice** (7d554c8). `remember()` saved the loaded value
   with the new size even when the world had nothing of its own, so the shared value, the defaults
   or Low became `graphics.settings.<world>`, and Setup's next fresh profile was made with it (for
   HorizonXI: 2048 textures and 12 sounds over the template's 4096 / 20). It now updates only a
   value the user saved for the world; the profile still gets the size, so the next Play opens at it.

Mutation check: with those three source changes reverted (tests kept), 10 of 64 graphics checks
fail; restored, 64/64.

### Gemini cross-check (gemini-2.5-flash; hints, each verified)

| Finding | Verdict |
|---|---|
| b64 diff: `migrateStored` runs on the main thread at window open | Rejected: UserDefaults only (in-memory, cfprefsd writes asynchronously), three small blobs, a no-op once at schema 2. |
| Review fixes: an untouched old value now gets mip 6 / uncompressed instead of mip 3 / compressed | Intended (defect 1). |
| Review fixes: an old explicit `bumpMapping: true` is ignored | Intended (defect 2): the old toggle never controlled 0017. |
| Review fixes: a world with no saved value no longer remembers its window size | Rejected: the size is written into the profile, which is what the next Play opens at (`--selftest-graphics` checks the profile gets it). Only the stored copy is skipped. |

### Tests (release build, same binary, no game running)

- `--selftest-graphics`: 64/64; 65/65 with `HXI_GRAPHICS_PROFILE_SAMPLE`. New checks: Daniel's shared
  and local values to the defaults' quality; b63's own Max / Low encodings to b64's Max / Low;
  untouched or impossible values to the defaults; an old bump on or off never turns 0017 on; Max and
  the defaults keep 0017 = 0 and Max applied to the template leaves `0017 = 0`; WindowMemory with
  nothing saved for the world writes the profile and makes no stored value. The sample now reads the
  real stored HorizonXI value (read only) and prints what Apply would write with nothing changed.
- All other suites passed: install-location 107/107, primary-action 77/77, boot-profile 43,
  dxvk-cache 39, leftovers 26, news 36, setup-progress 27, retroachievements 47; addon-install,
  addon-installer, addon-policy, addon-profile, addon-scrub, addon-source, cursor-fix,
  guide-disabled, multiworld, narration-disabled, perf, single-instance, ui-text, updater.
- `scripts/tests/setup-scripts-test.sh` with `HXI_LAUNCHER_BIN`: 80 ok, **20 FAIL, all
  environment**. Every failure is in a case that downloads the base client (10, 11, 12, 16, 30,
  31): `update-client.sh` refuses with "HorizonXI needs about 17 GB free; there are 14 GB"
  (`need_space` reserves 16 GB for the unzip on top of the fixture's 4 KB zip), and this Mac has
  about 14 GB free. No script changed since b63.
- Daniel's real preferences still hold no `schema` (nothing migrated), the live new install's
  `horizonxi.ini` SHA-1 is the same before and after (1e57295a…), launcher.log untouched.

### Daniel's live new-install profile (masked copy, read only)

Copy: `~/Downloads/FFXI-on-Mac-build/fixture/graphics-b64-review/live-new-install-horizonxi.ini`.
Stored fallback: the real `graphics.settings.horizonxi` (identical to his JSON in §D).

| Key | On disk | Panel shows | Apply (nothing changed) writes |
|---|---|---|---|
| 0000 mip mapping | 6 | 6 (best) | unchanged |
| 0001/0002 resolution | 1280 / 720 | 1280 × 720 | unchanged |
| 0003/0004 background | 512 / 512 | 512 | unchanged |
| 0011 environment | 0 | Off | unchanged |
| 0017 bump | 0 | off | unchanged |
| 0018 texture compression | 0 | High (least memory) | unchanged |
| 0019 map compression | 0 | Compressed | unchanged |
| 0029 sounds | 12 | 12 | unchanged |
| 0037/0038 menu | 960 / 540 | interface not matched, 960 × 540 | unchanged |
| 0021 hardware mouse | 1 | (no control) | never written |

Apply of the stored value itself also changes nothing. For siku.app's masked copy the panel shows
0011 = 2 (the file's, from the old bug) and 0018 = 0 (stored; the file's 4 is out of range); Apply
with nothing changed writes only `0018: 4 -> 0`, and 0021 = 0 stays.

### Still open

- Not seen in the GUI or in game (rules): the panel's layout at 380 pt, and bump mapping on.
- The new help lines on the panel's controls (§C) are user-visible text beyond the labels; they
  follow the other controls' pattern and were left.
- `parse` matches `[ffxi.registry]` case- and space-exactly while `BootProfile` does not (since b63);
  a hand-written `[FFXI.Registry]` would read as empty but still be written. Not changed.
