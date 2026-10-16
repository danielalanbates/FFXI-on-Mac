#!/bin/zsh
# Native tests for gamewindow.dylib (window/gamewindow.c). Never shows a window, never activates
# an app (the window test runs with activation policy Prohibited and never orders anything
# front), and exits by itself.
#
#   ./gamewindow-test.sh     window tests (arm64, then x86_64 under Rosetta), a process with no
#                            AppKit, and the DYLD_INSERT_LIBRARIES carry across the x87 sidecar
#
# GOTCHA: nothing here is run through arch(1) or env(1). Both are system binaries and dyld strips
# DYLD_* across an exec into them; the x86_64 binaries are run directly and Rosetta takes them.
set -uo pipefail
REPO="${0:A:h:h:h}"
DYLIB="$REPO/app/Resources/gamewindow.dylib"
[[ -f "$DYLIB" ]] || "$REPO/scripts/build-gamewindow.sh"
T=$(mktemp -d "${TMPDIR:-/tmp}/gamewindow-test.XXXXXX")
SERVICE_PATTERN="$T/scprobe"
cleanup() {
  for p in $(pgrep -f "$SERVICE_PATTERN" 2>/dev/null); do kill "$p" 2>/dev/null; done
  rm -rf "$T"
}
trap cleanup EXIT
fails=0
pass() { print -r -- "PASS  $1"; }
bad()  { print -r -- "FAIL  $1"; fails=$((fails + 1)); }

# --- Window tests --------------------------------------------------------------------------------
for arch in arm64 x86_64; do
  if ! clang -arch $arch -fobjc-arc -O1 -Wall -o "$T/wt-$arch" "$REPO/scripts/tests/gamewindow-test.m" \
       -framework AppKit; then
    bad "build the window test ($arch)"; continue
  fi
  print "== window test, $arch, HXI_GAME_ASPECT=1920x1080"
  if DYLD_INSERT_LIBRARIES="$DYLIB" HXI_GAME_ASPECT=1920x1080 FFXI_GAMEWINDOW_DEBUG=1 "$T/wt-$arch" lock; then
    pass "window test locks game windows ($arch)"
  else
    bad "window test locks game windows ($arch)"
  fi
  print "== window test, $arch, no HXI_GAME_ASPECT"
  if ( unset HXI_GAME_ASPECT; DYLD_INSERT_LIBRARIES="$DYLIB" FFXI_GAMEWINDOW_DEBUG=1 "$T/wt-$arch" none ); then
    pass "no HXI_GAME_ASPECT: nothing locked ($arch)"
  else
    bad "no HXI_GAME_ASPECT: nothing locked ($arch)"
  fi
  for v in "" banana 1920x0 0x1080 1920x1080x2 100000x1 1920X1080 800x100 x1080 1920x -1920x1080; do
    out=$(DYLD_INSERT_LIBRARIES="$DYLIB" HXI_GAME_ASPECT="$v" "$T/wt-$arch" none 2>&1); rc=$?
    if [[ $rc == 0 ]]; then pass "HXI_GAME_ASPECT='$v' is ignored ($arch)"
    else print -r -- "$out"; bad "HXI_GAME_ASPECT='$v' is ignored ($arch)"; fi
  done
done

# --- Processes with no AppKit at all -------------------------------------------------------------
# CoreFoundation (which on macOS 27 brings Foundation with it) is opened only when there is a ratio
# to keep, and never in wineserver; AppKit never.
cat > "$T/plain.c" <<'PLAIN'
#include <mach-o/dyld.h>
#include <stdio.h>
#include <string.h>
int main(void) {
  int appkit = 0, cf = 0, foundation = 0;
  for (uint32_t i = 0; i < _dyld_image_count(); i++) {
    const char *n = _dyld_get_image_name(i);
    if (strstr(n, "/AppKit.framework/")) appkit = 1;
    if (strstr(n, "/CoreFoundation.framework/")) cf = 1;
    if (strstr(n, "/Foundation.framework/")) foundation = 1;
  }
  printf("appkit=%d corefoundation=%d foundation=%d\n", appkit, cf, foundation);
  return 0;
}
PLAIN
plain_case() {  # plain_case <label> <binary> <expected substring> <ratio, or - for none>
  local out rc
  if [[ "$4" == "-" ]]; then
    out=$( ( unset HXI_GAME_ASPECT; DYLD_INSERT_LIBRARIES="$DYLIB" FFXI_GAMEWINDOW_DEBUG=1 "$2" ) 2>&1 ); rc=$?
  else
    out=$(DYLD_INSERT_LIBRARIES="$DYLIB" HXI_GAME_ASPECT="$4" FFXI_GAMEWINDOW_DEBUG=1 "$2" 2>&1); rc=$?
  fi
  print -r -- "$out"
  if [[ $rc == 0 && "$out" == *"gamewindow: loaded"* && "$out" == *"$3"* ]]; then pass "$1"; else bad "$1"; fi
}
for arch in arm64 x86_64; do
  clang -arch $arch -O1 -o "$T/plain-$arch" "$T/plain.c" || { bad "build the plain program ($arch)"; continue; }
  mkdir -p "$T/$arch" && cp "$T/plain-$arch" "$T/$arch/wineserver"
  plain_case "no ratio: nothing but the dylib loads, exits 0 ($arch)" \
             "$T/plain-$arch" "appkit=0 corefoundation=0 foundation=0" -
  plain_case "named wineserver, ratio set: no CoreFoundation, Foundation or AppKit, exits 0 ($arch)" \
             "$T/$arch/wineserver" "appkit=0 corefoundation=0 foundation=0" 1920x1080
  plain_case "any other process with a ratio: CoreFoundation opened, never AppKit, exits 0 ($arch)" \
             "$T/plain-$arch" "appkit=0 corefoundation=1" 1920x1080
