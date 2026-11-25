# In-game cursor: DXVK 1.10.3 erases FFXI's Hardware Mouse

**Status, 2026-10-16:**

- **Cause: likely.** It is confirmed from source, imports and logs. There is no runtime trace yet.
- **Fix:** written as a patch hunk, and `git apply --check` passes on a clean v1.10.3.
- **DLL:** rebuilt 2026-10-17 for b70 (`70ba5664…`, `patches/README.md`), together with the
  device-lost fix (`docs/BETA-70.md` §5). Not run yet: the probe and the A/B below need Wine.

## Symptom

On 2026-10-16 Daniel said: "I can't see my cursor even though hardware cursor is enabled."

- **World:** HorizonXI, on the new install from 2026-10-15.
- **Boot profile:** `0021 = 1` (Hardware Mouse). It was seeded from
  `app/Resources/horizonxi-boot.ini:101`, which is HorizonXI's stock value.
- **Not related to the freeze that day.** That was the game drive disconnecting; see
  `docs/BETA-70.md`.

## The chain

1. **FFXI's Hardware Mouse is a plain Win32 animated cursor, not a D3D one.** *(likely)*
   - `FFXiMain.dll` imports `SetCursor`, `LoadCursorA`, `LoadCursorFromFileA` and `SetCursorPos`
     from USER32. It does not import `ShowCursor` or `ClipCursor`.
   - It names `mousenor.ani`, `mousehit.ani` and the `arw_*.ani` files, which sit in the FFXI
     folder.
   - Nothing in the game process imports user32 `ShowCursor`. Only PlayOnlineViewer's `pol.exe`
     does.
2. **The game's `IDirect3DDevice8::ShowCursor` reaches DXVK unchanged.** *(likely, not traced)*
   d3d8to9 (`vendor/d3d8to9.dll`, v1.15.1) passes it straight through
   (`source/d3d8to9_device.cpp:164-167`).
3. **DXVK 1.10.3 then calls `SetCursor(NULL)`.** *(verified in source)*
   - `D3D9Cursor::ShowCursor` (`src/d3d9/d3d9_cursor.cpp:17-20`) does
     `::SetCursor(bShow ? m_hCursor : nullptr)`.
   - `m_hCursor` is set only by `SetCursorProperties`, and FFXI never sets a D3D cursor.
   - So every call becomes `SetCursor(NULL)`, `TRUE` as well as `FALSE`.
   - This is the only `SetCursor` call in our patched tree.
4. **Wine hides the Mac cursor.** *(verified in source; game wine athei cx-26.3.0-1)*
   - In `server/queue.c`, `set_cursor` makes the effective cursor 0 and posts
     `WM_WINE_SETCURSOR`.
   - From there the call goes win32u `process_wine_setcursor` → winemac
     `macdrv_SetCursor(hwnd, 0)` → `macdrv_set_cursor(NULL, NULL)` → `hideCursor` →
     `+[NSCursor hide]`.
   - The cursor stays hidden while the pointer is over a Wine window. It comes back when the
     pointer leaves (`cocoa_app.m` `updateCursor`, 1064-1075).
5. **Native D3D9 and wined3d never do this.**
   - Wine's `dlls/d3d9/tests/device.c` `test_cursor` (line 1853 on master) has been checked
     against Windows.
   - It expects the Win32 cursor handle "unchanged", and expects `ShowCursor` to enable nothing
     until a cursor surface is set.

## Why HardwareMouse cannot help

HorizonXI's approved HardwareMouse plugin ("Force-enables the game mouse while using certain
graphics proxies") detours user32 `SetCursor`.

- It drops `SetCursor(NULL)` only when the caller is `d3d8.dll`
  (AshitaXI/hardwaremouse-src `src/hardwaremouse.cpp:36-42`, detour at :100-103).
- Our `d3d8.dll` is d3d8to9, which imports only `GetDC`, `ReleaseDC` and `MessageBoxW` from USER32.
- The `SetCursor(NULL)` comes from `d3d9.dll` (DXVK). DXVK imports `SetCursor`,
  `CreateIconIndirect` and `SetCursorPos`.
- So the filter never matches. The plugin loads and runs: the Ashita log on 2026-10-16 shows
  `Loaded plugin: hardwaremouse - Version: 4.10` at 11:31:41.417, then hours of play. It just does
  nothing here.

Leave it in the managed block. It is on HorizonXI's list (`AddonPolicy.swift:107`).

