#!/bin/zsh
# update-client.sh — bring the game files in a prefix up to date, the way each server's own
# launcher would, so the login server stops answering "The game's data has been updated".
#
#   update-client.sh check  <drive_c/HorizonXI dir>            -> prints "installed=<ver> horizon=<marketing> latest=<marketing>"
#   update-client.sh horizon <drive_c/HorizonXI dir>           -> applies every pending HorizonXI update
#   update-client.sh install <drive_c/HorizonXI dir>           -> base client (and Ashita) if missing, then every update
#   update-client.sh tools   <any dir>                         -> makes sure aria2c is there, prints "aria2c=<path>"
#
# What each server actually does (checked 2026-08-15, see docs/CLIENT-UPDATES.md):
#
#   * HorizonXI: `api.horizonxi.com/api/v1/launcher/update-game?ver=<n>` lists numbered update
#     zips, each delivered as a BitTorrent magnet (their Electron launcher uses webtorrent).
#     This script fetches them with aria2c, unzips over the game dir, deletes the
#     `deleteFiles` list, and writes the new marketing version to version.json — the same steps
#     their launcher performs. Torrents mean it can be slow or stall when nobody is seeding.
#
#   * CatsEyeXI: their launcher syncs the client from a private Cloudflare R2 bucket using
#     credentials baked into the .exe. There is no public manifest, so this script cannot
#     update a CatsEye client. It can only tell you the version is wrong (see `check`) and the
#     required version comes from their public server settings.
#
# Needs nothing a stock Mac lacks (b60): aria2c is Homebrew's when present, otherwise aria2's own
# macOS build fetched once into $HXI_TOOLS (pinned by size and SHA-256), and JSON is read with
# JavaScript for Automation instead of python3 (a Mac without the Command Line Tools has only a
# stub that pops an installer).
#
# Every step is idempotent: re-running after a stall or a Stop resumes the aria2 download.
set -euo pipefail

say() { print -r -- "==> $*"; }
die() { print -r -- "!! $*" >&2; exit 1; }

API="${HXI_API:-https://api.horizonxi.com/api/v1/launcher}"
UA="FFXI-on-Mac launcher"

game="${2:-}"
[[ "${1:-}" == install && -n "$game" ]] && mkdir -p "$game"
[[ -n "$game" && -d "$game" ]] || die "usage: $0 {check|horizon|install|tools} <game dir>"
ffxi="$game/SquareEnix/FINAL FANTASY XI"

# aria2's last macOS release build (x86_64, runs under Rosetta, which the game needs anyway;
# links only system libraries). Fetched from aria2's own GitHub release, never redistributed by
# this project. GPL-2.0-or-later: the archive carries its COPYING and source is at the same page.
ARIA2_URL="${HXI_ARIA2_URL:-https://github.com/aria2/aria2/releases/download/release-1.35.0/aria2-1.35.0-osx-darwin.tar.bz2}"
ARIA2_BYTES=1953763
ARIA2_SHA256=f6d9ab4212a97b4a52cf0ff03aeb24da673b11599e6b9c1a5d6a5f6c94fd39da
ARIA2C=""

