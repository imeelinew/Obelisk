#!/bin/sh
set -eu

script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
server_directory=$(dirname "$script_directory")
mkdir -p "$server_directory/secrets"
umask 077
openssl genpkey \
  -algorithm RSA \
  -pkeyopt rsa_keygen_bits:3072 \
  -out "$server_directory/secrets/jwt-private.pem"
echo "Created Server/secrets/jwt-private.pem"
