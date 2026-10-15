#!/bin/zsh
# package.sh — build a distributable disk image of the launcher.
#
#   HXI_SIGN_ID=<Developer ID SHA-1> [HXI_NOTARY_PROFILE=batesai-notary] ./scripts/package.sh [output-dir]
#
# Needs the signing identity and a notarytool keychain profile, and clean, committed vanaguide and
# vanavoice checkouts beside this repo (their commits are recorded in Info.plist and printed).
#
# What ships in the .dmg:
#   FFXI-on-Mac.app   the launcher (preflight, repair, account, play, renderer)
#                          — the DXVK + d3d8to9 DLLs ride inside it, so the Metal
#                            renderer needs no separate download
#   START HERE.md          the non-technical setup guide
#   LICENSE.txt, Third-Party Notices.txt
#
# What does NOT ship, and why:
#   * The game client (15-30 GB, per world) — it is Square Enix's data and may not be
#     redistributed. The launcher fetches it with one *Download...* button per world.
#   * The Wine wrapper (~1GB+) — Sikarugir wine is LGPL 2.1 and may be redistributed, but doing
#     it properly means carrying the LGPL's source/relink obligations, so the launcher fetches
#     it from Sikarugir's own releases and assembles it on the user's Mac (*Install wine...*).
#
# So the ~9 MB image is the launcher, and the launcher gets the other two itself. Nothing here
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
# The app bundles Vanaguide and VanaVoice straight from the sibling checkouts, so a release is only
# reproducible from committed addon code. Refuse uncommitted or untracked changes in either.
VANAGUIDE_ROOT="${${HXI_VANAGUIDE_SOURCE:-$REPO/../vanaguide/Vanaguide}:h}"
VANAVOICE_ROOT="${${HXI_VANAVOICE_SOURCE:-$REPO/../vanavoice/addon/vanavoice}:h:h}"
for addon_root in "$VANAGUIDE_ROOT" "$VANAVOICE_ROOT"; do
  [[ -e "$addon_root/.git" ]] || { echo "release packaging needs a git checkout at $addon_root" >&2; exit 1; }
  if ! addon_state="$(/usr/bin/git -C "$addon_root" status --porcelain)" || [[ -n "$addon_state" ]]; then
    echo "release packaging refuses an addon checkout with uncommitted changes: $addon_root" >&2
    /usr/bin/git -C "$addon_root" status --short >&2 || true
    exit 1
  fi
done
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
BUILD="$(/usr/bin/plutil -extract CFBundleVersion raw "$APP/Contents/Info.plist")"
[[ -n "$VERSION" ]] || { echo "app has no version" >&2; exit 1; }
[[ "$BUILD" == <-> ]] || { echo "app has no numeric build (CFBundleVersion): $BUILD" >&2; exit 1; }
# bundle.sh records the addon commits in Info.plist (HXIAddonRevisions); they go in the notes.
VANAGUIDE_REV="$(/usr/bin/plutil -extract HXIAddonRevisions.Vanaguide raw "$APP/Contents/Info.plist")"
VANAVOICE_REV="$(/usr/bin/plutil -extract HXIAddonRevisions.VanaVoice raw "$APP/Contents/Info.plist")"
for rev in "$VANAGUIDE_REV" "$VANAVOICE_REV"; do
  [[ "$rev" =~ '^[0-9a-f]{40}$' ]] || { echo "app records no clean addon revision: $rev" >&2; exit 1; }
done
# The build rides in the asset name: the updater compares (version, build) and checks the
# staged app's CFBundleVersion against it (Updater.swift, UpdateRules.build(fromAssetName:)).
NAME="FFXI-on-Mac-$VERSION-b$BUILD.dmg"
DMG="$OUT/$NAME"
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
# Licences: ours, and every third-party text the app carries in one file (the same texts as
# Contents/Resources/ThirdPartyNotices, its README.txt index first).
cp "$REPO/LICENSE" "$STAGE/LICENSE.txt"
NOTICES="$APP/Contents/Resources/ThirdPartyNotices"
[[ -f "$NOTICES/README.txt" ]] || { echo "app carries no third-party notices: $NOTICES" >&2; exit 1; }
{
  cat "$NOTICES/README.txt"
  for notice in "$NOTICES"/*.txt(N); do
    [[ "${notice:t}" == README.txt ]] && continue
    print -r -- ""; print -r -- "==== ${notice:t:r} ===="; print -r -- ""
    cat "$notice"
  done
} > "$STAGE/Third-Party Notices.txt"

CANDIDATE="$WORK/$NAME"
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
FINAL_STAGE="$OUT/.$NAME.staging-$$"
ditto "$CANDIDATE" "$FINAL_STAGE"
mv "$FINAL_STAGE" "$DMG"
FINAL_STAGE=""
echo "built $DMG"
echo "for the release notes: Vanaguide $VANAGUIDE_REV, VanaVoice $VANAVOICE_REV"
