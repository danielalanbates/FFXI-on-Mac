#!/bin/zsh
# Exercise the scripts behind the main button's Setup and Repair (install.sh, update-client.sh,
# fix-wine-rpath.sh) on a tiny fixture tree: a fake wrapper whose wine, wineserver, curl and aria2c
# are stubs that only log, and a few-KB "HorizonXI" zip. No real wine runs, nothing is
# downloaded (the one aria2 fetch case reads a local copy through file://), and nothing outside the
# fixture folder is touched.
#
#   [HXI_LAUNCHER_BIN=<built HorizonXILauncher>] ./scripts/tests/setup-scripts-test.sh [aria2-1.35.0-osx-darwin.tar.bz2]
#
# The fixture lives in $FIXTURE (default ~/Downloads/FFXI-on-Mac-build/fixture/setup-scripts) and
# is rebuilt on every run. With the aria2 archive given, the pinned-fetch case runs too (it checks
# the archive against the size and SHA-256 update-client.sh pins, then runs the real aria2c
# --version under Rosetta). With HXI_LAUNCHER_BIN, the launcher's --next-action and --fix run
# against the fixture prefix too (the stub stands in for the patched game Wine).
set -uo pipefail
REPO="${0:A:h:h:h}"
INSTALL="$REPO/scripts/install.sh"
UPDATE="$REPO/scripts/update-client.sh"
RPATH="$REPO/scripts/fix-wine-rpath.sh"
ARIA2_TARBALL="${1:-}"
F="${FIXTURE:-$HOME/Downloads/FFXI-on-Mac-build/fixture/setup-scripts}"
[[ "$F" == */fixture/* ]] || { print -u2 "refusing: FIXTURE must be a .../fixture/... folder"; exit 2; }
/bin/chmod -R u+w "$F" 2>/dev/null; /bin/rm -rf "$F"; mkdir -p "$F"

fails=0
check() { if eval "$2"; then print -r -- "  ok   $1"; else print -r -- "  FAIL $1"; fails=$((fails + 1)); fi }

# ---- stubs ---------------------------------------------------------------------------------------
stubs="$F/stubs"; mkdir -p "$stubs"
LOG="$F/calls.log"
# wine: logs every call; `regsvr32 /s <path>` fails with the code given for that DLL in
# STUB_REGSVR32_FAIL ("FFXiMain.dll:3 polcore.dll:5").
cat > "$stubs/wine" <<'EOF'
#!/bin/zsh
print -r -- "wine $*" >> "$STUB_LOG"
if [[ "${1:-}" == regsvr32 ]]; then
  dll="${3##*\\}"
  for spec in ${=STUB_REGSVR32_FAIL:-}; do
    [[ "${spec%%:*}" == "$dll" ]] && exit "${spec##*:}"
  done
fi
exit 0
EOF
cat > "$stubs/wineserver" <<'EOF'
#!/bin/zsh
print -r -- "wineserver $*" >> "$STUB_LOG"
[[ "${1:-}" == --version ]] && print "Wine 10.0 (stub)"
exit 0
EOF
# curl: the HorizonXI API from fixture files, file:// through the real curl, anything else fails
# like being offline.
cat > "$stubs/curl" <<'EOF'
#!/bin/zsh
print -r -- "curl $*" >> "$STUB_LOG"
out="" url=""
while (( $# )); do
  case "$1" in -o) out="$2"; shift ;; -A) shift ;; --max-time) shift ;; -*) ;; *) url="$1" ;; esac
  shift
done
[[ -n "${STUB_OFFLINE:-}" ]] && exit 6
case "$url" in
  file://*) exec /usr/bin/curl -fsSL -o "$out" "$url" ;;
  */install-game) cp "$STUB_API/install-game.json" "$out" ;;
  */update-game*) cp "$STUB_API/update-game.json" "$out" ;;
  *) exit 6 ;;
esac
EOF
# aria2c: "downloads" the zip a magnet names (dn=) from the fixture's seed folder.
cat > "$stubs/aria2c" <<'EOF'
#!/bin/zsh
print -r -- "aria2c $*" >> "$STUB_LOG"
[[ -n "${STUB_ARIA2_FAIL:-}" ]] && exit 7
dir="" magnet=""
for a in "$@"; do
  case "$a" in --dir=*) dir="${a#--dir=}" ;; magnet:*) magnet="$a" ;; esac
