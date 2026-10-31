#!/bin/zsh
# Native tests for gamewindow.dylib (window/gamewindow.c). Never shows a window, never activates
# an app (the window test runs with activation policy Prohibited and never orders anything
# front), and exits by itself.
#
#   ./gamewindow-test.sh     window tests (arm64, then x86_64 under Rosetta) including AppKit's own
#                            drag computation on a locked window, the game window's title
#                            (HXI_WINDOW_TITLE) on wine's classes and Window menu, a process with no
#                            AppKit, and the DYLD_INSERT_LIBRARIES carry across the x87 sidecar, with
#                            the sidecar's real cooperative handshake and x87 hook, and the
#                            not-responding check (FFXI_GAMEWINDOW_HANG) on close, quit and Cmd-Q
#
# Run it only when no game is running: the carry test starts a renamed copy of the x87 sidecar,
# which attaches to the test's own probe and nothing else, but it is the same JIT the game uses.
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
       -framework AppKit -framework QuartzCore -framework Metal; then
    bad "build the window test ($arch)"; continue
  fi
  print "== window test, $arch, HXI_GAME_ASPECT=1920x1080"
  out=$(DYLD_INSERT_LIBRARIES="$DYLIB" HXI_GAME_ASPECT=1920x1080 FFXI_GAMEWINDOW_DEBUG=1 "$T/wt-$arch" lock 2>&1); rc=$?
  print -r -- "$out"
  if [[ $rc == 0 ]]; then
    pass "window test locks game windows ($arch)"
  else
    bad "window test locks game windows ($arch)"
  fi
  if [[ "$out" == *"resize ended: window "*" is 960x540 points, in proportion with 1920:1080"* \
        && "$out" == *"resize ended: window "*" is 1000x400 points, OUT OF PROPORTION with"* ]]; then
    pass "FFXI_GAMEWINDOW_DEBUG reports whether a live resize kept the ratio ($arch)"
  else
    bad "FFXI_GAMEWINDOW_DEBUG reports whether a live resize kept the ratio ($arch)"
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

  # The title. First seen through each notification wine's game window can post; with the ratio
  # too on the key one (both at once), the title alone on the others.
  for first in key main shown; do
    print "== title test, $arch, first seen on '$first', HXI_WINDOW_TITLE='FFXI on Mac'"
    if [[ $first == key ]]; then
      out=$( ( DYLD_INSERT_LIBRARIES="$DYLIB" HXI_GAME_ASPECT=1920x1080 HXI_WINDOW_TITLE="FFXI on Mac" \
               FFXI_GAMEWINDOW_DEBUG=1 "$T/wt-$arch" title $first expect ) 2>&1 ); rc=$?
    else
      out=$( ( unset HXI_GAME_ASPECT; DYLD_INSERT_LIBRARIES="$DYLIB" HXI_WINDOW_TITLE="FFXI on Mac" \
               FFXI_GAMEWINDOW_DEBUG=1 "$T/wt-$arch" title $first expect ) 2>&1 ); rc=$?
    fi
    print -r -- "$out"
    if [[ $rc == 0 && "$out" == *"$first: window "*" now reads \"FFXI on Mac\""* ]]; then
      pass "the game window reads 'FFXI on Mac' from its first '$first' on; other windows keep theirs ($arch)"
    else
      bad "the game window reads 'FFXI on Mac' from its first '$first' on; other windows keep theirs ($arch)"
    fi
  done
  print "== title test, $arch, no HXI_WINDOW_TITLE (ratio set, so the dylib is watching)"
  if ( unset HXI_WINDOW_TITLE; DYLD_INSERT_LIBRARIES="$DYLIB" HXI_GAME_ASPECT=1920x1080 "$T/wt-$arch" title key none ); then
    pass "no HXI_WINDOW_TITLE: no title changes, nothing overridden ($arch)"
  else
    bad "no HXI_WINDOW_TITLE: no title changes, nothing overridden ($arch)"
  fi
  long=$(printf 'x%.0s' {1..256})
  for v in "" "$long" $'\xff\xfe'; do
    out=$( ( unset HXI_GAME_ASPECT; DYLD_INSERT_LIBRARIES="$DYLIB" HXI_WINDOW_TITLE="$v" "$T/wt-$arch" title shown none ) 2>&1 ); rc=$?
    if [[ $rc == 0 ]]; then pass "HXI_WINDOW_TITLE of ${#v} bytes (empty, over 255, not UTF-8) is ignored ($arch)"
    else print -r -- "$out"; bad "HXI_WINDOW_TITLE of ${#v} bytes (empty, over 255, not UTF-8) is ignored ($arch)"; fi
  done

  # Not responding (FFXI_GAMEWINDOW_HANG, 1 s here). A close, quit or Cmd-Q the game neither reads
  # nor answers with a frame is asked about; anything else is left to the game. The answer
  # "force" is Force Quit without showing anything, so a question where none belongs kills the
  # test (137) instead of passing quietly.
  hang_case() {  # hang_case <label> <request> <model> <answer> <left|asked|raised|killed|none|off> [FFXI_GAMEWINDOW_HANG]
    local out rc asks ok=0
    out=$( ( unset HXI_GAME_ASPECT; DYLD_INSERT_LIBRARIES="$DYLIB" HXI_WINDOW_TITLE="FFXI on Mac" \
             FFXI_GAMEWINDOW_DEBUG=1 FFXI_GAMEWINDOW_HANG="${6:-1}" FFXI_GAMEWINDOW_HANG_ANSWER="$4" \
             "$T/wt-$arch" hang "$2" "$3" ) 2>&1 ); rc=$?
    asks=$(print -r -- "$out" | grep -c '; asking$')
    case $5 in
      left)   [[ $rc == 0 && $asks == 0 && "$out" == *"left to the game"* ]] && ok=1 ;;
      asked)  [[ $rc == 0 && $asks == 2 && "$out" == *"Wait chosen; the game keeps running"* \
                 && "$out" == *"nothing shown (window level 8)"* ]] && ok=1 ;;
      raised) [[ $rc == 0 && $asks == 2 && "$out" == *"Wait chosen; the game keeps running"* \
                 && "$out" == *"nothing shown (window level 1001)"* ]] && ok=1 ;;
      killed) [[ $rc == 137 && $asks == 1 && "$out" == *"Force Quit chosen; ending the game"* ]] && ok=1 ;;
      none)   [[ $rc == 0 && $asks == 0 && "$out" != *"watching the game for"* ]] && ok=1 ;;
      off)    [[ $rc == 0 && $asks == 0 && "$out" == *"hang check off"* && "$out" != *"hang: -"* ]] && ok=1 ;;
    esac
    if (( ok )); then pass "$1 ($arch)"; else print -r -- "$out"; bad "$1 ($arch)"; fi
  }
  hang_case "close, game playing (reads its input): left to the game"              close   polls  force left
  hang_case "close, game idle in GetMessage (the close wakes it): left to the game" close  wakes  force left
  hang_case "close, game drawing but reading nothing: left to the game"           close   frames force left 2
  hang_case "close, game hung: asked; Wait keeps it; the next close asks again"   close   hung   wait  asked
  hang_case "close: reads and frames from before the close do not count"          close   stops  wait  asked
  hang_case "close, game hung, Force Quit: the process ends by SIGKILL"           close   hung   force killed
  hang_case "close, game hung beside a window at level 1000: the question goes to 1001" close raised wait raised
  hang_case "close on a message box: never watched"                               close   dialog force none
  hang_case "FFXI_GAMEWINDOW_HANG=0: nothing overridden, the close still reaches wine" close hung force off 0
  hang_case "quit, game idle (the quit wakes it): left to the game"               quit    wakes  force left
  hang_case "quit, game hung: judged in AppKit's NSTerminateLater mode; Force Quit" quit   hung   force killed
  hang_case "quit, game hung: asked; Wait keeps it"                               quit    hung   wait  asked
  hang_case "Cmd-Q, game playing: left to the game, the key goes on unchanged"    cmdq    polls  force left
  hang_case "Cmd-Q, game hung, Force Quit"                                        cmdq    hung   force killed
  hang_case "Cmd-Option-Q is wine's menu Quit, never watched as Cmd-Q"            cmdqopt hung   force none
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
plain_case() {  # plain_case <label> <binary> <expected substring> <ratio, or - for none> [title]
  local out rc
  if [[ "$4" == "-" ]]; then
    out=$( ( unset HXI_GAME_ASPECT; DYLD_INSERT_LIBRARIES="$DYLIB" HXI_WINDOW_TITLE="${5:-}" FFXI_GAMEWINDOW_DEBUG=1 "$2" ) 2>&1 ); rc=$?
  else
    out=$( ( unset HXI_WINDOW_TITLE; DYLD_INSERT_LIBRARIES="$DYLIB" HXI_GAME_ASPECT="$4" FFXI_GAMEWINDOW_DEBUG=1 "$2" ) 2>&1 ); rc=$?
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
  plain_case "named wineserver, title set: no CoreFoundation, Foundation or AppKit, exits 0 ($arch)" \
             "$T/$arch/wineserver" "appkit=0 corefoundation=0 foundation=0" - "FFXI on Mac"
  plain_case "any other process with only a title: CoreFoundation opened, never AppKit, exits 0 ($arch)" \
             "$T/plain-$arch" "appkit=0 corefoundation=1" - "FFXI on Mac"
  # FFXI_GAMEWINDOW_HANG: 0 off, 1...600 seconds, anything else the default 5 s.
  for v want in "" "after 5 s" abc "after 5 s" 601 "after 5 s" -3 "after 5 s" 1.5 "after 5 s" \
                0 "off" 3 "after 3 s" 600 "after 600 s"; do
    out=$( ( unset HXI_GAME_ASPECT; DYLD_INSERT_LIBRARIES="$DYLIB" HXI_WINDOW_TITLE="FFXI on Mac" \
             FFXI_GAMEWINDOW_DEBUG=1 FFXI_GAMEWINDOW_HANG="$v" "$T/plain-$arch" ) 2>&1 )
    if [[ "$out" == *"hang check $want"* && "$out" == *"appkit=0"* ]]; then
      pass "FFXI_GAMEWINDOW_HANG='$v': hang check $want, no AppKit ($arch)"
    else
      print -r -- "$out"; bad "FFXI_GAMEWINDOW_HANG='$v': hang check $want, no AppKit ($arch)"
    fi
  done
done

# --- The carry across the x87 sidecar ----------------------------------------------------------
# The real sidecar binary, signed with the hardened runtime as bundle.sh signs it, under a name no
# game-process scan matches. The probe does wine's cooperative handshake with it (the sidecar then
# installs its x87 JIT hook in the probe, as in the game) and runs x87 arithmetic; with a ratio set,
# so CoreFoundation is opened before the handshake exactly as in the client. The sidecar exits with
# the probe; anything left is killed.
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
        HXI_GAME_ASPECT=1920x1080 "$T/carry" wine "$T/carry" > "$log" 2>&1 &
    else
      ( unset FFXI_GAMEWINDOW_CARRY
        ROSETTA_X87_PATH="$2" DYLD_INSERT_LIBRARIES="$DYLIB" FFXI_GAMEWINDOW_DEBUG=1 \
          HXI_GAME_ASPECT=1920x1080 exec "$T/carry" wine "$T/carry" ) > "$log" 2>&1 &
    fi
    pid=$!
    wait $pid
    sleep 1
    for p in $(pgrep -f "$SERVICE_PATTERN" 2>/dev/null); do kill "$p" 2>/dev/null; done
    grep -v '^#\|^WARNING\|^PROCESS\|^32-BIT\|rosettax87\|^M2:' "$log"
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
    [[ "$off" == *"probe: x87 handshake=0 sum=249750.0"* ]] \
      && pass "x87 on without the carry: the sidecar accepts the handshake and x87 runs (baseline)" \
      || bad "x87 on without the carry: the sidecar accepts the handshake and x87 runs (baseline)"
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
    if [[ "$on" == *"probe: x87 handshake=0 sum=249750.0"* ]]; then
      pass "x87 on with the carry: the sidecar's handshake still succeeds (hook installed) and x87 runs"
    else
      bad "x87 on with the carry: the sidecar's handshake still succeeds (hook installed) and x87 runs"
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