## Why it showed up on 2026-10-15

*(likely)* The new install was seeded with `0021 = 1`.

The old siku.app install had run with `0021 = 0` since about 2026-08-16. The pre-b64 Graphics
panel wrote `environmentAnimation` to `0021` (eedb715; `docs/BETA-64.md` table A).

With `0021 = 0`, FFXI draws its own software sprite into the frame. That sprite was seen working
on 2026-08-15: "game cursor visible, consistent, draws UNDER addon windows".

The local LSB world hides the bug. There, `winecursor` (loaded only on unrestricted worlds,
`CursorFix.swift`) sets an arrow every frame.

## The fix

Backport DXVK b0b46fd075.

- **Upstream:** PR #3562 by WinterSnowfall, written 2023-07-16, merged 2023-08-02, first released
  in v2.3. The PR names the same failure: Age of Mythology's Win32 cursor went missing because
  `ShowCursor(TRUE)` set it to `nullptr`.
- **Where:** the hunk is in both `patches/dxvk-1.10.3-horizonxi*.patch` files, in
  `src/d3d9/d3d9_cursor.cpp`.
- **With no D3D cursor set:** `ShowCursor` no longer calls `SetCursor`. It still records the
  visibility and returns the previous value.
- **`SetHardwareCursor` is untouched.** A game that does set a D3D cursor behaves exactly as on
  1.10.3.

**Not taken:** upstream bbe82aa534 (v2.5, "Fix (most) cursor-related Wine tests").

- With no cursor set, it also stops recording `bShow`, which matches Wine's "Not enabled without a
  surface".
- That only changes what a later `SetCursorProperties` shows, and FFXI never calls it.
- So the backport stays at the single upstream change that names this bug.

**What the fix does not do:**

- add no addon or plugin;
- change no game memory;
- inject no input;
- change no launcher code.

It is a change in the renderer DLL the launcher already ships. (`FFXI_FPS_DIVISOR`, in the same
DLL, does write game memory. It is a separate question; see `patches/README.md`.)

## Test plan

Use a throwaway prefix and the local LSB world only. Never use HorizonXI for the A/B, and never
test while a game runs.

1. **Probe.** Run `scripts/harness/cursorprobe.c`, following its header.
   - It sets `mousenor.ani`, makes a D3D9 device through the DLL under test, then calls
     `ShowCursor(FALSE)` and `ShowCursor(TRUE)`.
   - Expected: b69's DLL (`e5f1a6b9…`) prints FAIL, and b70's (`70ba5664…`) prints PASS.
2. **Local world, `0021 = 1`, with the stock DLL.**
   - Change only the `0021` line of `lsb.ini`. The boot profiles hold a password: never read or
     print them whole.
   - Set Settings → Extra environment `WINEDEBUG=+cursor`.
   - Type `/addon unload winecursor` in the client.
   - Expected: after the `.ani` handle is set, the log shows `NtUserSetCursor` with a 0 handle,
     and no cursor is visible over the game.
3. **Same, with the patched DLL.**
   - Expected: no 0-handle `SetCursor` from d3d9.
   - The gauntlet is visible and animated. Check with `screencapture -C`, which includes the
     cursor.
4. **Patched DLL with `0021 = 0`.**
   - Expected: exactly one cursor, FFXI's sprite.
   - The risk: FFXI's software-cursor mode may have relied on DXVK's accidental hide. Then a Mac
     arrow would now sit on top of the sprite.
5. **Afterwards:** remove `WINEDEBUG=+cursor` from Extra environment (it applies to every world),
   and put `0021` back.

**Only real play can show:**

- the cursor visible and animated on HorizonXI;
- still hidden during a held-button camera drag;
- Cmd-Tab out and back still working.

## Fallback, if the A/B fails

Hardware Mouse off (`0021 = 0`), so FFXI draws its own software sprite.

- The sprite is drawn at the game's frame rate, so it lags a little at 30 fps.
- Change only the `0021` line, through `BootProfile.setting`, and only with Daniel's OK.
- b70 plan item 8 adds a Graphics-panel toggle only if this path is needed.

**Never:**

- `winecursor` or any other unapproved addon on HorizonXI;
- removing HardwareMouse from the managed block;
- merging `origin/cursor-visible-as-dylib` (94a8984) as the fix. It was never tested in-game and
  only works on this exact winemac. It would also block FFXI's intended hides (software-mouse
  mode, and probably the held-button camera).
