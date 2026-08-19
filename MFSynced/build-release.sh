#!/bin/bash
# build-release.sh — signed, notarized, distributable MFSynced.app
#
# Output: dist/MFSynced-<version>.zip — runs on any Apple Silicon or Intel Mac
# (macOS 14+) with no Gatekeeper warnings.
#
# Requirements:
#   1. A "Developer ID Application" identity in the login keychain.
#      (Xcode → Settings → Accounts → Manage Certificates → + → Developer ID
#      Application; only the Apple Developer Account Holder can create one.)
#   2. Notary credentials, via environment or a gitignored .notary.env next
#      to this script:
#        ASC_KEY_ID=XXXXXXXXXX
#        ASC_ISSUER_ID=00000000-0000-0000-0000-000000000000
#        ASC_KEY_FILEPATH=~/.appstoreconnect/AuthKey_XXXXXXXXXX.p8
#
# Usage:
#   ./build-release.sh                  # build + sign + notarize + staple
#   ./build-release.sh --skip-notarize  # build + sign only (local testing)
#   VERSION=1.1 ./build-release.sh      # override CFBundleShortVersionString
#
# On the target Mac, after copying the app to /Applications, grant:
#   • Full Disk Access (reads the Messages database)  — System Settings
#   • Contacts + Automation (Messages) — prompted on first use
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DIST_DIR="$SCRIPT_DIR/dist"
APP_BUNDLE="$DIST_DIR/MFSynced.app"
BINARY_NAME="MFSynced"
BUNDLE_ID="tech.moonfive.MFSynced"
SKIP_NOTARIZE=0
[[ "${1:-}" == "--skip-notarize" ]] && SKIP_NOTARIZE=1

# --- credentials -------------------------------------------------------------
if [[ -f "$SCRIPT_DIR/.notary.env" ]]; then
  # shellcheck disable=SC1091
  source "$SCRIPT_DIR/.notary.env"
fi

IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
  | awk -F '"' '/Developer ID Application/ {print $2; exit}' || true)"
if [[ -z "$IDENTITY" ]]; then
  echo "ERROR: no 'Developer ID Application' identity in the keychain." >&2
  echo "Create one: Xcode → Settings → Accounts → Manage Certificates → +" >&2
  echo "(requires the Apple Developer Account Holder)." >&2
  exit 1
fi
echo "==> Signing identity: $IDENTITY"

if [[ $SKIP_NOTARIZE -eq 0 ]]; then
  for v in ASC_KEY_ID ASC_ISSUER_ID ASC_KEY_FILEPATH; do
    if [[ -z "${!v:-}" ]]; then
      echo "ERROR: $v is not set (env or $SCRIPT_DIR/.notary.env)." >&2
      exit 1
    fi
  done
  ASC_KEY_FILEPATH="${ASC_KEY_FILEPATH/#\~/$HOME}"
fi

# --- build (universal, release) ----------------------------------------------
echo "==> Building $BINARY_NAME (release, arm64 + x86_64)..."
cd "$SCRIPT_DIR"
swift build -c release --arch arm64 --arch x86_64
BIN_PATH="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"

# --- assemble ------------------------------------------------------------------
echo "==> Assembling .app bundle..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
cp "$BIN_PATH/$BINARY_NAME" "$APP_BUNDLE/Contents/MacOS/$BINARY_NAME"
cp "$SCRIPT_DIR/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
cp "$SCRIPT_DIR/Resources/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
if [[ -n "${VERSION:-}" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" \
    "$APP_BUNDLE/Contents/Info.plist"
fi
APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
  "$APP_BUNDLE/Contents/Info.plist")"

# --- sign ----------------------------------------------------------------------
echo "==> Code signing (Developer ID, hardened runtime)..."
codesign --force --timestamp --options runtime \
  --entitlements "$SCRIPT_DIR/entitlements-release.plist" \
  --identifier "$BUNDLE_ID" \
  --sign "$IDENTITY" \
  "$APP_BUNDLE"
codesign --verify --strict --verbose=2 "$APP_BUNDLE"

ZIP_PATH="$DIST_DIR/MFSynced-$APP_VERSION.zip"
rm -f "$ZIP_PATH"

if [[ $SKIP_NOTARIZE -eq 1 ]]; then
  ditto -c -k --keepParent "$APP_BUNDLE" "$ZIP_PATH"
  echo "✓ Built (NOT notarized): $ZIP_PATH"
  exit 0
fi

# --- notarize + staple ---------------------------------------------------------
echo "==> Submitting to Apple notary service (this can take a few minutes)..."
NOTARIZE_ZIP="$DIST_DIR/.notarize-upload.zip"
rm -f "$NOTARIZE_ZIP"
ditto -c -k --keepParent "$APP_BUNDLE" "$NOTARIZE_ZIP"
xcrun notarytool submit "$NOTARIZE_ZIP" \
  --key "$ASC_KEY_FILEPATH" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID" \
  --wait
rm -f "$NOTARIZE_ZIP"

echo "==> Stapling notarization ticket..."
xcrun stapler staple "$APP_BUNDLE"
xcrun stapler validate "$APP_BUNDLE"

# Final zip contains the stapled app, so it verifies offline on the target Mac.
ditto -c -k --keepParent "$APP_BUNDLE" "$ZIP_PATH"

echo "==> Gatekeeper assessment..."
spctl --assess --type execute --verbose=2 "$APP_BUNDLE"

echo ""
echo "✓ Distributable: $ZIP_PATH"
echo "  Install on any Mac: unzip, drag MFSynced.app to /Applications,"
echo "  then grant Full Disk Access in System Settings → Privacy & Security."
