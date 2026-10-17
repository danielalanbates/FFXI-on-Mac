# Mouse input on Wine — cursor invisible, addon windows unclickable

Measured 2026-08-17 with the `mousediag` addon (`addons/mousediag/mousediag.lua`).

**Corrected 2026-10-16:** the cursor claims below were wrong. The invisible cursor is the
vendored DXVK 1.10.3 calling `SetCursor(NULL)`; see `docs/CURSOR-DXVK.md`. Clicking is a
separate problem and is unchanged.

## Symptoms
- Mouse cursor invisible inside the game window.
- Ashita/ImGui addon windows (Links, HXUI, …) can't be hovered or clicked.

## Root cause
Ashita received **zero** mouse messages. `mouse events=0`, `MouseDown0=nil`,
`hovered=false` — confirmed with the pointer driven across the focused client area by
CGEvent *and* a real HID left-click posted at the window centre. Meanwhile
`io.MousePos` tracked perfectly, because Ashita polls `GetCursorPos` for position.
Position worked; the button/hover *message* stream was dead.

Separately, the cursor. *(Corrected 2026-10-16.)* This page said FFXI calls `ShowCursor(FALSE)`
and draws a sprite that does not render. Both halves are wrong.

- **No `ShowCursor` call.** Nothing in the game process imports user32 `ShowCursor`. Only
  PlayOnlineViewer's `pol.exe` does.
- **No sprite with Hardware Mouse on.** With Hardware Mouse on (`0021 = 1`), FFXI draws no
  sprite. The Aug 17 10:13 profile backup has `0021 = 1`, so this run most likely had it on.
  - Its cursor is a Win32 `.ani` (`mousenor.ani`, set with `SetCursor`).
  - DXVK 1.10.3's `IDirect3DDevice9::ShowCursor` replaces that cursor with `SetCursor(NULL)`
    whenever no D3D cursor is set.
- **With Hardware Mouse off,** FFXI draws its own sprite into the frame, and that renders: seen
  2026-08-15.

## NOT the cause
**RetinaMode.** Client rect and ImGui DisplaySize are both exactly 1920x1080,
`io.MousePos` matches the Win32 client cursor position exactly, and Wine screen coords
are exactly 2x macOS points with a clean conversion. An earlier `RetinaMode=n` "fix"
was a pure regression and has been reverted. Do not revisit it.

## Also ruled out by test
- `mouse.unhook=0` in `config/boot/horizonxi.ini` — no change.
- `io.MouseDown[0] = x` from Lua — Ashita's ImGui binding is read-only
  (`MouseDown assignable: false`).
- **`HardwareMouse.dll`: no help here, but not harmful any more** *(corrected 2026-10-16)*.
  - On 2026-08-17 the client died during startup with it loaded.
  - HorizonXI's managed block now loads it (`AddonPolicy.swift:107`). On 2026-10-16 it loaded at
    11:31:41 and ran for hours. The 08-17 death has no known cause and has not recurred.
  - It cannot fix the cursor on this stack. It drops `SetCursor(NULL)` only when the call comes
    from `d3d8.dll`, and ours comes from DXVK's `d3d9.dll`.

## 2026-08-21: injection is OFF again, and why

Restoring the synthetic message stream (step 2 below) made the game unplayable in a way the
original removal note never described: **Cmd-Tab back into the game and the camera spins**, and
clicking does not stop it. FFXI reads mouse-look as a delta from a captured position; a synthetic
WM_MOUSEMOVE posted on the frame focus returns hands it a delta the size of the screen, which it
keeps applying. Releasing the buttons on focus loss does not help — the spin is a *move*, not a
held button.

So injection is behind `FFXI_MOUSE_INJECT=1` and off by default. The cursor fix (step 1) is
unrelated, stays on, and is what stopped the blinking.

**Clicking addon windows is therefore still unsolved**, and the two obvious paths are both known
bad: this injection spins the camera, and `HardwareMouse.dll` only filters `SetCursor`, so it was
never a click fix. (It does not kill the client either; corrected 2026-10-16, see above.) What
has *not* been tried is fixing the message stream at its source — Ashita 4.3's own mouse hook
(`mouse.unhook` in the boot profile was tested and did nothing, but the hook itself was never
read) or a DirectInput-side interposer. That is where the next attempt should go, rather than at
another round of posting WM_ messages into a game that is doing its own mouse-look maths.

## The fix (verified working)
In `mousediag.lua`, per frame:

1. `SetCursor(LoadCursorA(nil, IDC_ARROW))` then drive `ShowCursor(1)` until the
   internal show-count is >= 0. Log line `ShowCursor count -> 1` means visible.
   **This is what made the cursor appear.**
   - *2026-10-16:* most likely the per-frame `SetCursor` did the work. It puts a cursor back
     after DXVK's `SetCursor(NULL)`.
   - The show-count is unlikely to matter, since nothing in the game calls `ShowCursor`.
2. (**Off by default — see the 2026-08-21 note above.**) Synthesise the missing message stream from `GetCursorPos` + `GetAsyncKeyState` and
   `PostMessageA` it to the `FFXiClass` window (WM_MOUSEMOVE 0x200,
   WM_LBUTTONDOWN/UP 0x201/0x202, WM_RBUTTONDOWN/UP 0x204/0x205). After this,
   `mousediag` reports `msgs=136` and climbing where it was pinned at 0.

Known rough edge: once messages flow, `io.MousePos` can read as -FLT_MAX (ImGui's
"no mouse" sentinel) and `client` coords stop differing from `screen` coords, which
suggests the `ScreenToClient` target window handle is wrong in that path. Clicking
should be re-verified against a real in-world addon window before calling it done.

## Shell -> game command channel
`mousediag` polls `addons/mousediag/cmd.txt` every frame and queues each line via
`AshitaCore:GetChatManager():QueueCommand(-1, line)`. Closes any addon window with no
mouse at all:

    printf '/addon unload links\n' > "$PREFIX/drive_c/HorizonXI/addons/mousediag/cmd.txt"

Verified by before/after screenshot on the Links box.

## Unclosable Wine windows
Cause: Wine's `winedbg --auto` crash dialog. Editing AeDebug in `system.reg` does NOT
stick — Wine rewrites `system.reg` on shutdown from its in-memory copy. Fix is
process-level:

- `scripts/quit-wine.sh` force-closes every Wine window/process
  (`wineserver -k` then a `pkill -9` sweep). Verified to 0 remaining.
- Launch alongside a reaper loop that `pkill`s `winedbg --auto` every 2s, so a crash
  can never leave a stuck window:

      while pgrep -qf "Ashita-cli.exe|horizon-loader.exe"; do
        pkill -f "winedbg --auto"; sleep 2
      done

## Gotchas
- Boot to first ImGui frame is ~60-80s (DXVK first frame). Don't judge by screenshot
  before then.
- Launching via `nohup` inside a tool call that later times out kills the game.
- The client needs a real keypress at the PlayOnline "Accept" screen, so fully scripted
  runs never reach the world and in-world addons aren't loaded there.

## Security
The HorizonXI password is plaintext in `config/boot/horizonxi.ini` and appears in `ps`
output. Worth changing how it's passed.