ensure_aria2() {
  if [[ -n "${HXI_ARIA2C:-}" && -x "${HXI_ARIA2C}" ]]; then ARIA2C="$HXI_ARIA2C"; return; fi
  if command -v aria2c >/dev/null; then ARIA2C="$(command -v aria2c)"; return; fi
  local tools="${HXI_TOOLS:-$HOME/Library/Application Support/HorizonXI-on-Mac/tools}"
  ARIA2C="$tools/aria2c"
  [[ -x "$ARIA2C" ]] && return
  mkdir -p "$tools" || die "could not create $tools"
  local tmp; tmp=$(mktemp -d "$tools/.aria2-fetch.XXXXXX")
  say "fetching the torrent tool (aria2, 2 MB)"
  curl -fsSL -A "$UA" --max-time 120 -o "$tmp/aria2.tar.bz2" "$ARIA2_URL" \
    || { rm -rf "$tmp"; die "Couldn't download the torrent tool. Check the internet connection, then try again."; }
  local size sum
  size=$(stat -f %z "$tmp/aria2.tar.bz2")
  sum=$(shasum -a 256 "$tmp/aria2.tar.bz2" | cut -d' ' -f1)
  if [[ "$size" != "$ARIA2_BYTES" || "$sum" != "$ARIA2_SHA256" ]]; then
    rm -rf "$tmp"; die "The torrent tool download didn't match its checksum, so it wasn't used. Try again."
  fi
  tar -xjf "$tmp/aria2.tar.bz2" -C "$tmp" aria2-1.35.0/bin/aria2c aria2-1.35.0/share/doc/aria2/COPYING \
    || { rm -rf "$tmp"; die "Couldn't unpack the torrent tool."; }
  mv -f "$tmp/aria2-1.35.0/share/doc/aria2/COPYING" "$tools/aria2-COPYING"
  chmod 755 "$tmp/aria2-1.35.0/bin/aria2c"
  mv -f "$tmp/aria2-1.35.0/bin/aria2c" "$ARIA2C"
  rm -rf "$tmp"
  "$ARIA2C" --version >/dev/null 2>&1 \
    || die "The torrent tool doesn't run on this Mac (it needs Rosetta 2; press Setup)."
}

# JSON without python3: JavaScript for Automation is part of macOS. `jsq <file> <expr> [args]`
# prints the expression's value, with `d` the parsed document and `a` the extra arguments.
jsq() {
  local f="$1" expr="$2"; shift 2
  osascript -l JavaScript - "$f" "$@" <<JS 2>/dev/null
function run(argv) {
  var t = \$.NSString.stringWithContentsOfFileEncodingError(argv[0], \$.NSUTF8StringEncoding, null);
  if (t.isNil()) return "";
  var d = JSON.parse(ObjC.unwrap(t)), a = argv.slice(1);
  var r = ($expr);
  return (r === undefined || r === null) ? "" : String(r);
}
JS
}

# The retail patch level the client is at. patch.cfg is the client's own record of applied
# patch groups; the newest one listed is what the login server sees at offset 0x74 of packet 0x26.
installed_client() {
  [[ -f "$ffxi/patch.cfg" ]] || { print ""; return; }
  grep -oE '\b30[0-9]{6}_[0-9]\b' "$ffxi/patch.cfg" | sort -u | tail -1
}

# Read by pattern, not as JSON: files written before 356f615 hold a literal "\n" and are not JSON.
horizon_marketing() {
  [[ -f "$game/version.json" ]] || { print ""; return; }
  grep -oE '"version"[[:space:]]*:[[:space:]]*"[^"]+"' "$game/version.json" | head -1 \
    | sed -E 's/.*"([^"]+)"$/\1/' || print ""
}

fetch_json() { curl -fsSL -A "$UA" --max-time 20 -o "$2" "$1"; }

