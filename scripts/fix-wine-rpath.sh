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
for f in "$FRAMEWORKS"/*.dylib(N) "$SHARED"/*.dylib(N); do
  [[ -e "$f" ]] || continue
  base="${f:t}"
  [[ -e "$LIBDIR/$base" ]] && continue
  ln -s "$f" "$LIBDIR/$base"
  linked=$((linked + 1))
done

echo "linked $linked dylib(s) into $LIBDIR"

# Verify: run wine with a deliberately empty environment. If this prints a path, the
# wrapper no longer needs DYLD_* and is safe to drive from scripts and launchers.
env -u DYLD_FALLBACK_LIBRARY_PATH -u DYLD_LIBRARY_PATH \
  "$SHARED/wine/bin/wine" cmd.exe /c echo '%AppData%' 2>/dev/null | tail -1 || true
