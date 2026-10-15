#!/bin/zsh
# Copyright (c) 2026 Bates LLC. All rights reserved.
#
# game-wine.sh — the game's Wine: athei/wine-build's CrossOver 26.3.0 build ("wine-coop"), the only
# Wine HorizonXI plays under. The wrapper's own Wine closes the client one second after login
# (docs/WINE-BUILD.md). Setup runs this after Wine and before the game download.
#
#   game-wine.sh install <FFXI on Mac folder>   -> <folder>/wine-coop/wine/bin/wine
#
# Fetched on the user's Mac from the build's own GitHub release, pinned here (and only here) by
# size and SHA-256, and never shipped with the app: Wine is LGPL 2.1 (LICENSING.md), the same
# model as aria2 in update-client.sh. Needs nothing a stock Mac lacks (curl, shasum, tar).
#
# Nothing is unpacked until the download's size and checksum match. The download resumes after a
# Stop or a dropped connection (curl -C -, a few attempts); it unpacks into a temp folder beside
# wine-coop and is renamed into place in one step, so wine-coop is either complete or not there,
# and the tarball (this script's own download) is deleted once it is unpacked. A download that
# does not match is deleted and nothing else changes.
set -euo pipefail

say() { print -r -- "==> $*"; }
die() { print -r -- "!! $*" >&2; exit 1; }

# The pin: athei/wine-build release cx-26.3.0-1, its asset's GitHub digest. Checked 2026-10-15 by
# a fresh download: every file in it matches the copy HorizonXI was measured on, except
# lib/external/libMoltenVK.dylib, which the launcher itself replaces with its bundled 1.4.2
# (Renderer.upgradeCoopMoltenVK). The HXI_GAME_WINE_* overrides are for
# scripts/tests/setup-scripts-test.sh only; the launcher clears them.
WINE_URL="${HXI_GAME_WINE_URL:-https://github.com/athei/wine-build/releases/download/cx-26.3.0-1/wine-cx-26.3.0-1-macos-x86_64.tar.xz}"
WINE_BYTES="${HXI_GAME_WINE_BYTES:-203696924}"
WINE_SHA256="${HXI_GAME_WINE_SHA256:-ec2a9e4d438917a26e381c01367773df79c3b0d6f0504b8183464619cad7e661}"
# Unpacked: 3,692 files, 1.13 GB on disk.
WINE_UNPACKED=1130000000

[[ "${1:-}" == install && -n "${2:-}" ]] || die "usage: $0 install <FFXI on Mac folder>"
root="${2%/}"
dest="$root/wine-coop"
dl="$root/.wine-coop-download"
tarball="$dl/${WINE_URL:t}"

