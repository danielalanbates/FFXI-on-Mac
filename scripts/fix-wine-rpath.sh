#!/bin/zsh
# Fix the Sikarugir/Kegworks wrapper's dylib rpath on macOS.
#
# The bundled `wineserver` (and `wine`) are linked with an rpath of `@loader_path/../../`,
# which resolves to `<wrapper>.app/Contents/SharedSupport/`. The dylibs they need
# (libinotify, libgnutls, libfreetype, ...) actually ship in `Contents/Frameworks/`.
# The result is a hard `dyld: Library not loaded: @rpath/libinotify.0.dylib` at launch.
#
# The commonly suggested workaround — exporting DYLD_FALLBACK_LIBRARY_PATH — is a trap on
# macOS: SIP strips every DYLD_* variable when exec'ing a protected binary, which includes
# `nohup` and `/bin/sh`. So the wrapper works interactively and breaks the instant it is
# backgrounded or driven from a shell script (winetricks is `#!/bin/sh`).
#
# Symlinking the frameworks into the directory the binaries actually search removes the
# dependency on any environment variable at all.
#
# Usage: ./fix-wine-rpath.sh /path/to/wrapper.app

set -euo pipefail

APP="${1:?usage: fix-wine-rpath.sh /path/to/wrapper.app}"
FRAMEWORKS="$APP/Contents/Frameworks"
SHARED="$APP/Contents/SharedSupport"
LIBDIR="$SHARED/wine/lib"

[[ -d "$FRAMEWORKS" ]] || { echo "no Contents/Frameworks in $APP" >&2; exit 1; }
[[ -d "$SHARED/wine/bin" ]] || { echo "no SharedSupport/wine/bin in $APP" >&2; exit 1; }

mkdir -p "$LIBDIR"

linked=0
# (N) is zsh's null_glob qualifier: a pattern that matches nothing expands to nothing instead
# of aborting the script. A freshly created wrapper has no dylibs loose in SharedSupport -- they
# are all in Frameworks -- so without this the script dies on exactly the case it exists for.
#
# Links are relative (b60), so a wrapper that is moved or copied to another drive keeps working;
# a link left dangling by such a move (the old absolute kind) is replaced instead of making
# `ln` fail with "File exists".
for f in "$FRAMEWORKS"/*.dylib(N) "$SHARED"/*.dylib(N); do
  [[ -e "$f" ]] || continue
  base="${f:t}"
  [[ -L "$LIBDIR/$base" && ! -e "$LIBDIR/$base" ]] && rm -f "$LIBDIR/$base"
  [[ -e "$LIBDIR/$base" ]] && continue
  if [[ "$f" == "$FRAMEWORKS"/* ]]; then rel="../../../Frameworks/$base"; else rel="../../$base"; fi
  ln -s "$rel" "$LIBDIR/$base"
  linked=$((linked + 1))
done

echo "linked $linked dylib(s) into $LIBDIR"

# Verify: wineserver loads the same dylibs and needs no prefix. (Running `wine cmd.exe` here
# booted whatever WINEPREFIX was set -- ~/.wine from first-run setup, or the game prefix from a
# Repair, which the wrapper's wine then re-stamped and the next Play had to update again.)
env -u DYLD_FALLBACK_LIBRARY_PATH -u DYLD_LIBRARY_PATH \
  "$SHARED/wine/bin/wineserver" --version 2>&1 | tail -1
