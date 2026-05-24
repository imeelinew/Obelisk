# Shared codesign identity lookup for local build scripts.
# shellcheck shell=bash

DEVELOPMENT_TEAM_ID="${DEVELOPMENT_TEAM_ID:-5Q5QT76MJU}"
EXPECTED_BUNDLE_ID="${EXPECTED_BUNDLE_ID:-local.elidev.Obelisk}"

find_default_codesign_identity() {
  local hash name cert subject

  while IFS=$'\t' read -r hash name; do
    [[ -n "$hash" && -n "$name" ]] || continue

    cert="$(security find-certificate -c "$name" -p 2>/dev/null || true)"
    [[ -n "$cert" ]] || continue

    subject="$(printf '%s\n' "$cert" | /usr/bin/openssl x509 -noout -subject 2>/dev/null || true)"
    if [[ "$subject" == *"OU = ${DEVELOPMENT_TEAM_ID}"* || "$subject" == *"OU=${DEVELOPMENT_TEAM_ID}"* ]]; then
      echo "$hash"
      return 0
    fi
  done < <(
    security find-identity -v -p codesigning 2>/dev/null \
      | awk -F '"' '/Apple Development:/ {
          gsub(/^[[:space:]]*[0-9]+\) /, "", $1)
          gsub(/[[:space:]]+$/, "", $1)
          print $1 "\t" $2
        }'
  )

  echo "==> No Apple Development identity for team ${DEVELOPMENT_TEAM_ID}. Open Obelisk in Xcode and run Product -> Run once." >&2
  return 1
}

verify_signed_code_identity() {
  local signed_path="$1"
  local sign_info

  codesign --verify --deep --strict "$signed_path"
  sign_info="$(codesign -dvvv "$signed_path" 2>&1)"

  echo "$sign_info" | grep -q "Identifier=${EXPECTED_BUNDLE_ID}" || {
    echo "==> Signed code missing Identifier=${EXPECTED_BUNDLE_ID}" >&2
    return 1
  }
  echo "$sign_info" | grep -q "TeamIdentifier=${DEVELOPMENT_TEAM_ID}" || {
    echo "==> Signed code missing TeamIdentifier=${DEVELOPMENT_TEAM_ID}" >&2
    return 1
  }
  if echo "$sign_info" | grep -q 'Signature=adhoc'; then
    echo "==> Signed code is adhoc; refusing unstable Keychain identity" >&2
    return 1
  fi
}
