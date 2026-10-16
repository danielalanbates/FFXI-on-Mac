#!/bin/zsh
# ashita-send-test.sh -- vendor/ashita-send.exe against a fake Thirdparty plugin, under the game's
# wine, in a throwaway prefix. No game, no install and no real prefix is involved.
#
# Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved. PolyForm Noncommercial 1.0.0
# with the commercial-use rider in LICENSE; commercial licences: help@batesai.org.
#
#   scripts/tests/ashita-send-test.sh [<wine>]
#
# <wine> defaults to the patched game wine (wine-coop) where the launcher looks for it. The prefix
# is ~/Downloads/FFXI-on-Mac-build/fixture/ashita-send/prefix (HXI_ASHITA_SEND_FIXTURE overrides
# the folder); it is made on the first run. Refuses to start while any game client runs, and the
# only wineserver it ever stops is the throwaway prefix's own.
set -uo pipefail
REPO="${0:A:h:h:h}"
FIX="${HXI_ASHITA_SEND_FIXTURE:-$HOME/Downloads/FFXI-on-Mac-build/fixture/ashita-send}"
WINE="${1:-}"
if [[ -z "$WINE" ]]; then
  for w in "/Volumes/x10/Video Games/Mac/FFXI/wine-coop/wine/bin/wine" \
           "/Volumes/Games/FFXI/wine-coop/wine/bin/wine" \
           "$HOME/Library/Application Support/BatesAI/ffxi-runtime/wine-coop/wine/bin/wine"; do
    [[ -x "$w" ]] && { WINE="$w"; break; }
  done
fi
[[ -x "$WINE" ]] || { echo "no game wine found; pass its bin/wine" >&2; exit 2; }
WINESERVER="${WINE:h}/wineserver"

# Counts only: a loader's command line carries the account password and is never printed.
game_running() {
  local n
  n="$(/bin/ps -axo args | /usr/bin/grep -E 'horizon-loader|FFXiMain|pol\.exe|Ashita-cli|x87sidecar' \
       | /usr/bin/grep -vE 'grep|zsh|bash' | /usr/bin/wc -l | /usr/bin/tr -d ' ')"
  [[ "$n" != "0" ]]
}
if game_running; then echo "a game client is running: not testing (wine tests only with no game)" >&2; exit 3; fi

BIN="$FIX/bin"
PREFIX="$FIX/prefix"
OUT="$FIX/out"
mkdir -p "$BIN" "$OUT"
"$REPO/scripts/build-ashita-send.sh" "$BIN" >/dev/null || exit 1
HELPER="$REPO/vendor/ashita-send.exe"
FAKE="$BIN/ashita-send-fake-plugin.exe"

export WINEPREFIX="$PREFIX"
export WINEDLLOVERRIDES="mscoree,mshtml=;winemac.drv=d"
export WINEDEBUG=-all
export WINEMSYNC=1 WINEESYNC=0
cleanup() { WINEPREFIX="$PREFIX" "$WINESERVER" -k >/dev/null 2>&1 || true; }
trap cleanup EXIT

winpath() { print -r -- "Z:${1//\//\\}"; }

fails=0
check() {  # name, got, want
  if [[ "$2" == "$3" ]]; then print -r -- "  ok   $1"
  else print -r -- "  FAIL $1 (got: $2, want: $3)"; fails=$((fails + 1)); fi
}

# Run the helper; sets RC, ELAPSED (ms) and STDOUT.
send() {
  local t0 t1
  t0=$(/usr/bin/perl -MTime::HiRes=time -e 'printf "%d", time*1000')
  STDOUT="$("$WINE" "$HELPER" "$@" 2>"$OUT/stderr.txt")"
  RC=$?
  t1=$(/usr/bin/perl -MTime::HiRes=time -e 'printf "%d", time*1000')
  ELAPSED=$((t1 - t0))
}
send_stdin() {
  local input="$1"; shift
  local t0 t1
  t0=$(/usr/bin/perl -MTime::HiRes=time -e 'printf "%d", time*1000')
  STDOUT="$(print -rn -- "$input" | "$WINE" "$HELPER" "$@" 2>"$OUT/stderr.txt")"
  RC=$?
  t1=$(/usr/bin/perl -MTime::HiRes=time -e 'printf "%d", time*1000')
  ELAPSED=$((t1 - t0))
}

# Start a fake plugin in the background; waits for its "ready" line. Sets FAKE_PID (Mac pid).
start_fake() {  # mode, file, seconds
  : > "$2"
  "$WINE" "$FAKE" "$1" "$(winpath "$2")" "$3" >/dev/null 2>&1 &
  FAKE_PID=$!
  local i
  for i in {1..600}; do
    /usr/bin/grep -q '^ready ' "$2" 2>/dev/null && return 0
    /bin/sleep 0.1
  done
  echo "fake plugin ($1) never became ready" >&2
  return 1
}
lines() { /usr/bin/grep -E "^$1 " "$2" | /usr/bin/sed -E "s/^$1 //"; }

echo "wine: $WINE ($("$WINE" --version 2>/dev/null))"
echo "prefix: $PREFIX"
if [[ ! -f "$PREFIX/system.reg" ]]; then
  echo "making the throwaway prefix..."
  "$WINE" wineboot --init >/dev/null 2>&1
  "$WINESERVER" -w
fi

