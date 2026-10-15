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
#   ./install.sh /path/to/wrapper.app [prefix-name] [game dir] [SquareEnix as C:\ or Z:\ path] [SquareEnix dir]
#
# The launcher's Repair passes all five, plus HXI_WINE (the wine Play runs, so a Repair does not
# leave the prefix stamped by another wine and make the next Play stop to update it). With only
# the first two it configures the classic <prefix>/drive_c/HorizonXI layout with the wrapper's
# own wine, as it always did.
#
# Nothing is written until the game data is known to be reachable: on 2026-10-15 a Repair ran
# against a ghost-mounted 'Games' drive, rewrote the registry, re-updated the prefix and then died
# in regsvr32 with a bare "exited 3". Every failure now ends in one "!!" line saying what.

set -euo pipefail

APP="${1:?usage: install.sh /path/to/wrapper.app [prefix-name] [game dir] [SquareEnix C:\\ path] [SquareEnix dir]}"
PREFIX_NAME="${2:-prefix10}"
SHARED="$APP/Contents/SharedSupport"
export WINEPREFIX="$SHARED/$PREFIX_NAME"
WINE="${HXI_WINE:-$SHARED/wine/bin/wine}"
GAME_DIR="${3:-$WINEPREFIX/drive_c/HorizonXI}"
SE_C="${4:-C:\\HorizonXI\\SquareEnix}"
SE_DIR="${5:-$GAME_DIR/SquareEnix}"
REG32='C:\windows\syswow64\reg.exe'
WINESERVER="${WINE:h}/wineserver"
# Never the Mono/Gecko install prompts (they would wait forever for a click), never a stray
# DYLD_* from whoever started this.
#
# And no window driver: nothing here draws, and Wine's Mac driver started from a script (not
# through `open`) crashes in a loop inside explorer.exe. 2026-10-15, b60 Setup on a fresh prefix
# with the game's Wine: regsvr32 waited on that explorer for good and the button said "Setting
# up…" forever. With winemac.drv off the same calls finish in about a second. The session is
# ended at the bottom, so Play starts a new one with the driver on.
export WINEDEBUG=-all WINEDLLOVERRIDES="mscoree,mshtml=;winemac.drv=d" WINEBOOT_HIDE_DIALOG=1
unset DYLD_FALLBACK_LIBRARY_PATH DYLD_LIBRARY_PATH

info() { print -r -- "==> $*"; }
die() { print -r -- "!! $*" >&2; exit "${2:-1}"; }

# Every wine call is bounded. One that has not returned after $1 seconds ends this prefix's
# whole session (that is what a hang holds) and returns 124, so the step names itself instead of
# leaving the button spinning.
wine_t() {
  local limit=$1 n=0 pid; shift
  "$WINE" "$@" >/dev/null 2>&1 &
  pid=$!
  while kill -0 $pid 2>/dev/null; do
    if (( n >= limit * 2 )); then
      "$WINESERVER" -k >/dev/null 2>&1 || true
      wait $pid 2>/dev/null || true
      return 124
    fi
    sleep 0.5; n=$((n + 1))
  done
  wait $pid
}

# End this prefix's session and wait (bounded) for it to go. The launcher runs Repair only with
# no game live in any launcher, so what is left here is wine's own programs or a leftover from an
# interrupted Setup -- e.g. that regsvr32 still waiting on a crash-looping explorer.
end_session() {
  "$WINESERVER" -k >/dev/null 2>&1 || return 0
  "$WINESERVER" -w >/dev/null 2>&1 &
  local pid=$! n=0
  while kill -0 $pid 2>/dev/null && (( n < 60 )); do sleep 0.5; n=$((n + 1)); done
  kill $pid 2>/dev/null || true
}

[[ -x "$WINE" ]] || die "Wine isn't installed in $APP — press Setup."
[[ -d "$GAME_DIR" ]] || die "The game isn't installed yet (no $GAME_DIR) — press Setup."

