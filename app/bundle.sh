#!/bin/zsh
# bundle.sh — build FFXI-on-Mac.app from the SPM executable.
# No Xcode required; this machine only has the Command Line Tools.
#
#   ./app/bundle.sh <output-dir>        e.g. ./app/bundle.sh ~/Downloads/FFXI-build
#
# There is no default output. /Applications/FFXI-on-Mac.app is the copy Daniel plays on: build
# elsewhere, and install there only with the launcher and every game client quit (this script
# refuses /Applications while any of them runs). A bundle it replaces is moved into
# ~/Downloads/FFXI-on-Mac-build/archive-apps/, never deleted. Version and build: app/VERSION.
# Swift build intermediates stay in Downloads.
set -euo pipefail

HERE="${0:A:h}"
REPO="${HERE:h}"
if [[ -z "${1:-}" ]]; then
  echo "usage: ${0:t} <output-dir>   (e.g. ${0:t} ~/Downloads/FFXI-build)" >&2
  exit 2
fi
OUT="$1"
APP="$OUT/FFXI-on-Mac.app"
BUILD_DIR="${HXI_BUILD_DIR:-$HOME/Downloads/FFXI-on-Mac-build/swift-build}"
ARCHIVE_DIR="${HXI_ARCHIVE_DIR:-$HOME/Downloads/FFXI-on-Mac-build/archive-apps}"

# app/VERSION: SHORT=<CFBundleShortVersionString>, BUILD=<CFBundleVersion>. The updater compares
# both, so a new local beta is a one-line BUILD bump there.
APP_SHORT_VERSION="" APP_BUILD=""
while IFS='=' read -r key value || [[ -n "$key" ]]; do
  value="${value//[[:space:]]/}"
  case "${key//[[:space:]]/}" in
    SHORT) APP_SHORT_VERSION="$value" ;;
    BUILD) APP_BUILD="$value" ;;
  esac
done < "$HERE/VERSION"
if [[ ! "$APP_SHORT_VERSION" =~ '^[0-9]+(\.[0-9]+){1,2}$' || "$APP_BUILD" != <-> ]]; then
  echo "app/VERSION must hold SHORT=<x.y[.z]> and BUILD=<number> (got '$APP_SHORT_VERSION' / '$APP_BUILD')" >&2
  exit 1
fi

canonical_path() {
  local path="$1"
  /bin/mkdir -p "${path:h}"
  (cd "${path:h}" && print -r -- "$PWD/${path:t}")
}

