#!/bin/zsh
# install.sh — configure a Wine prefix so HorizonXI (Final Fantasy XI) actually launches on macOS.
#
# Assumes: a Sikarugir/Kegworks-style wrapper .app containing a wine build, and the HorizonXI
# client already extracted to <prefix>/drive_c/HorizonXI (~27GB).
#
# This encodes the configuration that was proven to work on an M1 MacBook Pro, macOS 26.5,
# Wine 10.0 (Sikarugir), HorizonXI client 1.9.0, Ashita 4.3.1.2 — the first time FFXI has
# rendered natively on macOS. Every step here is load-bearing; see docs/FINDINGS.md for the
# instrumented evidence behind each one.
#
#   ./install.sh /path/to/wrapper.app [prefix-name]

set -euo pipefail

APP="${1:?usage: install.sh /path/to/wrapper.app [prefix-name]}"
PREFIX_NAME="${2:-prefix10}"
SHARED="$APP/Contents/SharedSupport"
export WINEPREFIX="$SHARED/$PREFIX_NAME"
WINE="$SHARED/wine/bin/wine"
GAME_C='C:\HorizonXI'
GAME_DIR="$WINEPREFIX/drive_c/HorizonXI"
SE_C="$GAME_C\\SquareEnix"
REG32='C:\windows\syswow64\reg.exe'

[[ -x "$WINE" ]] || { echo "no wine at $WINE" >&2; exit 1; }
[[ -d "$WINEPREFIX/drive_c/HorizonXI" ]] || { echo "no client at $WINEPREFIX/drive_c/HorizonXI" >&2; exit 1; }

info() { print -P "%F{cyan}==>%f $*"; }

# ---------------------------------------------------------------------------
# 1. dylib rpath.
#
# The wrapper's wine/wineserver are linked with rpath @loader_path/../../, which resolves to
# SharedSupport/, but the dylibs ship in Contents/Frameworks/. Everyone works around this by
# exporting DYLD_FALLBACK_LIBRARY_PATH — do not. SIP strips DYLD_* when exec'ing a protected
# binary, which includes nohup and /bin/sh, so anything scripted or backgrounded breaks with an
# unexplained "dyld: Library not loaded". Symlinking removes the env dependency entirely.
# ---------------------------------------------------------------------------
info "fixing dylib rpath"
"${0:h}/fix-wine-rpath.sh" "$APP" >/dev/null || true

# ---------------------------------------------------------------------------
# 2. PlayOnline registry.
#
# Taken verbatim from HorizonXI's own Switch_Horizon.bat, which ships in SquareEnix/. The layout
# is not what it looks like:
#   InstallFolder\0001 = the FINAL FANTASY XI directory   (NOT PlayOnlineViewer)
#   InstallFolder\1000 = the PlayOnlineViewer directory
#   Interface\0001     = the string "0"
# Putting PlayOnlineViewer in 0001 — the intuitive reading — stops FFXiMain.dll loading at all.
#
# Write BOTH registry views. The 32-bit game reads HKLM\SOFTWARE\Wow6432Node\..., and the 64-bit
# reg.exe writes only the 64-bit view, so a prefix configured with plain `wine reg add` leaves the
# game seeing nothing.
# ---------------------------------------------------------------------------
info "writing PlayOnline registry (both views)"
for REG in "$REG32" reg; do
  "$WINE" $REG add "HKLM\\SOFTWARE\\PlayOnlineUS\\InstallFolder" /v 0001 /d "$SE_C\\FINAL FANTASY XI" /f >/dev/null 2>&1
  "$WINE" $REG add "HKLM\\SOFTWARE\\PlayOnlineUS\\InstallFolder" /v 1000 /d "$SE_C\\PlayOnlineViewer" /f >/dev/null 2>&1
  "$WINE" $REG add "HKLM\\SOFTWARE\\PlayOnlineUS\\Interface"     /v 0001 /d "0" /f >/dev/null 2>&1
