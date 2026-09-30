#!/bin/bash
# Builds "GamePrint Companion.app" into ./dist (and optionally installs it).
#   scripts/build-app.sh            build + sign
#   scripts/build-app.sh --install  also copy to /Applications and relaunch
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${VERSION:-1.0.0}"
BUILD="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
APP="dist/GamePrint Companion.app"

swift build -c release --arch arm64 --arch x86_64 2>&1 | grep -v "deprecated" || true
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"
test -x "$BIN/GamePrintCompanion"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Library/LaunchAgents"
cp "$BIN/GamePrintCompanion" "$APP/Contents/MacOS/"
cp "$BIN/gpctl" "$APP/Contents/MacOS/"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" Resources/Info.plist > "$APP/Contents/Info.plist"
cp Resources/com.gameprint.companion.agent.plist "$APP/Contents/Library/LaunchAgents/"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/" && \
  /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP/Contents/Info.plist"

# Prefer a real signing identity (stable Keychain access across rebuilds);
# fall back to ad-hoc.
IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | grep -E 'Developer ID Application|Apple Development' | head -1 | sed -E 's/.*"(.*)".*/\1/' || true)}"
if [ -n "$IDENTITY" ]; then
  echo "Signing with: $IDENTITY"
  codesign --force --options runtime --timestamp=none -s "$IDENTITY" "$APP/Contents/MacOS/gpctl"
  codesign --force --options runtime --timestamp=none -s "$IDENTITY" "$APP"
else
  echo "Signing ad-hoc"
  codesign --force -s - "$APP/Contents/MacOS/gpctl"
  codesign --force -s - "$APP"
fi
codesign --verify --deep --strict "$APP"
echo "Built $APP ($VERSION build $BUILD)"

if [ "${1:-}" = "--install" ]; then
  pkill -x GamePrintCompanion 2>/dev/null && sleep 1 || true
  rm -rf "/Applications/GamePrint Companion.app"
  ditto "$APP" "/Applications/GamePrint Companion.app"
  xattr -dr com.apple.quarantine "/Applications/GamePrint Companion.app" 2>/dev/null || true
  open "/Applications/GamePrint Companion.app"
  echo "Installed to /Applications and launched"
fi
