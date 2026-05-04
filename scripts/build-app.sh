#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DIST_DIR="$ROOT_DIR/.build/dist"
APP_DIR="$DIST_DIR/UniBookmark.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

VERSION="${VERSION:-1.0.0}"
BUILD="${BUILD:-$(date +%Y%m%d%H%M)}"

cd "$ROOT_DIR"

# Try universal (arm64 + x86_64); requires full Xcode. Fall back to host arch
# (good enough for personal use) when only Command Line Tools are installed.
if swift build -c release --arch arm64 --arch x86_64 --product UniBookmarkMenu 2>/dev/null; then
    BIN_DIR="$ROOT_DIR/.build/apple/Products/Release"
    echo "==> Built universal (arm64 + x86_64)"
else
    echo "==> Universal build unavailable (need full Xcode); building host arch only"
    swift build -c release --product UniBookmarkMenu
    BIN_DIR="$ROOT_DIR/.build/release"
fi

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp "$BIN_DIR/UniBookmarkMenu" "$MACOS_DIR/UniBookmark"

# Generate the app icon from the shared source artwork.
swift "$ROOT_DIR/scripts/make-icon.swift" "$RESOURCES_DIR" "$ROOT_DIR/Sources/UniBookmarkMenu/Resources/AppIcon.png" >/dev/null
cp "$ROOT_DIR/Sources/UniBookmarkMenu/Resources/AppIcon.png" "$RESOURCES_DIR/AppIcon.png"

# Strip debug symbols (saves a few MB; we don't ship a dSYM for personal use).
strip -S "$MACOS_DIR/UniBookmark" 2>/dev/null || true

cat > "$CONTENTS_DIR/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>UniBookmark</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleIdentifier</key>
  <string>local.elidev.UniBookmark</string>
  <key>CFBundleName</key>
  <string>UniBookmark</string>
  <key>CFBundleDisplayName</key>
  <string>UniBookmark</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$VERSION</string>
  <key>CFBundleVersion</key>
  <string>$BUILD</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSUserActivityTypes</key>
  <array>
    <string>com.apple.corespotlightitem</string>
  </array>
  <key>NSAppleEventsUsageDescription</key>
  <string>UniBookmark uses AppleScript to read the URL and title of the active tab from your frontmost browser when you press the global add-bookmark shortcut (⌥B).</string>
  <key>NSHumanReadableCopyright</key>
  <string>Personal build. No warranty.</string>
</dict>
</plist>
PLIST

# Ad-hoc sign so macOS Gatekeeper doesn't quarantine on first launch.
# Personal use only — for distribution to others you'd need a Developer ID.
codesign --force --deep --sign - "$APP_DIR"

# Verify
codesign --verify --deep --strict "$APP_DIR"

# Zip for portability.
ZIP_PATH="$DIST_DIR/UniBookmark-$VERSION.zip"
rm -f "$ZIP_PATH"
ditto -c -k --keepParent "$APP_DIR" "$ZIP_PATH"

echo
echo "Built:   $APP_DIR"
echo "Zip:     $ZIP_PATH ($(du -h "$ZIP_PATH" | cut -f1))"
echo "Version: $VERSION ($BUILD)"
echo "Archs:   $(lipo -archs "$MACOS_DIR/UniBookmark")"
