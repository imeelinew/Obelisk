#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DIST_DIR="$ROOT_DIR/.build/dist"
APP_DIR="$DIST_DIR/Obelisk.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

VERSION="${VERSION:-1.3.2}"
BUILD="${BUILD:-$(date +%Y%m%d%H%M)}"

cd "$ROOT_DIR"

find_default_codesign_identity() {
  security find-identity -v -p codesigning \
    | awk -F '"' '/"Apple Development:/{ print $2; exit }'
}

# Try universal (arm64 + x86_64); requires full Xcode. Fall back to host arch
# (good enough for personal use) when only Command Line Tools are installed.
if swift build -c release --arch arm64 --arch x86_64 --product Obelisk 2>/dev/null; then
    BIN_DIR="$ROOT_DIR/.build/apple/Products/Release"
    echo "==> Built universal (arm64 + x86_64)"
else
    echo "==> Universal build unavailable (need full Xcode); building host arch only"
    swift build -c release --product Obelisk
    BIN_DIR="$ROOT_DIR/.build/release"
fi

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp "$BIN_DIR/Obelisk" "$MACOS_DIR/Obelisk"

# Compile the Icon Composer source. This keeps the app icon aligned with
# Apple's macOS 26 icon pipeline instead of flattening or re-drawing it here.
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" \
    xcrun actool \
    --compile "$RESOURCES_DIR" \
    --output-partial-info-plist "$CONTENTS_DIR/IconInfo.plist" \
    --platform macosx \
    --minimum-deployment-target 26.0 \
    --target-device mac \
    --app-icon Obelisk \
    "$ROOT_DIR/icon/Obelisk.icon" >/dev/null

ICONSET_DIR="$(mktemp -d)"
trap 'rm -rf "$ICONSET_DIR"' EXIT
iconutil -c iconset "$RESOURCES_DIR/Obelisk.icns" -o "$ICONSET_DIR/AppIcon.iconset"
cp "$ICONSET_DIR/AppIcon.iconset/icon_128x128@2x.png" "$RESOURCES_DIR/AppIcon.png"
cp "$ROOT_DIR/Sources/ObeliskMenu/Resources/PyramidSymbol.svg" "$RESOURCES_DIR/PyramidSymbol.svg"

# Strip debug symbols (saves a few MB; we don't ship a dSYM for personal use).
strip -S "$MACOS_DIR/Obelisk" 2>/dev/null || true

cat > "$CONTENTS_DIR/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>Obelisk</string>
  <key>CFBundleIconFile</key>
  <string>Obelisk</string>
  <key>CFBundleIconName</key>
  <string>Obelisk</string>
  <key>CFBundleIdentifier</key>
  <string>local.elidev.Obelisk</string>
  <key>CFBundleName</key>
  <string>Obelisk</string>
  <key>CFBundleDisplayName</key>
  <string>Obelisk</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$VERSION</string>
  <key>CFBundleVersion</key>
  <string>$BUILD</string>
  <key>LSMinimumSystemVersion</key>
  <string>26.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSAppleEventsUsageDescription</key>
  <string>Obelisk uses AppleScript to read the URL and title of the active tab from your frontmost browser when you press the global add-bookmark shortcut (⌥B).</string>
</dict>
</plist>
PLIST

# Prefer a stable Apple Development identity for local installs. This keeps the
# app's designated requirement stable across rebuilds, so Keychain prompts do
# not reset just because the binary hash changed.
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:-$(find_default_codesign_identity)}"
if [[ -n "$CODESIGN_IDENTITY" && "$CODESIGN_IDENTITY" != "-" ]]; then
  echo "==> Signing with: $CODESIGN_IDENTITY"
  codesign --force --deep --sign "$CODESIGN_IDENTITY" "$APP_DIR"
else
  echo "==> Signing ad-hoc"
  codesign --force --deep --sign - "$APP_DIR"
fi

# Verify
codesign --verify --deep --strict "$APP_DIR"

# Zip for portability.
ZIP_PATH="$DIST_DIR/Obelisk-$VERSION.zip"
rm -f "$ZIP_PATH"
ditto -c -k --keepParent "$APP_DIR" "$ZIP_PATH"

echo
echo "Built:   $APP_DIR"
echo "Zip:     $ZIP_PATH ($(du -h "$ZIP_PATH" | cut -f1))"
echo "Version: $VERSION ($BUILD)"
echo "Archs:   $(lipo -archs "$MACOS_DIR/Obelisk")"
