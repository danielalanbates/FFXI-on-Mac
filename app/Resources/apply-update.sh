#!/bin/zsh
# Replace the launcher only after it exits. All paths arrive as arguments, never shell code.
set -euo pipefail

pid="$1"
staged="$2"
current="$3"
workdir="$4"

for i in {1..600}; do
  kill -0 "$pid" 2>/dev/null || break
  sleep 0.5
done
if kill -0 "$pid" 2>/dev/null; then exit 1; fi

candidate="${current}.next-${pid}"
backup="${current}.previous-${pid}"
[[ ! -e "$candidate" && ! -e "$backup" && -d "$staged" && -d "$current" ]] || exit 1

# Copy and verify before moving the playable app. A failed copy leaves it untouched.
/usr/bin/ditto "$staged" "$candidate"
if ! /usr/bin/codesign --verify --strict --deep "$candidate"; then
  /bin/rm -rf "$candidate"
  exit 1
fi
/usr/bin/xattr -dr com.apple.quarantine "$candidate" 2>/dev/null || true

/bin/mv "$current" "$backup"
if ! /bin/mv "$candidate" "$current"; then
  /bin/mv "$backup" "$current"
  exit 1
fi
if ! /usr/bin/open "$current"; then
  /bin/mv "$current" "$candidate"
  /bin/mv "$backup" "$current"
  /usr/bin/open "$current" || true
  exit 1
fi

# Keep one recoverable copy outside Applications. The new app is now the only active bundle.
/bin/mv "$backup" "$workdir/previous-${pid}.app" || true
/bin/rm -rf "${staged:h}"
/bin/rm -f "$0"
