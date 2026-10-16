#!/bin/zsh
# Build gamewindow.dylib (universal: arm64 + x86_64).
#
# x86_64 is the one that matters — wine on Apple Silicon runs under Rosetta and that is the
# process whose game window is kept in proportion. arm64 is built too so the same file can be
# tested natively on the Mac (scripts/tests/gamewindow-test.sh) without Rosetta in the way.
set -euo pipefail
REPO="${0:A:h:h}"
SRC="$REPO/window/gamewindow.c"
OUT="$REPO/app/Resources/gamewindow.dylib"
mkdir -p "$REPO/app/Resources"
# The app's own minimum (LSMinimumSystemVersion 13.0), not whatever macOS builds it.
# CoreFoundation is deliberately not linked (window/gamewindow.c opens it only where it is needed).
CFLAGS=(-O2 -Wall -Wextra -dynamiclib -mmacosx-version-min=13.0 -lobjc
        -install_name @rpath/gamewindow.dylib)
clang -arch arm64   "${CFLAGS[@]}" -o "$OUT.arm64"  "$SRC"
clang -arch x86_64  "${CFLAGS[@]}" -o "$OUT.x86_64" "$SRC"
lipo -create "$OUT.arm64" "$OUT.x86_64" -output "$OUT"
rm -f "$OUT.arm64" "$OUT.x86_64"
codesign --force --sign - "$OUT"
echo "built $OUT"
lipo -info "$OUT"
