#!/bin/zsh
# publish-release.sh — check a packaged release, and publish it only when told to.
#
#   scripts/publish-release.sh <FFXI-on-Mac-X.Y-bN.dmg | folder holding exactly one .dmg>
#                              --notes <release-notes.md> [--legacy-dmg <v3.9 .dmg>] [--yes]
#
# Without --yes nothing is written anywhere: every check runs and the command that would publish
# is printed. With --yes, and only when every check passed, it runs `gh release create` (not a
# draft, not a prerelease) and then confirms that /releases/latest serves exactly this asset.
# Publishing is Daniel's call (RELEASE-WHEN-STABLE.md): at most weekly, only when stable.
#
# What is checked, and why:
#   * the name is FFXI-on-Mac-<version>-b<build>.dmg and the app inside says exactly that
#     version and build (the updater compares both, and checks the staged app against the name);
#   * the tag is v<version>, already pushed (gh --verify-tag), in the v1.2[.3] form the updater
#     accepts, with no release yet (a build-only release of the same version cannot have one);
#   * (version, build) is newer than the current latest release under the updater's own rule;
#   * the app satisfies the pinned requirement (Apple anchor, bundle id, team MG4YW8XX2Z) and
#     its TeamIdentifier is MG4YW8XX2Z; the app and the disk image are stapled and pass
#     Gatekeeper, so the updater's spctl check will accept them;
#   * the new launcher's own updater stages this exact image (--selftest-updater --dmg);
#   * the app's file list contains every file of v3.9's app. v3.9 clients update with the old
#     updater, which ditto-merges the new app over the old one: a file the new app dropped would
#     survive the merge, outside the new signature's seal.
set -uo pipefail

REPO_SLUG="danielalanbates/FFXI-on-Mac"
TEAM="MG4YW8XX2Z"
BUNDLE_ID="org.batesai.horizonxi-on-mac"
REQ="anchor apple generic and identifier \"$BUNDLE_ID\" and certificate leaf[subject.OU] = \"$TEAM\""
LEGACY_TAG="v3.9"

