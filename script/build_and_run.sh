#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="Obelisk"
BUNDLE_ID="com.eli.Obelisk"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA_DIR="$ROOT_DIR/.build/DerivedData"
APP_BUNDLE="$DERIVED_DATA_DIR/Build/Products/Debug/$APP_NAME.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"

case "$MODE" in
  run|--debug|debug|--logs|logs|--telemetry|telemetry|--verify|verify|--build|build) ;;
  *) echo "usage: $0 [run|--build|--debug|--logs|--telemetry|--verify]" >&2; exit 2 ;;
esac

xcodebuild \
  -project "$ROOT_DIR/Obelisk.xcodeproj" \
  -scheme "$APP_NAME" \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED_DATA_DIR" \
  build

"$ROOT_DIR/script/sign.sh" --app "$APP_BUNDLE" --output "$APP_BUNDLE"
codesign --verify --all-architectures --deep --strict "$APP_BUNDLE"
if [[ "$MODE" == --build || "$MODE" == build ]]; then
  exit 0
fi
pkill -x "$APP_NAME" >/dev/null 2>&1 || true

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    sleep 1
    pgrep -x "$APP_NAME" >/dev/null
    ;;
  *)
    echo "usage: $0 [run|--build|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
