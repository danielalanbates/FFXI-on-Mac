#!/bin/zsh
# Exercise app/Resources/apply-update.sh in a throwaway folder: no /Applications, no real
# launcher, nothing opened or registered (open and lsregister are stubs that only log, handed to
# the helper as its sixth argument). It runs under `env -i` and `zsh -f`, as the launcher starts it.
#
#   ./scripts/tests/apply-update-test.sh <notarized app signed by team MG4YW8XX2Z>
#
# The given app plays the downloaded update (any of this team's notarized apps will do, e.g.
# DockFix.app); a bare bundle plays the installed launcher. The real updater additionally pins
# the bundle id, which the success case relaxes because the stand-in is a different app.
set -uo pipefail
REPO="${0:A:h:h:h}"
HELPER="$REPO/app/Resources/apply-update.sh"
UPDATE="${1:-}"
[[ -d "$UPDATE" ]] || { print -u2 "usage: $0 <notarized MG4YW8XX2Z app>"; exit 2; }
TEAM_REQ='anchor apple generic and certificate leaf[subject.OU] = "MG4YW8XX2Z"'
PINNED_REQ='anchor apple generic and identifier "org.batesai.horizonxi-on-mac" and certificate leaf[subject.OU] = "MG4YW8XX2Z"'

T="$(mktemp -d "${TMPDIR:-/tmp}/apply-update-test.XXXXXX")"
trap '/usr/bin/chflags -R nouchg "$T" 2>/dev/null; /bin/chmod -R u+w "$T" 2>/dev/null; /bin/rm -rf "$T"' EXIT
fails=0
check() { if eval "$2"; then print "  ok   $1"; else print "  FAIL $1"; fails=$((fails + 1)); fi }

stubs="$T/stubs"
mkdir -p "$stubs"

