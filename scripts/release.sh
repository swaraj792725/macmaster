#!/bin/zsh
# Cuts a MacMaster release: bumps the version, commits, tags, builds the DMG and (optionally) publishes.
#
# Usage: scripts/release.sh <version> [--publish]
#   1. Add a "## [<version>] - YYYY-MM-DD" section to CHANGELOG.md first.
#   2. scripts/release.sh 0.3.0              # bump + commit + tag + DMG, prints the publish commands
#   3. scripts/release.sh 0.3.0 --publish    # same, then pushes and creates the GitHub Release
# The app's update checker reads GitHub's "latest release" (tag v<version>, .dmg asset).
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=${1:-}
PUBLISH=0
[[ "${2:-}" == "--publish" ]] && PUBLISH=1
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "usage: scripts/release.sh <x.y.z> [--publish]" >&2; exit 2; }
TAG="v$VERSION"

git diff --quiet && git diff --cached --quiet || { echo "error: commit or stash your changes first" >&2; exit 1; }
git rev-parse "$TAG" >/dev/null 2>&1 && { echo "error: tag $TAG already exists" >&2; exit 1; }
grep -q "^## \[$VERSION\]" CHANGELOG.md || { echo "error: CHANGELOG.md has no '## [$VERSION] - date' section" >&2; exit 1; }

# Release notes = that version's CHANGELOG section.
NOTES=build/release-notes-$VERSION.md
mkdir -p build
awk -v v="$VERSION" '$0 ~ "^## \\[" v "\\]" {on=1; next} /^## \[/ {on=0} on' CHANGELOG.md > "$NOTES"

PLIST=Resources/Info.plist
BUILD=$(( $(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" $PLIST) + 1 ))
CURRENT=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" $PLIST)
if [[ "$CURRENT" != "$VERSION" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" -c "Set :CFBundleVersion $BUILD" $PLIST
  git add $PLIST
  git commit -m "Release $TAG"
fi
git tag -a "$TAG" -m "MacMaster $VERSION"

scripts/make-dmg.sh
DMG=build/MacMaster-$VERSION.dmg

if [[ $PUBLISH == 1 ]]; then
  git push origin HEAD
  git push origin "$TAG"
  gh release create "$TAG" "$DMG" --title "MacMaster $VERSION" --notes-file "$NOTES"
else
  cat <<MSG

Release $TAG is ready locally ($DMG). To publish:
  git push origin HEAD && git push origin $TAG
  gh release create $TAG $DMG --title "MacMaster $VERSION" --notes-file $NOTES
MSG
fi