done

# Option must behave as Alt, or no Alt-based macro can ever be typed. Wine's Mac driver defaults
# both Option keys to composing special characters instead, which silently costs the player every
# Alt keybind — Ashita macro books included.
"$WINE" reg add "HKCU\\Software\\Wine\\Mac Driver" /v LeftOptionIsAlt  /d y /f >/dev/null 2>&1
"$WINE" reg add "HKCU\\Software\\Wine\\Mac Driver" /v RightOptionIsAlt /d y /f >/dev/null 2>&1

# The client ships pol.reg / polu.reg; polu.reg holds HKCU video settings the game needs present.
for r in pol polu; do
  [[ -f "$WINEPREFIX/drive_c/$r.reg" ]] && "$WINE" regedit /S "C:\\$r.reg" >/dev/null 2>&1 || true
done

# ---------------------------------------------------------------------------
# 3. COM registration.
#
# FFXI is three in-proc COM servers, not one: FFXi.FFXiEntry (FFXi.dll),
# FFXiMain.GameMain (FFXiMain.dll) and POLCore.POLCoreCom (polcore.dll). Missing any of them
# gives "Failed to initialize instance of FFxi!" or a bare err:ole:com_get_class_object.
#
# The /s flag is mandatory: without it FFXi.dll's DllRegisterServer opens a GUI dialog, and
# synthetic input (CGEvent) does not reach wine-hosted windows on macOS, so it hangs forever
# with nothing to click.
# ---------------------------------------------------------------------------
info "registering FFXI COM servers"
for d in FFXi.dll FFXiMain.dll FFXiVersions.dll; do
  "$WINE" regsvr32 /s "$SE_C\\FINAL FANTASY XI\\$d" >/dev/null 2>&1
done
"$WINE" regsvr32 /s "$SE_C\\PlayOnlineViewer\\viewer\\com\\polcore.dll" >/dev/null 2>&1