echo "-- nothing running"
send --list;                              check "--list with no plugin: exit 2" "$RC" 2
send "/addon load clock";                 check "a command with no plugin: exit 2 (no client)" "$RC" 2

echo "-- one plugin (normal)"
F1="$OUT/normal.txt"
start_fake normal "$F1" 40 || exit 1
F1PID=$FAKE_PID
send --list;                              check "--list finds the one plugin" "$RC" 0
send "/addon load clock";                 check "argv command delivered: exit 0" "$RC" 0
echo "     delivered in ${ELAPSED} ms, wine start included"
check "it ran exactly that command" "$(lines cmd "$F1")" "/addon load clock"
check "helper printed delivered" "${STDOUT%% *}" "delivered"
: > "$OUT/mark"; before=$(lines cmd "$F1" | /usr/bin/wc -l | /usr/bin/tr -d ' ')
send_stdin $'/addon unload clock\r\n\n/load minimap\n/addon load distance\n'
check "three stdin commands delivered: exit 0" "$RC" 0
check "they ran in order, exact text" "$(lines cmd "$F1" | /usr/bin/tail -n +$((before + 1)) | /usr/bin/tr '\n' '|')" \
  "/addon unload clock|/load minimap|/addon load distance|"
check "one batch, one entry, ';'-joined" "$(lines raw "$F1" | /usr/bin/tail -1)" \
  "/addon unload clock;/load minimap;/addon load distance"
# 200 commands of 22 bytes: 89 fit in an entry's 2047 bytes (23*89-1), so they pack into three.
many=""; for k in {1..200}; do many+="$(printf '/addon load addon%05d' $k)"$'\n'; done
before=$(lines cmd "$F1" | /usr/bin/wc -l | /usr/bin/tr -d ' ')
send_stdin "$many"
check "200 commands delivered in one batch: exit 0" "$RC" 0
check "200 commands ran" "$(lines cmd "$F1" | /usr/bin/tail -n +$((before + 1)) | /usr/bin/wc -l | /usr/bin/tr -d ' ')" 200
check "all 200 ran, in order" "$(lines cmd "$F1" | /usr/bin/tail -n +$((before + 1)) | /sbin/md5 -q)" \
  "$(print -rn -- "$many" | /sbin/md5 -q)"
check "packed into 3 entries (89+89+22)" "$(lines raw "$F1" | /usr/bin/tail -3 | /usr/bin/awk -F';' '{printf "%d ", NF}')" "89 89 22 "
before=$(lines raw "$F1" | /usr/bin/wc -l | /usr/bin/tr -d ' ')
for bad in "/unload thirdparty" "/reload Thirdparty" "  //unload  ThirdParty.dll" "/unload addons" \
           "/reload addons" "/unload" "/addon load clock;/unload thirdparty" $'/addon load clock\t'; do
  send "$bad"; check "refused: '${bad//$'\t'/<tab>}' exit 1" "$RC" 1
done
send_stdin $'/addon load clock\n/unload thirdparty\n'
check "a refused line in a batch refuses the whole batch: exit 1" "$RC" 1
check "nothing reached the plugin from any refused send" "$(lines raw "$F1" | /usr/bin/wc -l | /usr/bin/tr -d ' ')" "$before"

echo "-- two plugins"
F2="$OUT/second.txt"
start_fake normal "$F2" 8 || exit 1
before=$(lines raw "$F1" | /usr/bin/wc -l | /usr/bin/tr -d ' ')
send "/addon load clock";                 check "two clients: exit 3 (ambiguous)" "$RC" 3
check "neither got anything" "$(lines raw "$F1" | /usr/bin/wc -l | /usr/bin/tr -d ' ')/$(lines raw "$F2" | /usr/bin/wc -l | /usr/bin/tr -d ' ')" "$before/0"
pid2="$(lines ready "$F2")"
send --pid "$pid2" "/addon load timers";  check "--pid picks one of them: exit 0" "$RC" 0
check "only that one ran it" "$(lines cmd "$F2")" "/addon load timers"
wait $FAKE_PID 2>/dev/null
send "/addon load clock";                 check "after the second exits, one again: exit 0" "$RC" 0
echo "     waiting for the first fake to exit"
wait $F1PID 2>/dev/null

echo "-- busy (a batch never taken)"
F3="$OUT/busy.txt"
start_fake busy "$F3" 12 || exit 1
send "/addon load clock";                 check "busy: exit 4" "$RC" 4
check "gave up after about 3 s (2900-6000 ms incl. wine start)" "$(( ELAPSED >= 2900 && ELAPSED < 6000 ))" 1
echo "     ${ELAPSED} ms"
wait $FAKE_PID 2>/dev/null

echo "-- pending (the game stopped reading its keyboard)"
F4="$OUT/stall.txt"
start_fake stall "$F4" 12 || exit 1
send "/addon load clock";                 check "pending: exit 5" "$RC" 5
check "waited about 5 s (4900-8000 ms incl. wine start)" "$(( ELAPSED >= 4900 && ELAPSED < 8000 ))" 1
echo "     ${ELAPSED} ms"
check "helper printed pending" "${STDOUT%% *}" "pending"
send "/addon load timers";                check "a second send while the first is still waiting: exit 4 (busy)" "$RC" 4
wait $FAKE_PID 2>/dev/null

echo
if (( fails == 0 )); then echo "all checks passed"; else echo "$fails FAILED"; fi
exit $(( fails == 0 ? 0 : 1 ))
