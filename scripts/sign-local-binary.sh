#!/usr/bin/env bash
# Re-sign a swift-build Obelisk binary with a stable bundle ID + entitlements so
# Keychain items stay accessible across rebuilds (avoids 3x password prompts).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ENTITLEMENTS="$ROOT_DIR/Obelisk.entitlements"
BUNDLE_ID="local.elidev.Obelisk"
CONFIG="${1:-debug}"

DEVELOPMENT_TEAM_ID="${DEVELOPMENT_TEAM_ID:-5Q5QT76MJU}"

find_default_codesign_identity() {
  local team_pattern="(${DEVELOPMENT_TEAM_ID})"
  local match
  match="$(security find-identity -v -p codesigning \
    | awk -v team="$team_pattern" -F '"' '$0 ~ team { print $2; exit }')"
  if [[ -n "$match" ]]; then
    echo "$match"
    return 0
  fi
  echo "No Apple Development identity for team ${DEVELOPMENT_TEAM_ID}. Run Xcode Product → Run once." >&2
  return 1
}

find_binary() {
  local config="$1"
  local candidates=(
    "$ROOT_DIR/.build/arm64-apple-macosx/$config/Obelisk"
    "$ROOT_DIR/.build/$config/Obelisk"
    "$ROOT_DIR/.build/apple/Products/Release/Obelisk"
  )
  for path in "${candidates[@]}"; do
    if [[ -f "$path" ]]; then
      echo "$path"
      return 0
    fi
  done
  return 1
}

BINARY="$(find_binary "$CONFIG")" || {
  echo "No Obelisk binary found for config '$CONFIG'. Run: swift build -c $CONFIG --product Obelisk" >&2
  exit 1
}

IDENTITY="${CODESIGN_IDENTITY:-$(find_default_codesign_identity)}"
if [[ -z "$IDENTITY" ]]; then
  echo "No Apple Development signing identity found. Install one in Xcode or set CODESIGN_IDENTITY." >&2
  exit 1
fi

echo "==> Signing $BINARY"
echo "    Identity: $IDENTITY"
echo "    Bundle ID: $BUNDLE_ID"

/usr/bin/codesign --force --sign "$IDENTITY" \
  --identifier "$BUNDLE_ID" \
  --entitlements "$ENTITLEMENTS" \
  --options runtime \
  "$BINARY"

/usr/bin/codesign --verify --verbose=2 "$BINARY"
echo "==> Done"
