#!/bin/zsh
# Builds a distributable MacMaster DMG: build/MacMaster-<version>.dmg
#
# Usage: scripts/make-dmg.sh [--layout] [--no-build]
#
# Env:
#   MM_DMG_APP=/path/to/MacMaster.app   use this app and skip the build (same as --no-build with a path)
#   MM_DMG_LAYOUT=1                     (or --layout) arrange icons with Finder via AppleScript; needs a GUI
#                                       session and Automation permission for Finder. Optional.
#   MM_DMG_FORMAT=UDZO|ULFO             compression (default UDZO; ULFO is smaller but needs macOS 10.15+)
#   DEVELOPER_ID="Developer ID Application: Name (TEAMID)"   sign for distribution (hardened runtime)
#   NOTARY_PROFILE=<notarytool keychain profile>             with DEVELOPER_ID: notarize + staple
#   MM_SIGN_IDENTITY                    passed through to build-app.sh (default: local self-signed identity)
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD

LAYOUT=${MM_DMG_LAYOUT:-0}
NOBUILD=0
for arg in "$@"; do
  case $arg in
    --layout) LAYOUT=1 ;;
    --no-build) NOBUILD=1 ;;
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
    *) echo "Unknown option: $arg" >&2; exit 2 ;;
  esac
done

VOLNAME="MacMaster"
FORMAT=${MM_DMG_FORMAT:-UDZO}
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
DMG="build/MacMaster-$VERSION.dmg"

# 1. App to package ---------------------------------------------------------------------------
if [[ -n "${MM_DMG_APP:-}" ]]; then
  SRC_APP=$MM_DMG_APP
  echo "==> Using existing app (build skipped): $SRC_APP"
elif [[ $NOBUILD == 1 ]]; then
  SRC_APP=build/MacMaster.app
  echo "==> Using existing $SRC_APP (build skipped)"
else
  echo "==> Building MacMaster (release)"
  scripts/build-app.sh release
  SRC_APP=build/MacMaster.app
fi
[[ -d "$SRC_APP/Contents/MacOS" ]] || { echo "error: $SRC_APP is not an app bundle" >&2; exit 1; }

WORK=$(mktemp -d /tmp/macmaster-dmg.XXXXXX)
STAGE="$WORK/stage"
MOUNT_POINT=""
cleanup() {
  [[ -n "$MOUNT_POINT" ]] && hdiutil detach "$MOUNT_POINT" -force >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT

# 2. Stage: a copy of the app (never touch the original) + /Applications symlink -----------------
mkdir -p "$STAGE"
ditto --norsrc "$SRC_APP" "$STAGE/MacMaster.app"
ln -s /Applications "$STAGE/Applications"
xattr -cr "$STAGE/MacMaster.app" 2>/dev/null || true
APP="$STAGE/MacMaster.app"

# 3. Optional: Developer ID signing with hardened runtime ---------------------------------------
SIGNED=0
if [[ -n "${DEVELOPER_ID:-}" ]]; then
  echo "==> Signing app with hardened runtime: $DEVELOPER_ID"
  # Hardened runtime blocks these unless entitled. The app is NOT sandboxed.
  cat > "$WORK/entitlements.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.automation.apple-events</key><true/>
    <key>com.apple.security.device.bluetooth</key><true/>
    <key>com.apple.security.personal-information.location</key><true/>
</dict>
</plist>
PLIST
  codesign --force --options runtime --timestamp --entitlements "$WORK/entitlements.plist" \
    --identifier com.macmaster.app --sign "$DEVELOPER_ID" "$APP"
  codesign --verify --strict --verbose=2 "$APP"
  SIGNED=1
fi

# 4. Build the DMG -------------------------------------------------------------------------------
mkdir -p build
rm -f "$DMG"
if [[ $LAYOUT == 1 ]]; then
  echo "==> Creating DMG with Finder layout"
  RW="$WORK/rw.dmg"
  hdiutil create -srcfolder "$STAGE" -volname "$VOLNAME" -fs HFS+ -format UDRW -ov "$RW" >/dev/null
  hdiutil detach "/Volumes/$VOLNAME" -force >/dev/null 2>&1 || true
  ATTACH=$(hdiutil attach -readwrite -noverify -noautoopen "$RW")
  MOUNT_POINT=$(echo "$ATTACH" | grep -o '/Volumes/.*' | head -1)
  if ! osascript <<OSA
tell application "Finder"
  tell disk "$VOLNAME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, 740, 480}
    set opts to the icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 112
    set text size of opts to 13
    set position of item "MacMaster.app" of container window to {140, 170}
    set position of item "Applications" of container window to {400, 170}
    update without registering applications
    delay 1
    close
  end tell
end tell
OSA
  then
    echo "warning: Finder layout failed (Automation permission?). Continuing with the default layout." >&2
  fi
  sync
  hdiutil detach "$MOUNT_POINT" >/dev/null || hdiutil detach "$MOUNT_POINT" -force >/dev/null
  MOUNT_POINT=""
  hdiutil convert "$RW" -format "$FORMAT" -imagekey zlib-level=9 -o "$DMG" >/dev/null
else
  echo "==> Creating DMG"
  hdiutil create -srcfolder "$STAGE" -volname "$VOLNAME" -fs HFS+ -format "$FORMAT" -ov "$DMG" >/dev/null
fi

# 5. Optional: sign + notarize + staple the DMG ----------------------------------------------------
NOTARIZED=0
if [[ $SIGNED == 1 ]]; then
  echo "==> Signing DMG"
  codesign --force --timestamp --sign "$DEVELOPER_ID" "$DMG"
  if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    echo "==> Notarizing (this can take a few minutes)"
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
    xcrun stapler validate "$DMG"
    spctl --assess --type open --context context:primary-signature -v "$DMG" || true
    NOTARIZED=1
  fi
fi

SIZE=$(du -h "$DMG" | cut -f1)
echo
echo "Created $ROOT/$DMG ($SIZE)"
if [[ $NOTARIZED == 1 ]]; then
  echo "Signed with Developer ID, notarized and stapled. Ready to distribute."
else
  cat <<MSG

WARNING: this DMG is NOT notarized.
  Other Macs will show an "unidentified developer" / "cannot be opened" warning.
  Users must right-click MacMaster.app > Open (once), or run:
    xattr -dr com.apple.quarantine /Applications/MacMaster.app
  For public distribution set DEVELOPER_ID and NOTARY_PROFILE. See docs/RELEASE.md.
MSG
fi
