#!/usr/bin/env bash
# Build + stable-sign Obelisk for local development (Keychain won't re-prompt every compile).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${1:-debug}"

cd "$ROOT_DIR"
swift build -c "$CONFIG" --product Obelisk
"$ROOT_DIR/scripts/sign-local-binary.sh" "$CONFIG"

echo "Signed binary ready. Run: $ROOT_DIR/scripts/dev-run.sh $CONFIG"