target="" notes="" legacy_dmg="" yes=0
while (( $# )); do
  case "$1" in
    # zsh's `shift 2` with one argument left shifts nothing, which would loop forever.
    --notes) (( $# >= 2 )) || { print -u2 -- "--notes needs a file"; exit 2; }; notes="$2"; shift 2 ;;
    --legacy-dmg) (( $# >= 2 )) || { print -u2 -- "--legacy-dmg needs a file"; exit 2; }; legacy_dmg="$2"; shift 2 ;;
    --yes) yes=1; shift ;;
    -h|--help) sed -n '2,25p' "$0"; exit 0 ;;
    *) [[ -z "$target" ]] || { print -u2 "unexpected argument: $1"; exit 2; }; target="$1"; shift ;;
  esac
done
[[ -n "$target" ]] || { print -u2 "usage: $0 <dmg or folder> --notes <file> [--legacy-dmg <file>] [--yes]"; exit 2; }

fails=0
ok()   { print "  ok   $*"; }
bad()  { print "  FAIL $*"; fails=$((fails + 1)); }
need() { if eval "$2" >/dev/null 2>&1; then ok "$1"; else bad "$1"; fi }

T="$(mktemp -d "$HOME/Downloads/FFXI-publish-check.XXXXXXXX")"
MNT="$T/mnt"
cleanup() {
  [[ -d "$MNT" ]] && /usr/bin/hdiutil detach "$MNT" -quiet -force >/dev/null 2>&1
  /bin/rm -rf "$T"
}
trap cleanup EXIT

# --- the artifact ---------------------------------------------------------------------------
print "artifact"
if [[ -d "$target" ]]; then
  dmgs=("$target"/*.dmg(N))
  if (( ${#dmgs} == 1 )); then ok "exactly one .dmg in $target"; DMG="${dmgs[1]}"
  else bad "exactly one .dmg in $target (found ${#dmgs})"; print "$fails check(s) failed"; exit 1; fi
else
  DMG="$target"
  need "exactly one .dmg to upload" "[[ -f '$DMG' && '$DMG' == *.dmg ]]"
fi
NAME="${DMG:t}"
if [[ "$NAME" =~ '^FFXI-on-Mac-([0-9]+(\.[0-9]+){1,2})-b([0-9]+)\.dmg$' ]]; then
  VERSION="${match[1]}" BUILD="${match[3]}"
  ok "asset name $NAME carries version $VERSION and build $BUILD"
else
  bad "asset name must be FFXI-on-Mac-<version>-b<build>.dmg (got $NAME)"
  print "$fails check(s) failed"; exit 1
fi
TAG="v$VERSION"
need "release notes given ($notes)" "[[ -s '$notes' ]]"

# --- the image and the app inside it ---------------------------------------------------------
print "disk image"
need "disk image is stapled" "/usr/bin/xcrun stapler validate '$DMG'"
need "disk image passes Gatekeeper" "/usr/sbin/spctl -a -t open --context context:primary-signature '$DMG'"
mkdir -p "$MNT"
if ! /usr/bin/hdiutil attach "$DMG" -nobrowse -readonly -noautoopen -mountpoint "$MNT" -quiet < /dev/null; then
  bad "disk image mounts"; print "$fails check(s) failed"; exit 1
fi
[[ -d "$MNT/FFXI-on-Mac.app" ]] || { bad "disk image holds FFXI-on-Mac.app"; print "$fails check(s) failed"; exit 1; }
/usr/bin/ditto "$MNT/FFXI-on-Mac.app" "$T/FFXI-on-Mac.app"
/usr/bin/hdiutil detach "$MNT" -quiet -force >/dev/null 2>&1 && rmdir "$MNT"
APP="$T/FFXI-on-Mac.app"
PL="$APP/Contents/Info.plist"

print "app"
need "bundle id is $BUNDLE_ID" "[[ \$(/usr/bin/plutil -extract CFBundleIdentifier raw '$PL') == '$BUNDLE_ID' ]]"
need "CFBundleShortVersionString is $VERSION (tag $TAG)" "[[ \$(/usr/bin/plutil -extract CFBundleShortVersionString raw '$PL') == '$VERSION' ]]"
need "CFBundleVersion is $BUILD" "[[ \$(/usr/bin/plutil -extract CFBundleVersion raw '$PL') == '$BUILD' ]]"
need "signature meets the updater's pinned requirement" "/usr/bin/codesign --verify --strict --deep -R '=$REQ' '$APP'"
team="$(/usr/bin/codesign -dv --verbose=2 "$APP" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
need "TeamIdentifier is $TEAM (got ${team:-none})" "[[ '$team' == '$TEAM' ]]"
need "app is stapled" "/usr/bin/xcrun stapler validate '$APP'"
need "app passes Gatekeeper (notarized)" "/usr/sbin/spctl -a -t execute '$APP'"
# Only a binary that has the test is run: an older one would not know the flag.
if /usr/bin/grep -q -- "--selftest-updater" "$APP/Contents/MacOS/FFXI-on-Mac"; then
  need "the new updater stages this image (--selftest-updater --dmg)" \
    "'$APP/Contents/MacOS/FFXI-on-Mac' --selftest-updater --dmg '$DMG' --tag '$TAG'"
else
  bad "the app has no --selftest-updater (built before 3.9 b59?)"
fi

# --- against what is published ---------------------------------------------------------------
print "GitHub"
vercmp() {
  local -a x y; x=(${(s:.:)1}); y=(${(s:.:)2})
  local i n=$(( ${#x} > ${#y} ? ${#x} : ${#y} ))
  for (( i = 1; i <= n; i++ )); do
    (( ${x[i]:-0} > ${y[i]:-0} )) && { print 1; return; }
    (( ${x[i]:-0} < ${y[i]:-0} )) && { print -- -1; return; }
  done
  print 0
}
# The updater's rule (UpdateRules.isOffered): newer short version, or the same one with a
# higher build when the asset names one. Against a latest release whose asset names no build
# (v3.9) only a newer short version counts: its build is unknown here.
offered() {
  local c; c=$(vercmp "$1" "$3")
  (( c > 0 )) && return 0
  (( c < 0 )) && return 1
  (( $4 > 0 && $2 > $4 ))
}
need "tag $TAG is in the form the updater accepts" "[[ '$TAG' =~ '^v[0-9]+(\.[0-9]+){1,2}$' ]]"
if ! command -v gh >/dev/null 2>&1; then
  bad "gh is installed (needed to compare with and publish to GitHub)"
else
  latest_json="$(gh api "repos/$REPO_SLUG/releases/latest" 2>/dev/null)"
  latest_tag="$(print -r -- "$latest_json" | /usr/bin/python3 -I -c 'import json,sys; print(json.load(sys.stdin)["tag_name"])' 2>/dev/null)"
  latest_asset="$(print -r -- "$latest_json" | /usr/bin/python3 -I -c 'import json,sys; print(next((a["name"] for a in json.load(sys.stdin)["assets"] if a["name"].lower().endswith(".dmg")), ""))' 2>/dev/null)"
  if [[ -z "$latest_tag" ]]; then
    bad "read the current latest release"
  else
    latest_version="${latest_tag#v}" latest_build=0
    [[ "$latest_asset" =~ '-b([0-9]+)\.dmg$' ]] && latest_build="${match[1]}"
    if offered "$VERSION" "$BUILD" "$latest_version" "$latest_build"; then
      ok "$VERSION b$BUILD is newer than the latest release $latest_tag ($latest_asset)"
    else
      bad "$VERSION b$BUILD is not newer than the latest release $latest_tag ($latest_asset)"
    fi
    if [[ "$(vercmp "$VERSION" "$latest_version")" != 1 ]]; then
      print "  note same short version as $latest_tag: v3.9 clients (short version only) will not see it"
    fi
  fi
  need "tag $TAG exists on GitHub (push it first; the release never invents one)" \
    "gh api 'repos/$REPO_SLUG/git/ref/tags/$TAG'"
  # The tag is always v<version>, so a second build of one version would pass every check
  # above and only fail at `gh release create`, against a tag on the earlier build's commit.
  need "no release exists yet for $TAG (each release needs a new short version)" \
    "! gh release view '$TAG' --repo '$REPO_SLUG'"
fi

# --- v3.9 clients' merge updater -------------------------------------------------------------
print "v3.9 merge updater"
if [[ -z "$legacy_dmg" ]] && command -v gh >/dev/null 2>&1; then
  mkdir -p "$T/legacy"
  if gh release download "$LEGACY_TAG" --repo "$REPO_SLUG" --pattern '*.dmg' --dir "$T/legacy" >/dev/null 2>&1; then
    legacy_dmg="$(print -r -- "$T"/legacy/*.dmg(N[1]))"
  fi
fi
if [[ -f "$legacy_dmg" ]]; then
  LMNT="$T/legacy-mnt"; mkdir -p "$LMNT"
  if /usr/bin/hdiutil attach "$legacy_dmg" -nobrowse -readonly -noautoopen -mountpoint "$LMNT" -quiet < /dev/null; then
    (cd "$LMNT/FFXI-on-Mac.app" && find . \( -type f -o -type l \) | LC_ALL=C sort) > "$T/legacy.files"
    /usr/bin/hdiutil detach "$LMNT" -quiet -force >/dev/null 2>&1
    (cd "$APP" && find . \( -type f -o -type l \) | LC_ALL=C sort) > "$T/new.files"
    missing="$(LC_ALL=C comm -23 "$T/legacy.files" "$T/new.files")"
    if [[ -z "$missing" ]]; then
      ok "every file of $LEGACY_TAG's app is in the new app ($(wc -l < "$T/legacy.files" | tr -d ' ') files)"
    else
      bad "the new app drops files $LEGACY_TAG had; a v3.9 client's merge would keep them unsealed:"
      print -r -- "$missing" | sed 's/^/         /'
    fi
  else
    bad "mount the $LEGACY_TAG disk image ($legacy_dmg)"
  fi
else
  print "  CHECK BY HAND: no $LEGACY_TAG disk image (pass --legacy-dmg). Every file in v3.9's"
  print "  FFXI-on-Mac.app must also exist in this one, or v3.9 clients' merge leaves it unsealed."
fi

# --- verdict ---------------------------------------------------------------------------------
print
if (( fails )); then
  print "$fails check(s) failed: not publishing."
  exit 1
fi
cmd=(gh release create "$TAG" "$DMG" --repo "$REPO_SLUG" --verify-tag --latest
     --title "FFXI on Mac $VERSION" --notes-file "$notes")
if (( ! yes )); then
  print "All checks passed. Nothing was published. To publish, rerun with --yes, which runs:"
  print -r -- "  ${(j: :)${(q-)cmd}}"
  exit 0
fi

print "publishing $TAG"
"${cmd[@]}" || { print -u2 "gh release create failed"; exit 1; }
sum="$(/usr/bin/shasum -a 256 "$DMG" | cut -d' ' -f1)"
for i in {1..10}; do
  got="$(gh api "repos/$REPO_SLUG/releases/latest" 2>/dev/null | /usr/bin/python3 -I -c '
import json, sys
r = json.load(sys.stdin)
dmgs = [a for a in r["assets"] if a["name"].lower().endswith(".dmg")]
print(r["tag_name"], r["draft"], r["prerelease"], len(dmgs), dmgs[0]["name"] if dmgs else "", (dmgs[0].get("digest") or "") if dmgs else "")
' 2>/dev/null)"
  [[ "$got" == "$TAG False False 1 $NAME "* ]] && break
  sleep 3
done
if [[ "$got" == "$TAG False False 1 $NAME "* ]]; then
  digest="${got##* }"
  if [[ -n "$digest" && "$digest" != "sha256:$sum" ]]; then
    print -u2 "published, but GitHub's digest ($digest) is not this file's (sha256:$sum)"; exit 1
  fi
  print "published: /releases/latest is $TAG with exactly one .dmg, $NAME"
else
  print -u2 "published, but /releases/latest does not show $TAG with exactly $NAME yet: $got"
  exit 1
fi
