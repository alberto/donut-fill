#!/bin/bash
# Creates a self-signed code-signing identity ("Donut Fill Dev") in the login keychain.
# Signing every build with the same identity keeps macOS privacy permissions
# (Full Disk Access, Files & Folders) across rebuilds. Local use only: it can't
# be notarized or distributed. Safe to re-run; it does nothing if the identity exists.
set -euo pipefail

NAME="Donut Fill Dev"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
    echo "\"$NAME\" already exists in the login keychain."
    exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
PASS="$(openssl rand -hex 16)"

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -subj "/CN=$NAME" \
    -addext "basicConstraints=critical,CA:false" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null

# -legacy: the macOS keychain can't read PKCS#12 files using OpenSSL 3's default ciphers.
openssl pkcs12 -export -legacy -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
    -name "$NAME" -out "$WORK/identity.p12" -passout "pass:$PASS"

# -T lets codesign use the private key without prompting each time.
security import "$WORK/identity.p12" -k "$KEYCHAIN" -P "$PASS" -T /usr/bin/codesign

echo "Created \"$NAME\". scripts/build-app.sh will sign with it from now on."
