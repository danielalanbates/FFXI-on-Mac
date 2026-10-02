#!/bin/zsh
# bundle.sh — build FFXI-on-Mac.app from the SPM executable.
# No Xcode required; this machine only has the Command Line Tools.
set -euo pipefail

HERE="${0:A:h}"
REPO="${HERE:h}"
# Keep generated bundles out of the source checkout. The playable app is HorizonXI.app;
# this beta bundle lives beside it in /Applications. Swift build intermediates stay in Downloads.
if [[ -n "${1:-}" ]]; then
  OUT="$1"
else
  OUT="/Applications"
fi
APP="$OUT/FFXI-on-Mac.app"
BUILD_DIR="${HXI_BUILD_DIR:-$HOME/Downloads/FFXI-on-Mac-build/swift-build}"

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
  "$REPO/scripts/catseye-launcher.sh" "$REPO/scripts/retail-client.sh"; do
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
cp "$REPO/scripts/catseye-launcher.sh" "$APP/Contents/Resources/catseye-launcher.sh"
cp "$REPO/scripts/retail-client.sh"    "$APP/Contents/Resources/retail-client.sh"
chmod +x "$APP/Contents/Resources/"*.sh

# The Metal/DXVK renderer ships inside the app: Renderer.swift resolves these by name out of
# Bundle.main, so the user never has to fetch a DLL by hand.
for dll in d3d8to9.dll dxvk-1.10.3-x32-d3d9-horizonxi.dll libMoltenVK-1.4.2.dylib; do
  [[ -f "$REPO/vendor/$dll" ]] && cp "$REPO/vendor/$dll" "$APP/Contents/Resources/$dll"
done

# x87sidecar: the fix for FFXI's x87 floating-point math running ~100x slow under Rosetta (see
# docs/X87-WALL.md). Signed individually below with its own entitlements -- the app's deep-sign
# strips them otherwise, and without get-task-allow/cs.debugger it cannot attach to the game.
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

cat > "$APP/Contents/Info.plist" <<'PLIST'
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
  <key>CFBundleShortVersionString</key><string>3.9</string>
  <key>CFBundleVersion</key><string>58</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.games</string>
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
# Order matters, and the obvious order is wrong. x87sidecar_entitled needs its own entitlements
# (get-task-allow, cs.debugger) or it cannot attach to the game at all. Signing it *after* the
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
  codesign --force --options runtime -s "$HXI_SIGN_ID" "$APP"
else
  if [[ -f "$X87SC" ]]; then
    codesign --force -s - --entitlements "$REPO/vendor/x87sidecar-entitlements.plist" "$X87SC"
  fi
  if [[ -f "$AUDIOFOLLOW" ]]; then codesign --force -s - "$AUDIOFOLLOW"; fi
  codesign --force -s - "$APP"
fi
codesign --verify --deep --strict "$APP"

# Re-register with Launch Services. Replacing a bundle in place leaves the Dock and Finder
# showing the icon they cached for that path -- after a rebuild the app came up with the generic
# executable icon even though AppIcon.icns was present and complete.
touch "$APP"
if [[ -e "$APP_CANONICAL" ]]; then mv "$APP_CANONICAL" "$BACKUP"; fi
if ! mv "$APP" "$APP_CANONICAL"; then
  [[ -e "$BACKUP" ]] && mv "$BACKUP" "$APP_CANONICAL"
  rm -rf "$STAGE"
  exit 1
fi
rm -rf "$BACKUP"
trap - EXIT
LSREG=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
[[ -x "$LSREG" ]] && "$LSREG" -f "$APP_CANONICAL" >/dev/null 2>&1 || true

echo "built $APP_CANONICAL"
