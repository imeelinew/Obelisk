#!/usr/bin/env bash
# Strict local signing verification for Obelisk (Keychain stability).
# Exit 0 only when Team, Bundle ID, codesign, and designated requirement match project.yml.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

EXPECTED_TEAM="${DEVELOPMENT_TEAM_ID:-5Q5QT76MJU}"
EXPECTED_BUNDLE_ID="local.elidev.Obelisk"
CONFIGURATION="${CONFIGURATION:-Debug}"
SCHEME="${SCHEME:-Obelisk}"
COMPARE_DR="${COMPARE_DR:-0}"

fail() {
  echo "verify-dev-signing: FAIL: $*" >&2
  exit 1
}

pass() {
  echo "verify-dev-signing: $*"
}

read_team_from_project_yml() {
  local team
  team="$(grep -E '^\s*DEVELOPMENT_TEAM:\s*[A-Z0-9]+$' project.yml | head -1 | awk '{print $2}')"
  if [[ -z "$team" ]]; then
    fail "could not read DEVELOPMENT_TEAM from project.yml"
  fi
  echo "$team"
}

YML_TEAM="$(read_team_from_project_yml)"
if [[ "$YML_TEAM" != "$EXPECTED_TEAM" ]]; then
  fail "project.yml DEVELOPMENT_TEAM=$YML_TEAM does not match EXPECTED_TEAM=$EXPECTED_TEAM"
fi
pass "project.yml team = $YML_TEAM"

if ! security find-identity -v -p codesigning 2>/dev/null | grep -q "(${EXPECTED_TEAM})"; then
  fail "no codesigning identity for team $EXPECTED_TEAM (run Xcode once to create Apple Development cert)"
fi
pass "codesigning identity exists for team $EXPECTED_TEAM"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "(7558SBX9GQ)"; then
  echo "verify-dev-signing: WARN: another team cert 7558SBX9GQ is present; do not use scripts without DEVELOPMENT_TEAM_ID=$EXPECTED_TEAM" >&2
fi

BUILD_SETTINGS="$(xcodebuild -scheme "$SCHEME" -configuration "$CONFIGURATION" -showBuildSettings 2>/dev/null || true)"
if [[ -z "$BUILD_SETTINGS" ]]; then
  fail "xcodebuild -showBuildSettings failed (open project in Xcode?)"
fi

xcode_team="$(echo "$BUILD_SETTINGS" | awk -F' = ' '/^[[:space:]]*DEVELOPMENT_TEAM = / {print $2; exit}')"
xcode_bundle="$(echo "$BUILD_SETTINGS" | awk -F' = ' '/^[[:space:]]*PRODUCT_BUNDLE_IDENTIFIER = / {print $2; exit}')"
xcode_identity="$(echo "$BUILD_SETTINGS" | awk -F' = ' '/^[[:space:]]*CODE_SIGN_IDENTITY = / {print $2; exit}')"

[[ "$xcode_team" == "$EXPECTED_TEAM" ]] || fail "xcodebuild DEVELOPMENT_TEAM=$xcode_team (expected $EXPECTED_TEAM)"
[[ "$xcode_bundle" == "$EXPECTED_BUNDLE_ID" ]] || fail "xcodebuild PRODUCT_BUNDLE_IDENTIFIER=$xcode_bundle"
[[ "$xcode_identity" != "-" ]] || fail "CODE_SIGN_IDENTITY is adhoc (-)"
pass "xcodebuild team/bundle/identity OK"

resolve_app_path() {
  if [[ -n "${1:-}" ]]; then
    echo "$1"
    return 0
  fi
  ls -dt "$HOME/Library/Developer/Xcode/DerivedData"/Obelisk-*/Build/Products/"$CONFIGURATION"/Obelisk.app 2>/dev/null | head -1
}

APP_PATH="$(resolve_app_path "${1:-}")"
if [[ -z "$APP_PATH" || ! -d "$APP_PATH" ]]; then
  fail "Obelisk.app not found; build first: xcodebuild -scheme $SCHEME -configuration $CONFIGURATION build"
fi
pass "app: $APP_PATH"

codesign --verify --deep --strict "$APP_PATH"

SIGN_INFO="$(codesign -dvvv "$APP_PATH" 2>&1)" || fail "codesign -dvvv failed"
echo "$SIGN_INFO" | grep -q "Identifier=$EXPECTED_BUNDLE_ID" || fail "missing Identifier=$EXPECTED_BUNDLE_ID"
echo "$SIGN_INFO" | grep -q "TeamIdentifier=$EXPECTED_TEAM" || fail "missing TeamIdentifier=$EXPECTED_TEAM"
echo "$SIGN_INFO" | grep -q 'Signature=adhoc' && fail "app is adhoc signed"
pass "codesign metadata OK"

if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
  echo "$CODESIGN_IDENTITY" | grep -q "$EXPECTED_TEAM" || fail "CODESIGN_IDENTITY does not include team $EXPECTED_TEAM"
  pass "CODESIGN_IDENTITY matches expected team"
fi

if [[ "$COMPARE_DR" == "1" ]]; then
  pass "running double clean build DR comparison (slow)..."
  xcodebuild -scheme "$SCHEME" -configuration "$CONFIGURATION" clean build -quiet
  DR1="$(codesign -d -r- "$APP_PATH" 2>&1)"
  APP_PATH="$(resolve_app_path "")"
  xcodebuild -scheme "$SCHEME" -configuration "$CONFIGURATION" clean build -quiet
  APP_PATH="$(resolve_app_path "")"
  DR2="$(codesign -d -r- "$APP_PATH" 2>&1)"
  [[ "$DR1" == "$DR2" ]] || fail "designated requirement changed across clean rebuilds"
  pass "designated requirement stable across clean rebuilds"
fi

pass "ALL CHECKS PASSED"
