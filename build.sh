#!/bin/bash
# Build SyncBrightness and assemble a runnable macOS .app bundle.
# Usage: ./build.sh
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="Monitor Brightness Sync"
EXEC_NAME="SyncBrightness"
BUNDLE_ID="com.rick.syncbrightness"
APP_DIR="build/${APP_NAME}.app"

echo "› Compiling (release)…"
swift build -c release

BIN_PATH="$(swift build -c release --show-bin-path)/${EXEC_NAME}"
if [[ ! -f "$BIN_PATH" ]]; then
  echo "✗ Built binary not found at $BIN_PATH" >&2
  exit 1
fi

# Build the app icon if it hasn't been generated yet.
if [[ ! -f "Resources/AppIcon.icns" ]]; then
  echo "› Generating app icon…"
  mkdir -p Resources
  ICONSET="$(mktemp -d)/AppIcon.iconset"
  swift tools/make-icon.swift "$ICONSET"
  iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
fi

echo "› Assembling ${APP_DIR}…"
rm -rf "$APP_DIR"
mkdir -p "${APP_DIR}/Contents/MacOS"
mkdir -p "${APP_DIR}/Contents/Resources"
cp "$BIN_PATH" "${APP_DIR}/Contents/MacOS/${EXEC_NAME}"
cp "Resources/AppIcon.icns" "${APP_DIR}/Contents/Resources/AppIcon.icns"

cat > "${APP_DIR}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>
  <string>${APP_NAME}</string>
  <key>CFBundleDisplayName</key>
  <string>${APP_NAME}</string>
  <key>CFBundleExecutable</key>
  <string>${EXEC_NAME}</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleIdentifier</key>
  <string>${BUNDLE_ID}</string>
  <key>CFBundleVersion</key>
  <string>1.0</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>LSUIElement</key>
  <true/>
</dict>
</plist>
PLIST

echo "› Code signing (ad-hoc)…"
codesign --force --sign - "${APP_DIR}" >/dev/null

echo "✓ Built ${APP_DIR}"
echo "  Run it with:  open \"${APP_DIR}\""