# ---------------------------------------------------------------------------
# 3b. Metal renderer (the performance fix).
#
# EXPERIMENTAL, OFF BY DEFAULT -- set HXI_METAL=1 to try it.
#
# Wine's builtin D3D8 runs through OpenGL and is translated on a single CPU thread: measured at
# 148% CPU with the GPU at 6%. Routing D3D8 -> d3d8to9 -> DXVK 1.10.3 -> MoltenVK -> Metal gets
# the CPU down to ~11-16% with the GPU at 24-32% -- but the window stays BLACK. DXVK creates the
# device, the GPU does work, and no frame is ever presented (watched for 6 minutes; the OpenGL
# path draws its splash in ~40s). So the low CPU partly reflects it not drawing. Presentation is
# the unsolved part; do not mistake the counters for a working renderer.
#
# Three things all have to be true or it silently fails:
#
#   1. api-ms-win-crt-*. This wine build ships NONE, and every renderer DLL imports a dozen of
#      them, so none of them can load in a stock prefix. The wrapper's own wine.cx32bak has
#      working 32-bit copies.
#   2. Ashita.dll imports d3d8.dll itself, so the shim must also sit where Ashita can see it --
#      C:\HorizonXI and bootloader\ -- not only in the game directories. Miss this and you get
#      "[E] Injection failed!", which looks like the renderer breaking Ashita and is not.
#   3. MoltenVK. The default libMoltenVK in the wrapper reports Vulkan 1.1 and DXVK cannot create
#      a device on it ("DxvkAdapter: Failed to create device"). The moltenvkcx build alongside it
#      reports Vulkan 1.2 and works. DXVK 2.x/3.x cannot be used at all -- they require Vulkan 1.3
#      and geometryShader, which Metal has no equivalent for.
# ---------------------------------------------------------------------------
if [[ -n "${HXI_METAL:-}" && -f "${0:h}/../vendor/d3d8to9.dll" && -f "${0:h}/../vendor/dxvk-1.10.3-x32-d3d9-horizonxi.dll" ]]; then
  info "installing the Metal renderer (DXVK 1.10.3 + d3d8to9)"
  SYSWOW="$WINEPREFIX/drive_c/windows/syswow64"
  mkdir -p "$WINEPREFIX/drive_c/dll-backup"
  for d in d3d8 d3d9; do
    [[ -f "$SYSWOW/$d.dll" && ! -f "$WINEPREFIX/drive_c/dll-backup/$d.builtin.dll" ]] \
      && cp "$SYSWOW/$d.dll" "$WINEPREFIX/drive_c/dll-backup/$d.builtin.dll"
  done

  # 1. the CRT api-sets wine does not ship
  CRT="$SHARED/wine.cx32bak/lib32on64/wine"
  if [[ -d "$CRT" ]]; then
    cp "$CRT"/api-ms-win-crt-*.dll "$SYSWOW/" 2>/dev/null || true
  else
    echo "  ! no api-ms-win-crt-* source found; the renderer will not load" >&2
  fi

  # 2. every directory whose process loads d3d8 -- including Ashita's
  for d in "$WINEPREFIX/drive_c/windows/syswow64" \
           "$GAME_DIR" "$GAME_DIR/bootloader" \
           "$GAME_DIR/SquareEnix/PlayOnlineViewer" "$GAME_DIR/SquareEnix/FINAL FANTASY XI"; do
    [[ -d "$d" ]] || continue
    cp "${0:h}/../vendor/d3d8to9.dll" "$d/d3d8.dll"
    cp "${0:h}/../vendor/dxvk-1.10.3-x32-d3d9-horizonxi.dll" "$d/d3d9.dll"
  done

  for REG in "$REG32" reg; do
    "$WINE" $REG add "HKCU\\Software\\Wine\\DllOverrides" /v "*d3d8" /d native /f >/dev/null 2>&1
    "$WINE" $REG add "HKCU\\Software\\Wine\\DllOverrides" /v "*d3d9" /d native /f >/dev/null 2>&1
  done

  # 3. the MoltenVK that can actually create a Vulkan 1.2 device
  MVK="$APP/Contents/Frameworks/moltenvkcx/libMoltenVK.dylib"
  LINK="$SHARED/wine/lib/libMoltenVK.dylib"
  if [[ -f "$MVK" ]]; then
    [[ -e "$LINK" && ! -e "$LINK.stock" ]] && mv "$LINK" "$LINK.stock"
    ln -sf "$MVK" "$LINK"
  else
    echo "  ! moltenvkcx not found; DXVK will fail to create a device" >&2
  fi
fi

# ---------------------------------------------------------------------------
# 4. Launcher.
#
# Launch through Ashita-cli, not xiloader directly. With the registry above but launched
# xiloader-direct, the game still exits silently before creating its window; through Ashita it
# runs. Always pass the absolute C:\ path — wine resolves a bare exe name against
# C:\windows\system32, not the cwd.
# ---------------------------------------------------------------------------
info "writing launcher"
LAUNCHER="${APP:h}/Play HorizonXI.command"
cat > "$LAUNCHER" <<EOF
#!/bin/zsh
W="$APP"
export WINEPREFIX="\$W/Contents/SharedSupport/$PREFIX_NAME"
export D3DMETAL_FRAMEWORK_PATH="\$W/Contents/Frameworks/renderer/d3dmetal/external"
export WINEDEBUG=-all
cd "\$WINEPREFIX/drive_c/HorizonXI" || { echo "game dir missing"; exit 1; }
exec "\$W/Contents/SharedSupport/wine/bin/wine" "C:\\\\HorizonXI\\\\Ashita-cli.exe" horizonxi.ini
EOF
chmod +x "$LAUNCHER"

info "done — launch with: $LAUNCHER"
echo
echo "Note: the character-select screen needs a real keypress. Synthetic input does not reach"
echo "wine windows on macOS, so that step cannot be scripted; click the window and press Enter."