APP_CANONICAL="$(canonical_path "$APP")"
if [[ "$APP_CANONICAL" == */*.app/Contents/* ]]; then
  echo "output app cannot be created inside another application bundle: $APP_CANONICAL" >&2
  exit 1
fi

# Never swap the bundle Daniel plays on while it, the game or any wine is running. Checked before
# the build and again right before the swap.
LIVE_PATTERN='FFXI-on-Mac.app/Contents/MacOS|horizon-loader|Ashita-cli|wineserver'
refuse_if_live() {
  [[ "${APP_CANONICAL:h}" == /Applications ]] || return 0
  if /usr/bin/pgrep -f "$LIVE_PATTERN" >/dev/null 2>&1; then
    echo "refusing to replace $APP_CANONICAL: the launcher, a game client or wine is running." >&2
    echo "Quit them first (in game, /shutdown; never kill a logged-in client):" >&2
    /usr/bin/pgrep -fl "$LIVE_PATTERN" >&2 || true
    exit 1
  fi
}
refuse_if_live
for source in "${HXI_VANAGUIDE_SOURCE:-$REPO/../vanaguide/Vanaguide}" \
              "${HXI_VANAVOICE_SOURCE:-$REPO/../vanavoice/addon/vanavoice}" \
              "${HXI_WINECURSOR_SOURCE:-$REPO/addons/winecursor}"; do
  SOURCE_CANONICAL="$(canonical_path "$source")"
  if [[ "$SOURCE_CANONICAL" == "$APP_CANONICAL" || "$SOURCE_CANONICAL" == "$APP_CANONICAL"/* \
     || "$APP_CANONICAL" == "$SOURCE_CANONICAL"/* ]]; then
    echo "addon source and output app overlap; refusing unsafe bundle: $source" >&2
    exit 1
  fi
done

cd "$HERE"
if [[ -n "${HXI_BINARY:-}" ]]; then
  BIN="$HXI_BINARY"
else
  swift build -c release --scratch-path "$BUILD_DIR"
  BIN="$(swift build -c release --scratch-path "$BUILD_DIR" --show-bin-path)/HorizonXILauncher"
fi
[[ -x "$BIN" ]] || { echo "build produced no binary" >&2; exit 1; }

bundle_addon() {
  local addon_name="$1" addon_source="$2" entry_file="$3" license_file="$4"
  local addon_destination="$APP/Contents/Resources/$addon_name"
  mkdir -p "$addon_destination"
  cp -R "$addon_source/." "$addon_destination/"
  cp "$license_file" "$addon_destination/LICENSE"
}

VANAGUIDE_SOURCE="${HXI_VANAGUIDE_SOURCE:-$REPO/../vanaguide/Vanaguide}"
VANAVOICE_SOURCE="${HXI_VANAVOICE_SOURCE:-$REPO/../vanavoice/addon/vanavoice}"
WINECURSOR_SOURCE="${HXI_WINECURSOR_SOURCE:-$REPO/addons/winecursor}"
VANAGUIDE_LICENSE="$REPO/../vanaguide/LICENSE"
VANAVOICE_LICENSE="$REPO/../vanavoice/LICENSE"

for relative in \
  Vanaguide.lua core/guide.lua core/progress.lua core/story.lua core/conditions.lua \
  core/util.lua core/lookup.lua core/verify.lua core/walk.lua guides/init.lua \
  routing/zonegraph.lua routing/router.lua routing/path.lua routing/zonepoints.lua \
  routing/navgrid.lua ui/arrow.lua ui/window.lua ui/line.lua ui/project.lua \
  data/zone_names.lua data/zonelines.lua data/zonepoints.lua data/drops.lua \
  data/gear.lua data/missions.lua data/nm.lua data/quests.lua data/travel.lua data/vendors.lua; do
  [[ -f "$VANAGUIDE_SOURCE/$relative" ]] || {
    echo "incomplete Vanaguide source; missing $relative" >&2
    exit 1
  }
done
[[ -f "$VANAVOICE_SOURCE/vanavoice.lua" ]] || {
  echo "incomplete VanaVoice source; missing vanavoice.lua" >&2
  exit 1
}
[[ -f "$WINECURSOR_SOURCE/winecursor.lua" ]] || {
  echo "incomplete winecursor source; missing winecursor.lua" >&2
  exit 1
}

for required in \
  "$VANAGUIDE_SOURCE/Vanaguide.lua" "$VANAGUIDE_LICENSE" \
  "$VANAVOICE_SOURCE/vanavoice.lua" "$VANAVOICE_LICENSE" \
  "$WINECURSOR_SOURCE/winecursor.lua" \
  "$REPO/scripts/install.sh" "$REPO/scripts/fix-wine-rpath.sh" \
  "$REPO/scripts/lsb-server.sh" "$REPO/scripts/update-client.sh" \
  "$REPO/scripts/catseye-launcher.sh" "$REPO/scripts/retail-client.sh" \
  "$REPO/vendor/dxvk.conf" "$REPO/LICENSE" \
  "$REPO/vendor/licenses/README.txt" "$REPO/vendor/licenses/d3d8to9-BSD-3-Clause.txt" \
  "$REPO/vendor/licenses/DXVK-zlib.txt" "$REPO/vendor/licenses/MoltenVK-Apache-2.0.txt" \
  "$REPO/vendor/licenses/cereal-BSD-3-Clause.txt" "$REPO/vendor/licenses/x87sidecar-MIT.txt"; do
  [[ -f "$required" ]] || { echo "required bundle input missing: $required" >&2; exit 1; }
done

STAGE="$OUT/.FFXI-on-Mac.app.staging-$$"
BACKUP="$OUT/.FFXI-on-Mac.app.previous-$$"
rm -rf "$STAGE" "$BACKUP"
trap 'rm -rf "$STAGE"; if [[ -e "$BACKUP" && ! -e "$APP_CANONICAL" ]]; then mv "$BACKUP" "$APP_CANONICAL"; fi' EXIT
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources"
APP="$STAGE"
bundle_addon Vanaguide "$VANAGUIDE_SOURCE" Vanaguide.lua "$VANAGUIDE_LICENSE"
bundle_addon vanavoice "$VANAVOICE_SOURCE" vanavoice.lua "$VANAVOICE_LICENSE"
mkdir -p "$APP/Contents/Resources/winecursor"
cp "$WINECURSOR_SOURCE/winecursor.lua" "$APP/Contents/Resources/winecursor/winecursor.lua"
cp "$BIN" "$APP/Contents/MacOS/FFXI-on-Mac"

# install.sh + its helper are the Repair action; lsb-server.sh is the whole local-server world
# (dependencies, source, database, build, run). All three are run out of the bundle.
cp "$REPO/scripts/install.sh"        "$APP/Contents/Resources/install.sh"
cp "$REPO/scripts/fix-wine-rpath.sh" "$APP/Contents/Resources/fix-wine-rpath.sh"
cp "$REPO/scripts/lsb-server.sh"     "$APP/Contents/Resources/lsb-server.sh"
cp "$REPO/scripts/update-client.sh"  "$APP/Contents/Resources/update-client.sh"
cp "$HERE/Resources/apply-update.sh" "$APP/Contents/Resources/apply-update.sh"
cp "$REPO/scripts/catseye-launcher.sh" "$APP/Contents/Resources/catseye-launcher.sh"
cp "$REPO/scripts/retail-client.sh"    "$APP/Contents/Resources/retail-client.sh"
chmod +x "$APP/Contents/Resources/"*.sh

# The Metal/DXVK renderer ships inside the app: Renderer.swift resolves these by name out of
# Bundle.main, so the user never has to fetch a DLL by hand.
for dll in d3d8to9.dll dxvk-1.10.3-x32-d3d9-horizonxi.dll libMoltenVK-1.4.2.dylib; do
  [[ -f "$REPO/vendor/$dll" ]] && cp "$REPO/vendor/$dll" "$APP/Contents/Resources/$dll"
done
# DXVK's settings file. Play copies it into the prefix and sets DXVK_CONFIG_FILE (Renderer.swift).
cp "$REPO/vendor/dxvk.conf" "$APP/Contents/Resources/dxvk.conf"
# The licence texts travel with the binaries (BSD-3, zlib, Apache-2.0 and MIT all require it), and
# this project's own LICENSE beside them. Index and provenance: vendor/NOTICE.md.
mkdir -p "$APP/Contents/Resources/ThirdPartyNotices"
cp "$REPO/vendor/licenses/"*.txt "$APP/Contents/Resources/ThirdPartyNotices/"
cp "$REPO/LICENSE" "$APP/Contents/Resources/LICENSE"

# x87sidecar: the fix for FFXI's x87 floating-point math running ~100x slow under Rosetta (see
# docs/X87-WALL.md). Signed individually below, before the app -- x87sidecar_entitled needs its
# own cs.debugger entitlement to attach to the game. Order and reasons: vendor/NOTICE.md.
if [[ -f "$REPO/vendor/x87sidecar-coop" ]]; then
  # Cooperative-mode sidecar (no entitlements, notarizable); preferred on macOS >= 26.5.2.
  cp "$REPO/vendor/x87sidecar-coop" "$APP/Contents/Resources/x87sidecar-coop"
  chmod +x "$APP/Contents/Resources/x87sidecar-coop"
fi
# attach-by-pid sidecar: BROKEN on macOS 26.5.2+ (cross-process i-cache flush), so it is no
# longer bundled by default. Restore this block only for older macOS.
# Bundled again 2026-08-21: cooperative mode does not survive into the client (it exits with the
# injector and leaves the game at stock Rosetta x87, ~5 fps -- see docs/X87-WALL.md). attach-by-pid
# is the mode that measured 11.3 -> 28.5 fps, so it is preferred again and this binary has to ship.
if [[ -f "$REPO/vendor/x87sidecar_entitled" ]]; then
  cp "$REPO/vendor/x87sidecar_entitled" "$APP/Contents/Resources/x87sidecar_entitled"
  chmod +x "$APP/Contents/Resources/x87sidecar_entitled"
fi

# audiofollow.dylib -- inserted into wine so a running game follows the Mac's Sound Output
# setting (see audio/audiofollow.c). Built here if it is missing so a fresh clone still gets it.
if [[ ! -f "$REPO/app/Resources/audiofollow.dylib" ]]; then
  "$REPO/scripts/build-audiofollow.sh" >/dev/null 2>&1 || true
fi
[[ -f "$REPO/app/Resources/audiofollow.dylib" ]] && \
  cp "$REPO/app/Resources/audiofollow.dylib" "$APP/Contents/Resources/audiofollow.dylib"

# Dock/Finder icon: an original crystal mark in the launcher's own Vana'diel palette (see
# scripts/make_icon.py), not extracted from Square Enix's client -- this project's own art.
[[ -f "$HERE/AppIcon.icns" ]] && cp "$HERE/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
# The icon a *running world* wears in the Dock. Stamped into the wine wrapper at launch by
# DockIcon.swift, so it has to ride along in the launcher's Resources.
[[ -f "$HERE/GameIcon.icns" ]] && cp "$HERE/GameIcon.icns" "$APP/Contents/Resources/GameIcon.icns"

# Which Vanaguide and VanaVoice commits this bundle carries: they are copied from the sibling
# checkouts as they sit on disk. "-dirty" means uncommitted changes went in; package.sh refuses
# that for a release and prints both revisions for the release notes.
addon_revision() {
  local root="$1" rev state
  [[ -e "$root/.git" ]] || { print -r -- "unknown"; return 0; }
  rev="$(/usr/bin/git -C "$root" rev-parse HEAD 2>/dev/null)" || { print -r -- "unknown"; return 0; }
  if ! state="$(/usr/bin/git -C "$root" --no-optional-locks status --porcelain 2>/dev/null)" \
     || [[ -n "$state" ]]; then
    rev="$rev-dirty"
  fi
  print -r -- "$rev"
}
VANAGUIDE_REVISION="$(addon_revision "${VANAGUIDE_SOURCE:h}")"
VANAVOICE_REVISION="$(addon_revision "${VANAVOICE_SOURCE:h:h}")"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>FFXI on Mac</string>
  <key>CFBundleDisplayName</key><string>FFXI on Mac</string>
  <key>CFBundleExecutable</key><string>FFXI-on-Mac</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIconName</key><string>AppIcon</string>
  <key>CFBundleIdentifier</key><string>org.batesai.horizonxi-on-mac</string>
  <!-- Without these usage strings macOS silently refuses the folder/volume instead of asking:
       the launcher then reports "you don't have permission to view" wine/lib on an external
       drive and Play stays grey. With them, the first access shows the normal permission prompt
       once, and a Developer ID signature keeps that answer across builds. -->
  <key>NSRemovableVolumesUsageDescription</key><string>Your FFXI game data may live on an external drive.</string>
  <key>NSNetworkVolumesUsageDescription</key><string>Your FFXI game data may live on a network drive.</string>
  <key>NSDownloadsFolderUsageDescription</key><string>To find a wrapper or installer you saved to Downloads.</string>
  <key>NSDesktopFolderUsageDescription</key><string>To find a wrapper you keep on the Desktop.</string>
  <key>NSDocumentsFolderUsageDescription</key><string>To find a wrapper you keep in Documents.</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${APP_SHORT_VERSION}</string>
  <key>CFBundleVersion</key><string>${APP_BUILD}</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.games</string>
  <key>HXIAddonRevisions</key>
  <dict>
    <key>Vanaguide</key><string>${VANAGUIDE_REVISION}</string>
    <key>VanaVoice</key><string>${VANAVOICE_REVISION}</string>
  </dict>
</dict>
</plist>
PLIST

# Default to the Developer ID when it is in the keychain, so a Full Disk Access grant (keyed to
# bundle id + team) survives rebuilds. HXI_ADHOC=1 forces ad-hoc.
if [[ -z "${HXI_SIGN_ID:-}" && -z "${HXI_ADHOC:-}" ]]; then
  HXI_SIGN_ID="$(security find-identity -v -p codesigning 2>/dev/null | awk '/Developer ID Application/ {print $2; exit}')"
fi
# Signature. Ad-hoc by default; set HXI_SIGN_ID to a Developer ID hash for a release build
# that can be notarised. Use the certificate *hash*, not its name -- there are two identical
# "Developer ID Application: Daniel Bates" certs in the login keychain and codesign rejects
# the name as ambiguous. Do NOT pass --timestamp here: it hangs on this network.
# Order matters, and the obvious order is wrong. x87sidecar_entitled needs its own entitlement
# (cs.debugger; get-task-allow is left out because the notary rejects it) or it cannot attach. Signing it *after* the
# app breaks the app's seal -- `codesign -v` then reports "a sealed resource is missing or
# invalid" and Gatekeeper rejects the bundle. So sign the nested binary FIRST, then sign the app
# WITHOUT --deep, which leaves nested signatures alone and seals them as they are.
#
# iCloud puts xattrs on everything it syncs and codesign refuses to sign a bundle carrying them
# ("resource fork, Finder information, or similar detritus not allowed"), so strip them first.
find "$APP" -exec xattr -c {} \; 2>/dev/null || true

X87SC="$APP/Contents/Resources/x87sidecar_entitled"
X87COOP="$APP/Contents/Resources/x87sidecar-coop"
AUDIOFOLLOW="$APP/Contents/Resources/audiofollow.dylib"
MOLTENVK="$APP/Contents/Resources/libMoltenVK-1.4.2.dylib"
if [[ -n "${HXI_SIGN_ID:-}" ]]; then
  # The cooperative sidecar has no entitlements, so it can carry the hardened runtime and the
  # secure timestamp the notary demands of nested executables. --timestamp is required here:
  # without it notarization returns Invalid on exactly this file (measured 2026-08-20).
  if [[ -f "$X87COOP" ]]; then codesign --force --options runtime --timestamp -s "$HXI_SIGN_ID" "$X87COOP"; fi
  if [[ -f "$X87SC" ]]; then
    codesign --force --options runtime -s "$HXI_SIGN_ID" \
      --entitlements "$REPO/vendor/x87sidecar-entitlements.plist" "$X87SC"
  fi
  # Nested dylibs need the hardened runtime and a secure timestamp too, or the notary rejects
  # the whole bundle on this one file.
  if [[ -f "$AUDIOFOLLOW" ]]; then codesign --force --options runtime --timestamp -s "$HXI_SIGN_ID" "$AUDIOFOLLOW"; fi
  if [[ -f "$MOLTENVK" ]]; then codesign --force --options runtime --timestamp -s "$HXI_SIGN_ID" "$MOLTENVK"; fi
  codesign --force --options runtime -s "$HXI_SIGN_ID" "$APP"
else
  if [[ -f "$X87SC" ]]; then
    codesign --force -s - --entitlements "$REPO/vendor/x87sidecar-entitlements.plist" "$X87SC"
  fi
  if [[ -f "$AUDIOFOLLOW" ]]; then codesign --force -s - "$AUDIOFOLLOW"; fi
  if [[ -f "$MOLTENVK" ]]; then codesign --force -s - "$MOLTENVK"; fi
  codesign --force -s - "$APP"
fi
codesign --verify --deep --strict "$APP"

# Re-register with Launch Services. Replacing a bundle in place leaves the Dock and Finder
# showing the icon they cached for that path -- after a rebuild the app came up with the generic
# executable icon even though AppIcon.icns was present and complete.
touch "$APP"
refuse_if_live
if [[ -e "$APP_CANONICAL" ]]; then mv "$APP_CANONICAL" "$BACKUP"; fi
if ! mv "$APP" "$APP_CANONICAL"; then
  [[ -e "$BACKUP" ]] && mv "$BACKUP" "$APP_CANONICAL"
  rm -rf "$STAGE"
  exit 1
fi
# Archive rule: exactly one live copy here; the one it replaced goes to the archive, never rm.
if [[ -e "$BACKUP" ]]; then
  old_version="$(/usr/bin/plutil -extract CFBundleShortVersionString raw "$BACKUP/Contents/Info.plist" 2>/dev/null || print unknown)"
  old_build="$(/usr/bin/plutil -extract CFBundleVersion raw "$BACKUP/Contents/Info.plist" 2>/dev/null || print unknown)"
  archived="$ARCHIVE_DIR/FFXI-on-Mac-$old_version-b$old_build-$(date +%Y%m%d-%H%M%S).app"
  if /bin/mkdir -p "$ARCHIVE_DIR" && mv "$BACKUP" "$archived"; then
    echo "archived the previous app to $archived"
  else
    echo "warning: could not archive the previous app; it is still at $BACKUP" >&2
  fi
fi
trap - EXIT
LSREG=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
[[ -x "$LSREG" ]] && "$LSREG" -f "$APP_CANONICAL" >/dev/null 2>&1 || true

echo "built $APP_CANONICAL"
