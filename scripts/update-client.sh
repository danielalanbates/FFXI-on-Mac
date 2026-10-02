#!/bin/zsh
# update-client.sh — bring the game files in a prefix up to date, the way each server's own
# launcher would, so the login server stops answering "The game's data has been updated".
#
#   update-client.sh check  <drive_c/HorizonXI dir>            -> prints "installed=<ver> horizon=<marketing> latest=<marketing>"
#   update-client.sh horizon <drive_c/HorizonXI dir>           -> applies every pending HorizonXI update
#
# What each server actually does (checked 2026-08-15, see docs/CLIENT-UPDATES.md):
#
#   * HorizonXI: `api.horizonxi.com/api/v1/launcher/update-game?ver=<n>` lists numbered update
#     zips, each delivered as a BitTorrent magnet (their Electron launcher uses webtorrent).
#     This script fetches them with aria2c (brew), unzips over the game dir, deletes the
#     `deleteFiles` list, and writes the new marketing version to version.json — the same steps
#     their launcher performs. Torrents mean it can be slow or stall when nobody is seeding.
#
#   * CatsEyeXI: their launcher syncs the client from a private Cloudflare R2 bucket using
#     credentials baked into the .exe. There is no public manifest, so this script cannot
#     update a CatsEye client. It can only tell you the version is wrong (see `check`) and the
#     required version comes from their public server settings.
#
# Every step is idempotent: re-running after a stall resumes the aria2 download. Torrent
# metadata is cached separately so a retry does not have to find the same peer again.
set -euo pipefail

say() { print -r -- "==> $*"; }
die() { print -r -- "!! $*" >&2; exit 1; }

API="https://api.horizonxi.com/api/v1/launcher"
UA="FFXI-on-Mac launcher"
typeset -r TORRENT_METADATA_ATTEMPTS=3
typeset -r TORRENT_METADATA_TIMEOUT=60

game="${2:-}"
[[ "${1:-}" == install && -n "$game" ]] && mkdir -p "$game"
[[ -n "$game" && -d "$game" ]] || die "usage: $0 {check|horizon|install} <game dir>"
ffxi="$game/SquareEnix/FINAL FANTASY XI"

# The retail patch level the client is at. patch.cfg is the client's own record of applied
# patch groups; the newest one listed is what the login server sees at offset 0x74 of packet 0x26.
installed_client() {
  [[ -f "$ffxi/patch.cfg" ]] || { print ""; return; }
  grep -oE '\b30[0-9]{6}_[0-9]\b' "$ffxi/patch.cfg" | sort -u | tail -1
}

horizon_marketing() {
  [[ -f "$game/version.json" ]] || { print ""; return; }
  python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("version",""))' "$game/version.json" 2>/dev/null || print ""
}

fetch_json() { curl -fsSL -A "$UA" --max-time 20 "$1"; }

# aria2 cannot create the destination file until it has fetched the torrent metadata. Keep that
# peer-discovery step short and retry it in a fresh process: aria2 repairs a bad DHT routing file
# when it exits, so the next attempt reloads the repaired copy instead of sitting silent for 30
# minutes. Once metadata is available, download from the saved .torrent so the large transfer
# never has to repeat the fragile magnet handshake.
download_torrent() {
  local magnet="$1" archive="$2" dl="$3" stall_timeout="$4" summary_interval="$5"
  local info_hash="${magnet#*xt=urn:btih:}"
  info_hash="${info_hash%%&*}"
  [[ "$info_hash" =~ '^[[:xdigit:]]{40}$' ]] \
    || die "HorizonXI returned an invalid torrent link for $archive"

  local torrent="$dl/${info_hash:l}.torrent"
  local have_metadata=false

  if [[ -s "$torrent" ]]; then
    if aria2c --show-files "$torrent" >/dev/null 2>&1; then
      say "using saved torrent metadata for $archive"
      have_metadata=true
    else
      say "discarding invalid saved torrent metadata for $archive"
      rm -f "$torrent"
    fi
  elif [[ -e "$torrent" ]]; then
    rm -f "$torrent"
  fi

  if [[ "$have_metadata" != true ]]; then
    local attempt
    for (( attempt = 1; attempt <= TORRENT_METADATA_ATTEMPTS; attempt++ )); do
      say "finding peers for $archive (attempt $attempt/$TORRENT_METADATA_ATTEMPTS, up to ${TORRENT_METADATA_TIMEOUT}s)"
      if aria2c --dir="$dl" --seed-time=0 --bt-metadata-only=true --bt-save-metadata=true \
           --stop="$TORRENT_METADATA_TIMEOUT" --bt-stop-timeout="$TORRENT_METADATA_TIMEOUT" \
           --summary-interval=10 --console-log-level=warn --enable-dht=true "$magnet" \
           && [[ -s "$torrent" ]]; then
        have_metadata=true
        break
      fi
      if (( attempt < TORRENT_METADATA_ATTEMPTS )); then
        say "no metadata received; refreshing peer data and trying again"
      fi
    done
  fi

  [[ "$have_metadata" == true ]] \
    || die "no peer supplied metadata for $archive after $TORRENT_METADATA_ATTEMPTS attempts; try again later"

  say "metadata ready; downloading $archive"
  aria2c --dir="$dl" --seed-time=0 --bt-stop-timeout="$stall_timeout" \
         --summary-interval="$summary_interval" --console-log-level=warn --enable-dht=true \
         --allow-overwrite=true "$torrent" \
    || die "torrent download of $archive failed or stalled; run again to resume"
  [[ -f "$dl/$archive" ]] || die "aria2 finished but $archive is not in $dl"
}