done

# --- The carry across the x87 sidecar ----------------------------------------------------------
# The real sidecar binary, signed with the hardened runtime as bundle.sh signs it, under a name no
# game-process scan matches. Its cooperative service waits for a handshake the probe never sends;
# it is killed as soon as the probe has reported.
if clang -arch x86_64 -O1 -o "$T/carry" "$REPO/scripts/tests/gamewindow-carry.c"; then
  print "== direct exec (x87 off): the probe sees the dylib"
  out=$(DYLD_INSERT_LIBRARIES="$DYLIB" "$T/carry" probe x 2>&1)
  print -r -- "$out"
  [[ "$out" == *"mapped=1 insert=$DYLIB"* ]] && pass "x87 off: the client gets DYLD_INSERT_LIBRARIES" \
                                             || bad "x87 off: the client gets DYLD_INSERT_LIBRARIES"

  carry_run() {  # carry_run <label> <sidecar> [FFXI_GAMEWINDOW_CARRY value]
    local log="$T/carry-$1.log" pid
    if [[ $# -ge 3 ]]; then
      ROSETTA_X87_PATH="$2" FFXI_GAMEWINDOW_CARRY="$3" DYLD_INSERT_LIBRARIES="$DYLIB" FFXI_GAMEWINDOW_DEBUG=1 \
        "$T/carry" wine "$T/carry" > "$log" 2>&1 &
    else
      ( unset FFXI_GAMEWINDOW_CARRY
        ROSETTA_X87_PATH="$2" DYLD_INSERT_LIBRARIES="$DYLIB" FFXI_GAMEWINDOW_DEBUG=1 \
          exec "$T/carry" wine "$T/carry" ) > "$log" 2>&1 &
    fi
    pid=$!
    wait $pid
    sleep 0.3
    for p in $(pgrep -f "$SERVICE_PATTERN" 2>/dev/null); do kill "$p" 2>/dev/null; done
    grep -v '^#\|^WARNING\|^PROCESS\|^32-BIT\|rosettax87' "$log"
  }
  sidecar_test() {  # sidecar_test <sidecar> <description> <resign: yes|no>
    rm -f "$T/scprobe"
    cp "$1" "$T/scprobe" || return 2
    if [[ "$3" == yes ]]; then codesign -f -s - -o runtime "$T/scprobe" 2>/dev/null || return 2; fi
    print "== x87 on, carry off ($2): what the sidecar alone delivers"
    off=$(carry_run off "$T/scprobe" 0)
    print -r -- "$off"
    if [[ "$off" != *"mapped=0 insert=(unset)"* ]]; then
      print "   this sidecar copy does not strip DYLD_*; the carry cannot be judged with it"
      return 3
    fi
    pass "x87 on without the carry: the hardened sidecar strips DYLD_INSERT_LIBRARIES (the problem)"
    print "== x87 on, carry on ($2)"
    on=$(carry_run on "$T/scprobe")
    print -r -- "$on"
    wpid=$(print -r -- "$on" | sed -n 's/^wine: pid=\([0-9]*\).*/\1/p')
    if [[ -n "$wpid" && "$on" == *"probe: pid=$wpid mapped=1 insert=$DYLIB"* ]]; then
      pass "x87 on with the carry: the client has the dylib, same pid as the exec (handshake pid kept)"
    else
      bad "x87 on with the carry: the client has the dylib, same pid as the exec (handshake pid kept)"
    fi
    if [[ "$on" == *"probe: arg1=[two words]"* && "$on" == *"probe: arg2=[q'u\"o te]"* ]]; then
      pass "x87 on with the carry: the client's arguments arrive unchanged"
    else
      bad "x87 on with the carry: the client's arguments arrive unchanged"
    fi
    return 0
  }
  sidecar_test "$REPO/vendor/x87sidecar-coop" "vendor sidecar, re-signed with the hardened runtime" yes; r=$?
  INSTALLED=/Applications/FFXI-on-Mac.app/Contents/Resources/x87sidecar-coop
  if [[ $r != 0 && -f "$INSTALLED" ]]; then
    sidecar_test "$INSTALLED" "the installed app's Developer ID sidecar, signature kept" no; r=$?
  fi
  [[ $r == 0 ]] || bad "the carry could not be tested against a DYLD-stripping sidecar"
else
  bad "build the carry probe"
fi

print
if (( fails )); then print "gamewindow-test: $fails failure(s)"; exit 1; fi
print "gamewindow-test: all passed"
