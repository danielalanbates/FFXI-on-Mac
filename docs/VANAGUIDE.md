# Vanaguide wiring (LSB / unrestricted only)

| Item | Detail |
| --- | --- |
| Swift helper | `app/Sources/HorizonXILauncher/Guide.swift` (parallel to `Narration.swift`) |
| Pref toggle | Setup & Diagnostics → **Quest guide (Vanaguide, local LSB only)** (`PerfSettings.enableVanaguide`) |
| Load line | `/addon load vanaguide` + marker `# Vanaguide quest guide`, written **outside** `--HORIZON_ADDONS_*--` |
| Dest folder | `<game>/addons/Vanaguide` (same layout as `vanaguide/tools/install.sh`) |
| Policy | `Guide.allowed(by:)` — refuse + scrub on allowlist worlds (HorizonXI, CatsEyeXI, FFEra, …) |
| Hosted servers | **Never** offer or auto-load. Ban risk; see `docs/ADDON-POLICY.md` and vanaguide `docs/SERVERS.md` |
| Separate companion | `/Applications/Vanaguide.app`, launched by **Open Vanaguide** in Setup & Diagnostics |

## How to enable on local LandSandBoat

1. The local beta bundles a tested `Vanaguide` addon snapshot when its repository sits next to the launcher checkout. Older builds can use a separate Code checkout or `~/Downloads/Vanaguide`.
2. In the launcher, select **Local server (LandSandBoat)** (unrestricted policy).
3. Turn on **Quest guide (Vanaguide, local LSB only)** under Setup & Diagnostics.
4. Press Play. Log should show `==> vanaguide: on (from …, via scripts/…)`.
5. In game: `/vg` (keyboard — Mac port mouse UI is limited; see `docs/MOUSE.md`).

## Source search order

1. Launcher bundle `Contents/Resources/Vanaguide`
2. Google Drive and iCloud Code checkouts
3. `~/Downloads/Vanaguide` or `~/Downloads/vanaguide/Vanaguide`

`/Applications/HorizonXI.app` and `/Applications/VanaVoice.app` are **not** modified by this wiring.

## Relation to the old `lsb.txt` approach

Earlier Mac notes (`vanaguide/docs/INSTALL_MAC.md`) used a separate `scripts/lsb.txt` plus `script=` in `lsb.ini`. `Guide.swift` instead appends the load line to whichever script the boot profile already names (same resolution as VanaVoice), and removes it when the world is allowlisted. Prefer the launcher toggle going forward; do not put Vanaguide in shipped `addons/default.txt`.
