#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${1:-debug}"

cd "$ROOT_DIR"
swift build -c "$CONFIG" --product Obelisk
"$ROOT_DIR/scripts/sign-local-binary.sh" "$CONFIG"

BINARY="$ROOT_DIR/.build/arm64-apple-macosx/$CONFIG/Obelisk"
if [[ ! -f "$BINARY" ]]; then
  BINARY="$ROOT_DIR/.build/$CONFIG/Obelisk"
fi

exec "$BINARY"
