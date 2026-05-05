#!/bin/bash
# Compiles HighlightAnything.swift into HighlightAnything.app.
# Requires macOS 14+ (uses ScreenCaptureKit's SCScreenshotManager).
set -e

APP_NAME="HighlightAnything"
DISPLAY_NAME="Highlight Anything"
BUNDLE_ID="local.highlightanything"
APP_DIR="${APP_NAME}.app"
SRC="HighlightAnything.swift"

if ! command -v swiftc >/dev/null 2>&1; then
  echo "ERROR: swiftc not found. Install Xcode Command Line Tools:"
  echo "       xcode-select --install"
  exit 1
fi

echo "==> Compiling ${SRC}..."
swiftc -O \
  -o "${APP_NAME}" \
  "${SRC}" \
  -framework Cocoa \
  -framework Vision \
  -framework ScreenCaptureKit

echo "==> Building ${APP_DIR}..."
rm -rf "${APP_DIR}"
mkdir -p "${APP_DIR}/Contents/MacOS"
mv "${APP_NAME}" "${APP_DIR}/Contents/MacOS/"

cat > "${APP_DIR}/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>${APP_NAME}</string>
  <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
  <key>CFBundleName</key><string>${DISPLAY_NAME}</string>
  <key>CFBundleDisplayName</key><string>${DISPLAY_NAME}</string>
  <key>CFBundleVersion</key><string>3.0</string>
  <key>CFBundleShortVersionString</key><string>3.0</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSUIElement</key><true/>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
</dict>
</plist>
EOF

echo "==> Code-signing (ad-hoc)..."
codesign --force --deep --sign - "${APP_DIR}" 2>/dev/null || true

echo
echo "Done. Launch with:"
echo "    open ${APP_DIR}"
echo
echo "First launch will prompt for Accessibility AND Screen Recording."
echo "Enable ${DISPLAY_NAME} in BOTH panes, then quit (📋 → Quit) and relaunch."