case "${1:-}" in
  check)
    inst=$(installed_client); hm=$(horizon_marketing)
    latest=$(fetch_json "$API/install-game" 2>/dev/null \
      | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["updateData"][-1]["marketingVersion"] if d.get("updateData") else d["installData"]["baseGameMarketingVersion"])' 2>/dev/null || print "")
    print "installed=${inst:-unknown} horizon=${hm:-unknown} latest=${latest:-unknown}"
    ;;

  install)
    # Fresh client: their base torrent (HorizonXI.zip, ~9.4 GB) into an empty folder, then fall
    # through to the update path. Same magnet their launcher uses.
    command -v aria2c >/dev/null || die "aria2c is not installed (brew install aria2). HorizonXI ships its client as a torrent; nothing else can fetch it."
    [[ -f "$game/version.json" ]] && { say "already has a client (version.json) — updating instead"; exec "$0" horizon "$game"; }
    read -r magnet base mv <<< "$(fetch_json "$API/install-game" | python3 -c '
import json,sys; d=json.load(sys.stdin)["installData"]; print(d["baseGameMagnetLink"], d["baseZipName"], d["baseGameMarketingVersion"])')"
    [[ -n "$magnet" ]] || die "could not read the install manifest from api.horizonxi.com"
    dl="$game/updates"; mkdir -p "$dl"
    say "fetching $base ($mv) by torrent into $dl — this is ~9.4 GB"
    download_torrent "$magnet" "$base" "$dl" 1800 60
    say "extracting $base"
    ditto -x -k "$dl/$base" "$game" || die "unzip failed"
    if [[ -d "$game/HorizonXI" && ! -f "$game/version.json" ]]; then ditto "$game/HorizonXI" "$game" && rm -rf "$game/HorizonXI"; fi
    [[ -f "$game/version.json" ]] || print -r -- "{\n  \"version\": \"$mv\"\n}" > "$game/version.json"
    say "base client in place — applying updates"
    exec "$0" horizon "$game"
    ;;

  horizon)
    command -v aria2c >/dev/null || die "aria2c is not installed (brew install aria2). HorizonXI ships updates as torrents; nothing else can fetch them."
    hm=$(horizon_marketing); [[ -n "$hm" ]] || die "no version.json in $game — is this a HorizonXI install?"
    say "installed HorizonXI $hm, asking api.horizonxi.com what is newer"
    # ver= takes the *marketing* version; the API answers with everything after it.
    plan=$(fetch_json "$API/update-game?ver=$hm" | python3 -c '
import json,sys
seen=set()
for e in json.load(sys.stdin):
    if e["updateZipName"] in seen: continue
    seen.add(e["updateZipName"])
    print("\t".join([str(e["version"]), e["marketingVersion"], e["updateZipName"], e["updateMagnetLink"], "|".join(e.get("deleteFiles",[]))]))')
    [[ -n "$plan" ]] || { say "already up to date"; exit 0; }
    dl="$game/updates"; mkdir -p "$dl"
    # Files this project puts in place (Metal renderer shims, x87 loader) that an update zip
    # may clobber. Saved and put back; Repair does the same thing more thoroughly.
    keep=(d3d8.dll d3d9.dll dxvk.conf dgVoodoo.conf)
    print -r -- "$plan" | while IFS=$'\t' read -r ver mv zip magnet dels; do
      say "update $mv ($zip)"
      if [[ ! -f "$dl/$zip" ]]; then
        download_torrent "$magnet" "$zip" "$dl" 600 30
      fi
      tmpk=$(mktemp -d)
      for f in $keep; do
        [[ -f "$game/$f" ]] && cp "$game/$f" "$tmpk/game.$f"
        [[ -f "$ffxi/$f" ]] && cp "$ffxi/$f" "$tmpk/ffxi.$f"
      done
      say "extracting $zip"
      ditto -x -k "$dl/$zip" "$game" || die "unzip of $zip failed"
      # Their zips are rooted at HorizonXI/ sometimes; flatten if so.
      if [[ -d "$game/HorizonXI" && -f "$game/HorizonXI/version.json" ]]; then
        ditto "$game/HorizonXI" "$game" && rm -rf "$game/HorizonXI"
      fi
      if [[ -n "$dels" ]]; then
        for d in ${(s:|:)dels}; do rm -rf "$game/$d"; done
      fi
      for f in $keep; do
        [[ -f "$tmpk/game.$f" ]] && cp "$tmpk/game.$f" "$game/$f"
        [[ -f "$tmpk/ffxi.$f" ]] && cp "$tmpk/ffxi.$f" "$ffxi/$f"
      done
      rm -rf "$tmpk"
      print -r -- "{\n  \"version\": \"$mv\"\n}" > "$game/version.json"
      say "now at $mv"
    done
    say "done — client is at $(installed_client)"
    ;;
  *) die "usage: $0 {check|horizon} <drive_c/HorizonXI>" ;;
esac
