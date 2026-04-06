#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$SCRIPT_DIR/.build/arm64-apple-macosx/debug"
APP_BUNDLE="$SCRIPT_DIR/MFSynced.app"
BINARY_NAME="MFSynced"
BUNDLE_ID="tech.moonfive.MFSynced"

echo "==> Building $BINARY_NAME..."
cd "$SCRIPT_DIR"
swift build 2>&1

echo "==> Assembling .app bundle..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# Copy binary
cp "$BUILD_DIR/$BINARY_NAME" "$APP_BUNDLE/Contents/MacOS/$BINARY_NAME"

# Copy Info.plist
cp "$SCRIPT_DIR/Info.plist" "$APP_BUNDLE/Contents/Info.plist"

echo "==> Code signing (ad-hoc)..."
codesign \
  --force \
  --deep \
  --sign - \
  --entitlements "$SCRIPT_DIR/entitlements.plist" \
  --identifier "$BUNDLE_ID" \
  "$APP_BUNDLE"

echo "==> Verifying signature..."
codesign --verify --verbose "$APP_BUNDLE" 2>&1

echo ""
echo "✓ Built: $APP_BUNDLE"
echo ""
echo "To install: cp -r \"$APP_BUNDLE\" /Applications/"
echo "Or just run: open \"$APP_BUNDLE\""
