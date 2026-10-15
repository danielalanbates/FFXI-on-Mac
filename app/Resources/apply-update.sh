#!/bin/zsh
# apply-update.sh <launcher-pid> <staged.app> <current.app> <workdir> <requirement>
#
# Replace the launcher with a verified update once the launcher has quit. Started detached
# (Detach.spawn) so it survives the launcher's exit. All paths arrive as arguments, never as
# shell code.
#
#   * Everything is logged, timestamped, to <workdir>/apply-update.log.
#   * One helper at a time: <workdir>/apply.lock holds the owner's pid. The launcher quits only
#     once it sees its own helper's pid there.
#   * ANY failure after the launcher has quit puts the old app back and reopens it, and leaves
#     the reason in <workdir>/last-failure for the reopened launcher to show, with the release's
#     tag and whether the same failure would recur on every try (the launcher then offers the
#     Download link instead of Restart; see Updater.becomeReady).
#   * The candidate must satisfy the same Apple-anchored requirement and Gatekeeper check the
#     launcher used. The swap is two renames with rollback.
#   * Exactly one previous copy is kept, in <workdir>.
#
# No `set -e`: every step is checked explicitly, so the EXIT trap always gets to clean up.
set -u
setopt pipefail

pid="${1:-}" staged="${2:-}" current="${3:-}" workdir="${4:-}" requirement="${5:-}"
[[ -n "$pid" && -n "$staged" && -n "$current" && -n "$workdir" && -n "$requirement" ]] || exit 2

log="$workdir/apply-update.log"
# Keep the log readable: trim it to its tail once it passes 1 MB.
if [[ -f "$log" ]] && (( $(/usr/bin/stat -f %z "$log" 2>/dev/null || echo 0) > 1048576 )); then
  /usr/bin/tail -n 2000 "$log" > "$log.tmp" 2>/dev/null && /bin/mv "$log.tmp" "$log"
fi
exec >>"$log" 2>&1
say() { print -r -- "$(/bin/date '+%Y-%m-%d %H:%M:%S') [$$] $*"; }

lock="$workdir/apply.lock"
cancel="$workdir/apply.cancel-$$"
if ! /bin/mkdir "$lock" 2>/dev/null; then
  owner="$(/bin/cat "$lock/pid" 2>/dev/null || true)"
  # Stale when its owner is gone or it is older than any helper run (the launcher uses the
  # same rule before starting one).
  if [[ -n "$owner" ]] && /bin/kill -0 "$owner" 2>/dev/null \
     && [[ -z "$(/usr/bin/find "$lock" -maxdepth 0 -mmin +15 2>/dev/null)" ]]; then
    say "another update helper (pid $owner) holds the lock; leaving it alone"
    exit 0
  fi
  say "removing a stale lock left by pid ${owner:-unknown}"
  /bin/rm -rf "$lock"
  /bin/mkdir "$lock" 2>/dev/null || { say "could not take the update lock"; exit 1; }
fi
print -r -- "$$" > "$lock/pid"

LSREG=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
OPEN=/usr/bin/open
SEEN_WAIT=60
# Test hooks for scripts/tests/apply-update-test.sh only: the launcher starts this helper with
# PATH as its sole environment variable, so none of these is ever set in real use.
if [[ -n "${HXI_UPDATE_TEST_STUBS:-}" ]]; then
  OPEN="$HXI_UPDATE_TEST_STUBS/open" LSREG="$HXI_UPDATE_TEST_STUBS/lsregister" SEEN_WAIT=1
fi
candidate="${current}.next-$$"
backup="${current}.previous-$$"
# The launcher stages each release in <workdir>/staged-<tag>/.
tag="${${${staged:h}:t}#staged-}"
ok=0 launcher_gone=0 moved_current=0 placed=0 lasting=0 reason="stopped before finishing"

finish() {
  if (( ! ok )); then
    say "update not applied: $reason"
    if (( placed )); then
      /bin/mv "$current" "$candidate" || say "could not move the new app aside"
    fi
    if (( moved_current )); then
      # mv onto an existing folder would move the backup *into* it, so never try that.
      if [[ -e "$current" ]]; then say "ROLLBACK FAILED: $current is occupied; the previous app is at $backup"
      elif /bin/mv "$backup" "$current"; then say "restored the previous app"
      else say "ROLLBACK FAILED: the previous app is at $backup"; fi
    fi
    [[ -e "$candidate" ]] && /bin/rm -rf "$candidate"
    if (( launcher_gone )); then
      print -rl -- "reason=$reason" "tag=$tag" "lasting=$lasting" > "$workdir/last-failure"
      local app="$current"
      [[ -d "$app" ]] || app="$backup"
      if [[ -d "$app" ]] && "$OPEN" "$app"; then say "reopened $app"
      else say "could not reopen the launcher"; fi
    fi
  fi
  /bin/rm -f "$cancel"
  /bin/rm -rf "$lock"
}
trap finish EXIT
trap 'reason="interrupted"; exit 1' INT TERM HUP
fail() { reason="$1"; exit 1; }
# A failure every later try would meet too (the folder or the rename refused).
fail_lasting() { lasting=1; fail "$1"; }

