#!/bin/zsh
# Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
# https://batesai.org — help@batesai.org
# Explicit output only; no opening the app or starting screen capture.
set -euo pipefail
HERE="${0:A:h}"
REPO="${HERE:h}"
[[ -n "${1:-}" ]] || { print -u2 'usage: bundle-server-safe.sh <output-directory>'; exit 2; }
OUT="${1:A}"
APP="$OUT/VanaGuide Server-Safe.app"
SOURCE="${HXI_VANAGUIDE_SOURCE:-$REPO/../vanaguide/Vanaguide}"
SOURCE="${SOURCE:A}"
[[ -f "$SOURCE/data/quests.lua" && -f "$SOURCE/data/missions.lua" && -d "$SOURCE/guides" ]] || {
  print -u2 'Vanaguide guide data is missing'; exit 1
}
[[ "$APP" != "$SOURCE" && "$APP" != "$SOURCE"/* && "$SOURCE" != "$APP"/* ]] || {
  print -u2 'Guide source and output overlap'; exit 1
}
refuse_if_live() {
  # A same-identifier copy can own capture/TCC state even when its executable lives elsewhere.
  if [[ -e "$APP" ]] && /usr/bin/pgrep -f '/Contents/MacOS/VanaguideCompanion([[:space:]]|$)' >/dev/null 2>&1; then
    print -u2 'Quit Vanaguide Server-Safe before replacing its bundle.'; exit 1
  fi
}
refuse_if_live
BIN="${HXI_COMPANION_BINARY:-}"
if [[ -z "$BIN" ]]; then
  SCRATCH="${HXI_BUILD_DIR:-$HOME/Downloads/FFXI-on-Mac-build/swift-build}"
  (cd "$HERE"; swift build --build-system native -c release -j 1 --scratch-path "$SCRATCH" -Xswiftc -parse-as-library)
  BIN="$(cd "$HERE"; swift build --build-system native -c release --scratch-path "$SCRATCH" --show-bin-path)/VanaguideCompanion"
fi
[[ -x "$BIN" ]] || { print -u2 'VanaguideCompanion executable is missing'; exit 1; }
mkdir -p "$OUT"
STAGE="$OUT/.Vanaguide-Server-Safe.staging-$$"
BACKUP="$OUT/.Vanaguide-Server-Safe.previous-$$"
cleanup() {
  rm -rf "$STAGE"
  if [[ -e "$BACKUP" && ! -e "$APP" ]]; then mv "$BACKUP" "$APP"; fi
}
trap cleanup EXIT
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources/Vanaguide"
cp "$BIN" "$STAGE/Contents/MacOS/VanaguideCompanion"
# Only static Lua data, never settings, dialogue, screenshots, navgrids or account files.
for subdir in guides data; do
  mkdir -p "$STAGE/Contents/Resources/Vanaguide/$subdir"
  for file in "$SOURCE/$subdir/"*.lua(N); do
    cp "$file" "$STAGE/Contents/Resources/Vanaguide/$subdir/"
  done
done
# Per-server Gear and Skills, generated from each server's public source (data/servers/<key>/).
for dir in "$SOURCE/data/servers/"*(N/); do
  mkdir -p "$STAGE/Contents/Resources/Vanaguide/data/servers/${dir:t}"
  for file in "$dir"*.lua(N); do
    cp "$file" "$STAGE/Contents/Resources/Vanaguide/data/servers/${dir:t}/"
  done
done
cp "$REPO/LICENSE" "$STAGE/Contents/Resources/LICENSE"
[[ ! -f "${SOURCE:h}/LICENSE" ]] || cp "${SOURCE:h}/LICENSE" "$STAGE/Contents/Resources/Vanaguide/LICENSE"
# Its own icon, so the Dock and Cmd-Tab tell it apart from the launcher
# (tools/make-server-safe-icon.swift draws it).
if [[ -f "$HERE/ServerSafeIcon.icns" ]]; then
  cp "$HERE/ServerSafeIcon.icns" "$STAGE/Contents/Resources/AppIcon.icns"
elif [[ -f "$HERE/AppIcon.icns" ]]; then
  cp "$HERE/AppIcon.icns" "$STAGE/Contents/Resources/AppIcon.icns"
fi
VERSION="$(sed -n 's/^SHORT=//p' "$HERE/VERSION")"
BUILD="$(sed -n 's/^BUILD=//p' "$HERE/VERSION")"
cat > "$STAGE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>ALPHA VanaGuide Server-Safe</string>
<key>CFBundleDisplayName</key><string>ALPHA VanaGuide Server-Safe</string>
<key>CFBundleExecutable</key><string>VanaguideCompanion</string>
<key>CFBundleIdentifier</key><string>org.batesai.vanaguide-companion</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>CFBundleVersion</key><string>$BUILD</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>LSApplicationCategoryType</key><string>public.app-category.games</string>
<key>NSScreenCaptureUsageDescription</key><string>Read the selected FFXI window's chat region locally to find the matching guide.</string>
</dict></plist>
PLIST
plutil -lint "$STAGE/Contents/Info.plist"
find "$STAGE" -exec xattr -c {} \; 2>/dev/null || true
if [[ -n "${HXI_SIGN_ID:-}" ]]; then
  codesign --force --options runtime --timestamp -s "$HXI_SIGN_ID" "$STAGE"
else
  codesign --force -s - "$STAGE"
fi
codesign --verify --strict --deep "$STAGE"
refuse_if_live
[[ ! -e "$APP" ]] || mv "$APP" "$BACKUP"
mv "$STAGE" "$APP"
if [[ -e "$BACKUP" ]]; then
  ARCHIVE="${HXI_ARCHIVE_DIR:-$HOME/Downloads/FFXI-on-Mac-build/archive-apps}"
  mkdir -p "$ARCHIVE"
  mv "$BACKUP" "$ARCHIVE/Vanaguide-Server-Safe-$(date +%Y%m%d-%H%M%S)-$$.app"
fi
print -r -- "built $APP"
