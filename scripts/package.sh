#!/bin/zsh
# package.sh — build a distributable disk image of the launcher.
#
#   ./scripts/package.sh [output-dir]
#
# What ships in the .dmg:
#   FFXI-on-Mac.app   the launcher (preflight, repair, account, play, renderer)
#                          — the DXVK + d3d8to9 DLLs ride inside it, so the Metal
#                            renderer needs no separate download
#   START HERE.md          the non-technical setup guide
#
# What does NOT ship, and why:
#   * The game client (15-30 GB, per world) — it is Square Enix's data and may not be
#     redistributed. The launcher fetches it with one *Download...* button per world.
#   * The Wine wrapper (~1GB+) — Sikarugir wine is LGPL 2.1 and may be redistributed, but doing
#     it properly means carrying the LGPL's source/relink obligations, so the launcher fetches
#     it from Sikarugir's own releases and assembles it on the user's Mac (*Install wine...*).
#
# So the 5 MB image is the launcher, and the launcher gets the other two itself. Nothing here
# leaves the user at a Terminal prompt.
set -euo pipefail

HERE="${0:A:h}"
REPO="${HERE:h}"
OUT="${1:-$REPO/dist}"
if [[ -z "${HXI_SIGN_ID:-}" ]]; then
  echo "release packaging requires HXI_SIGN_ID; no unsigned disk image was created" >&2
  exit 1
fi
PROFILE="${HXI_NOTARY_PROFILE:-batesai-notary}"
# Keep every intermediate in Downloads. Only a verified disk image is moved into dist.
WORK="$(mktemp -d "$HOME/Downloads/FFXI-package.XXXXXXXX")"
FINAL_STAGE=""
cleanup() {
  rm -rf -- "$WORK"
  if [[ -n "$FINAL_STAGE" ]]; then rm -f -- "$FINAL_STAGE"; fi
}
trap cleanup EXIT
BUILDDIR="$WORK/build"
STAGE="$WORK/image"
"$REPO/app/bundle.sh" "$BUILDDIR" >/dev/null
APP="$BUILDDIR/FFXI-on-Mac.app"
VERSION="$(/usr/bin/plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist")"
[[ -n "$VERSION" ]] || { echo "app has no version" >&2; exit 1; }
DMG="$OUT/FFXI-on-Mac-$VERSION.dmg"
[[ ! -e "$DMG" ]] || { echo "release artifact already exists: $DMG" >&2; exit 1; }
mkdir -p "$OUT"

# Notarise and staple the .app BEFORE it goes into the image. Stapling the disk image alone is
# not enough: an app dragged out of it carries no ticket of its own, so the first launch has to
# ask Apple over the network and fails closed if the machine is offline.
echo "notarising the app (a few minutes)"
ditto -c -k --keepParent "$APP" "$WORK/app.zip"
xcrun notarytool submit "$WORK/app.zip" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
codesign --verify --strict --deep "$APP"
spctl -a -t execute -v "$APP"

mkdir -p "$STAGE"
ditto "$APP" "$STAGE/FFXI-on-Mac.app"
ln -s /Applications "$STAGE/Applications"
cp "$REPO/README.md"     "$STAGE/README.md"
cp "$REPO/docs/SETUP.md" "$STAGE/START HERE.md"

CANDIDATE="$WORK/FFXI-on-Mac-$VERSION.dmg"
hdiutil create -quiet -volname "FFXI on Mac" -srcfolder "$STAGE" -format UDZO "$CANDIDATE"
echo "signing the disk image"
codesign --force -s "$HXI_SIGN_ID" "$CANDIDATE"

echo "submitting to Apple's notary service (a few minutes)"
xcrun notarytool submit "$CANDIDATE" --keychain-profile "$PROFILE" --wait

xcrun stapler staple "$CANDIDATE"
xcrun stapler validate "$CANDIDATE"
codesign --verify "$CANDIDATE"
spctl -a -t open --context context:primary-signature -v "$CANDIDATE"

# Keep a failed or interrupted attempt from replacing the last known release image.
FINAL_STAGE="$OUT/.FFXI-on-Mac-$VERSION.dmg.staging-$$"
ditto "$CANDIDATE" "$FINAL_STAGE"
mv "$FINAL_STAGE" "$DMG"
FINAL_STAGE=""
echo "built $DMG"