# The mount point serving $1. /Volumes is case-insensitive: with 'Games' ghost-mounted, a stick
# named 'GAMES' answered at /Volumes/Games (2026-10-15), so "it exists" is not enough.
mount_of() { /bin/df -P "$1" 2>/dev/null | /usr/bin/awk 'NR == 2 { for (i = 6; i <= NF; i++) printf "%s%s", $i, (i < NF ? " " : "") }'; }
vol_gone() {
  [[ -e "$1" ]] || return 0
  local m; m=$(mount_of "$1")
  [[ "$m" == /Volumes/* && "$m" != "$1" ]]
}

# The game's files can sit behind a symlink on another drive (SquareEnix -> /Volumes/Games/…).
# Writing through it while that drive is gone fails half way, so say so before writing anything.
drive_check() {
  local se="$game/SquareEnix" tgt vol
  [[ -L "$se" ]] || return 0
  tgt=$(readlink "$se")
  if [[ "$tgt" == /Volumes/* ]]; then
    vol="/Volumes/${${tgt#/Volumes/}%%/*}"
    vol_gone "$vol" && die "The '${vol:t}' drive isn't connected — reconnect it or press Setup. Nothing was changed."
  fi
  [[ -e "$se" ]] || die "The game's files link to $tgt, which isn't there. Nothing was changed."
}

# Bytes free on the volume holding $1, and a refusal when a download would not fit.
need_space() {
  local dir="$1" bytes="$2" what="$3" free
  free=$(( $(df -k "$dir" | awk 'NR==2 {print $4}') * 1024 ))
  (( free >= bytes )) || die "$what needs about $(( (bytes + 999999999) / 1000000000 )) GB free; there are $(( free / 1000000000 )) GB. Free some space, then try again."
}

# Unzips $1 into the empty folder $2. ditto says nothing while it works, and the base zip unpacks
# 15.5 GB (minutes, longer on a spinning drive), so every 2 s this says how much of the unpacked
# size is there ("==> unpacking 42%"): the launcher's button reads it (Daniel, 2026-10-15: "it's
# been stuck on setting up 0%"). The size is the zip's own listing (zipinfo), or about 1.65x the
# zip when that can't be read.
unpack() {
  local zip="$1" dest="$2" total kb pct last=-1 pid rc=0
  total=$(/usr/bin/zipinfo -t "$zip" 2>/dev/null | /usr/bin/awk '$5 == "uncompressed," { print $3 }')
  [[ "$total" == <-> ]] && (( total > 0 )) || total=$(( $(stat -f %z "$zip") * 165 / 100 + 1 ))
  ditto -x -k "$zip" "$dest" &
  pid=$!
  while kill -0 $pid 2>/dev/null; do
    kb=$(/usr/bin/du -skA "$dest" 2>/dev/null | /usr/bin/awk '{ print $1 }')
    pct=$(( ${kb:-0} * 1024 * 100 / total ))
    (( pct > 99 )) && pct=99
    (( pct > last )) && { say "unpacking $pct%"; last=$pct; }
    sleep 2
  done
  wait $pid || rc=$?
  (( rc == 0 )) && say "unpacking 100%"
  return $rc
}

# Puts everything under $1 at the same place under $2, replacing what $2 already has file by file,
# as unzipping over it would. A rename where both are on one drive: the whole client lands in
# place at once, with no second copy (flattening their HorizonXI/ root by copying it used to need
# another 15.5 GB beside the first). Through a link onto another drive (SquareEnix -> /Volumes/…)
# it is a copy, file by file, as before.
zmodload -F zsh/files b:zf_mv 2>/dev/null || true
merge_into() {
  local e t
  for e in "$1"/*(DN); do
    t="$2/${e:t}"
    if [[ -d "$e" && ! -L "$e" && -d "$t" ]]; then
      merge_into "$e" "$t" || return 1
    else
      if [[ -d "$t" && ! -L "$t" ]]; then rm -rf "$t" || return 1; fi
      zf_mv -f "$e" "$t" 2>/dev/null || mv -f "$e" "$t" || return 1
    fi
  done
}

# What a complete base client has: without these, version.json alone means nothing.
base_complete() {
  [[ -f "$ffxi/FFXiMain.dll" && -f "$game/SquareEnix/PlayOnlineViewer/viewer/com/polcore.dll" ]] \
    && [[ -f "$game/Ashita-cli.exe" || -f "$game/injector.exe" ]]
}

tmpd=$(mktemp -d "${TMPDIR:-/tmp}/ffxi-update.XXXXXX")
# A Stop during an unzip leaves its half-unpacked folder (up to 15 GB): ours, and never complete.
tmpx=""
trap 'rm -rf "$tmpd"; [[ -n "$tmpx" ]] && rm -rf "$tmpx"' EXIT

case "${1:-}" in
  check)
    inst=$(installed_client); hm=$(horizon_marketing)
    latest=""
    if fetch_json "$API/install-game" "$tmpd/install.json" 2>/dev/null; then
      latest=$(jsq "$tmpd/install.json" 'd.updateData && d.updateData.length ? d.updateData[d.updateData.length-1].marketingVersion : d.installData.baseGameMarketingVersion')
    fi
    print "installed=${inst:-unknown} horizon=${hm:-unknown} latest=${latest:-unknown}"
    ;;

  tools)
    ensure_aria2
    print -r -- "aria2c=$ARIA2C"
    ;;

  install)
    # Fresh client: their base torrent (HorizonXI.zip, ~9.4 GB) into the folder, then fall
    # through to the update path. Same magnet their launcher uses. A client that already has
    # version.json but lost Ashita or the base files gets the base again (b60, G10): before,
    # version.json alone sent it to the update path, which said "already up to date".
    drive_check
    if [[ -f "$game/version.json" ]] && base_complete; then
      say "already has a client (version.json) — updating instead"; rm -rf "$tmpd"; exec "$0" horizon "$game"
    fi
    ensure_aria2
    fetch_json "$API/install-game" "$tmpd/install.json" \
      || die "Couldn't reach api.horizonxi.com. Check the internet connection, then press Setup again."
    read -r magnet base mv <<< "$(jsq "$tmpd/install.json" '[d.installData.baseGameMagnetLink, d.installData.baseZipName, d.installData.baseGameMarketingVersion].join(" ")')"
    [[ -n "$magnet" && -n "$base" && -n "$mv" ]] || die "could not read the install manifest from api.horizonxi.com"
    xl=$(print -r -- "$magnet" | grep -oE '[?&]xl=[0-9]+' | head -1 | cut -d= -f2 || true)
    dl="$game/updates"; mkdir -p "$dl"
    if [[ ! -f "$dl/$base" || -f "$dl/$base.aria2" ]]; then
      if [[ -n "$xl" ]]; then
        have=0; [[ -f "$dl/$base" ]] && have=$(stat -f %z "$dl/$base")
        # The zip still to come, plus the unpacked client (~16 GB).
        need_space "$dl" $(( xl - have + 16000000000 )) "HorizonXI"
      fi
      say "fetching $base ($mv) by torrent into $dl — this is ~9.4 GB"
      "$ARIA2C" --dir="$dl" --seed-time=0 --bt-stop-timeout=1800 --summary-interval=2 \
             --console-log-level=warn --enable-dht=true --allow-overwrite=true "$magnet" \
        || die "The HorizonXI download stalled or failed — press Setup again to resume."
      [[ -f "$dl/$base" && ! -f "$dl/$base.aria2" ]] || die "aria2 finished but $base is not complete in $dl"
    fi
    say "extracting $base"
    # Unpacked beside the game folder (the same drive: $dl is inside it), then moved into place.
    # ditto will not write through a symlinked SquareEnix, and their zip is rooted at HorizonXI/.
    tmpx="$dl/.base-extract"; rm -rf "$tmpx"; mkdir -p "$tmpx"
    unpack "$dl/$base" "$tmpx" || { rm -rf "$tmpx"; die "Couldn't unpack $base."; }
    src="$tmpx"; [[ -d "$tmpx/HorizonXI" ]] && src="$tmpx/HorizonXI"
    merge_into "$src" "$game" || { rm -rf "$tmpx"; die "Couldn't put the unpacked files in $game."; }
    rm -rf "$tmpx"
    # The base's own version, so every update after it is applied again (an older version.json
    # over freshly unpacked base files would skip them).
    printf '{\n  "version": "%s"\n}\n' "$mv" > "$game/version.json"
    base_complete || die "$base unpacked, but the game files are still incomplete."
    # 9.4 GB that is no longer needed once unpacked.
    rm -f "$dl/$base" "$dl/$base.aria2"
    say "base client in place — applying updates"
    rm -rf "$tmpd"
    exec "$0" horizon "$game"
    ;;

  horizon)
    drive_check
    hm=$(horizon_marketing); [[ -n "$hm" ]] || die "no version.json in $game — is this a HorizonXI install?"
    ensure_aria2
    say "installed HorizonXI $hm, asking api.horizonxi.com what is newer"
    fetch_json "$API/update-game?ver=$hm" "$tmpd/updates.json" \
      || die "Couldn't reach api.horizonxi.com. Check the internet connection, then try again."
    # ver= takes the *marketing* version; the API answers with everything after it.
    # The API stopped honouring ver= (2026-10: it returns every update since 1.1.1), so filter
    # here too -- applying an old zip over a newer client would roll its files back.
    plan=$(jsq "$tmpd/updates.json" '(function () {
        function v(s) { return String(s).split(".").map(function (x) { return /^[0-9]+$/.test(x) ? +x : 0; }); }
        function gt(p, q) { for (var k = 0; k < Math.max(p.length, q.length); k++) { var x = p[k] || 0, y = q[k] || 0; if (x != y) return x > y; } return false; }
        var have = v(a[0]), seen = {}, out = [];
        d.forEach(function (e) {
          if (!gt(v(e.marketingVersion), have) || seen[e.updateZipName]) return;
          seen[e.updateZipName] = 1;
          out.push([String(e.version), e.marketingVersion, e.updateZipName, e.updateMagnetLink, (e.deleteFiles || []).join("|")].join("\t"));
        });
        return out.join("\n");
      })()' "$hm")
    [[ -n "$plan" ]] || { say "already up to date"; exit 0; }
    dl="$game/updates"; mkdir -p "$dl"
    # Files this project puts in place (Metal renderer shims, x87 loader) that an update zip
    # may clobber. Saved and put back; Repair does the same thing more thoroughly.
    keep=(d3d8.dll d3d9.dll dxvk.conf dgVoodoo.conf)
    total=$(print -r -- "$plan" | wc -l | tr -d ' '); n=0
    print -r -- "$plan" | while IFS=$'\t' read -r ver mv zip magnet dels; do
      n=$((n+1))
      say "update $mv ($n/$total)"
      # A Stop leaves the full-size file plus its .aria2 control file: that is a resume, not a
      # finished download.
      if [[ ! -f "$dl/$zip" || -f "$dl/$zip.aria2" ]]; then
        "$ARIA2C" --dir="$dl" --seed-time=0 --bt-stop-timeout=600 --summary-interval=2 \
               --console-log-level=warn --enable-dht=true --allow-overwrite=true "$magnet" \
          || die "The download of HorizonXI $mv stalled or failed (nobody may be sharing it right now) — try again later."
        [[ -f "$dl/$zip" && ! -f "$dl/$zip.aria2" ]] || die "aria2 finished but $zip is not complete in $dl"
      fi
      tmpk=$(mktemp -d)
      for f in $keep; do
        [[ -f "$game/$f" ]] && cp "$game/$f" "$tmpk/game.$f"
        [[ -f "$ffxi/$f" ]] && cp "$ffxi/$f" "$tmpk/ffxi.$f"
      done
      say "extracting $zip"
      # Unpack beside the game folder (the same drive, not the Mac's own disk), then move into
      # place file by file: SquareEnix in the game dir is often a symlink to shared data, and
      # ditto/cp/openrsync all refuse to write through a symlinked directory.
      tmpx="$dl/.update-extract"; rm -rf "$tmpx"; mkdir -p "$tmpx"
      unpack "$dl/$zip" "$tmpx" || { rm -rf "$tmpx"; die "unzip of $zip failed"; }
      src="$tmpx"
      # Their zips are rooted at HorizonXI/ sometimes; flatten if so.
      [[ -d "$tmpx/HorizonXI" && -f "$tmpx/HorizonXI/version.json" ]] && src="$tmpx/HorizonXI"
      merge_into "$src" "$game" || { rm -rf "$tmpx"; die "could not write the files of $zip"; }
      rm -rf "$tmpx"
      if [[ -n "$dels" ]]; then
        for d in ${(s:|:)dels}; do rm -rf "$game/$d"; done
      fi
      for f in $keep; do
        [[ -f "$tmpk/game.$f" ]] && cp "$tmpk/game.$f" "$game/$f"
        [[ -f "$tmpk/ffxi.$f" ]] && cp "$tmpk/ffxi.$f" "$ffxi/$f"
      done
      rm -rf "$tmpk"
      printf '{\n  "version": "%s"\n}\n' "$mv" > "$game/version.json"
      say "now at $mv"
    done
    say "done — client is at $(installed_client)"
    ;;
  *) die "usage: $0 {check|horizon|install|tools} <drive_c/HorizonXI>" ;;
esac
