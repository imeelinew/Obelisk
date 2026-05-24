#!/usr/bin/env bash
# Secondary debug helper. Xcode Product -> Run is the normal development path.
# Re-signs a swift-build Obelisk binary with the pinned Team + bundle ID.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ENTITLEMENTS="$ROOT_DIR/Obelisk.entitlements"
BUNDLE_ID="local.elidev.Obelisk"
CONFIG="${1:-debug}"

# shellcheck source=scripts/codesign-identity.sh
source "$ROOT_DIR/scripts/codesign-identity.sh"

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

IDENTITY="${CODESIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
  IDENTITY="$(find_default_codesign_identity)"
fi
if [[ -z "$IDENTITY" || "$IDENTITY" == "-" ]]; then
  echo "No ${DEVELOPMENT_TEAM_ID} Apple Development signing identity found. Use Xcode Product -> Run once." >&2
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

verify_signed_code_identity "$BINARY"
echo "==> Done"
