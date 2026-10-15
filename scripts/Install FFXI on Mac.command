#!/bin/zsh
# "Install FFXI on Mac.command" — double-clickable installer.
#
# Written for someone who has never opened Terminal. It explains what it is doing, checks the
# things that actually go wrong on this setup, and refuses to guess when it needs a human answer.
#
# It does NOT download the game. The client is ~27GB of Square Enix data and the Wine wrapper has
# licence questions this project has not cleared, so both are things you supply.

emulate -L zsh
setopt no_unset pipe_fail

BOLD=$'\e[1m'; DIM=$'\e[2m'; RED=$'\e[31m'; GRN=$'\e[32m'; YEL=$'\e[33m'; OFF=$'\e[0m'
HERE="${0:A:h}"; REPO="${HERE:h}"

say()  { print -r -- "$BOLD$*$OFF" }
info() { print -r -- "  $*" }
ok()   { print -r -- "  ${GRN}✓$OFF $*" }
warn() { print -r -- "  ${YEL}!$OFF $*" }
die()  { print -r -- "\n  ${RED}✗ $*$OFF\n"; print -r -- "  Press return to close."; read -r _; exit 1 }

clear
say "FINAL FANTASY XI on Mac — installer"
print -r -- "${DIM}This sets up the launcher. It will tell you before it changes anything.$OFF\n"

# ---------------------------------------------------------------- 1. this Mac
say "1. Checking this Mac"
[[ "$(uname -s)" == Darwin ]] || die "This only runs on macOS."
os=$(sw_vers -productVersion)
(( ${os%%.*} >= 13 )) || die "macOS 13 or newer is required. You have $os."
ok "macOS $os on $(uname -m)"
[[ "$(uname -m)" == arm64 ]] || warn "Intel Mac — untested. It may work; nobody has tried."

# ---------------------------------------------------------------- 2. the wrapper
say "\n2. Looking for a Wine wrapper with a HorizonXI client"
typeset -a found
for root in /Applications ~/Applications /Volumes/*(N); do
  for app in $root/**/*.app(N/); do
    [[ -x "$app/Contents/SharedSupport/wine/bin/wine" ]] || continue
    for p in $app/Contents/SharedSupport/prefix*(N/); do
      [[ -d "$p/drive_c/HorizonXI" ]] && found+=("$app::${p:t}")
    done
  done
done

if (( ${#found} == 0 )); then
  print -r -- ""
  warn "No install found."
  cat <<'TXT'

  You need two things this installer cannot legally fetch for you:

    1. The HorizonXI client (~27GB). Install it with HorizonXI's own Windows
       launcher, or copy an existing install, into:
           <wrapper>.app/Contents/SharedSupport/prefix10/drive_c/HorizonXI
    2. A Wine wrapper app (Kegworks / Sikarugir style) containing
           Contents/SharedSupport/wine/bin/wine

  Put the wrapper in /Applications or on an external drive, then run this again.

  One warning that will save you a day: the wrapper cannot live on an exFAT
  volume, and if it is on an external drive every app touching it needs the
  "Removable Volumes" permission in System Settings › Privacy & Security.
TXT
  print -r -- "\n  Press return to close."; read -r _; exit 1
fi

if (( ${#found} == 1 )); then
  choice="${found[1]}"
else
  print -r -- ""
  for i in {1..${#found}}; do info "$i) ${found[$i]%%::*} (${found[$i]##*::})"; done
  print -rn -- "\n  Which one? [1] "; read -r n; n=${n:-1}
  choice="${found[$n]:-${found[1]}}"
fi
APP="${choice%%::*}"; PREFIX="${choice##*::}"
ok "using ${APP:t} · $PREFIX"

# Nothing below may run under a live game: step 3 rewrites the prefix the client is using and
# step 4 replaces the launcher. The same processes app/bundle.sh refuses to install under (see its
# LIVE_PATTERN); it checks again itself before the swap. Pid and executable only: a loader's
# arguments carry the account password.
LIVE_PATTERN='FFXI-on-Mac\.app/Contents/(MacOS|Resources/x87sidecar)|horizon-loader|Ashita-cli|/wine-coop/wine/|/SharedSupport/wine/'
if live=$(/usr/bin/pgrep -f "$LIVE_PATTERN"); then
  print -r -- ""
  /bin/ps -o pid=,comm= -p "${(j:,:)${(f)live}}" 2>/dev/null | while read -r line; do info "$DIM$line$OFF"; done
  die "FFXI on Mac or the game is running. Quit it (in game, type /shutdown) and run this again."
fi

# ---------------------------------------------------------------- 3. configure
say "\n3. Configuring the Wine prefix"
info "This writes the PlayOnline registry keys and registers FFXI's COM servers."
info "It does not touch anything outside the wrapper."
print -rn -- "\n  Continue? [Y/n] "; read -r go
[[ "${go:l}" == n* ]] && die "Stopped at your request. Nothing was changed."
"$REPO/scripts/install.sh" "$APP" "$PREFIX" || die "Configuration failed. See the output above."
ok "prefix configured"

# ---------------------------------------------------------------- 4. the app
say "\n4. Installing the launcher"
command -v swift >/dev/null 2>&1 || die "No Swift toolchain. Install Xcode Command Line Tools:
      xcode-select --install"
info "Building it (about a minute)…"
# bundle.sh builds beside the installed copy and swaps it in only once the new one is complete
# (putting the old one back if that fails), and moves the old one to
# ~/Downloads/FFXI-on-Mac-build/archive-apps instead of deleting it.
"$REPO/app/bundle.sh" /Applications >/dev/null || die "Could not install to /Applications. See the lines above."
ok "installed to /Applications/FFXI-on-Mac.app"

# ---------------------------------------------------------------- done
say "\nDone."
cat <<'TXT'

  Open FFXI on Mac from /Applications, pick your server, type your account
  name and password, and press PLAY. Your password is saved for your Mac user only.

  Two things to expect:

    * macOS will ask for permission to read a removable volume the first time.
      Say Allow, or the launcher cannot see the game.
    * It is slow. Zone loads take minutes on an 8GB M1. That is a known,
      unsolved problem — see docs/ANNOUNCEMENT.md.

TXT
print -r -- "  Press return to close."; read -r _
