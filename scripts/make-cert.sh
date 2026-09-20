#!/bin/sh
# Create a self-signed code-signing certificate "dictate-dev" in the login
# keychain so TCC grants (Microphone, Accessibility) survive rebuilds.
# No Apple developer account is involved. May prompt for your login password.
set -eu
NAME="${1:-dictate-dev}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
if security find-identity -v -p codesigning | grep -q "\"$NAME\""; then
  echo "identity '$NAME' already exists"; exit 0
fi
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -subj "/CN=$NAME" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning" \
  -addext "basicConstraints=critical,CA:false" 2>/dev/null
openssl pkcs12 -export -legacy -out "$TMP/id.p12" -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -passout pass:dictate 2>/dev/null \
  || openssl pkcs12 -export -out "$TMP/id.p12" -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -passout pass:dictate
security import "$TMP/id.p12" -k "$KEYCHAIN" -P dictate -T /usr/bin/codesign -T /usr/bin/security -T /usr/bin/productbuild
# Trust it for code signing (user trust settings; prompts for login password in a GUI session).
security add-trusted-cert -p codeSign -k "$KEYCHAIN" "$TMP/cert.pem"
security find-identity -v -p codesigning | grep "$NAME" || { echo "identity not usable yet" >&2; exit 1; }
echo "created '$NAME'"
