#!/bin/zsh
# build-ashita-send.sh -- build vendor/ashita-send.exe from tools/ashita-send.c.
#
# Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved. PolyForm Noncommercial 1.0.0
# with the commercial-use rider in LICENSE; commercial licences: help@batesai.org.
#
#   scripts/build-ashita-send.sh            builds vendor/ashita-send.exe (bundled by app/bundle.sh)
#   scripts/build-ashita-send.sh <dir>      also builds the test-only fake plugin into <dir>
#
# i686 (the game is 32-bit, and so is Thirdparty's shared memory layout), static (no libgcc or
# winpthread DLL beside it), stripped, and with no PE timestamp so the same source gives the same
# bytes. The import table is checked: KERNEL32 and the C runtime only (Homebrew's mingw-w64 targets
# the UCRT, so that is ucrtbase's api-ms-win-crt-* set, which wine provides) -- no user32, so wine
# never needs a desktop or explorer to run it. Needs Homebrew's mingw-w64 (i686-w64-mingw32-gcc).
set -euo pipefail
REPO="${0:A:h:h}"
CC="${CC_I686:-i686-w64-mingw32-gcc}"
OBJDUMP="${OBJDUMP_I686:-i686-w64-mingw32-objdump}"
command -v "$CC" >/dev/null || { echo "missing $CC (brew install mingw-w64)" >&2; exit 1; }
CFLAGS=(-std=c11 -O2 -Wall -Wextra -Werror -static -s -Wl,--no-insert-timestamp)

build() {
  local src="$1" out="$2"
  "$CC" "${CFLAGS[@]}" -o "$out" "$src"
  local dlls
  dlls="$("$OBJDUMP" -p "$out" | awk '/DLL Name:/ {print tolower($3)}' | sort -u | tr '\n' ' ')"
  for d in ${=dlls}; do
    case "$d" in
      kernel32.dll|msvcrt.dll|ucrtbase.dll|api-ms-win-crt-*.dll) ;;
      *) echo "$out imports $d; only KERNEL32 and the C runtime are allowed" >&2; rm -f "$out"; exit 1 ;;
    esac
  done
  echo "built $out (imports: $dlls)"
}

build "$REPO/tools/ashita-send.c" "$REPO/vendor/ashita-send.exe"
shasum -a 256 "$REPO/vendor/ashita-send.exe"
if [[ -n "${1:-}" ]]; then
  mkdir -p "$1"
  build "$REPO/scripts/tests/ashita-send-fake-plugin.c" "$1/ashita-send-fake-plugin.exe"
fi