apps="$T/Apps" work="$T/work"
current="$apps/FFXI-on-Mac.app" staged="$work/staged-v9.9/FFXI-on-Mac.app"
setup() {
  /usr/bin/chflags -R nouchg "$T" 2>/dev/null
  /bin/chmod -R u+w "$T" 2>/dev/null
  rm -rf "$apps" "$work" "$T"/*.calls(N)
  # Stubs that only log; a case may replace one after setup.
  for s in open lsregister; do
    printf '#!/bin/sh\necho "$@" >> "%s/%s.calls"\n' "$T" "$s" > "$stubs/$s"
    chmod +x "$stubs/$s"
  done
  mkdir -p "$current/Contents" "${staged:h}"
  print old > "$current/Contents/marker"
  /usr/bin/plutil -create xml1 "$current/Contents/Info.plist"
  /usr/bin/plutil -insert CFBundleShortVersionString -string 1.0 "$current/Contents/Info.plist"
  /usr/bin/plutil -insert CFBundleVersion -string 7 "$current/Contents/Info.plist"
  /usr/bin/ditto "$UPDATE" "$staged"
}
dead_pid() { /bin/sleep 0 & local p=$!; wait $p 2>/dev/null; print $p; }
# Started the way the launcher starts it (UpdateWork.helperCommand), plus the stubs argument.
CLEAN=(/usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin /bin/zsh -f)
helper() { "${CLEAN[@]}" "$HELPER" "$@" "$stubs"; }

print "1. success: swap, reopen, register, keep exactly one previous copy"
setup
mkdir -p "$work/previous-0.9-b3.app"
helper "$(dead_pid)" "$staged" "$current" "$work" "$TEAM_REQ"; rc=$?
check "exit 0" "(( rc == 0 ))"
check "update in place" "[[ ! -e '$current/Contents/marker' && -d '$current/Contents/MacOS' ]]"
check "previous kept as previous-1.0-b7.app" "[[ -f '$work/previous-1.0-b7.app/Contents/marker' ]]"
check "only one previous copy" "(( \$(ls -d '$work'/previous*.app | wc -l) == 1 ))"
check "opened the new app" "grep -qx '$current' '$T/open.calls'"
check "re-registered with lsregister" "grep -qx -- '-f $current' '$T/lsregister.calls'"
check "staged copy removed" "[[ ! -e '${staged:h}' ]]"
check "lock released" "[[ ! -e '$work/apply.lock' ]]"
check "no failure note" "[[ ! -e '$work/last-failure' ]]"
check "no leftovers beside the app" "[[ -z \$(ls '$apps' | grep -v '^FFXI-on-Mac.app\$') ]]"
check "log is timestamped" "grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9:]{8} .*swapped in the update' '$work/apply-update.log'"

print "2. wrong signer: old app untouched and reopened, reason left for the launcher"
setup
helper "$(dead_pid)" "$staged" "$current" "$work" "$PINNED_REQ"; rc=$?
check "exit non-zero" "(( rc != 0 ))"
check "old app untouched" "[[ -f '$current/Contents/marker' ]]"
check "reopened the old app" "grep -qx '$current' '$T/open.calls'"
check "failure note written" "grep -qx 'reason=the update is not signed by this project' '$work/last-failure'"
check "failure note names the release" "grep -qx 'tag=v9.9' '$work/last-failure'"
check "a wrong signer is not marked as recurring" "grep -qx 'lasting=0' '$work/last-failure'"
check "no leftovers beside the app" "[[ -z \$(ls '$apps' | grep -v '^FFXI-on-Mac.app\$') ]]"
check "lock released" "[[ ! -e '$work/apply.lock' ]]"
check "staged copy kept for a retry" "[[ -d '$staged' ]]"

print "3. another helper holds the lock: leave everything alone"
setup
mkdir -p "$work/apply.lock"; print $$ > "$work/apply.lock/pid"
helper "$(dead_pid)" "$staged" "$current" "$work" "$TEAM_REQ"; rc=$?
check "exit 0" "(( rc == 0 ))"
check "old app untouched" "[[ -f '$current/Contents/marker' ]]"
check "nothing opened" "[[ ! -e '$T/open.calls' ]]"
check "the other helper's lock kept" "[[ \$(cat '$work/apply.lock/pid') == $$ ]]"

print "4. stale lock (dead owner): taken over, update applied"
setup
mkdir -p "$work/apply.lock"; print "$(dead_pid)" > "$work/apply.lock/pid"
helper "$(dead_pid)" "$staged" "$current" "$work" "$TEAM_REQ"; rc=$?
check "exit 0" "(( rc == 0 ))"
check "update in place" "[[ ! -e '$current/Contents/marker' ]]"

print "5. launcher cancels (quit was cancelled): nothing touched, nothing opened"
setup
/bin/sleep 15 &
launcher=$!
# Started directly, not through the helper function, so $! is the helper's own pid (env execs).
"${CLEAN[@]}" "$HELPER" "$launcher" "$staged" "$current" "$work" "$TEAM_REQ" "$stubs" &
h=$!
for i in {1..100}; do [[ "$(cat "$work/apply.lock/pid" 2>/dev/null)" == "$h" ]] && break; /bin/sleep 0.1; done
: > "$work/apply.cancel-$h"
wait $h; rc=$?
check "exit 0" "(( rc == 0 ))"
check "old app untouched" "[[ -f '$current/Contents/marker' ]]"
check "nothing opened" "[[ ! -e '$T/open.calls' ]]"
check "no failure note" "[[ ! -e '$work/last-failure' ]]"
check "cancel marker and lock cleaned" "[[ ! -e '$work/apply.cancel-$h' && ! -e '$work/apply.lock' ]]"
wait $launcher 2>/dev/null

print "6. folder not writable: refuse before touching anything, reopen the old app"
setup
/bin/chmod a-w "$apps"
helper "$(dead_pid)" "$staged" "$current" "$work" "$TEAM_REQ"; rc=$?
/bin/chmod u+w "$apps"
check "exit non-zero" "(( rc != 0 ))"
check "old app untouched" "[[ -f '$current/Contents/marker' ]]"
check "reopened the old app" "grep -qx '$current' '$T/open.calls'"
check "failure note says why" "grep -q 'no write access' '$work/last-failure'"
check "marked as recurring (the launcher offers Download instead)" "grep -qx 'lasting=1' '$work/last-failure'"

print "7. the new app does not open: roll back to the old app and reopen it"
setup
# This open fails once (the new app), then works (the reopened old one).
printf '#!/bin/sh\necho "$@" >> "%s/open.calls"\n[ -e "%s/open.failed" ] && exit 0\n: > "%s/open.failed"; exit 1\n' \
  "$T" "$T" "$T" > "$stubs/open"
helper "$(dead_pid)" "$staged" "$current" "$work" "$TEAM_REQ"; rc=$?
check "exit non-zero" "(( rc != 0 ))"
check "old app restored" "[[ -f '$current/Contents/marker' ]]"
check "open tried twice (new, then old)" "(( \$(grep -cx '$current' '$T/open.calls') == 2 ))"
check "no leftovers beside the app" "[[ -z \$(ls '$apps' | grep -v '^FFXI-on-Mac.app\$') ]]"
check "failure note says why" "grep -q 'did not open' '$work/last-failure'"
rm -f "$T/open.failed"

print "8. the rename is refused (as App Management would): old app reopened, marked as recurring"
setup
/usr/bin/chflags uchg "$current"
helper "$(dead_pid)" "$staged" "$current" "$work" "$TEAM_REQ"; rc=$?
/usr/bin/chflags nouchg "$current"
check "exit non-zero" "(( rc != 0 ))"
check "old app untouched" "[[ -f '$current/Contents/marker' ]]"
check "reopened the old app" "grep -qx '$current' '$T/open.calls'"
check "failure note says why" "grep -qx 'reason=could not move the current app aside' '$work/last-failure'"
check "marked as recurring" "grep -qx 'lasting=1' '$work/last-failure'"
check "no leftovers beside the app" "[[ -z \$(ls '$apps' | grep -v '^FFXI-on-Mac.app\$') ]]"

print "9. a test hook in the environment is ignored: only the argument counts"
setup
poison="$T/poison"
mkdir -p "$poison"
for s in open lsregister; do
  printf '#!/bin/sh\necho "$@" >> "%s/poison.calls"\n' "$T" > "$poison/$s"
  chmod +x "$poison/$s"
done
# Not through env -i, so the variable really is in the helper's environment.
HXI_UPDATE_TEST_STUBS="$poison" /bin/zsh -f "$HELPER" "$(dead_pid)" "$staged" "$current" "$work" "$TEAM_REQ" "$stubs"; rc=$?
check "exit 0" "(( rc == 0 ))"
check "the environment's open was never run" "[[ ! -e '$T/poison.calls' ]]"
check "the argument's open was" "grep -qx '$current' '$T/open.calls'"
check "the helper names no environment hook" "! grep -q 'HXI_UPDATE_TEST_STUBS' '$HELPER'"

print "10. the old launcher was reopened meanwhile: nothing touched, nothing reopened, no note"
setup
# A stand-in running from the bundle's MacOS folder, as a launcher reopened from the Dock would.
mkdir -p "$current/Contents/MacOS"
printf '#!/bin/sh\nwhile [ ! -e "%s/stand-in.stop" ]; do /bin/sleep 0.2; done\n' "$T" > "$current/Contents/MacOS/stand-in"
chmod +x "$current/Contents/MacOS/stand-in"
rm -f "$T/stand-in.stop"
"$current/Contents/MacOS/stand-in" &
standin=$!
helper "$(dead_pid)" "$staged" "$current" "$work" "$TEAM_REQ"; rc=$?
: > "$T/stand-in.stop"; wait $standin 2>/dev/null
check "exit non-zero" "(( rc != 0 ))"
check "old app untouched" "[[ -f '$current/Contents/marker' ]]"
check "nothing opened (it is running)" "[[ ! -e '$T/open.calls' ]]"
check "no failure note (it offers Restart again)" "[[ ! -e '$work/last-failure' ]]"
check "logged why" "grep -q 'the launcher was reopened during the update' '$work/apply-update.log'"
check "no leftovers beside the app" "[[ -z \$(ls '$apps' | grep -v '^FFXI-on-Mac.app\$') ]]"
check "staged copy kept" "[[ -d '$staged' ]]"
check "lock released" "[[ ! -e '$work/apply.lock' ]]"

print "11. launcher running from a previous copy in the work dir: the cleanup spares it"
saved="$current"
current="$work/previous-0.9-b3.app"
setup
helper "$(dead_pid)" "$staged" "$current" "$work" "$TEAM_REQ"; rc=$?
check "exit 0" "(( rc == 0 ))"
check "the app just opened is still there, updated" "[[ -d '$current/Contents/MacOS' && ! -e '$current/Contents/marker' ]]"
check "previous kept as previous-1.0-b7.app" "[[ -f '$work/previous-1.0-b7.app/Contents/marker' ]]"
print "    same, where the previous copy's name is the app's own"
current="$work/previous-1.0-b7.app"
setup
helper "$(dead_pid)" "$staged" "$current" "$work" "$TEAM_REQ"; rc=$?
check "exit 0" "(( rc == 0 ))"
check "the app just opened is still there, updated" "[[ -d '$current/Contents/MacOS' && ! -e '$current/Contents/marker' ]]"
check "nothing moved into the new app" "[[ \$(ls '$current') == Contents ]]"
check "the previous app left beside it" "[[ -f \$(print -r -- '$current'.previous-*(N[1]))/Contents/marker ]]"
current="$saved"

print
if (( fails == 0 )); then print "all checks passed"; else print "$fails FAILED"; fi
(( fails == 0 ))