done
name="${${magnet#*dn=}%%&*}"
cp "$STUB_SEED/$name" "$dir/$name" && rm -f "$dir/$name.aria2"
EOF
# python3 must never be needed (a stock Mac has only a stub that pops an installer).
cat > "$stubs/python3" <<'EOF'
#!/bin/zsh
print -r -- "python3 $*" >> "$STUB_LOG"
exit 99
EOF
chmod +x "$stubs"/*
export STUB_LOG="$LOG" STUB_API="$F/api" STUB_SEED="$F/seed"
# Like a launched app: no Homebrew on PATH, stubs first.
SAFE_PATH="$stubs:/usr/bin:/bin:/usr/sbin:/sbin"
run() { env -i HOME="$HOME" TMPDIR="${TMPDIR:-/tmp}" PATH="${RUN_PATH:-$SAFE_PATH}" STUB_LOG="$STUB_LOG" STUB_API="$STUB_API" \
          STUB_SEED="$STUB_SEED" STUB_REGSVR32_FAIL="${STUB_REGSVR32_FAIL:-}" STUB_OFFLINE="${STUB_OFFLINE:-}" \
          STUB_ARIA2_FAIL="${STUB_ARIA2_FAIL:-}" HXI_WINE="${HXI_WINE:-}" HXI_ARIA2C="${HXI_ARIA2C:-}" \
          HXI_TOOLS="${HXI_TOOLS:-$F/tools}" HXI_ARIA2_URL="${HXI_ARIA2_URL:-}" "$@"; }

# ---- fixture game files --------------------------------------------------------------------------
# A client tree as HorizonXI's zips lay it out (rooted at HorizonXI/).
make_client() {   # <dir> <version>
  local d="$1"
  mkdir -p "$d/SquareEnix/FINAL FANTASY XI" "$d/SquareEnix/PlayOnlineViewer/viewer/com" "$d/config/boot" "$d/bootloader"
  for f in FFXi.dll FFXiMain.dll FFXiVersions.dll; do print -r -- "$f" > "$d/SquareEnix/FINAL FANTASY XI/$f"; done
  print -r -- polcore > "$d/SquareEnix/PlayOnlineViewer/viewer/com/polcore.dll"
  print -r -- ashita > "$d/Ashita-cli.exe"
  print -r -- "command = --server example.invalid --user fixture --pass fixture" > "$d/config/boot/horizonxi.ini"
  printf '{\n  "version": "%s"\n}\n' "$2" > "$d/version.json"
}
seed="$F/seed"; mkdir -p "$seed" "$F/api"
( b="$F/build/base/HorizonXI"; mkdir -p "$b"; make_client "$b" 2.0.2
  cd "$F/build/base" && /usr/bin/zip -qr "$seed/HorizonXI.zip" HorizonXI )
( u="$F/build/u3/HorizonXI"; mkdir -p "$u/addons/new"; print v3 > "$u/addons/new/new.lua"; printf '{\n  "version": "2.0.3"\n}\n' > "$u/version.json"
  print stale > "$u/stale-from-2.0.3.txt"
  cd "$F/build/u3" && /usr/bin/zip -qr "$seed/HorizonXI-2_0_3.zip" HorizonXI )
( u="$F/build/u4"; mkdir -p "$u"; print v4 > "$u/patched-2.0.4.txt"
  cd "$u" && /usr/bin/zip -qr "$seed/HorizonXI-2_0_4.zip" . )
cat > "$F/api/install-game.json" <<'EOF'
{"latestVersion":23,"installData":{"baseGameVersion":21,"baseGameMarketingVersion":"2.0.2","baseGameMagnetLink":"magnet:?xt=urn:btih:aaaa&dn=HorizonXI.zip&xl=4096","baseZipName":"HorizonXI.zip"},"updateData":[{"marketingVersion":"2.0.4"}]}
EOF
cat > "$F/api/update-game.json" <<'EOF'
[{"deleteFiles":[],"updateZipName":"HorizonXI-1_1_1.zip","updateMagnetLink":"magnet:?xt=urn:btih:0000&dn=HorizonXI-1_1_1.zip","version":5,"marketingVersion":"1.1.1"},
 {"deleteFiles":[],"updateZipName":"HorizonXI-2_0_3.zip","updateMagnetLink":"magnet:?xt=urn:btih:3333&dn=HorizonXI-2_0_3.zip","version":22,"marketingVersion":"2.0.3"},
 {"deleteFiles":["stale-from-2.0.3.txt"],"updateZipName":"HorizonXI-2_0_4.zip","updateMagnetLink":"magnet:?xt=urn:btih:4444&dn=HorizonXI-2_0_4.zip","version":23,"marketingVersion":"2.0.4"}]
EOF

# A wrapper: Frameworks with a dylib, stub wine, a prefix with drive_c/HorizonXI.
APP="$F/Wrapper/Fake.app"
make_wrapper() {
  /bin/chmod -R u+w "$F/Wrapper" 2>/dev/null; rm -rf "$F/Wrapper"
  mkdir -p "$APP/Contents/Frameworks" "$APP/Contents/SharedSupport/wine/bin" "$APP/Contents/SharedSupport/prefix10/drive_c/HorizonXI"
  print dylib > "$APP/Contents/Frameworks/libinotify.0.dylib"
  cp "$stubs/wine" "$stubs/wineserver" "$APP/Contents/SharedSupport/wine/bin/"
}
GAME="$APP/Contents/SharedSupport/prefix10/drive_c/HorizonXI"
MARKER="$APP/Contents/SharedSupport/prefix10/.ffxi-on-mac-registry-target"
GONE="NoSuchDrive-$$"
wines() { local n; n=$(grep -c '^wine ' "$LOG" 2>/dev/null); print -r -- "${n:-0}"; }

print "install.sh (Repair)"
print "1. data behind a drive that is not there: refused, nothing written"
make_wrapper; : > "$LOG"
ln -s "/Volumes/$GONE/FFXI/SquareEnix" "$GAME/SquareEnix"
out=$(run /bin/zsh "$INSTALL" "$APP" prefix10 2>&1); rc=$?
check "exit 4" "(( rc == 4 ))"
check "names the drive, says Setup, never restart" "[[ \"\$out\" == *\"!! The '$GONE' drive isn't connected — reconnect it or press Setup. Nothing was changed.\"* && \"\${out:l}\" != *restart* ]]"
check "no wine ran" "(( \$(wines) == 0 ))"
check "no registry marker" "[[ ! -e '$MARKER' ]]"

print "2. DLLs missing on a present drive: refused, named"
make_wrapper; : > "$LOG"
make_client "$GAME" 2.0.4; rm "$GAME/SquareEnix/FINAL FANTASY XI/FFXiMain.dll"
out=$(run /bin/zsh "$INSTALL" "$APP" prefix10 2>&1); rc=$?
check "exit 4" "(( rc == 4 ))"
check "names FFXiMain.dll" "[[ \"\$out\" == *'Game files missing (FFXiMain.dll)'* ]]"
check "no wine ran" "(( \$(wines) == 0 ))"

print "3. no SquareEnix at all, and no game folder at all"
make_wrapper; : > "$LOG"
out=$(run /bin/zsh "$INSTALL" "$APP" prefix10 2>&1); rc=$?
check "exit 4, files not there" "(( rc == 4 )) && [[ \"\$out\" == *\"aren't in\"* ]]"
rmdir "$GAME"
out=$(run /bin/zsh "$INSTALL" "$APP" prefix10 2>&1); rc=$?
check "exit 1, game not installed, press Setup" "(( rc == 1 )) && [[ \"\$out\" == *\"isn't installed yet\"*Setup* ]]"

print "4. a DLL that will not register: every DLL still tried, the failure named"
make_wrapper; : > "$LOG"; make_client "$GAME" 2.0.4
out=$(STUB_REGSVR32_FAIL="FFXiMain.dll:3" run /bin/zsh "$INSTALL" "$APP" prefix10 2>&1); rc=$?
check "exit 3" "(( rc == 3 ))"
check "names FFXiMain.dll and the code" "[[ \"\$out\" == *'FFXiMain.dll couldn'\\''t be loaded (regsvr32 3)'* ]]"
check "FFXiVersions.dll and polcore.dll were still tried" "grep -q 'regsvr32 /s .*FFXiVersions.dll' '$LOG' && grep -q 'regsvr32 /s .*polcore.dll' '$LOG'"
check "no registry marker after a failure" "[[ ! -e '$MARKER' ]]"

print "5. all good: registry, COM, marker, relative dylib links, the wine Play runs"
make_wrapper; : > "$LOG"; make_client "$GAME" 2.0.4
mkdir -p "$F/playwine"; cp "$stubs/wine" "$F/playwine/wine"
out=$(HXI_WINE="$F/playwine/wine" run /bin/zsh "$INSTALL" "$APP" prefix10 2>&1); rc=$?
check "exit 0" "(( rc == 0 ))"
check "registry names C:\\HorizonXI\\SquareEnix" "grep -qF 'reg add HKLM\\SOFTWARE\\PlayOnlineUS\\InstallFolder /v 0001 /d C:\\HorizonXI\\SquareEnix\\FINAL FANTASY XI /f' '$LOG'"
check "four DLLs registered" "(( \$(grep -c 'regsvr32 /s' '$LOG') == 4 ))"
check "marker names the folder" "[[ \"\$(cat '$MARKER')\" == 'C:\\HorizonXI\\SquareEnix' ]]"
check "dylib link is relative and resolves" "[[ \"\$(readlink '$APP/Contents/SharedSupport/wine/lib/libinotify.0.dylib')\" == ../../../Frameworks/libinotify.0.dylib && -e '$APP/Contents/SharedSupport/wine/lib/libinotify.0.dylib' ]]"
check "rpath verified with wineserver --version, not by booting a prefix" "grep -q '^wineserver --version' '$LOG' && ! grep -q 'cmd.exe' '$LOG'"
check "no ANSI colour codes in the output" "[[ \"\$out\" != *$'\\e['* ]]"
check "Play HorizonXI.command written" "[[ -x '$F/Wrapper/Play HorizonXI.command' ]]"

print "6. polcore.dll missing: a warning, as in the launcher's checks; Repair still finishes"
make_wrapper; : > "$LOG"; make_client "$GAME" 2.0.4; rm "$GAME/SquareEnix/PlayOnlineViewer/viewer/com/polcore.dll"
out=$(run /bin/zsh "$INSTALL" "$APP" prefix10 2>&1); rc=$?
check "exit 0" "(( rc == 0 ))"
check "one !! line about polcore.dll" "[[ \"\$out\" == *'!! polcore.dll is missing'* ]]"
check "three DLLs registered" "(( \$(grep -c 'regsvr32 /s' '$LOG') == 3 ))"

print "7. the wrapper's folder cannot be written: Play HorizonXI.command is skipped, Repair succeeds"
make_wrapper; : > "$LOG"; make_client "$GAME" 2.0.4
chmod 555 "$F/Wrapper"
out=$(run /bin/zsh "$INSTALL" "$APP" prefix10 2>&1); rc=$?
chmod 755 "$F/Wrapper"
check "exit 0" "(( rc == 0 ))"
check "says it skipped it" "[[ \"\$out\" == *'skipped'*'Play HorizonXI.command'* ]]"

print "8. a world's own folder (args 3-5, Z:\\ path)"
make_wrapper; : > "$LOG"
OWN="$F/Elsewhere/HorizonXI"; mkdir -p "$OWN"; make_client "$OWN" 2.0.4
ZSE="Z:${OWN//\//\\}\\SquareEnix"
out=$(run /bin/zsh "$INSTALL" "$APP" prefix10 "$OWN" "$ZSE" "$OWN/SquareEnix" 2>&1); rc=$?
check "exit 0" "(( rc == 0 ))"
check "registry names the Z: path" "grep -qF '/d Z:' '$LOG' && grep -qF 'Elsewhere\\HorizonXI\\SquareEnix\\FINAL FANTASY XI' '$LOG'"

print "\nfix-wine-rpath.sh"
print "9. a dangling link left by a moved wrapper is replaced; the moved copy keeps working"
make_wrapper; : > "$LOG"; mkdir -p "$APP/Contents/SharedSupport/wine/lib"
ln -s "/Volumes/$GONE/old/Fake.app/Contents/Frameworks/libinotify.0.dylib" "$APP/Contents/SharedSupport/wine/lib/libinotify.0.dylib"
out=$(run /bin/zsh "$RPATH" "$APP" 2>&1); rc=$?
check "exit 0" "(( rc == 0 ))"
check "link replaced and resolving" "[[ -e '$APP/Contents/SharedSupport/wine/lib/libinotify.0.dylib' ]]"
mv "$F/Wrapper" "$F/Moved"
check "still resolves after the wrapper moved" "[[ -e '$F/Moved/Fake.app/Contents/SharedSupport/wine/lib/libinotify.0.dylib' ]]"
mv "$F/Moved" "$F/Wrapper"

print "\nupdate-client.sh (Setup's download, Update)"
export HXI_ARIA2C="$stubs/aria2c"
print "10. fresh install: base by torrent, unpacked and flattened, then every update"
make_wrapper; : > "$LOG"
out=$(run /bin/zsh "$UPDATE" install "$GAME" 2>&1); rc=$?
check "exit 0" "(( rc == 0 ))"
check "Ashita and the base files in place, not under HorizonXI/" "[[ -f '$GAME/Ashita-cli.exe' && -f '$GAME/SquareEnix/FINAL FANTASY XI/FFXiMain.dll' && ! -e '$GAME/HorizonXI' ]]"
check "updates applied in order (2.0.3's file, 2.0.4's file, 2.0.4 deleted 2.0.3's stale one)" "[[ -f '$GAME/addons/new/new.lua' && -f '$GAME/patched-2.0.4.txt' && ! -e '$GAME/stale-from-2.0.3.txt' ]]"
check "version.json says 2.0.4" "grep -q '\"2.0.4\"' '$GAME/version.json'"
check "the 9 GB base zip is removed once unpacked" "[[ ! -e '$GAME/updates/HorizonXI.zip' ]]"
check "the old 1.1.1 update was not applied" "! grep -q 'HorizonXI-1_1_1' '$LOG'"
check "progress lines the launcher reads" "[[ \"\$out\" == *'==> base client in place'* && \"\$out\" == *'==> update 2.0.3 (1/2)'* && \"\$out\" == *'==> update 2.0.4 (2/2)'* ]]"
check "python3 never ran" "! grep -q '^python3' '$LOG'"

print "11. version.json there but Ashita gone (G10): the base comes back, then the updates again"
: > "$LOG"; rm "$GAME/Ashita-cli.exe"
out=$(run /bin/zsh "$UPDATE" install "$GAME" 2>&1); rc=$?
check "exit 0" "(( rc == 0 ))"
check "base fetched again" "grep -q 'dn=HorizonXI.zip' '$LOG'"
check "Ashita back, at 2.0.4" "[[ -f '$GAME/Ashita-cli.exe' ]] && grep -q '\"2.0.4\"' '$GAME/version.json'"

print "12. complete client: install goes straight to the update path, which has nothing to do"
: > "$LOG"
out=$(run /bin/zsh "$UPDATE" install "$GAME" 2>&1); rc=$?
check "exit 0, already up to date, no download" "(( rc == 0 )) && [[ \"\$out\" == *'already up to date'* ]] && ! grep -q '^aria2c' '$LOG'"

print "13. the old version.json with a literal \\\\n still reads (only 2.0.4 is applied)"
: > "$LOG"; print -r -- '{\n  "version": "2.0.3"\n}' > "$GAME/version.json"
out=$(run /bin/zsh "$UPDATE" horizon "$GAME" 2>&1); rc=$?
check "exit 0, read as 2.0.3" "(( rc == 0 )) && [[ \"\$out\" == *'installed HorizonXI 2.0.3'* ]]"
check "only 2.0.4 applied" "[[ \"\$out\" == *'==> update 2.0.4 (1/1)'* && \"\$out\" != *'update 2.0.3'* ]]"

print "14. a Stop leaves the zip and its .aria2 file: the next run resumes instead of unzipping half a file"
: > "$LOG"; print -r -- '{"version": "2.0.3"}' > "$GAME/version.json"
mkdir -p "$GAME/updates"; print partial > "$GAME/updates/HorizonXI-2_0_4.zip"; : > "$GAME/updates/HorizonXI-2_0_4.zip.aria2"
out=$(run /bin/zsh "$UPDATE" horizon "$GAME" 2>&1); rc=$?
check "exit 0 and aria2 resumed" "(( rc == 0 )) && grep -q 'dn=HorizonXI-2_0_4.zip' '$LOG'"

print "15. offline: one line saying so"
print -r -- '{"version": "2.0.3"}' > "$GAME/version.json"
out=$(STUB_OFFLINE=1 run /bin/zsh "$UPDATE" horizon "$GAME" 2>&1); rc=$?
check "exit 1, Couldn't reach api.horizonxi.com" "(( rc == 1 )) && [[ \"\$out\" == *\"!! Couldn't reach api.horizonxi.com\"* ]]"

print "16. a stalled torrent: one line, press Setup again"
make_wrapper; : > "$LOG"
out=$(STUB_ARIA2_FAIL=1 run /bin/zsh "$UPDATE" install "$GAME" 2>&1); rc=$?
check "exit 1, says press Setup again" "(( rc == 1 )) && [[ \"\$out\" == *'stalled or failed — press Setup again'* ]]"

print "17. game files behind a drive that is not there: refused before anything is written"
make_wrapper; : > "$LOG"; make_client "$GAME" 2.0.4; rm -rf "$GAME/SquareEnix"
ln -s "/Volumes/$GONE/FFXI/SquareEnix" "$GAME/SquareEnix"
out=$(run /bin/zsh "$UPDATE" install "$GAME" 2>&1); rc=$?
check "install: exit 1, names the drive, never restart" "(( rc == 1 )) && [[ \"\$out\" == *\"The '$GONE' drive isn't connected — reconnect it or press Setup\"* && \"\${out:l}\" != *restart* ]]"
check "install: no updates folder, no download" "[[ ! -e '$GAME/updates' ]] && ! grep -q '^aria2c' '$LOG'"
out=$(run /bin/zsh "$UPDATE" horizon "$GAME" 2>&1); rc=$?
check "horizon: refused the same way" "(( rc == 1 )) && [[ \"\$out\" == *\"The '$GONE' drive\"* ]]"

print "18. not enough free space for the base: refused with the numbers"
make_wrapper; : > "$LOG"
sed -i '' 's/xl=4096/xl=999999999999999/' "$F/api/install-game.json"
out=$(run /bin/zsh "$UPDATE" install "$GAME" 2>&1); rc=$?
sed -i '' 's/xl=999999999999999/xl=4096/' "$F/api/install-game.json"
check "exit 1, says how much is needed, nothing fetched" "(( rc == 1 )) && [[ \"\$out\" == *'GB free; there are'* ]] && ! grep -q '^aria2c' '$LOG'"

unset HXI_ARIA2C
print "19. no aria2c anywhere: the pinned build is fetched once (checksum checked)"
if [[ -f "$ARIA2_TARBALL" ]]; then
  # PATH without any aria2c (not the stub, not Homebrew's). Only `tools` runs: the real aria2c
  # must never be handed a magnet here.
  nostub="$F/stubs-no-aria2"; mkdir -p "$nostub"
  for t in curl python3; do ln -sf "$stubs/$t" "$nostub/$t"; done
  cp "$ARIA2_TARBALL" "$F/aria2-good.tar.bz2"
  make_wrapper; : > "$LOG"; rm -rf "$F/tools"
  out=$(RUN_PATH="$nostub:/usr/bin:/bin:/usr/sbin:/sbin" HXI_ARIA2_URL="file://$F/aria2-good.tar.bz2" \
        run /bin/zsh "$UPDATE" tools "$GAME" 2>&1); rc=$?
  check "exit 0, fetched once" "(( rc == 0 )) && [[ \"\$out\" == *'fetching the torrent tool'* && \"\$out\" == *\"aria2c=$F/tools/aria2c\"* ]]"
  check "aria2c installed into tools/ and runs (Rosetta)" "[[ -x '$F/tools/aria2c' ]] && '$F/tools/aria2c' --version | head -1 | grep -q 'aria2 version 1.35.0'"
  check "its licence kept beside it" "[[ -f '$F/tools/aria2-COPYING' ]]"
  out=$(RUN_PATH="$nostub:/usr/bin:/bin:/usr/sbin:/sbin" HXI_ARIA2_URL="file://$F/missing.tar.bz2" \
        run /bin/zsh "$UPDATE" tools "$GAME" 2>&1); rc=$?
  check "second run uses the installed copy, no fetch" "(( rc == 0 )) && [[ \"\$out\" != *'fetching'* ]]"
  rm -rf "$F/tools"; cp "$F/aria2-good.tar.bz2" "$F/aria2-bad.tar.bz2"; print tampered >> "$F/aria2-bad.tar.bz2"
  out=$(RUN_PATH="$nostub:/usr/bin:/bin:/usr/sbin:/sbin" HXI_ARIA2_URL="file://$F/aria2-bad.tar.bz2" \
        run /bin/zsh "$UPDATE" tools "$GAME" 2>&1); rc=$?
  check "a tampered archive is refused and not installed" "(( rc == 1 )) && [[ \"\$out\" == *\"didn't match its checksum\"* && ! -e '$F/tools/aria2c' ]]"
else
  print "  skip (no aria2-1.35.0-osx-darwin.tar.bz2 given)"
fi

print "21. the launcher's own --next-action and --fix on this fixture (HXI_LAUNCHER_BIN)"
if [[ -x "${HXI_LAUNCHER_BIN:-}" ]]; then
  # The stub stands in for the patched game Wine; the real ones are never looked at.
  launcher() { FFXI_ON_MAC_WINE="$F/playwine/wine" STUB_LOG="$LOG" "$HXI_LAUNCHER_BIN" "$@"; }
  PFX="$APP/Contents/SharedSupport/prefix10"
  make_wrapper; : > "$LOG"; make_client "$GAME" 2.0.4   # no wine/lib yet: the links are missing
  out=$(launcher --next-action HorizonXI --prefix "$PFX" 2>/dev/null); rc=$?
  check "next-action: Repair, Wine's links ($out)" "(( rc == 10 )) && [[ \"\$out\" == 'repair:wine | Repair | Wine needs a quick repair.' ]]"
  out=$(launcher --fix HorizonXI --prefix "$PFX" 2>/dev/null); rc=$?
  check "fix: repaired with the game Wine, then Play with no line" "(( rc == 0 )) && [[ \"\$out\" == *'result: ok'* && \"\$out\" == *'after:  play | Play | '* ]] && grep -q 'regsvr32 /s' '$LOG'"
  check "fix: registry/COM left to Play did not grey it" "[[ ! -e '$PFX/system.reg' ]]"
  rm "$GAME/Ashita-cli.exe"
  out=$(launcher --next-action HorizonXI --prefix "$PFX" 2>/dev/null); rc=$?
  check "next-action: Setup, files missing ($out)" "(( rc == 10 )) && [[ \"\$out\" == \"setup:game-files | Setup | Some of HorizonXI's files are missing.\" ]]"
  make_client "$GAME" 2.0.4; rm -rf "$GAME/SquareEnix"; ln -s "/Volumes/$GONE/FFXI/SquareEnix" "$GAME/SquareEnix"
  out=$(launcher --next-action HorizonXI --prefix "$PFX" 2>/dev/null); rc=$?
  check "next-action: Setup, the drive ($out)" "(( rc == 10 )) && [[ \"\$out\" == \"setup:data-drive | Setup | The '$GONE' drive isn't connected — reconnect it or press Setup.\" ]]"
  : > "$LOG"
  out=$(launcher --fix HorizonXI --prefix "$PFX" 2>/dev/null); rc=$?
  check "fix refuses a missing drive (it needs a person) and runs nothing" "(( rc == 3 )) && [[ \"\$out\" == *refusing* ]] && ! grep -q '^wine' '$LOG'"
else
  print "  skip (set HXI_LAUNCHER_BIN to a built HorizonXILauncher)"
fi

print "20. the scripts' user-facing lines never say restart"
check "no 'restart' in install.sh or update-client.sh messages" "! grep -niE '(die|print|info|say)[^#]*restart' '$INSTALL' '$UPDATE'"

print
(( fails == 0 )) && print "all checks passed" || print "$fails FAILED"
exit $(( fails > 0 ))
