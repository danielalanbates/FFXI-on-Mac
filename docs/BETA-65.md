# Beta 3.9 build 65 (local only)

Branch `beta-b65`, on top of `beta-b64` (44388e4). Local beta: no GitHub release, nothing pushed.

One change: the install picker under "Remember me" is gone, and the install in use no longer
changes behind the user's back.

## A. Why

Daniel, 2026-10-15: "why under remember me is there 2 options? that box doesn't need to exist"

On his Mac the box listed two installs:

- `siku.app · prefix10`, the old wrapper. Its game data is on the ghost 'Games' drive.
- `FFXI on Mac Wine.app · prefix10`, the one Setup made. Defaults:
  - `install.last` = `/Volumes/x10/Video Games/Mac/FFXI/FFXI on Mac/FFXI on Mac Wine.app#prefix10`
  - `install.location` = `/Volumes/x10/Video Games/Mac/FFXI/FFXI on Mac`

Taking the box out was not enough. Up to b64 a rescan (↻, a drive mounting, the end of Setup)
switched to the first install it found in two cases, and wrote that one into `install.last`:

- `install.last` not on disk, for example with x10 unplugged. `Install.remembered()` was nil, so
  the scan picked `found.first`: siku.app.
- `install.last` on disk but not found by the scan, with no game yet. This is a fresh Setup
  install while its game downloads, or a wrapper chosen with the folder button.

With the picker the user could at least see that and switch back. Without it, the switch would be
invisible.

## B. What was removed (App.swift, sidebar)

This block, right after `Toggle("Remember me", …)`:

```swift
if installs.count > 1 {
    Picker("", selection: …) {
        ForEach(installs) { i in Text("\(i.wrapper.lastPathComponent) · \(i.prefixName)").tag(i.id) }
    }
    .labelsHidden()
}
```

Nothing replaces it in the window. The ACCOUNT row keeps both of its icons:

- ↻ "Rescan for installs".
- The folder, "Choose wrapper app…". It is now the only way to switch to another wrapper.

## C. The rule (InstallSelection.swift)

The same function decides at launch, on every rescan, and in `--check`, `--next-action` and
`--fix`.

| `install.last` | Install in use | `install.last` afterwards |
|---|---|---|
| set, prefix on disk | that one, whatever else the scan finds | unchanged |
| set, not on disk (drive unplugged or ghost-mounted, folder gone) | none; nothing else is picked | unchanged |
| not set, one in use this session | that one | it |
| not set, nothing in use | the scan's best (below) | it |
| not set, nothing found | none: Setup | not set |

When `install.last` is set but not on disk, the main button takes the b60 path
(`hasInstall = false`, `Primary.rememberedDrive`):

- drive unplugged or ghost-mounted: **Setup**, "The 'x10' drive isn't connected — reconnect it or
  press Setup.";
- drive known to macOS but not mounted: **Repair** (mount);
- drive there but folder gone: **Setup**.

Reconnecting the drive brings that install back. While it is away, a mount or activation stats
only its own prefix; it does not scan /Volumes each time.

The scan's best, used only when there is no `install.last`:

1. under `install.location`;
2. then one with the game;
3. then the one Wine ran last (newest `system.reg` / `user.reg`);
4. then discovery's own order (checks passed, internal disk first).

Who still writes `install.last`:

- Setup making or adopting an install;
- Move…;
- the folder button;
- the adoption in the table above.

A rescan writes it only in that last case.

Unchanged:

- **Worlds.** A world never changes the install. `active` is still
  `selected.forServer(world)`: the same wrapper and prefix, pointed at the world's own `dataPath`.
  So per-world client folders resolve exactly as before.
- **G11.** "Install dependencies…" beside an install that has the game keeps that one in use. The
  new wrapper is reached with the folder button; before, it was in the picker.
- **Leftovers (b62).** Adoption looks at the selected install's prefix, as before. That install is
  now always `install.last` or nothing.

Where:

- `InstallSelection.decide` (InstallSelection.swift:56) and `rank` (:65): the rule on plain values.
- `InstallSelection.resolve` (:99): the same with defaults and disk. The scan closure is called
  only when there is no `install.last` and nothing in use.
- `InstallSelection.inUse` (:110): the headless commands. It never writes.
- `Install.lastChosen` (Install.swift:325): `install.last` as written, on disk or not.
  `remembered()` (:319) is that one when its prefix exists.
- The window:
  - `refreshAsync` (App.swift:2642-2656);
  - `autoRecheck` (App.swift:2675);
  - the launch fast path (App.swift:461), unchanged.
