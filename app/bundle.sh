#!/bin/zsh
# bundle.sh — build FFXI-on-Mac.app from the SPM executable.
# No Xcode required; this machine only has the Command Line Tools.
set -euo pipefail

HERE="${0:A:h}"
REPO="${HERE:h}"
# Default output is beside the sources, except when the checkout lives in iCloud Drive: iCloud
# re-adds extended attributes to files while they are being written, and codesign refuses any
# bundle carrying them ("resource fork, Finder information, or similar detritus not allowed").
# Stripping them does not help -- they come back mid-build -- so build somewhere else entirely.
if [[ -n "${1:-}" ]]; then
  OUT="$1"
elif [[ "$HERE" == *"/Mobile Documents/"* ]]; then
  OUT="${TMPDIR:-/tmp}/ffxi-on-mac-build"
else
  OUT="$HERE/build"
fi
APP="$OUT/FFXI-on-Mac.app"

cd "$HERE"
swift build -c release
BIN="$(swift build -c release --show-bin-path)/HorizonXILauncher"
[[ -x "$BIN" ]] || { echo "build produced no binary" >&2; exit 1; }

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
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

# Bundle the tested Vanaguide addon when its project is next to this one in the Code folder.
# The launcher still needs no addon on allowlist worlds; they use Vanaguide.app separately.
VG_SOURCE="${VG_ADDON_SOURCE:-${REPO:h}/vanaguide/Vanaguide}"
if [[ -f "$VG_SOURCE/Vanaguide.lua" ]]; then
  cp -R "$VG_SOURCE" "$APP/Contents/Resources/Vanaguide"
fi

# The Metal/DXVK renderer ships inside the app: Renderer.swift resolves these by name out of
# Bundle.main, so the user never has to fetch a DLL by hand.
for dll in d3d8to9.dll dxvk-1.10.3-x32-d3d9-horizonxi.dll; do
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
  <key>CFBundleShortVersionString</key><string>3.8.1</string>
  <key>CFBundleVersion</key><string>22</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.games</string>
</dict>
</plist>
PLIST

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
  [[ -f "$X87COOP" ]] && codesign --force --options runtime --timestamp -s "$HXI_SIGN_ID" "$X87COOP"
  [[ -f "$X87SC" ]] && codesign --force --options runtime -s "$HXI_SIGN_ID" \
    --entitlements "$REPO/vendor/x87sidecar-entitlements.plist" "$X87SC"
  # Nested dylibs need the hardened runtime and a secure timestamp too, or the notary rejects
  # the whole bundle on this one file.
  [[ -f "$AUDIOFOLLOW" ]] && codesign --force --options runtime --timestamp -s "$HXI_SIGN_ID" "$AUDIOFOLLOW"
  codesign --force --options runtime -s "$HXI_SIGN_ID" "$APP"
else
  [[ -f "$X87SC" ]] && codesign --force -s - \
    --entitlements "$REPO/vendor/x87sidecar-entitlements.plist" "$X87SC" >/dev/null 2>&1 || true
  [[ -f "$AUDIOFOLLOW" ]] && codesign --force -s - "$AUDIOFOLLOW" >/dev/null 2>&1 || true
  codesign --force -s - "$APP" >/dev/null 2>&1 || true
fi

# Re-register with Launch Services. Replacing a bundle in place leaves the Dock and Finder
# showing the icon they cached for that path -- after a rebuild the app came up with the generic
# executable icon even though AppIcon.icns was present and complete.
touch "$APP"
LSREG=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
[[ -x "$LSREG" ]] && "$LSREG" -f "$APP" >/dev/null 2>&1 || true

echo "built $APP"