# The mount point serving $1, and whether the /Volumes/<name> it needs is gone (or another drive
# answers at that name: /Volumes is case-insensitive). Same rule as update-client.sh.
mount_of() { /bin/df -P "$1" 2>/dev/null | /usr/bin/awk 'NR == 2 { for (i = 6; i <= NF; i++) printf "%s%s", $i, (i < NF ? " " : "") }'; }
vol_gone() {
  [[ -e "$1" ]] || return 0
  local m; m=$(mount_of "$1")
  [[ "$m" == /Volumes/* && "$m" != "$1" ]]
}
size_of() { [[ -f "$1" ]] && /usr/bin/stat -f %z "$1" || print 0; }

if [[ -x "$dest/wine/bin/wine" && -x "$dest/wine/bin/wineserver" ]]; then
  say "the game's Wine is already installed in $dest"
  exit 0
fi
if [[ "$root" == /Volumes/* ]]; then
  vol="/Volumes/${${root#/Volumes/}%%/*}"
  vol_gone "$vol" && die "The '${vol:t}' drive isn't connected — reconnect it or press Setup. Nothing was changed."
fi
have=$(size_of "$tarball")
# Larger than the pin: not something a resume can fix (deleted below, once there is room).
(( have > WINE_BYTES )) && have=0

# The rest of the download plus the unpacked tree; on the Mac's own disk, 8 GB stay free as well.
# Asked of the nearest folder that exists, so a refusal writes nothing.
probe="$root"; while [[ ! -e "$probe" ]]; do probe="${probe:h}"; done
need=$(( WINE_BYTES - have + WINE_UNPACKED ))
m=$(mount_of "$probe")
[[ "$m" == / || "$m" == /System/Volumes/Data ]] && need=$(( need + 8000000000 ))
free=$(( $(/bin/df -k "$probe" | /usr/bin/awk 'NR==2 {print $4}') * 1024 ))
(( free >= need )) || die "The game's Wine needs about $(( (need + 999999999) / 1000000000 )) GB free here; there are $(( free / 1000000000 )) GB. Free some space, or press Setup to choose another place."

mkdir -p "$dl" || die "Couldn't make a folder in $root. Nothing was changed."
(( have == 0 )) && /bin/rm -f "$tarball"

# A Stop during an unpack leaves its temp folder: ours, by name, and never complete.
unpack=""
trap '[[ -n "$unpack" ]] && /bin/rm -rf "$unpack"' EXIT
for old in "$root"/.wine-coop-unpack.*(N/); do /bin/rm -rf "$old"; done

if (( have < WINE_BYTES )); then
  say "downloading the game's Wine ($(( WINE_BYTES / 1000000 )) MB) into $root"
  attempt=0 last=-1
  while (( $(size_of "$tarball") < WINE_BYTES )); do
    (( ++attempt <= 5 )) || die "The game's Wine didn't download. Check the internet connection, then press Setup again."
    (( attempt > 1 )) && sleep 2
    # -C -: carry on from what is there. A stall (under 1 KB/s for a minute) ends the attempt and
    # the next one resumes.
    /usr/bin/curl -fL -sS --connect-timeout 20 --speed-limit 1024 --speed-time 60 \
        --retry 2 --retry-delay 2 -C - -o "$tarball" "$WINE_URL" &
    pid=$!
    rc=0
    # The same readout as aria2's ("…(42%)"), so the launcher's button shows it and its log skips it.
    while kill -0 $pid 2>/dev/null; do
      pct=$(( $(size_of "$tarball") * 100 / WINE_BYTES ))
      (( pct != last )) && { print -r -- "[#game-wine $(( $(size_of "$tarball") / 1000000 ))/$(( WINE_BYTES / 1000000 ))MB($pct%)]"; last=$pct; }
      sleep 1
    done
    wait $pid || rc=$?
    # A finished download of another size is another file: no resume can fix that.
    got=$(size_of "$tarball")
    if (( (rc == 0 && got != WINE_BYTES) || got > WINE_BYTES )); then
      /bin/rm -f "$tarball"; /bin/rmdir "$dl" 2>/dev/null || true
      die "The game's Wine download didn't match its checksum, so it wasn't installed. Press Setup to try again."
    fi
    # 33: the server ignored the resume. Start that file over rather than append to it.
    (( rc == 33 )) && /bin/rm -f "$tarball"
  done
  print -r -- "[#game-wine $(( WINE_BYTES / 1000000 ))/$(( WINE_BYTES / 1000000 ))MB(100%)]"
fi

say "verifying the game's Wine"
sum=$(/usr/bin/shasum -a 256 "$tarball" | /usr/bin/cut -d' ' -f1)
if [[ "$(size_of "$tarball")" != "$WINE_BYTES" || "$sum" != "$WINE_SHA256" ]]; then
  /bin/rm -f "$tarball"; /bin/rmdir "$dl" 2>/dev/null || true
  die "The game's Wine download didn't match its checksum, so it wasn't installed. Press Setup to try again."
fi

say "extracting the game's Wine"
unpack=$(/usr/bin/mktemp -d "$root/.wine-coop-unpack.XXXXXX")
/bin/chmod 755 "$unpack"
/usr/bin/tar -xJf "$tarball" -C "$unpack" || die "Couldn't unpack the game's Wine. Press Setup to try again."
[[ -x "$unpack/wine/bin/wine" && -x "$unpack/wine/bin/wineserver" ]] \
  || die "The game's Wine download didn't hold Wine. Nothing was installed."

# Something already called wine-coop without a Wine in it is set aside, never deleted.
if [[ -e "$dest" || -L "$dest" ]]; then
  aside="$dest.incomplete-$(/bin/date +%Y%m%d-%H%M%S)"
  /bin/mv "$dest" "$aside" || die "Couldn't set the old $dest aside. Nothing was installed."
  say "an incomplete wine-coop folder was set aside as ${aside:t}"
fi
# Same folder, so a rename: wine-coop appears complete or not at all.
/bin/mv "$unpack" "$dest" || die "Couldn't put the game's Wine in place. Press Setup to try again."
unpack=""
/bin/rm -f "$tarball"; /bin/rmdir "$dl" 2>/dev/null || true
say "the game's Wine is installed in $dest"