say "helper started: launcher pid $pid, $staged -> $current"

# Wait for the launcher to quit. It quits as soon as it sees this helper hold the lock; if it
# changes its mind (the quit was cancelled) it writes $cancel and nothing is touched.
for i in {1..120}; do
  if [[ -e "$cancel" ]]; then reason="cancelled by the launcher"; exit 0; fi
  /bin/kill -0 "$pid" 2>/dev/null || break
  /bin/sleep 0.5
done
if /bin/kill -0 "$pid" 2>/dev/null; then fail "the launcher did not quit within 60 s"; fi
launcher_gone=1

[[ -d "$staged" ]] || fail "the staged update is missing"
[[ -d "$current" ]] || fail "the current app is missing"
[[ -w "${current:h}" ]] || fail_lasting "no write access to ${current:h}"
[[ ! -e "$backup" ]] || fail "a leftover $backup is in the way"
/bin/rm -rf "$candidate"

# Copy and verify beside the app before touching it. A failed copy leaves the app as it was.
/usr/bin/ditto "$staged" "$candidate" || fail "could not copy the update next to the app"
/usr/bin/xattr -dr com.apple.quarantine "$candidate" 2>/dev/null
/usr/bin/codesign --verify --strict --deep -R "=$requirement" "$candidate" \
  || fail "the update is not signed by this project"
/usr/sbin/spctl -a -t execute "$candidate" || fail "Gatekeeper rejected the update"
say "candidate verified"

# The old launcher may have been reopened (from the Dock, say) while the update was copied and
# checked. Renaming its bundle under it would leave it running from the previous copy, so nothing
# is touched. Nothing is reopened either, since it is running, and it offers Restart again.
if /usr/bin/pgrep -qf -U "$UID" "$current/Contents/MacOS/"; then
  launcher_gone=0
  fail "the launcher was reopened during the update"
fi
/bin/mv "$current" "$backup" || fail_lasting "could not move the current app aside"
moved_current=1
[[ ! -e "$current" ]] || fail "$current reappeared during the swap"
/bin/mv "$candidate" "$current" || fail "could not move the update into place"
placed=1
say "swapped in the update"

# Replacing a bundle in place leaves the Dock and Finder on the icon they cached for the path
# (bundle.sh does the same after a rebuild).
/usr/bin/touch "$current"
[[ -x "$LSREG" ]] && "$LSREG" -f "$current" >/dev/null 2>&1

"$OPEN" "$current" || fail "the updated app did not open"
ok=1
say "opened $current"

# Keep exactly one previous copy, outside Applications. Never the app just opened, should the
# launcher have been running from a previous copy in the work dir.
for old in "$workdir"/previous*.app(N); do [[ "${old:A}" == "${current:A}" ]] || /bin/rm -rf "$old"; done
old_version="$(/usr/bin/plutil -extract CFBundleShortVersionString raw "$backup/Contents/Info.plist" 2>/dev/null || echo unknown)"
old_build="$(/usr/bin/plutil -extract CFBundleVersion raw "$backup/Contents/Info.plist" 2>/dev/null || echo 0)"
keep="$workdir/previous-${old_version}-b${old_build}.app"
# mv onto an existing folder would move the backup *into* it (here: into the new app).
if [[ -e "$keep" ]]; then
  say "${keep:t} is in the way; left the previous app at $backup"
elif /bin/mv "$backup" "$keep"; then
  say "kept the previous app as ${keep:t}"
else
  say "could not move $backup out of the way; remove it by hand"
fi
/bin/rm -rf "${staged:h}"
/bin/rm -f "$workdir/last-failure"

# Informational only: rolling back an app that is merely slow to start would do more harm.
for i in {1..$SEEN_WAIT}; do
  /usr/bin/pgrep -qf "$current/Contents/MacOS/" && { say "the updated launcher is running"; exit 0; }
  /bin/sleep 0.5
done
say "the updated launcher was not seen running within 30 s (the previous copy is in $workdir)"