- Headless:
  - `--check` (Headless.swift:152). It says "the install in use isn't on disk: … The 'x10' drive
    isn't connected — reconnect it or press Setup." and exits 2.
  - `--next-action` and `--fix` (PrimaryHeadless.swift:81, :96).
  - None of them falls back to `discover().first` any more.

## D. Tests

Build: `nice -n 19 swift build -c release --scratch-path ~/Downloads/FFXI-on-Mac-build/swift-build`.
The only warnings are the two old ones (LocalServer.swift:251, Runner.swift:1966).

Daniel started HorizonXI at 18:43:57, near the end of the first build. Nothing was running when
that build started. The second build (a test-only fix) and every suite below then ran while his
game was running, against the rule.

- No self-test signals or touches a running process.
- His client was still running afterwards.
- No further build was made.

`--selftest-install-selection` (new): **20/20**.

Plain values:

- `install.last` on disk is kept, though siku.app ranks first.
- `install.last` on disk but not found by the scan is kept.
- `install.last` off disk is kept, nothing is in use, and it is never switched to siku.app.
- That holds even while another install is in memory.
- With no `install.last`, the one in use this session is kept.
- With no `install.last`, `install.location` is preferred, even with no game.
- Then the game, then the most recent run, then discovery's order.
- A folder beside `install.location` with a longer name is not counted as under it.
- Nothing at all gives none.
- 40 rescans, with shuffled scan orders, the drive coming and going and `selected` fed back each
  time, never land on another install.

Fixtures in `$TMPDIR` and a throwaway defaults suite:

- The game and last-run facts are read from the prefix.
- With no `install.last`, the fresh install under the location is adopted over a siku.app that has
  the game. After it is remembered, a rescan keeps it without asking the scan.
- An `install.last` on a `/Volumes/<missing>` drive stays unreachable and the scan is not asked.
  `Primary.decide` then gives Setup with "The '<drive>' drive isn't connected — reconnect it or
  press Setup.".
- An `install.last` whose folder is gone is kept.
- When it is back on disk, it is in use again.
- Malformed `install.last` values are not installs.

Every suite, same binary:

| Suite | Result |
|---|---|
| install-selection | 20/20 |
| install-location | 107/107 |
| primary-action | 77/77 |
| graphics | 64/64 |
| boot-profile 43/43, dxvk-cache 39/39, leftovers 26/26, news 36/36, setup-progress 27/27, retroachievements 47/47 | passed |
| addon-install, addon-installer, addon-policy, addon-profile, addon-scrub, addon-source, cursor-fix, guide-disabled, narration-disabled, multiworld, perf, single-instance, ui-text, updater | all passed |

Read-only on Daniel's Mac (`--next-action`, the build binary, the app's own defaults):

- HorizonXI `play | Play`: the install is `install.last`, not siku.app.
- CatsEyeXI `setup:game | Setup | CatsEyeXI isn't installed yet.`: same base install as b64 would
  use.

His `install.last` and `install.location` were read before and after, and are unchanged.

Not run: `scripts/tests/setup-scripts-test.sh`. No script changed.

## E. Risks and what was not tested

- **Not seen in the GUI.** The rules for this task forbid launching it. The sidebar just loses one
  row.
- **No silent fallback any more.** With `install.last` on an unplugged drive, the launcher used to
  play from another install it found, such as siku.app. Now the button says Setup and names the
  drive. Switching on purpose is the folder button. This is what was asked for, but it is a change
  for anyone who kept two working installs on two drives.
- **↻ shows less.** With `install.last` set, a rescan cannot change the install, so ↻ in effect
  re-runs the checks. Mount and activation already do that. Its help text, "Rescan for installs",
  is still literally true.
- **The folder button's panel still says "usually siku.app".** That text is older than Setup's
  "FFXI on Mac Wine.app". It was left as it is.
- **A stat on the main thread.** While `install.last` is away, a mount or activation stats its
  prefix on the main thread. On a ghost or unplugged drive that is an immediate ENOENT. A
  spinning-up drive could hold the window briefly. Up to b64 the code scanned instead (off the main
  thread, but the whole of /Volumes).
- **"Ran last" is a proxy.** It is the modification time of the prefix's registry files. It matters
  only when there is no `install.last` (first run, or defaults cleared).
- **`--check` exits 2 when `install.last` is away.** It no longer checks whichever install
  discovery finds first.
- **Empty `org.batesai.horizonxi-on-mac.selftest-*.plist` files.** Every self-test run leaves one
  in ~/Library/Preferences (cfprefsd keeps the emptied file). That is not new; 113 were there after
  this run.
