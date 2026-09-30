#!/bin/bash
# Creates a self-signed code-signing certificate in its own keychain so that rebuilds
# keep the same signature, and macOS keeps Hop's Accessibility permission across builds.
# The keychain and its password are local only; nothing here is used for distribution.
set -euo pipefail
# Undo: security delete-keychain ~/Library/Keychains/hop-signing.keychain-db

KEYCHAIN="$HOME/Library/Keychains/hop-signing.keychain-db"
PASSWORD="hop-local-signing"
NAME="Hop Local Signing"

if [[ -f "$KEYCHAIN" ]]; then
    echo "Signing keychain already exists: $KEYCHAIN"
    exit 0
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/cert.conf" <<CONF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
CONF

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$TMP/cert.conf" \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null
openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$NAME" \
    -out "$TMP/identity.p12" -passout pass:"$PASSWORD" $(openssl version | grep -q '^OpenSSL 3' && echo -legacy)

security create-keychain -p "$PASSWORD" "$KEYCHAIN"
security set-keychain-settings "$KEYCHAIN" # never auto-lock
security unlock-keychain -p "$PASSWORD" "$KEYCHAIN"
security import "$TMP/identity.p12" -k "$KEYCHAIN" -P "$PASSWORD" -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$PASSWORD" "$KEYCHAIN" >/dev/null

# codesign only finds identities in keychains on the search list; keep the existing ones.
eval "security list-keychains -d user -s $(security list-keychains -d user | tr '\n' ' ') \"$KEYCHAIN\""

echo "Created \"$NAME\" in $KEYCHAIN"
echo "Rebuild with ./build.sh install, then grant Accessibility one last time."
