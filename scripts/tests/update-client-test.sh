#!/bin/zsh
set -euo pipefail

REPO="${0:A:h:h:h}"
ROOT=$(mktemp -d /tmp/update-client-test.XXXXXX)
trap 'rm -rf "$ROOT"' EXIT

fail() { print -r -- "FAIL: $*" >&2; exit 1; }
assert_contains() { grep -Fq -- "$2" "$1" || fail "$1 does not contain: $2"; }

MOCK_BIN="$ROOT/bin"
mkdir -p "$MOCK_BIN"

cat > "$MOCK_BIN/curl" <<'EOF'
#!/bin/zsh
if [[ "$argv[-1]" == *update-game* ]]; then
  print '[]'
else
  print '{"installData":{"baseGameMagnetLink":"magnet:?xt=urn:btih:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa&dn=HorizonXI.zip","baseZipName":"HorizonXI.zip","baseGameMarketingVersion":"2.0.2"}}'
fi
EOF

cat > "$MOCK_BIN/ditto" <<'EOF'
#!/bin/zsh
if [[ "$argv[-1]" == */game ]]; then
  print '{"version":"2.0.2"}' > "$argv[-1]/version.json"
fi
exit 0
EOF

cat > "$MOCK_BIN/aria2c" <<'EOF'
#!/bin/zsh
set -eu
count_file="$MOCK_STATE/count"
count=0
[[ -f "$count_file" ]] && count=$(<"$count_file")
(( ++count ))
print -r -- "$count" > "$count_file"
print -r -- "CALL $count $*" >> "$MOCK_STATE/calls"

dir=""
for arg in "$@"; do
  [[ "$arg" == --dir=* ]] && dir="${arg#--dir=}"
done

if [[ "$*" == *--show-files* ]]; then
  [[ "$MOCK_MODE" == invalid-cache ]] && exit 7
  exit 0
fi

if [[ "$*" == *--bt-metadata-only=true* ]]; then
  [[ "$MOCK_MODE" == fail ]] && exit 7
  [[ "$MOCK_MODE" == retry && "$count" == 1 ]] && exit 7
  print torrent > "$dir/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.torrent"
  exit 0
fi

print archive > "$dir/HorizonXI.zip"
EOF

chmod +x "$MOCK_BIN/curl" "$MOCK_BIN/ditto" "$MOCK_BIN/aria2c"

run_install() {
  local name="$1" mode="$2"
  local game="$ROOT/$name/game" state="$ROOT/$name/state"
  mkdir -p "$game" "$state"
  if ! MOCK_STATE="$state" MOCK_MODE="$mode" PATH="$MOCK_BIN:/usr/bin:/bin" \
       "$REPO/scripts/update-client.sh" install "$game" > "$state/output" 2>&1; then
    sed -n '1,200p' "$state/output" >&2
    find "$game" -maxdepth 2 -ls >&2
    fail "$name install failed"
  fi
  print -r -- "$state"
}

state=$(run_install retry retry)
[[ "$(<"$state/count")" == 3 ]] || fail "retry scenario did not make two metadata attempts and one download"
assert_contains "$state/output" "finding peers for HorizonXI.zip (attempt 1/3, up to 60s)"
assert_contains "$state/output" "no metadata received; refreshing peer data and trying again"
assert_contains "$state/output" "finding peers for HorizonXI.zip (attempt 2/3, up to 60s)"
assert_contains "$state/calls" "--stop=60"
assert_contains "$state/calls" "--bt-stop-timeout=1800"
assert_contains "$state/calls" "$ROOT/retry/game/updates/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.torrent"

cached_game="$ROOT/cached/game"
cached_state="$ROOT/cached/state"
mkdir -p "$cached_game/updates" "$cached_state"
print torrent > "$cached_game/updates/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.torrent"
MOCK_STATE="$cached_state" MOCK_MODE=cached PATH="$MOCK_BIN:/usr/bin:/bin" \
  "$REPO/scripts/update-client.sh" install "$cached_game" > "$cached_state/output" 2>&1
[[ "$(<"$cached_state/count")" == 2 ]] || fail "cached scenario did not validate metadata and start one download"
assert_contains "$cached_state/output" "using saved torrent metadata for HorizonXI.zip"
if grep -Fq -- '--bt-metadata-only=true' "$cached_state/calls"; then
  fail "cached scenario repeated metadata discovery"
fi

invalid_game="$ROOT/invalid/game"
invalid_state="$ROOT/invalid/state"
mkdir -p "$invalid_game/updates" "$invalid_state"
print broken > "$invalid_game/updates/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.torrent"
MOCK_STATE="$invalid_state" MOCK_MODE=invalid-cache PATH="$MOCK_BIN:/usr/bin:/bin" \
  "$REPO/scripts/update-client.sh" install "$invalid_game" > "$invalid_state/output" 2>&1
[[ "$(<"$invalid_state/count")" == 3 ]] || fail "invalid cache was not replaced before downloading"
assert_contains "$invalid_state/output" "discarding invalid saved torrent metadata for HorizonXI.zip"
assert_contains "$invalid_state/calls" "--bt-metadata-only=true"

failed_game="$ROOT/failed/game"
failed_state="$ROOT/failed/state"
mkdir -p "$failed_game" "$failed_state"
if MOCK_STATE="$failed_state" MOCK_MODE=fail PATH="$MOCK_BIN:/usr/bin:/bin" \
     "$REPO/scripts/update-client.sh" install "$failed_game" > "$failed_state/output" 2>&1; then
  fail "metadata failure unexpectedly succeeded"
fi
[[ "$(<"$failed_state/count")" == 3 ]] || fail "metadata failure did not stop after three attempts"
assert_contains "$failed_state/output" "no peer supplied metadata for HorizonXI.zip after 3 attempts; try again later"

print "PASS: update-client torrent metadata retry tests"