# ---------------------------------------------------------------------------
# 0. Is the game data there at all? A drive that is gone and files that are gone need different
# answers (reconnect the drive / get the files again), and neither is something Repair can fix.
# Checked before anything is written.
# ---------------------------------------------------------------------------
# The mount point serving $1. /Volumes is case-insensitive: with 'Games' ghost-mounted, a stick
# named 'GAMES' answered at /Volumes/Games (2026-10-15), so "it exists" is not enough.
mount_of() { /bin/df -P "$1" 2>/dev/null | /usr/bin/awk 'NR == 2 { for (i = 6; i <= NF; i++) printf "%s%s", $i, (i < NF ? " " : "") }'; }
vol_gone() {
  [[ -e "$1" ]] || return 0
  local m; m=$(mount_of "$1")
  [[ "$m" == /Volumes/* && "$m" != "$1" ]]
}
# The /Volumes/<name> that $1 lives on or links into, when that volume is not there.
missing_drive() {
  local p="$1" hops=0 t
  while (( hops < 16 )); do
    if [[ "$p" == /Volumes/* ]]; then
      local vol="/Volumes/${${p#/Volumes/}%%/*}"
      vol_gone "$vol" && { print -r -- "${vol:t}"; return 0; }
    fi
    [[ -L "$p" ]] || break
    t=$(readlink "$p"); [[ "$t" == /* ]] || t="${p:h}/$t"
    p="$t"; hops=$((hops + 1))
  done
  return 1
}
if [[ ! -d "$SE_DIR/FINAL FANTASY XI" ]]; then
  if d=$(missing_drive "$SE_DIR"); then
    die "The '$d' drive isn't connected — reconnect it or press Setup. Nothing was changed." 4
  fi
  die "The game's files aren't in $SE_DIR — press Setup to get them again. Nothing was changed." 4
fi
missing=()
for f in FFXi.dll FFXiMain.dll FFXiVersions.dll; do
  [[ -f "$SE_DIR/FINAL FANTASY XI/$f" ]] || missing+=("$f")
done
(( ${#missing} == 0 )) \
  || die "Game files missing (${(j:, :)missing}) — press Setup to get them again. Nothing was changed." 4

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
rpath_out=$("${0:h}/fix-wine-rpath.sh" "$APP" 2>&1) \
  || die "Couldn't fix Wine's library links: ${${(f)rpath_out}[-1]:-no output}"

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
end_session
info "writing PlayOnline registry (both views)"
# The first call also brings the prefix up to this wine's version, which can take a minute on a
# slow drive; a second call is quick.
reg_set() {
  local rc=0
  wine_t 300 "$@" || rc=$?
  (( rc == 0 )) && return 0
  (( rc == 124 )) && die "Wine stopped answering while writing the game's settings. Press Repair to try again."
  die "Couldn't write the game's registry settings (reg exit $rc). Quit the game, then press Repair again."
}
for REG in "$REG32" reg; do
  reg_set $REG add "HKLM\\SOFTWARE\\PlayOnlineUS\\InstallFolder" /v 0001 /d "$SE_C\\FINAL FANTASY XI" /f
  reg_set $REG add "HKLM\\SOFTWARE\\PlayOnlineUS\\InstallFolder" /v 1000 /d "$SE_C\\PlayOnlineViewer" /f
  reg_set $REG add "HKLM\\SOFTWARE\\PlayOnlineUS\\Interface"     /v 0001 /d "0" /f
done

# Option must behave as Alt, or no Alt-based macro can ever be typed. Wine's Mac driver defaults
# both Option keys to composing special characters instead, which silently costs the player every
# Alt keybind — Ashita macro books included.
reg_set reg add "HKCU\\Software\\Wine\\Mac Driver" /v LeftOptionIsAlt  /d y /f
reg_set reg add "HKCU\\Software\\Wine\\Mac Driver" /v RightOptionIsAlt /d y /f

# The client ships pol.reg / polu.reg; polu.reg holds HKCU video settings the game needs present.
for r in pol polu; do
  [[ -f "$WINEPREFIX/drive_c/$r.reg" ]] && wine_t 120 regedit /S "C:\\$r.reg" || true
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
#
# Every DLL is tried and every failure named (regsvr32's own codes: 3 = could not be loaded,
# 4 = no DllRegisterServer, 5 = registration refused). polcore.dll is a warning, as it is in the
# launcher's checks: Play goes ahead without it, so Repair does too, and says so.
# ---------------------------------------------------------------------------
info "registering FFXI COM servers"
failed=()
register() {
  local rc=0
  wine_t 120 regsvr32 /s "$1" || rc=$?
  case $rc in
    0) ;;
    124) failed+=("${1##*\\} didn't answer within two minutes") ;;
    3) failed+=("${1##*\\} couldn't be loaded (regsvr32 3)") ;;
    4) failed+=("${1##*\\} has no registration entry (regsvr32 4)") ;;
    5) failed+=("${1##*\\} refused to register (regsvr32 5)") ;;
    *) failed+=("${1##*\\} failed to register (regsvr32 $rc)") ;;
  esac
}
for d in FFXi.dll FFXiMain.dll FFXiVersions.dll; do
  register "$SE_C\\FINAL FANTASY XI\\$d"
done
if [[ -f "$SE_DIR/PlayOnlineViewer/viewer/com/polcore.dll" ]]; then
  register "$SE_C\\PlayOnlineViewer\\viewer\\com\\polcore.dll"
else
  print -r -- "!! polcore.dll is missing — the game may not start. Press Setup to get the game files again."
fi
(( ${#failed} == 0 )) || die "Couldn't register the game: ${(j:; :)failed}." 3
# GameRegistry (the launcher's per-Play twin of §2–3) caches what the registry names; it now
# names this folder.
print -r -- "$SE_C" > "$WINEPREFIX/.ffxi-on-mac-registry-target"

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
    wine_t 120 $REG add "HKCU\\Software\\Wine\\DllOverrides" /v "*d3d8" /d native /f || true
    wine_t 120 $REG add "HKCU\\Software\\Wine\\DllOverrides" /v "*d3d9" /d native /f || true
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

# Play must not join this session: its explorer has no window driver.
end_session

# ---------------------------------------------------------------------------
# 4. Launcher.
#
# Launch through Ashita-cli, not xiloader directly. With the registry above but launched
# xiloader-direct, the game still exits silently before creating its window; through Ashita it
# runs. Always pass the absolute C:\ path — wine resolves a bare exe name against
# C:\windows\system32, not the cwd.
# ---------------------------------------------------------------------------
# A convenience only: a folder that cannot be written (a read-only drive, /Applications without
# admin) must not turn a Repair that did all the real work into a failure.
LAUNCHER="${APP:h}/Play HorizonXI.command"
write_launcher() {
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
}
if write_launcher 2>/dev/null; then
  info "wrote $LAUNCHER"
else
  info "skipped $LAUNCHER (that folder can't be written)"
fi

info "done — launch with: $LAUNCHER"
echo
echo "Note: the character-select screen needs a real keypress. Synthetic input does not reach"
echo "wine windows on macOS, so that step cannot be scripted; click the window and press Enter."
