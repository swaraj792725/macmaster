#!/bin/zsh
# Builds MacMaster.app into ./build. Usage: scripts/build-app.sh [debug|release] [--install] [--run]
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG=${1:-release}
[[ "$CONFIG" == --* ]] && CONFIG=release
export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk   # SDK 27 needs Xcode-only SwiftUI macro plugins

swift build -c "$CONFIG" --arch arm64
BIN=$(swift build -c "$CONFIG" --arch arm64 --show-bin-path)/MacMaster

APP=build/MacMaster.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/MacMaster"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp CHANGELOG.md "$APP/Contents/Resources/CHANGELOG.md"   # shown in the app's What's New window

# Prefer a stable local identity so macOS privacy grants (Accessibility, Screen Recording)
# survive rebuilds. Falls back to ad-hoc (grants must be re-approved after each build).
IDENTITY="${MM_SIGN_IDENTITY:-MacMaster Local Signing}"
if security find-certificate -c "$IDENTITY" >/dev/null 2>&1; then
  codesign --force --deep --sign "$IDENTITY" --identifier com.macmaster.app "$APP"
else
  codesign --force --deep --sign - --identifier com.macmaster.app "$APP"
fi
echo "Built $APP"

for arg in "$@"; do
  case $arg in
    --install)
      pkill -x MacMaster 2>/dev/null || true
      rm -rf /Applications/MacMaster.app
      # Move, not copy: a second MacMaster.app in ./build shows up twice in Spotlight, Launchpad and "Open With".
      LSREG=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
      "$LSREG" -u "$PWD/$APP" 2>/dev/null || true
      mv "$APP" /Applications/
      APP=/Applications/MacMaster.app
      "$LSREG" -f "$APP" 2>/dev/null || true
      echo "Installed to $APP" ;;
    --run)
      pkill -x MacMaster 2>/dev/null || true
      open "$APP" ;;
  esac
done
