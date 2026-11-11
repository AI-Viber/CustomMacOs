#!/bin/bash
# Builds a signed, notarised CustomMacOS.app that other people can download and run,
# and zips it into dist/ ready to attach to a GitHub release.
#
# One-time setup (see "Publishing a release" in the README):
#   1. A "Developer ID Application" certificate in your keychain.
#   2. Notary credentials saved under a keychain profile:
#        xcrun notarytool store-credentials notary --apple-id YOU@EXAMPLE.COM --team-id TEAMID
#
# Optional overrides:
#   SIGN_ID="Developer ID Application: Your Name (TEAMID)"   which certificate to sign with
#   NOTARY_PROFILE=notary                                    keychain profile name
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="CustomMacOS"
NOTARY_PROFILE="${NOTARY_PROFILE:-notary}"
SIGN_ID="${SIGN_ID:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -n 1)}"

if [[ -z "$SIGN_ID" ]]; then
  echo "No \"Developer ID Application\" certificate found in your keychain."
  echo "Create one in Xcode → Settings → Accounts → Manage Certificates, then run this again."
  exit 1
fi
export SIGN_ID

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)"
echo "→ Building $APP_NAME $VERSION, signing as: $SIGN_ID"
./build.sh --release

# Work on a copy outside the project: iCloud-synced folders add attributes that break signatures.
WORK="$(mktemp -d "${TMPDIR:-/tmp}/CustomMacOS-release.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
APP="$WORK/$APP_NAME.app"
ditto --noextattr --norsrc "build/$APP_NAME.app" "$APP"
codesign --verify --strict --verbose=2 "$APP"

echo "→ Notarising with Apple (usually a few minutes)…"
ditto -c -k --keepParent "$APP" "$WORK/upload.zip"
xcrun notarytool submit "$WORK/upload.zip" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP"
spctl --assess --type execute --verbose=2 "$APP"

mkdir -p dist
OUT="dist/$APP_NAME-$VERSION.zip"
rm -f "$OUT"
ditto -c -k --keepParent --norsrc --noextattr "$APP" "$OUT"

echo "✓ $OUT is signed, notarised and ready to share."
echo "  Publish it with:  gh release create v$VERSION \"$OUT\" --title \"$APP_NAME $VERSION\" --generate-notes"
echo "  or attach it by hand at the repository's Releases page on GitHub."
