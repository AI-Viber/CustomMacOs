#!/bin/bash
# Builds CustomMacOS.app with the Xcode command-line tools (no Xcode project needed).
#   ./build.sh            build into ./build/CustomMacOS.app
#   ./build.sh --install  build, copy to /Applications and launch
# Optional: SIGN_ID="Your Certificate Name" ./build.sh  (a stable signing identity means
# macOS keeps the Accessibility permission across rebuilds; the default ad-hoc signature does not)
#
# The app is assembled in a temporary folder outside the project: if the project lives in
# an iCloud-synced folder (Documents, Desktop), iCloud attaches extended attributes that
# codesign rejects ("resource fork, Finder information, or similar detritus not allowed").
set -euo pipefail
cd "$(dirname "$0")"
PROJECT_DIR="$(pwd)"

APP_NAME="CustomMacOS"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/CustomMacOS-build.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
APP="$WORK/$APP_NAME.app"

if ! xcrun --find swiftc >/dev/null 2>&1; then
  echo "Swift compiler not found. Install the command-line tools with:  xcode-select --install"
  exit 1
fi

echo "→ Compiling…"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

for ARCH in arm64 x86_64; do
  xcrun --sdk macosx swiftc -O -swift-version 5 \
    -target "$ARCH-apple-macos13.0" \
    -o "$WORK/$APP_NAME-$ARCH" \
    Sources/*.swift
done
lipo -create -output "$APP/Contents/MacOS/$APP_NAME" "$WORK/$APP_NAME-arm64" "$WORK/$APP_NAME-x86_64"

cp Info.plist "$APP/Contents/Info.plist"
# Record where the project lives so the app can write its diagnostics logs here.
/usr/libexec/PlistBuddy -c "Add :CMOSProjectDir string $PROJECT_DIR" "$APP/Contents/Info.plist"

echo "→ Making icon…"
if xcrun --sdk macosx swiftc -O -o "$WORK/makeicon" Tools/MakeIcon.swift 2>/dev/null; then
  ICONSET="$WORK/AppIcon.iconset"
  mkdir -p "$ICONSET"
  "$WORK/makeicon" "$ICONSET"
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns" || true
fi

echo "→ Signing…"
xattr -cr "$APP"
codesign --force --sign "${SIGN_ID:--}" "$APP"

# Keep a copy in ./build for reference (not used for installing).
rm -rf build
mkdir -p build
ditto --noextattr --norsrc "$APP" "build/$APP_NAME.app"
echo "✓ Built $APP_NAME.app"

if [[ "${1:-}" == "--install" ]]; then
  osascript -e "quit app \"$APP_NAME\"" 2>/dev/null || true
  sleep 1
  rm -rf "/Applications/$APP_NAME.app"
  ditto --noextattr --norsrc "$APP" "/Applications/$APP_NAME.app"
  echo "✓ Installed to /Applications/$APP_NAME.app"
  open "/Applications/$APP_NAME.app"
fi
