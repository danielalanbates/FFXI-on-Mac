#!/bin/zsh
# release-check.sh — should a release go out, and is the local .app current?
#
# RELEASE-WHEN-STABLE.md holds two rules that are easy to state and easy to forget:
#
#   * /Applications/FFXI-on-Mac.app must be playable at ALL times and tracks the working
#     tree. Rebuild it as soon as a fix lands.
#   * The GitHub release is the opposite: gated on stability, and cut at most about once a
#     week. The clock is a ceiling, never an obligation.
#
# The failure mode is not disagreement with either rule; it is nobody knowing which state
# the tree is in. This answers that in one command. It only ever *reports* -- it does not
# build, install, tag or push, because every one of those is a decision.
#
#   scripts/release-check.sh
#
# Copyright (c) 2026 Bates LLC.  All rights reserved.
set -u

ROOT=${0:A:h:h}
APP=${VG_APP:-/Applications/FFXI-on-Mac.app}
BIN="$APP/Contents/MacOS/FFXI-on-Mac"

# Every git call is on a leash.  This repository lives in iCloud Drive, and when iCloud
# decides to evict or re-download a pack file, git blocks in mmap until it gives up -- for
# minutes, sometimes not at all.  A status report that hangs forever is worse than one that
# says "git did not answer", so nothing here waits longer than GIT_TIMEOUT seconds.
GIT_TIMEOUT=${GIT_TIMEOUT:-10}
GIT_OUT=$(mktemp)
trap 'rm -f "$GIT_OUT"' EXIT

git_try() {
  : > "$GIT_OUT"
  ( git -C "$ROOT" --no-optional-locks "$@" > "$GIT_OUT" 2>/dev/null ) &
  local pid=$! i=0
  while kill -0 $pid 2>/dev/null && (( i < GIT_TIMEOUT * 4 )); do
    sleep 0.25
    (( i += 1 ))
  done
  if kill -0 $pid 2>/dev/null; then
    kill -9 $pid 2>/dev/null
    return 124
  fi
  wait $pid 2>/dev/null
  cat "$GIT_OUT"
}

bold() { print -P "%B$*%b" }
say()  { print -r -- "  $*" }
warn() { print -P "  %F{yellow}!%f $*" }
good() { print -P "  %F{green}ok%f $*" }
bad()  { print -P "  %F{red}no%f $*" }

bold "the local .app  ($APP)"
if [[ ! -x "$BIN" ]]; then
  bad "not installed -- Daniel cannot play. Build with app/bundle.sh and copy it in."
else
  ver=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null)
  bld=$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$APP/Contents/Info.plist" 2>/dev/null)
  built=$(stat -f '%Sm' -t '%Y-%m-%d %H:%M' "$BIN")
  good "v$ver build $bld, built $built"
  # Anything in the launcher's own sources newer than the binary means the installed app is
  # behind the tree. Resources are checked too: the DXVK dll and the sidecar ship inside it.
  newer=$(find "$ROOT/app/Sources" "$ROOT/app/Package.swift" "$ROOT/app/Resources" \
               -type f -newer "$BIN" 2>/dev/null | wc -l | tr -d ' ')
  if [[ "$newer" == "0" ]]; then
    good "current with the launcher sources"
  else
    warn "$newer launcher source file(s) newer than the installed binary -- rebuild"
    find "$ROOT/app/Sources" "$ROOT/app/Package.swift" "$ROOT/app/Resources" \
         -type f -newer "$BIN" 2>/dev/null | sed "s|$ROOT/||" | head -8 | sed 's/^/      /'
  fi
fi

print
bold "is a rebuild safe right now?"
# Never replace the bundle under a running launcher or client: the wine process has the
# wrapper's Frameworks open, and Daniel plays on this build during development.
busy=0
if pgrep -f 'horizon-loader.exe' >/dev/null 2>&1; then
  bad "a client is running -- somebody is playing. Do not touch the bundle."
  busy=1
fi
if pgrep -f 'FFXI-on-Mac.app/Contents/MacOS' >/dev/null 2>&1; then
  warn "the launcher is open -- quit it before replacing the bundle"
  busy=1
fi
(( busy )) || good "nothing is running; the bundle can be replaced"

print
bold "the published release"
if ! git_try rev-parse --git-dir >/dev/null; then
  warn "git did not answer in ${GIT_TIMEOUT}s (iCloud, most likely) -- skipping the release check"
else
  tag=$(git_try describe --tags --abbrev=0)
  if [[ -z "$tag" ]]; then
    warn "no tag yet -- nothing has ever been released"
  else
    when=$(git_try log -1 --format=%cd --date=short "$tag")
    if [[ -n "$when" ]]; then
      days=$(( ( $(date +%s) - $(date -j -f %Y-%m-%d "$when" +%s 2>/dev/null || date +%s) ) / 86400 ))
      say "latest tag $tag, $when ($days days ago)"
      ahead=$(git_try rev-list --count "$tag"..HEAD)
      say "${ahead:-?} commits since it"
      if (( days < 7 )); then
        good "inside the week -- no release is due"
      elif [[ "$ahead" == "0" ]]; then
        good "nothing new to release"
      else
        warn "$days days and $ahead commits: a release is DUE, if and only if the tree is stable"
      fi
    fi
  fi
  dirty=$(git_try status --porcelain | wc -l | tr -d ' ')
  [[ "$dirty" == "0" ]] && good "working tree clean" || warn "$dirty uncommitted change(s)"
fi

print
bold "what only a person can answer"
cat <<'TXT'
  Every one of these has to be true, verified fresh, before a release is cut.
  RELEASE-WHEN-STABLE.md is the full text; this is the short form.

    [ ] several consecutive cold launches reach the world, no silent exit
    [ ] the mouse works: cursor visible, addon windows hoverable and clickable
    [ ] no wine window can be left unclosable; scripts/quit-wine.sh works
    [ ] frame rate holds at the max-settings target (scripts/max.json / max4k.json)
    [ ] several real play sessions with no manual intervention

  The clock is a ceiling, not an obligation. A week with an unstable tree means
  no release, not a release with caveats.
TXT
