# Beta 3.9 build 66 (local only)

Branch `beta-b66`, on top of `beta-b65` (293327e). Local beta: no GitHub release, nothing pushed.

Three changes:

- **A.** No-execute stays on under the game's Wine (the fault storm).
- **B.** Addons… changes reach a running client at once, through Ashita's Thirdparty plugin.
- **C.** The remembered account name is no longer focused and selected when the window opens.

## A. The fault storm: `WINE_DISABLE_NX_COMPAT=1` on every Play

### What was measured (2026-10-15, live, HorizonXI)

Without the variable, on the pinned game Wine (athei/wine-build `cx-26.3.0-1`, "wine-coop"),
under Rosetta:

- a steady ~85-94k page faults/s and ~380k Mach messages/s;
- 50-84% kernel time;
- 2-minute zone loads and multi-second freezes.

With `WINE_DISABLE_NX_COMPAT=1` set through Daniel's extra environment, the same character
select screen measured ~3k faults/s at 35-50% CPU. Daniel: "it seems to work as good as it ever
has". Three sessions exited cleanly (Ashita `UninstallAshita` Finished, no crash).

### Why

When a module without the PE `NX_COMPAT` flag loads, the i386 ntdll's `alloc_module` in that
build calls `NtSetInformationProcess(ProcessExecuteFlags, MEM_EXECUTE_OPTION_ENABLE)`. That turns
no-execute off for the whole process, for the rest of its life. Every later mapping is then
writable and executable. Under Rosetta, the first touch of such a page costs a Mach round trip,
so a client that allocates and clears memory all the time (DXVK's buffers) spends its time in
the kernel.

The only way out in that build is the environment variable `WINE_DISABLE_NX_COMPAT`. The build
checks only that it is present. Checked on a copy of the installed build
(`~/Downloads/FFXI-on-Mac-build/fixture/nx-compat/`): the name is in
`lib/wine/i386-windows/ntdll.dll` (UTF-16, one occurrence), not in `x86_64-unix/ntdll.so`.

Which modules trigger it. `DllCharacteristics`, read from copies of Daniel's HorizonXI install:

| Module | Flags | NX_COMPAT |
| --- | --- | --- |
| `bootloader/horizon-loader.exe`, `bootloader/pol.exe`, `bootloader/xiloader.exe`, `Ashita-cli.exe` | 0x8140 | yes |
| `Ashita.dll`, `d3d8.dll`, `d3d9.dll` (ours) | 0x0140 | yes |
| `FFXiMain.dll`, `FFXi.dll`, `FFXiResource.dll`, `FFXiVersions.dll` | 0x0000 | **no** |
| PlayOnlineViewer `pol.exe`, `polhook.dll`, `viewer/com/app.dll`, `viewer/com/polcore.dll` | 0x0000 | **no** |

The loaders have the flag, and that was as far as the earlier checks looked. Square Enix's DLLs
do not, and the client loads them in every world.

Upstream: [athei/wine-build#3](https://github.com/athei/wine-build/issues/3), reported by rdbell,
measured the same thing on FFXI with the same ratios. Example: seconds below 10 fps went from 24
to 1 with the variable set. The [cx-26.3.0-6 release notes](https://github.com/athei/wine-build/releases/tag/cx-26.3.0-6)
say "No-execute stays on under Rosetta, so 32-bit games without the `NX_COMPAT` flag no longer
crawl". On that build the variable means something else: "`WINE_DISABLE_NX_COMPAT=0` restores
the Windows behaviour for programs that execute their data". Any other value keeps no-execute
on. So the launcher always sets `"1"`. That is right on the pinned build (present) and on
`-6` and later (not `"0"`).

rdbell's PR #21 in this repo (DXVK "enforce-nx": DXVK itself sets DISABLE | PERMANENT) addressed
the same stall from inside DXVK. Its contributor licence is not cleared, so none of #17-#24 was
used. This change was written independently: one environment variable set by the launcher.

### What changed

- `app/Sources/HorizonXILauncher/Settings.swift:246` sets `WINE_DISABLE_NX_COMPAT=1`, beside the
  `DXVK_CONFIG_FILE` default, in `PerfSettings.environment(for:x87:world:gameWine:)`. That is
  whenever the client runs under the game's Wine (`gameWine`, default true).
- `Settings.swift:126` adds `PerfSettings.nxCompatKey`.
- `Settings.swift:130`: `extraEnvironment` parses the extra environment. An explicit value
  there still wins over every launcher default, this one included. New: `KEY=` with nothing after
  the `=` removes KEY, a launcher default included. Before, such a line was ignored. On the
  pinned build that is the only way to turn this off: any value, "0" included, counts as
  present there.
- `Runner.swift:1321` looks up `X87Sidecar.patchedWine()` once. The environment (`gameWine:`),
  the command (`:1365`) and the x87 watch (`:1386`) now agree on which Wine runs. Before, it was
  looked up three times.
- `Runner.swift` `spawnViaShell`: the game gets `WINE_DISABLE_NX_COMPAT` only when the
  environment above has it, never inherited from however the launcher was started, so
  `WINE_DISABLE_NX_COMPAT=` really turns it off (:1810). It is recorded in `last-spawn.txt`
  (:1827), so a launch shows whether it had it.

### Which worlds: all of them

Every world's game goes through `Runner.launch` → `PerfSettings.environment`, under the same game
Wine. Every world's client loads the Square Enix DLLs above.

- **HorizonXI**: measured (above).
- **Local server (LSB)**: the same client folder and `horizon-loader.exe` as HorizonXI
  (`Server.loader`, MultiWorld), so the same storm. Its seeded 640x480 graphics do not change
  which DLLs load.
- **CatsEyeXI**: plays through `Runner.launch` with its own `pol.exe` loader and the same SE
  DLLs, so it gets the variable. Its *own launcher* (`runCatsEyeLauncher`,
  `scripts/catseye-launcher.sh`) runs under the wrapper's Wine with its own environment and never
  calls `PerfSettings.environment`, so it is unchanged.
- **Gaia XI**: runs with x87, msync and DXVK off. Each was measured: its client exits a second
  after login with them (Servers.swift). None of that involves no-execute, so it gets the
  variable too. Not played under b66.

A world would need it off if its client executes its own data. That shows up as an access
violation at boot with no-execute on. No world has shown that: HorizonXI played three clean
sessions with it. If one does, the per-user switch is `WINE_DISABLE_NX_COMPAT=` in the extra
environment. A per-world flag (like `Server.x87`) would be the next step, with the measurement
that justifies it.

Not set for the wrapper's own Wine: that build was never measured with the variable. The
wrapper's Wine is only a fallback, and the client exits a second after login on it anyway
(docs/WINE-BUILD.md).

### Self-tests (`--selftest-perf`)

- Present by default under the game's Wine.
- Present for every built-in world, with x87 on or off.
- An explicit extra-environment value wins (`=0`, ` = 2 `), and other lines still work.
- `WINE_DISABLE_NX_COMPAT=` removes it, CRLF included. A later line still sets it again.
- Not set for the wrapper's Wine unless asked.
- `KEY=` drops a launcher default (`DXVK_CONFIG_FILE`). A line with no `=`, or no name, is
  ignored. `A==b` gives `=b`.

### Earlier dismissals, corrected

`BETA-59.md` (Performance), `HANDOFF.md` (PR table #21 and Performance item 2),
`MACOS-27-PERFORMANCE.md` (dependency review) and `NEXT.md` (item 7) all concluded that the
variable could not matter because the FFXI exes are NX_COMPAT. Each now says the DLLs are what
trigger it, and points here.

### Not changed: the benchmark harness

`scripts/harness` profiles build their own environment and do not set the variable. Every
harness and Play number taken before b66 ran with the storm. Comparisons across b66 must say
which side had it.

### Recommended later (not done): bump the game Wine to `cx-26.3.0-6` or later

The upstream fix makes the variable unnecessary. The launcher keeps setting `"1"`, which means
the same thing there. The pin is in `scripts/game-wine.sh`: `WINE_URL`, `WINE_BYTES`,
`WINE_SHA256`, `WINE_UNPACKED`. `X87Sidecar.swift` and `docs/WINE-BUILD.md` name `cx-26.3.0-1`.
Verify these first, in a throwaway prefix under `~/Downloads/FFXI-on-Mac-build/fixture/` with no
game running, then on the local world only, with Daniel's OK:

1. **The x87 cooperative hook is still there.** athei/wine `3804c30b` ("Recognize
   `ROSETTA_X87_PATH`"): look for the UTF-16 name in the new `lib/wine/i386-windows/ntdll.dll`.
   In-world, a live `x87sidecar-coop` in the session, no "x87 acceleration didn't attach", and
   `x87.brokenFor` still unset.
2. **The MoltenVK swap still applies.** `Renderer.upgradeCoopMoltenVK` replaces
   `lib/external/libMoltenVK.dylib` with the bundled 1.4.2. Confirm the new tree has that path
   and that the swap runs on it. DXVK 1.10.3 needs that MoltenVK (docs/MAX4K.md).
3. **Size and SHA-256** from a fresh download, against GitHub's release digest. On 2026-10-03,
   `-7` was unpacked in a lab, digest `4009323e…454e` (MACOS-27-PERFORMANCE.md). Also update
   `WINE_UNPACKED`.
4. **The client survives login.** That is why this Wine is used at all: the wrapper's own exits a
   second after login. The prefix update (`prefixStale` → `wineboot -u`) runs once for the new
   `wine.inf`.
5. **DEP stays on and is permanent.** On `-6`, requests to turn it off fail. Watch for a world
   whose client then faults at boot.

Existing installs keep their `wine-coop`. `game-wine.sh` only installs one that is missing, so a
bump reaches existing users only if Setup is made to replace an older pinned tree.

## B. Addons… changes apply at once while the game runs

Daniel asked whether addon loading and unloading could be instant with the game running. It can
now. Applying the Addons… sheet still writes `scripts/default.txt` first, exactly as before. Then,
if that world's client is running from the selected install, the lines that changed are handed
to the running client. A changed addon appears or disappears within a frame or two. Before, it
appeared or disappeared at the next Play.

### How

HorizonXI's own `default.txt` loads Ashita's **Thirdparty** plugin (in its "Horizon Launcher
Controlled Plugins" block; Daniel's log shows "Loaded plugin: thirdparty - Version: 4.10").
Thirdparty exposes the Windower-era keyboard block, `WindowerMMFKeyboardHandler_<pid>`. Anything
written there as a type-3 entry, it runs through `ChatManager::ParseCommand`: the same path as a
typed command. It runs it from the game's own keyboard read, about once a frame. The layout and
the handshake are from AshitaXI/thirdparty-src (`src/handlers/keyboard.cpp`, 9d6d7749) and were
checked against the installed `Thirdparty.dll`. The protocol is written out at the top of
`tools/ashita-send.c`.

- **`tools/ashita-send.c`** → `vendor/ashita-send.exe`, built by `scripts/build-ashita-send.sh`:
  - i686 mingw, static, stripped, no PE timestamp. The same source gives the same bytes.
  - Imports KERNEL32 and the C runtime only, with no user32, so it needs no desktop and touches
    no window or input.
  - Finds the client by trying `OpenFileMappingA` on the block's name for each process wine
    lists. It never reads any process.
  - Waits up to 3 s for `handled_ == 1`, writes the commands (';'-joined into up to 32 entries,
    one batch), then sets `handled_ = 0`. It then waits up to 5 s for `handled_` to come back
    to 1.
  - Exit codes: 0 delivered, 1 bad input, 2 no client, 3 more than one client (refuses to
    guess), 4 busy, 5 pending.
  - Commands come from argv, or from stdin one per line.
  - Bundled as `Contents/Resources/ashita-send.exe`. Notice and SHA-256: `vendor/NOTICE.md`. Its
    statically linked mingw-w64 runtime is ZPL 2.1; that text now ships in
    `ThirdPartyNotices/`.
- **`app/Sources/HorizonXILauncher/LiveAddons.swift`**:
  - `commands(from:to:policy:)`: the diff between the script as it was just before Apply and
    what Apply writes. Order: addon unloads, plugin unloads, plugin loads, addon loads.
  - `resolve(...)`: is the world's client running from this install, and under which wine?
  - `run(...)`: runs the helper under that wine, with the commands as arguments and its output
    to a file. Time limit 30 s.
  - `deliver` / `apply`: runs off the main thread on one serial queue, so two helpers never
    write the block together.
- **`App.swift`**, the sheet's Apply: reads the script, writes it as before, then
  `LiveAddons.apply(...)`. It logs one line per Apply to launcher.log (`logFileOnly`) and shows
  nothing on screen.

### What is sent, and what never is

- Only the items that changed. Only names the world's `AddonPolicy` allows are loaded, so
  HorizonXI never gets anything off its list or an fps monitor. Unloads go through for any name.
- Never `/unload` or `/reload thirdparty`: the plugin would free itself in the middle of running
  the command. Never `/load thirdparty` either, since it is the channel itself.
- Never `/unload` or `/reload addons`: that ends every Lua addon at once. `/load addons` is sent,
  ahead of the addon loads.
- Never `winefix`, `vanavoice` or `vanaguide`. The sheet does not list them anyway.
- A name with anything outside `A-Z a-z 0-9 _ - .` is not sent. **Deviation from the brief**,
  which said "strip ';'": stripping `clo;ck` would load `clock`, a different addon, so such a name
  is skipped instead. The plugin's `;` split can still never be reached from a name.
- The helper refuses the never-list, `;`, control characters, and `/unload` or `/reload` with no
  name, whoever asks. Every command is checked before anything is written, so a batch goes in
  whole or not at all.
- Only type 3 (command text) is ever written. The key types (1, 2, 1000) are not in the helper.

### When nothing is sent

The change then loads at the next Play, as it always did. Each case gets one `i ` or `!!` line in
launcher.log.

- No client of this world is running (the usual case).
- An injector is running, so a launch is under way.
- Another world's client is running too, so which plugin is which cannot be told from here. The
  helper also refuses two clients on its own (exit 3).
- No wineserver serves this install's prefix, so the client runs from another install. The
  helper is not run then, because wine would start a fresh wineserver for it. If a wineserver
  exits in the moment between the scan and the helper's start, that one window is left.
  Measured in the throwaway prefix: a wineserver the helper started ends by itself about 4 s
  after the helper exits, and leaves no wine process behind.
- The running wineserver is not from a wine this launcher runs.

How the helper joins the running game's wineserver:

- **Wine:** the one whose `bin/wineserver` is the running server's executable (compared after
  realpath, so the `lib/wine/../../bin/wineserver` form matches). The helper then speaks that
  server's protocol.
- **Sync mode:** read from the running wineserver (`LiveClients.wineserver(serving:among:)`, the
  same `ps -E` read as MULTI_WORLD.md rule 6).
- **Environment:** that prefix and sync mode, `WINEDLLOVERRIDES=mscoree,mshtml=;winemac.drv=d`
  and `WINEDEBUG=-all`. Nothing else of the game's environment is passed.

**Busy:** the plugin has not yet taken an earlier batch. It is retried, with a fresh scan and a
fresh helper about every 3 s, for up to 2 minutes, so a second Apply made while the first is
still waiting is not dropped. **Pending:** the batch is written but the game has not read its
keyboard for 5 s. It is not lost, and the plugin runs it whenever the game next reads its
keyboard. Whether FFXI under wine reads its keyboard while it is behind the launcher is **not
known**; see the in-game check.

The sheet's text is unchanged. **Correction to the brief:** it said the sheet "already says
changes apply next Play". It does not: the sheet's only text about it is the help tooltip on its
title ("Written to scripts/default.txt…"). No text was added either way.

### By hand: `--send-ashita`

```
FFXI-on-Mac --send-ashita "/addon load clock" [--world HorizonXI]
```

- Sends one command to that world's running client (default: the selected world) the same way.
- Refuses everything the helper refuses. On a hosted world it also refuses any `/addon load`,
  `/addon reload`, `/load` or `/reload` whose name is not on that world's published list. A
  hosted world with no published list gets no load at all. `/exec`, `/alias` and `/bind` are
  refused on hosted worlds, since they can run anything.
- Other commands pass, such as `/drawdistance setworld 5`.
- Headless, and exempt from SingleInstance (`isExempt`), so its `--world` is never handed to a
  running launcher window. It prints to stdout/stderr only; launcher.log is not touched.
- Exit: the helper's code; 1 refused; 2 not sent (with why); 64 usage.

### Tests

- **`--selftest-addons-live`, 47 checks:**
  - the diff (unchanged, untick, tick, order, plugins, thirdparty, the Lua host, launcher-managed
    names, HorizonXI's list and fps, the local world, unsourced policy, newly installed, odd
    names, duplicates, case);
  - the `--send-ashita` refusals;
  - exit codes;
  - the log line;
  - the helper's environment (exactly seven variables);
  - `resolve` on synthetic `ps` output (found with msync and esync, no client, injector, two
    worlds, localhost = 127.0.0.1, another install's prefix, a foreign wineserver, the
    wrapper's wine, the `../../bin` path);
  - the SingleInstance exemption, and that the helper is found and is a PE file.
- **`scripts/tests/ashita-send-test.sh`, 38 checks, all pass (the final version, run twice):**
  - The setup: the game's own wine (wine-coop, "wine-11.0"), a throwaway prefix at
    `~/Downloads/FFXI-on-Mac-build/fixture/ashita-send/prefix`, msync on.
  - The test refuses to start while any game client runs. It stops only that prefix's
    wineserver.
  - A fake plugin (`scripts/tests/ashita-send-fake-plugin.c`) creates the block under its own
    pid. It polls every 16 ms and does what the plugin's `update()` does (the ';' split, the
    '/' handling), writing down each command instead of running it.
  - Measured:
    - delivered: exact text, argv and stdin, in order, in 98-111 ms *including wine start-up*;
    - 200 commands in one batch, packed 89+89+22, all in order;
    - the never-list and malformed commands refused (exit 1) with nothing reaching the plugin,
      including a refused line inside a batch;
    - no plugin: exit 2;
    - two plugins: exit 3, nothing written to either; `--pid` picks one;
    - busy: exit 4 after 3.12-3.14 s; pending: exit 5 after 5.12-5.15 s; a send during a
      pending batch is busy.
  - The launcher's own path: the release build's `--selftest-addons-live` with
    `HXI_LIVE_ADDONS_WINE_PREFIX` set. It found the fake (filed under `--server fake.invalid`)
    from the live scan, with its wineserver, wine and msync, and delivered through
    `LiveAddons.run` in 0.14-0.16 s. The helper refused `/unload thirdparty`. In a second run, an
    earlier batch held for 6 s gave busy and then delivered, after 2 tries and 5.8 s, and the
    fake ran the two batches in order.
- All 25 suites pass. launcher.log was identical (inode, mtime, size) before and after.

None of this ran against a real client. That was not allowed while Daniel was playing, and the
helper has never touched his prefix.

### Risks

- **Never run against a real Thirdparty.** The layout and the handshake are from the source and
  the disassembly. The fake mirrors the source's `update()`. The first real test is the in-game
  check below.
- **Background reads:** if the game does not read its keyboard while unfocused, an Apply made
  from the launcher is "pending" and runs the moment the game window is clicked back into.
  Applies made meanwhile are retried for 2 minutes and then left for the next Play.
- **How the command arrives:** Thirdparty passes mode -1 (AshitaParse), not Typed. Plugins and
  addons see `injected = true`. `/addon load` and `/load` are Ashita's own commands and ignore
  both.
- **Frame hitch:** an addon loads inside one game frame, the same hitch as typing the command.
- **HorizonXI's rules:** Thirdparty ships in HorizonXI's own script but is not on its published
  plugin list. It is used here only to send what the player could type, and only for names on
  HorizonXI's list; no packet is sent.
- **Two clients in one prefix** (HorizonXI plus the local world): nothing is sent; it waits for
  the next Play. Matching a client by process start time, the research's suggestion, is not
  built.
- **Busy retries:** each retry starts a short wine process (about 0.1 s of work), every 3 s for
  at most 2 minutes, and only while the plugin is still busy.

### In-game check (Daniel)

This needs b66 installed. It is not installed yet: `bundle.sh` was not run, because it
re-registers the bundle with Launch Services.

1. Play HorizonXI from the b66 launcher and log in. `clock` is on in your script now.
2. In the launcher: **Addons…** → untick **clock** → **Apply**. The clock disappears at once.
   If it only goes when you click back into the game window, that is the "pending" case and is
   worth telling me.
3. **Addons…** → tick **clock** → **Apply**. It comes back.
4. `~/Library/Application Support/HorizonXI-on-Mac/launcher.log` should have one line per
   Apply. For example, `==> addons, live in HorizonXI: /addon unload clock: delivered (0.2 s)`,
   or `i  … handed over, not taken yet …` for pending.
5. Optional, from Terminal:
   `/Applications/FFXI-on-Mac.app/Contents/MacOS/FFXI-on-Mac --send-ashita "/addon unload clock" --world HorizonXI`
   prints `delivered`. Running it again with `"/addon load clock"` brings the clock back.

## C. The account field when the window opens

### What happened

When the window opened, the remembered account name was in a focused field with all of its text
selected. Daniel was typing in another app while the launcher came up, and two keystrokes
replaced the name with "de".

### Cause

No code focused the field: `focus = .account` only runs from the main button's "enter account"
step. The first time a window is shown, AppKit makes its first key view the first responder.
Here that is the account `TextField`. An `NSTextField` that becomes first responder that way
selects all of its text.

### What changed

- `app/Sources/HorizonXILauncher/OpenFocus.swift` (new; `OpenFocus` at :17, `OpenFocusAnchor`
  at :41):
  - `OpenFocus.focusAccount`: focus the account field only when it is empty and editable.
  - `OpenFocus.isSelectAll`: the signature of a field focused by the window, not by a click.
  - `OpenFocus.isTyping`: which keys count as typing.
  - `OpenFocusAnchor`: a zero-size `NSView`, made the window's `initialFirstResponder` before the
    window is first shown (:77). AppKit gives it the keyboard instead of the first text field.
    Typing while it holds the keyboard is dropped, with no beep. Tab, Return (Play), Escape,
    arrows and shortcuts carry on as before. It is never a Tab stop itself (:61).
  - Just after the window first becomes key, then once more 0.4 s later (SwiftUI may apply its
    own default focus a pass later, :97): a field found focused with *all* of its text selected
    is let go of (`releaseSelectAll`, :107), and its text is untouched. A click leaves a caret, so a field the user clicked
    keeps the keyboard.
- `App.swift:343`: the anchor sits behind the window's content. Once the window has opened, the
  account field is focused only if no field is focused yet and
  `OpenFocus.focusAccount(accountName: user, …)` holds. The field is empty then, so nothing is
  selected. The local world's disabled fields are never focused.

The main button's "enter account" step (`focus = .account` or `.password`) is unchanged.

### Self-tests (`--selftest-ui-text`)

The rules, and the same in AppKit on a window that is created but never shown:

- The anchor is that window's initial first responder.
- A field the window focuses has all of its text selected. This is the bug, reproduced.
- The anchor takes the keyboard back, and the text is unchanged.
- A field with a caret keeps the keyboard.
- A letter typed while the anchor holds the keyboard changes nothing.
- Tab from the anchor reaches the field, and the anchor is not a Tab stop.

### Probe in a real SwiftUI window (not part of the suites)

A throwaway program used the same `OpenFocus.swift` and a SwiftUI `TextField` (filled in) plus a
`SecureField` in an `NSHostingView`. Each window was put on screen off to the side
(`orderFrontRegardless` at -5000,-5000), from a process that is never active, so nothing took
the keyboard from anyone. One second later:

| Window | First responder |
| --- | --- |
| without the anchor | the field editor, text `someaccount`, selection {0, 11}: all selected (the bug) |
| with the anchor | `AnchorView` |

Not covered by either:

- The empty-name case, where the account field is focused once the window becomes key. A window
  only becomes key in an active app, and the probe never activates.
- The launcher's real window. Starting the launcher was off limits while Daniel was playing.

The manual check below covers both.

### Manual check

1. Quit the launcher with no game running.
2. With "Remember me" on and an account name saved, open FFXI on Mac and type a few letters at
   once. The name is unchanged, no field shows a focus ring, and nothing is selected.
3. Press Tab: the keyboard moves into the fields.
4. Click into the name: a caret, not a selection.
5. Clear the name, quit, reopen: the empty account field has the cursor.
6. Pick the local world: no field is focused.

## Tests

Release build (`swift build -c release`, `nice -n 19`, scratch path
`~/Downloads/FFXI-on-Mac-build/swift-build`). It was built once Daniel's game had exited.
Nothing was running during the builds, the suites or the probe. Only the two old warnings
(LocalServer.swift:251, Runner.swift:1971).

- All 25 `--selftest-*` suites pass (re-run after B; B's suite and wine test are in section B):
  - addons-live: 47, all new (B);
  - perf: 45, of which 6 are new (A);
  - ui-text: 33, of which 9 are new (C);
  - primary-action 77/77, install-location 107/107, install-selection 21/21,
    setup-progress 27/27;
  - graphics 64, boot-profile 43, dxvk-cache 39, leftovers 26, news 36, retroachievements 47,
    multiworld 72, updater 79;
  - all checks passed in: addon-install, addon-installer, addon-policy, addon-profile,
    addon-scrub, addon-source, cursor-fix, guide-disabled, narration-disabled, single-instance.
- launcher.log: identical (inode, mtime, size) before and after the suites.
- Nothing was launched, signalled or focused. No game, launcher or Wine process was touched.
  Daniel's installs were only read: the PE headers and ntdll come from copies in
  `~/Downloads/FFXI-on-Mac-build/fixture/nx-compat/`.

Not tested here: a Play under b66. The variable's effect was measured live by Daniel's own
session (A, above), and the launcher now sets the same value. The first b66 Play should show
`WINE_DISABLE_NX_COMPAT=1` in `~/Library/Application Support/HorizonXI-on-Mac/last-spawn.txt`.
