#!/bin/zsh
# Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
# Input must already be Developer ID signed, notarized and stapled.
set -euo pipefail
[[ $# == 2 ]] || { print -u2 'usage: package-companion-dmg.sh <app> <new-output-directory>'; exit 2; }
APP="${1:A}"
OUT="${2:A}"
[[ ! -e "$OUT" ]] || { print -u2 'Output must be new'; exit 1; }
codesign --verify --strict --deep "$APP"
xcrun stapler validate "$APP"
spctl -a -t execute "$APP"
mkdir -p "$OUT/image"
ditto "$APP" "$OUT/image/VanaGuide Server-Safe.app"
ln -s /Applications "$OUT/image/Applications"
print 'VanaGuide (Beta): drag the app to Applications. Apple Silicon, macOS 14 or later. Help: help@batesai.org' > "$OUT/image/START HERE.txt"
hdiutil create -volname 'VanaGuide (Beta)' -srcfolder "$OUT/image" -format UDZO "$OUT/VanaGuide-macOS-Beta.dmg"
hdiutil verify "$OUT/VanaGuide-macOS-Beta.dmg"
